import 'package:flutter/material.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../played_song_cache.dart';
import '../kugou/kugou_api_client.dart';
import '../kugou/kugou_auth.dart';
import '../kugou/kugou_models.dart';
import '../kugou/kugou_playback_service.dart';
import 'music_source.dart';

/// 酷狗音乐数据源。
///
/// 三家里最省事的一家：没有加密，只有一个 MD5 签名，而且取播放地址时会
/// 明确返回 status / error_code —— QQ 那边缺这个，才会出现「显示可播但
/// 全是死链」。所以这边 [prepareQueue] 筛出来的结果是可信的。
///
/// 免登录能用推荐、榜单和搜索；登录之后多两样：收藏（云端「我喜欢」）和
/// 云端歌单。会员曲的取址接口认 token + dfid，所以登录也直接提高可播率。
/// [isAvailable] 恒为 true —— 没登录只是少几块内容，不是不能用。
class KugouSource implements MusicSource {
  KugouSource._();

  static final KugouSource instance = KugouSource._();

  final KugouApiClient _api = KugouApiClient.instance;

  List<KugouPlaylist>? _rankCache;

  /// 云端歌单缓存。首页歌单区块和「我喜欢」都从这份里取，避免同一次加载
  /// 里把 get_all_list 请求两遍。
  List<KugouPlaylist>? _cloudCache;

  List<SongEntity>? _favoriteCache;

  Future<List<SongEntity>>? _songInflight;

  bool get isLoggedIn => KugouAuth.instance.isLoggedIn.value;

  /// 首页推荐缓存。必须缓存：点歌播放时会再拉一次完整列表当队列，两次拉到
  /// 的内容和顺序必须一致，否则「屏幕上点的那首」和「队列里那个下标」对不上。
  List<SongEntity>? _songCache;

  @override
  String get id => 'kugou';

  @override
  String get label => '酷狗音乐';

  @override
  IconData get icon => Icons.library_music_rounded;

  @override
  String get assetIcon => 'assets/source/kugou.png';

  @override
  Color get accent => const Color(0xFF2CA2F9);

  @override
  bool get isAvailable => true;

  @override
  String get unavailableHint => '';

  String? lastError;

  void reset() {
    _rankCache = null;
    _songCache = null;
    _cloudCache = null;
    _favoriteCache = null;
    _songInflight = null;
  }

  /// 云端歌单。没登录返回空，调用方据此不渲染。
  Future<List<KugouPlaylist>> _cloudPlaylists() async {
    if (!isLoggedIn) return const [];
    final cached = _cloudCache;
    if (cached != null) return cached;
    final lists = await _api.userPlaylists();
    _cloudCache = lists;
    return lists;
  }

  /// 「我喜欢」。酷狗把它当成一张普通的云端歌单，靠名字认。
  Future<List<SongEntity>> _favorites() async {
    if (!isLoggedIn) return const [];
    final cached = _favoriteCache;
    if (cached != null) return cached;
    final lists = await _cloudPlaylists();
    if (lists.isEmpty) return const [];
    final liked = lists.firstWhere(
      (p) => p.name.contains('我喜欢') || p.name.contains('喜欢的'),
      orElse: () => lists.first,
    );
    final songs = await _api.userPlaylistSongs(liked.id);
    final entities = [
      for (final s in songs) KugouPlaybackService.toSongEntity(s),
    ];
    _favoriteCache = entities;
    debugPrint('[KugouSource] 收藏 ${entities.length} 首（${liked.name}）');
    return entities;
  }

  Future<List<SongEntity>> _recommendedSongs() {
    final cached = _songCache;
    if (cached != null && cached.isNotEmpty) return Future.value(cached);
    // 首页一次加载里，hero、最新歌曲、歌曲页会同时问推荐 —— 缓存要等第一次
    // 回来才有，中间那几发就都真的打出去了（日志里表现为「推荐歌曲 60 首」
    // 一次加载打印三遍）。共用同一个 in-flight future。
    return _songInflight ??= _loadRecommended().whenComplete(() {
      _songInflight = null;
    });
  }

  Future<List<SongEntity>> _loadRecommended() async {
    final songs = await _api.recommendSongs(limit: 60);
    final entities = [
      for (final s in songs) KugouPlaybackService.toSongEntity(s),
    ];
    if (entities.isNotEmpty) _songCache = entities;
    debugPrint('[KugouSource] 推荐歌曲 ${entities.length} 首');
    return entities;
  }

  @override
  Future<SourceHero?> hero() => refreshHero();

  @override
  Future<SourceHero?> refreshHero() async {
    try {
      final songs = await _recommendedSongs();
      if (songs.isEmpty) return null;
      // 复制一份再打乱：直接 shuffle 会把缓存本体（也就是首页列表）搅了。
      final shuffled = [...songs]..shuffle();
      return SourceHero(song: shuffled.first, queue: shuffled, label: '热门推荐');
    } on KugouApiException catch (e) {
      lastError = '推荐读取失败：${e.message}';
      debugPrint('[KugouSource] hero error: ${e.message}');
      return null;
    }
  }

  @override
  Future<List<SongEntity>> feed(HomeFeed kind, {int limit = 10}) async {
    final all = await fullFeed(kind, limit: limit);
    return all.length <= limit ? all : all.sublist(0, limit);
  }

  @override
  Future<List<SongEntity>> fullFeed(HomeFeed kind, {required int limit}) async {
    try {
      switch (kind) {
        case HomeFeed.favorites:
          return await _favorites();
        case HomeFeed.recentPlayed:
          // 酷狗没有稳定可用的播放历史接口。与其猜一个，不如用本机播过的
          // 记录 —— 用户想在这块看到的本来就是「我刚才听的」。
          await PlayedSongCache.instance.ensureLoaded();
          return PlayedSongCache.instance.recent(
            limit: limit,
            idPrefix: SongSource.kugouPrefix,
          );
        case HomeFeed.latestSongs:
          return await _recommendedSongs();
      }
    } on KugouApiException catch (e) {
      lastError = '读取失败：${e.message}';
      debugPrint('[KugouSource] feed $kind error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) =>
      KugouPlaybackService.instance.prepareQueue(songs);

  @override
  Future<List<SongEntity>> search(String keyword, {int limit = 30}) async {
    try {
      final songs = await _api.searchSongs(keyword, limit: limit);
      return [for (final s in songs) KugouPlaybackService.toSongEntity(s)];
    } on KugouApiException catch (e) {
      lastError = '搜索失败：${e.message}';
      debugPrint('[KugouSource] search error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SourcePlaylist>> playlists({int limit = 10}) async {
    try {
      final cached = _rankCache;
      final ranks = (cached != null && cached.isNotEmpty)
          ? cached
          : await _api.rankList(limit: 20);
      if (ranks.isNotEmpty) _rankCache = ranks;
      // 登录了就把自己的歌单排前面 —— 那才是用户想点的。
      final lists = [...await _cloudPlaylists(), ...ranks];
      return [
        for (final p in lists.take(limit))
          SourcePlaylist(
            id: '$id:${p.id}',
            name: p.name,
            coverId: p.coverUrl,
            trackCount: p.trackCount,
          ),
      ];
    } on KugouApiException catch (e) {
      debugPrint('[KugouSource] playlists error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SongEntity>> playlistSongs(String playlistId) async {
    final raw = playlistId.startsWith('$id:')
        ? playlistId.substring(id.length + 1)
        : playlistId;
    final listId = int.tryParse(raw);
    if (listId == null) return const [];
    try {
      // 云端歌单和榜单是两套接口，按 id 在哪份缓存里出现来分。
      final cloud = _cloudCache ?? const <KugouPlaylist>[];
      final isCloud = cloud.any((p) => p.id == listId);
      final songs = isCloud
          ? await _api.userPlaylistSongs(listId)
          : await _api.rankSongs(listId, limit: 100);
      return [for (final s in songs) KugouPlaybackService.toSongEntity(s)];
    } on KugouApiException catch (e) {
      debugPrint('[KugouSource] playlistSongs error: ${e.message}');
      return const [];
    }
  }
}
