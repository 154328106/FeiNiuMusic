import 'package:flutter/material.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../played_song_cache.dart';
import '../qq/qq_api_client.dart';
import '../qq/qq_auth.dart';
import '../qq/qq_models.dart';
import '../qq/qq_playback_service.dart';
import 'music_source.dart';

/// QQ 音乐数据源。
///
/// 搜索、推荐歌单、榜单、取播放地址都走免登录接口，所以 [isAvailable]
/// 恒为 true —— 不登录也能用。
///
/// 登录之后额外多出「我的歌单」和「收藏（我喜欢）」。这两块 2026-09-11 才
/// 补上：QQ 当初是按纯免登录源做的，扫码登录是后加的，`fullFeed` 里这两个
/// 分支一直写死 `return const []`，所以登录了也什么都不显示。
class QQSource implements MusicSource {
  QQSource._();

  static final QQSource instance = QQSource._();

  final QQApiClient _api = QQApiClient.instance;

  /// 推荐歌单缓存。首页的大图、最新歌曲都从第一张推荐歌单里取，
  /// 每次各拉一遍纯属浪费。
  List<QQPlaylist>? _playlistCache;

  /// 登录用户自己的歌单缓存（含「我喜欢」）。
  List<QQPlaylist>? _cloudCache;

  /// 「我喜欢」歌曲缓存。
  List<SongEntity>? _favoriteCache;

  /// 首页推荐歌曲缓存。
  ///
  /// 必须缓存：点歌播放时会再拉一次完整列表当队列，两次拉到的内容和顺序
  /// 必须一致，否则「屏幕上点的那首」和「队列里那个下标」对不上。
  List<SongEntity>? _songCache;

  @override
  String get id => 'qq';

  @override
  String get label => '扣扣音乐';

  @override
  IconData get icon => Icons.music_note_rounded;

  @override
  String get assetIcon => 'assets/source/qq.png';

  @override
  Color get accent => const Color(0xFF31C27C);

  @override
  bool get isAvailable => true;

  @override
  String get unavailableHint => '';

  /// 最近一次失败原因，供首页在区块为空时给出可读提示。
  String? lastError;

  void reset() {
    _playlistCache = null;
    _songCache = null;
    _cloudCache = null;
    _favoriteCache = null;
  }

  Future<List<QQPlaylist>> _ensurePlaylists() async {
    final cached = _playlistCache;
    if (cached != null && cached.isNotEmpty) return cached;
    final lists = await _api.recommendPlaylists(limit: 12);
    // 空结果不进缓存：上一版缓存了空列表，之后每次都直接返回空，
    // 连一条日志都不打，排查时看不出是「拉过了但没有」还是「压根没拉」。
    if (lists.isNotEmpty) _playlistCache = lists;
    debugPrint('[QQSource] 推荐歌单 ${lists.length} 张');
    return lists;
  }

  /// 首页大图和「最新歌曲」的共同数据源。
  ///
  /// 用热歌 / 新歌 / 飙升三个公开榜拼出来。QQ 的「每日推荐」和推荐歌单那套
  /// musicu 模块实测返回是空的（多半要登录），榜单这条是纯 GET 的老接口，
  /// 免登录、字段稳。
  bool get _isLoggedIn => QQAuth.instance.isLoggedIn.value;

  Future<List<QQPlaylist>> _cloudPlaylists() async {
    if (!_isLoggedIn) return const [];
    final cached = _cloudCache;
    if (cached != null && cached.isNotEmpty) return cached;
    final lists = await _api.userPlaylists();
    // 空结果不进缓存，理由同 _ensurePlaylists：否则拉空一次就永远是空。
    if (lists.isNotEmpty) _cloudCache = lists;
    return lists;
  }

  /// 「我喜欢」。QQ 把它做成一张 dirid == 201 的特殊歌单，所以先取歌单列表
  /// 找到它，再按普通歌单拉内容。
  Future<List<SongEntity>> _favorites() async {
    if (!_isLoggedIn) return const [];
    final cached = _favoriteCache;
    if (cached != null && cached.isNotEmpty) return cached;
    final lists = await _cloudPlaylists();
    if (lists.isEmpty) return const [];
    final tid = _api.favoriteTid(lists);
    if (tid == null) {
      debugPrint('[QQSource] 歌单里没认出「我喜欢」，收藏留空');
      return const [];
    }
    final songs = await _api.playlistSongs(tid);
    final entities = [for (final s in songs) QQPlaybackService.toSongEntity(s)];
    debugPrint('[QQSource] 我喜欢 ${entities.length} 首（tid=$tid）');
    if (entities.isNotEmpty) _favoriteCache = entities;
    return entities;
  }

  Future<List<SongEntity>> _recommendedSongs() async {
    final cached = _songCache;
    if (cached != null && cached.isNotEmpty) return cached;
    final songs = await _api.recommendSongs(limit: 60);
    final entities = [for (final s in songs) QQPlaybackService.toSongEntity(s)];
    if (entities.isNotEmpty) _songCache = entities;
    debugPrint('[QQSource] 推荐歌曲 ${entities.length} 首');
    return entities;
  }

  @override
  Future<SourceHero?> hero() => refreshHero();

  @override
  Future<SourceHero?> refreshHero() async {
    try {
      final songs = await _recommendedSongs();
      if (songs.isEmpty) return null;
      // 每次换一首。注意不能直接 shuffle 那个 list —— 它是缓存本体，
      // 打乱它就等于把首页列表的顺序也搅了。复制一份再挑。
      final shuffled = [...songs]..shuffle();
      return SourceHero(song: shuffled.first, queue: shuffled, label: '每日推荐');
    } on QQApiException catch (e) {
      lastError = '推荐读取失败：${e.message}';
      debugPrint('[QQSource] hero error: ${e.message}');
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
          // QQ 的播放历史接口不稳，和酷狗那边一个处理：用本机播过的记录。
          // 用户想在这块看到的本来就是「我刚才听的」。
          await PlayedSongCache.instance.ensureLoaded();
          return PlayedSongCache.instance.recent(
            limit: limit,
            idPrefix: SongSource.qqPrefix,
          );
        case HomeFeed.latestSongs:
          return await _recommendedSongs();
      }
    } on QQApiException catch (e) {
      lastError = '读取失败：${e.message}';
      debugPrint('[QQSource] feed $kind error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) =>
      QQPlaybackService.instance.prepareQueue(songs);

  @override
  Future<List<SongEntity>> search(String keyword, {int limit = 30}) async {
    try {
      final songs = await _api.searchSongs(keyword, limit: limit);
      return [for (final s in songs) QQPlaybackService.toSongEntity(s)];
    } on QQApiException catch (e) {
      lastError = '搜索失败：${e.message}';
      debugPrint('[QQSource] search error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SourcePlaylist>> playlists({int limit = 10}) async {
    try {
      // 登录了就把**自己的歌单**排前面，推荐歌单往后补齐。原来这里只有推荐，
      // 所以登录之后「歌单」里看到的还是别人的。
      final mine = await _cloudPlaylists();
      final recommended = await _ensurePlaylists();
      final seen = <int>{for (final p in mine) p.id};
      final lists = [
        ...mine,
        for (final p in recommended)
          if (seen.add(p.id)) p,
      ];
      return [
        for (final p in lists.take(limit))
          SourcePlaylist(
            id: '$id:${p.id}',
            name: p.name,
            coverId: p.coverUrl,
            trackCount: p.trackCount,
          ),
      ];
    } on QQApiException catch (e) {
      debugPrint('[QQSource] playlists error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SongEntity>> playlistSongs(String playlistId) async {
    final raw = playlistId.startsWith('$id:')
        ? playlistId.substring(id.length + 1)
        : playlistId;
    final tid = int.tryParse(raw);
    if (tid == null) return const [];
    try {
      final songs = await _api.playlistSongs(tid);
      return [for (final s in songs) QQPlaybackService.toSongEntity(s)];
    } on QQApiException catch (e) {
      debugPrint('[QQSource] playlistSongs error: ${e.message}');
      return const [];
    }
  }
}
