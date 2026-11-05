import 'package:flutter/material.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../migu/migu_api_client.dart';
import '../migu/migu_models.dart';
import '../migu/migu_playback_service.dart';
import '../played_song_cache.dart';
import 'artist_cover_cache.dart';
import 'music_source.dart';

/// 咪咕音乐源（搜索 + 首页热门 + 歌手 + 播放 + 扫码登录）。
///
/// 搜索/封面直连咪咕（`search_all.do`，免签名、带真封面）；播放免登录走聚合/
/// LX 的 mg 后端，登录后额外尝试咪咕自家直连 VIP 地址（见 [MiguPlaybackService]）。
/// 首页用「热门歌手混合」充当推荐（咪咕官方榜接口解析复杂，MVP 先用搜索拼）。
class MiguSource implements MusicSource {
  MiguSource._();
  static final MiguSource instance = MiguSource._();

  final MiguApiClient _api = MiguApiClient.instance;

  String? lastError;

  List<SongEntity>? _hotCache;
  Future<List<SongEntity>>? _hotInflight;

  @override
  String get id => 'migu';

  @override
  String get label => '咪咕音乐';

  @override
  IconData get icon => Icons.library_music_rounded;

  @override
  String get assetIcon => 'assets/source/migu.png';

  @override
  Color get accent => const Color(0xFFE02020);

  @override
  bool get isAvailable => true;

  @override
  String get unavailableHint => '';

  Future<List<SongEntity>> _hot() {
    if (_hotCache != null) return Future.value(_hotCache);
    return _hotInflight ??= () async {
      try {
        final songs = await _hotMix();
        final mapped = [
          for (final s in songs) MiguPlaybackService.toSongEntity(s),
        ];
        if (mapped.isNotEmpty) _hotCache = mapped;
        return mapped;
      } catch (e) {
        debugPrint('[MiguSource] hot error: $e');
        return const <SongEntity>[];
      } finally {
        _hotInflight = null;
      }
    }();
  }

  /// 热门混合：一次搜多位热门歌手（每天轮换窗口），合并去重打乱，充当首页流。
  Future<List<MiguSong>> _hotMix() async {
    final day = DateTime.now().day;
    final picks = [
      for (var i = 0; i < 5; i++) _hotArtists[(day + i) % _hotArtists.length],
    ];
    final results = await Future.wait([
      for (final a in picks) _api.search(a, limit: 10),
    ]);
    final merged = <MiguSong>[];
    final seen = <String>{};
    for (final list in results) {
      for (final s in list) {
        if (seen.add(s.copyrightId)) merged.add(s);
      }
    }
    merged.shuffle();
    return merged.take(30).toList();
  }

  @override
  Future<SourceHero?> hero() => refreshHero();

  @override
  Future<SourceHero?> refreshHero() async {
    final songs = await _hot();
    if (songs.isEmpty) return null;
    final shuffled = [...songs]..shuffle();
    return SourceHero(song: shuffled.first, queue: shuffled, label: '咪咕热门');
  }

  @override
  Future<List<SongEntity>> feed(HomeFeed kind, {int limit = 10}) async {
    final all = await fullFeed(kind, limit: limit);
    return all.length <= limit ? all : all.sublist(0, limit);
  }

  @override
  Future<List<SongEntity>> fullFeed(HomeFeed kind, {required int limit}) async {
    switch (kind) {
      case HomeFeed.favorites:
        return const [];
      case HomeFeed.recentPlayed:
        await PlayedSongCache.instance.ensureLoaded();
        return PlayedSongCache.instance.recent(
          limit: limit,
          idPrefix: SongSource.miguPrefix,
        );
      case HomeFeed.latestSongs:
        return _hot();
    }
  }

  /// 歌单广场（首页「歌单」入口）。id 形如 mgp:<歌单 id>。
  @override
  Future<List<SourcePlaylist>> playlists({int limit = 10}) async {
    final list = await _api.plazaPlaylists();
    return [
      for (final p in list.take(limit))
        SourcePlaylist(id: 'mgp:${p.id}', name: p.name, coverId: p.pic),
    ];
  }

  /// 官方目录之外、实测也能拿歌的榜（2026-11-05 逐个试 columnId 试出来的）。
  static const List<({String id, String name})> _extraCharts = [
    (id: '23189399', name: '内地榜'),
    (id: '23189800', name: '港台榜'),
    (id: '76557036', name: '彩铃分贝榜'),
  ];

  /// 官方目录拿不到时的兜底（目录里的 9 个 + 上面 3 个）。
  static const List<({String id, String name})> _fallbackCharts = [
    (id: '83048887', name: '全网热歌榜'),
    (id: '83049014', name: '抖音热歌榜'),
    (id: '83048867', name: '免费热歌榜'),
    (id: '83049056', name: '收藏人气榜'),
    (id: '76557745', name: '会员臻爱榜'),
    (id: '83176390', name: '国风热歌榜'),
    (id: '27553319', name: '尖叫新歌榜'),
    (id: '27186466', name: '尖叫热歌榜'),
    (id: '27553408', name: '尖叫原创榜'),
  ];

  /// 咪咕排行榜（首页「排行榜」入口）：官方榜单目录（带封面）+ 3 个目录外的榜，
  /// 原来只有尖叫三榜。目录外的榜没封面，取榜里第一首歌的封面。
  Future<List<SourcePlaylist>> toplists({int limit = 10}) async {
    final catalog = await _api.rankCatalog();
    final base = catalog.isNotEmpty
        ? catalog
        : [
            for (final c in _fallbackCharts)
              (id: c.id, name: c.name, pic: null),
          ];
    final ids = {for (final c in base) c.id};
    final extras = [
      for (final c in _extraCharts)
        if (!ids.contains(c.id)) c,
    ];
    final needCover = [
      for (final c in [
        ...base,
        ...extras.map((e) => (id: e.id, name: e.name, pic: null)),
      ])
        if (c.pic == null) c.id,
    ];
    final firsts = await Future.wait([
      for (final id in needCover) _api.chart(id, limit: 1),
    ]);
    final coverOf = <String, String?>{
      for (var i = 0; i < needCover.length; i++)
        needCover[i]: firsts[i].isNotEmpty ? firsts[i].first.coverUrl : null,
    };
    return [
      for (final c in base)
        SourcePlaylist(
          id: 'mgt:${c.id}',
          name: c.name,
          coverId: c.pic ?? coverOf[c.id],
        ),
      for (final c in extras)
        SourcePlaylist(id: 'mgt:${c.id}', name: c.name, coverId: coverOf[c.id]),
    ];
  }

  /// 热门歌手（首页「歌手」入口）。点进去是该歌手的歌（搜索，带封面）。
  static const List<String> _hotArtists = [
    '周杰伦',
    '林俊杰',
    '邓紫棋',
    '薛之谦',
    '陈奕迅',
    '毛不易',
    '李荣浩',
    '张学友',
    '王菲',
    '李健',
    '赵雷',
    '陈粒',
    '周深',
    '张杰',
    '汪苏泷',
    '许嵩',
    '李宇春',
    '华晨宇',
    '邓丽君',
    '刘德华',
  ];

  // 歌手名 → 头像，存本地；第一次最多等 1.2 秒，剩下的后台补（见 ArtistCoverCache）。
  late final ArtistCoverCache _artistCovers = ArtistCoverCache(
    'migu.artistCovers.v1',
    _firstCover,
  );

  Future<String?> _firstCover(String name) async {
    try {
      final s = await _api.search(name, limit: 5);
      for (final song in s) {
        if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
          return song.coverUrl;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<SourcePlaylist>> artists({int limit = 30}) async {
    final covers = await _artistCovers.covers(_hotArtists);
    return [
      for (final a in _hotArtists)
        SourcePlaylist(id: 'mga:$a', name: a, coverId: covers[a]),
    ];
  }

  @override
  Future<List<SongEntity>> playlistSongs(String playlistId) async {
    // 歌手条目：id 形如 mga:<歌手名>，点进去搜该歌手的歌。
    if (playlistId.startsWith('mga:')) {
      final name = playlistId.substring(4);
      try {
        final songs = await _api.search(name, limit: 50);
        return [for (final s in songs) MiguPlaybackService.toSongEntity(s)];
      } catch (e) {
        debugPrint('[MiguSource] artist songs error: $e');
        return const [];
      }
    }
    // 榜单条目：id 形如 mgt:<columnId>。
    if (playlistId.startsWith('mgt:')) {
      final columnId = playlistId.substring(4);
      try {
        final songs = await _api.chart(columnId, limit: 100);
        return [for (final s in songs) MiguPlaybackService.toSongEntity(s)];
      } catch (e) {
        debugPrint('[MiguSource] chart songs error: $e');
        return const [];
      }
    }
    // 歌单条目：id 形如 mgp:<歌单 id>。
    if (playlistId.startsWith('mgp:')) {
      final songs = await _api.playlistSongs(playlistId.substring(4));
      return [for (final s in songs) MiguPlaybackService.toSongEntity(s)];
    }
    return const [];
  }

  @override
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) =>
      MiguPlaybackService.instance.prepareQueue(songs);

  @override
  Future<List<SongEntity>> search(String keyword, {int limit = 30}) async {
    try {
      final songs = await _api.search(keyword, limit: limit);
      return [for (final s in songs) MiguPlaybackService.toSongEntity(s)];
    } catch (e) {
      lastError = '搜索失败：$e';
      debugPrint('[MiguSource] search error: $e');
      return const [];
    }
  }

  /// 换源 / 登录态变化后清掉缓存，让首页重新拉。
  void reset() {
    _hotCache = null;
    _hotInflight = null;
  }
}
