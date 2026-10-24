import 'package:flutter/material.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../migu/migu_api_client.dart';
import '../migu/migu_models.dart';
import '../migu/migu_playback_service.dart';
import '../played_song_cache.dart';
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
    final picks = [for (var i = 0; i < 5; i++) _hotArtists[(day + i) % _hotArtists.length]];
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

  @override
  Future<List<SourcePlaylist>> playlists({int limit = 10}) async => const [];

  /// 咪咕排行榜（首页「排行榜」入口）。columnId 实测可用的三个尖叫榜。
  static const List<({String id, String name})> _charts = [
    (id: '27186466', name: '尖叫热歌榜'),
    (id: '27553319', name: '尖叫新歌榜'),
    (id: '27553408', name: '尖叫原创榜'),
  ];

  /// 榜单封面取各榜第一首歌的封面。
  Future<List<SourcePlaylist>> toplists({int limit = 10}) async {
    final covers = await Future.wait([
      for (final c in _charts) _api.chart(c.id, limit: 1),
    ]);
    return [
      for (var i = 0; i < _charts.length; i++)
        SourcePlaylist(
          id: 'mgt:${_charts[i].id}',
          name: _charts[i].name,
          coverId: covers[i].isNotEmpty ? covers[i].first.coverUrl : null,
        ),
    ];
  }

  /// 热门歌手（首页「歌手」入口）。点进去是该歌手的歌（搜索，带封面）。
  static const List<String> _hotArtists = [
    '周杰伦', '林俊杰', '邓紫棋', '薛之谦', '陈奕迅', '毛不易',
    '李荣浩', '张学友', '王菲', '李健', '赵雷', '陈粒',
    '周深', '张杰', '汪苏泷', '许嵩', '李宇春', '华晨宇',
    '邓丽君', '刘德华',
  ];

  // 歌手名 → 已拿到的封面。只存非空：找到的不会再丢。
  static final Map<String, String> _artistCoverCache = {};

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
    final missing = [
      for (final a in _hotArtists)
        if (!_artistCoverCache.containsKey(a)) a,
    ];
    // 限并发：每批 4 个，避免并发过多被限流。配合缓存，封面只会越补越全。
    for (var i = 0; i < missing.length; i += 4) {
      final batch = missing.skip(i).take(4).toList();
      final covers = await Future.wait([for (final a in batch) _firstCover(a)]);
      for (var j = 0; j < batch.length; j++) {
        final c = covers[j];
        if (c != null && c.isNotEmpty) _artistCoverCache[batch[j]] = c;
      }
    }
    return [
      for (final a in _hotArtists)
        SourcePlaylist(id: 'mga:$a', name: a, coverId: _artistCoverCache[a]),
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
