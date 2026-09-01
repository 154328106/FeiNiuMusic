import 'package:flutter/material.dart';

import '../../state/song_state.dart';
import '../qq/qq_api_client.dart';
import '../qq/qq_models.dart';
import '../qq/qq_playback_service.dart';
import 'music_source.dart';

/// QQ 音乐数据源。
///
/// 和网易云的关键差别：这边**完全不需要登录**。搜索、推荐歌单、歌单内容、
/// 取播放地址走的都是免登录接口，所以 [isAvailable] 恒为 true，也没有
/// 「收藏 / 最近播放」这种账号维度的区块 —— 那两条留空，首页会自动不显示。
class QQSource implements MusicSource {
  QQSource._();

  static final QQSource instance = QQSource._();

  final QQApiClient _api = QQApiClient.instance;

  /// 推荐歌单缓存。首页的大图、最新歌曲都从第一张推荐歌单里取，
  /// 每次各拉一遍纯属浪费。
  List<QQPlaylist>? _playlistCache;

  @override
  String get id => 'qq';

  @override
  String get label => 'QQ 音乐';

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

  void reset() => _playlistCache = null;

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
  Future<List<SongEntity>> _recommendedSongs() async {
    final songs = await _api.recommendSongs(limit: 60);
    debugPrint('[QQSource] 推荐歌曲 ${songs.length} 首');
    return [for (final s in songs) QQPlaybackService.toSongEntity(s)];
  }

  @override
  Future<SourceHero?> hero() => refreshHero();

  @override
  Future<SourceHero?> refreshHero() async {
    try {
      final songs = await _recommendedSongs();
      if (songs.isEmpty) return null;
      // 每次换一首：列表本身不变，随机取一首当大图，行为上贴近漫游。
      songs.shuffle();
      return SourceHero(song: songs.first, queue: songs, label: '每日推荐');
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
        case HomeFeed.recentPlayed:
          // 都要登录才有，先留空。首页对空区块本来就不渲染。
          return const [];
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
      final lists = await _ensurePlaylists();
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
