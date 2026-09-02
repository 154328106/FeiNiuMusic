import 'package:flutter/material.dart';

import '../../state/song_state.dart';
import '../kugou/kugou_api_client.dart';
import '../kugou/kugou_models.dart';
import '../kugou/kugou_playback_service.dart';
import 'music_source.dart';

/// 酷狗音乐数据源。
///
/// 三家里最省事的一家：没有加密，只有一个 MD5 签名，而且取播放地址时会
/// 明确返回 status / error_code —— QQ 那边缺这个，才会出现「显示可播但
/// 全是死链」。所以这边 [prepareQueue] 筛出来的结果是可信的。
///
/// 全程免登录，[isAvailable] 恒为 true；收藏 / 最近播放是账号维度的，留空。
class KugouSource implements MusicSource {
  KugouSource._();

  static final KugouSource instance = KugouSource._();

  final KugouApiClient _api = KugouApiClient.instance;

  List<KugouPlaylist>? _rankCache;

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
  }

  Future<List<SongEntity>> _recommendedSongs() async {
    final cached = _songCache;
    if (cached != null && cached.isNotEmpty) return cached;
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
        case HomeFeed.recentPlayed:
          // 账号维度的数据，免登录拿不到。首页对空区块本来就不渲染。
          return const [];
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
      final lists = (cached != null && cached.isNotEmpty)
          ? cached
          : await _api.rankList(limit: 20);
      if (lists.isNotEmpty) _rankCache = lists;
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
    final rankId = int.tryParse(raw);
    if (rankId == null) return const [];
    try {
      final songs = await _api.rankSongs(rankId, limit: 100);
      return [for (final s in songs) KugouPlaybackService.toSongEntity(s)];
    } on KugouApiException catch (e) {
      debugPrint('[KugouSource] playlistSongs error: ${e.message}');
      return const [];
    }
  }
}
