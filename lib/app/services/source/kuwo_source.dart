import 'package:flutter/material.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../kuwo/kuwo_api_client.dart';
import '../kuwo/kuwo_playback_service.dart';
import '../played_song_cache.dart';
import 'music_source.dart';

/// 酷我音乐源（MVP：搜索 + 榜单 + 播放）。
///
/// 无需登录即可用（公开搜索/榜单接口）。首页流用「飙升榜」充当推荐；播放地址
/// 由 [KuwoPlaybackService] 解析（海棠 / 解灰 / antiserver）。歌单、登录（会员
/// 高音质）留待后续。
class KuwoSource implements MusicSource {
  KuwoSource._();
  static final KuwoSource instance = KuwoSource._();

  final KuwoApiClient _api = KuwoApiClient.instance;

  String? lastError;

  // 榜单缓存：首页一次加载里 hero / 最新歌曲 / 歌曲页会同时问，合并成一次。
  List<SongEntity>? _rankCache;
  Future<List<SongEntity>>? _rankInflight;

  @override
  String get id => 'kuwo';

  @override
  String get label => '酷我音乐';

  @override
  IconData get icon => Icons.library_music_rounded;

  @override
  String get assetIcon => 'assets/source/kuwo.png';

  @override
  Color get accent => const Color(0xFFFF8A00);

  @override
  bool get isAvailable => true;

  @override
  String get unavailableHint => '';

  Future<List<SongEntity>> _rank() {
    if (_rankCache != null) return Future.value(_rankCache);
    return _rankInflight ??= () async {
      try {
        // 优先真·飙升榜（www，带完整封面）；www 被风控挡住就回落热门歌手搜索
        // （r.s，也带封面、每天轮换一位）。kbangserver 榜单没封面，不用。
        var songs = await _api.rank(bangId: 93, limit: 30);
        if (songs.isEmpty) {
          const seeds = [
            '周杰伦',
            '林俊杰',
            '邓紫棋',
            '薛之谦',
            '陈奕迅',
            '毛不易',
            '李荣浩',
          ];
          final seed = seeds[DateTime.now().day % seeds.length];
          songs = await _api.search(seed, limit: 30);
        }
        final mapped = [for (final s in songs) KuwoPlaybackService.toSongEntity(s)];
        if (mapped.isNotEmpty) _rankCache = mapped;
        return mapped;
      } catch (e) {
        debugPrint('[KuwoSource] rank error: $e');
        return const <SongEntity>[];
      } finally {
        _rankInflight = null;
      }
    }();
  }

  @override
  Future<SourceHero?> hero() => refreshHero();

  @override
  Future<SourceHero?> refreshHero() async {
    final songs = await _rank();
    if (songs.isEmpty) return null;
    final shuffled = [...songs]..shuffle();
    return SourceHero(song: shuffled.first, queue: shuffled, label: '酷我热门');
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
        // 未接登录，无收藏。
        return const [];
      case HomeFeed.recentPlayed:
        await PlayedSongCache.instance.ensureLoaded();
        return PlayedSongCache.instance.recent(
          limit: limit,
          idPrefix: SongSource.kuwoPrefix,
        );
      case HomeFeed.latestSongs:
        return _rank();
    }
  }

  @override
  Future<List<SourcePlaylist>> playlists({int limit = 10}) async => const [];

  @override
  Future<List<SongEntity>> playlistSongs(String playlistId) async => const [];

  @override
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) =>
      KuwoPlaybackService.instance.prepareQueue(songs);

  @override
  Future<List<SongEntity>> search(String keyword, {int limit = 30}) async {
    try {
      final songs = await _api.search(keyword, limit: limit);
      return [for (final s in songs) KuwoPlaybackService.toSongEntity(s)];
    } catch (e) {
      lastError = '搜索失败：$e';
      debugPrint('[KuwoSource] search error: $e');
      return const [];
    }
  }

  /// 换源 / 登出后清掉缓存，让首页重新拉。
  void reset() {
    _rankCache = null;
    _rankInflight = null;
  }
}
