import 'package:flutter/material.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../netease/netease_api_client.dart';
import '../netease/netease_models.dart';
import '../netease/netease_playback_service.dart';
import 'music_source.dart';

/// 网易云数据源。
///
/// 除「推荐歌单 / 推荐新歌」外都要登录 —— 收藏、播放记录、每日推荐都是账号
/// 维度的数据，未登录时服务端直接返回失败。所以 [isAvailable] 挂在登录态上。
class NetEaseSource implements MusicSource {
  NetEaseSource._();

  static final NetEaseSource instance = NetEaseSource._();

  final NetEaseApiClient _api = NetEaseApiClient.instance;

  /// 缓存的用户 id。收藏、播放记录都要它，每次现取要多一轮请求。
  int? _uid;

  /// 「我喜欢的音乐」歌单 id：用户歌单里的第一个。
  int? _likedPlaylistId;

  @override
  String get id => 'netease';

  @override
  String get label => '网易云音乐';

  @override
  IconData get icon => Icons.cloud_rounded;

  @override
  Color get accent => const Color(0xFFD33A31);

  @override
  bool get isAvailable => _api.isLoggedIn;

  @override
  String get unavailableHint => '尚未登录网易云账号';

  /// 登出后清掉缓存，换账号不会读到上一个人的收藏。
  void reset() {
    _uid = null;
    _likedPlaylistId = null;
  }

  Future<int?> _ensureUid() async {
    final cached = _uid;
    if (cached != null) return cached;
    try {
      final user = await _api.account();
      _uid = user.userId;
      return _uid;
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEaseSource] account error: ${e.message}');
      return null;
    }
  }

  /// 「我喜欢的音乐」是用户歌单列表里的第一个，网易云没有专门的接口。
  Future<int?> _ensureLikedPlaylist() async {
    final cached = _likedPlaylistId;
    if (cached != null) return cached;
    final uid = await _ensureUid();
    if (uid == null) return null;
    try {
      final lists = await _api.userPlaylists(uid);
      if (lists.isEmpty) return null;
      _likedPlaylistId = lists.first.id;
      return _likedPlaylistId;
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEaseSource] userPlaylists error: ${e.message}');
      return null;
    }
  }

  List<SongEntity> _toEntities(List<NetEaseSong> songs) =>
      songs.map(NetEasePlaybackService.toSongEntity).toList();

  @override
  Future<SourceHero?> hero() => refreshHero();

  @override
  Future<SourceHero?> refreshHero() async {
    // 私人 FM 每次返回一小批，语义上最接近飞牛的漫游；拿不到就退每日推荐。
    try {
      final fm = await _api.personalFm();
      if (fm.isNotEmpty) {
        final queue = _toEntities(fm);
        return SourceHero(song: queue.first, queue: queue, label: '私人 FM');
      }
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEaseSource] personalFm error: ${e.message}');
    }
    try {
      final daily = await _api.dailyRecommend();
      if (daily.isEmpty) return null;
      final queue = _toEntities(daily);
      return SourceHero(song: queue.first, queue: queue, label: '每日推荐');
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEaseSource] dailyRecommend error: ${e.message}');
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
          final playlistId = await _ensureLikedPlaylist();
          if (playlistId == null) return const [];
          return _toEntities(await _api.playlistTracks(playlistId));
        case HomeFeed.recentPlayed:
          final uid = await _ensureUid();
          if (uid == null) return const [];
          return _toEntities(await _api.playRecord(uid));
        case HomeFeed.latestSongs:
          return _toEntities(await _api.newSongs(limit: limit));
      }
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEaseSource] feed $kind error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SourcePlaylist>> playlists({int limit = 10}) async {
    try {
      final uid = await _ensureUid();
      // 登录了就给自己的歌单，否则退推荐歌单（这个接口不需要登录）。
      final lists = uid != null
          ? await _api.userPlaylists(uid)
          : await _api.personalizedPlaylists(limit: limit);
      final capped = lists.length <= limit ? lists : lists.sublist(0, limit);
      return capped
          .map(
            (p) => SourcePlaylist(
              id: SongSource.encodeNetease(p.id),
              name: p.name,
              // 网易云封面是公网直链，直接存完整地址（与 SongEntity.coverId
              // 同约定，渲染层按 http 开头分流）。
              coverId: p.coverUrl,
              trackCount: p.trackCount,
            ),
          )
          .toList();
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEaseSource] playlists error: ${e.message}');
      return const [];
    }
  }

  @override
  Future<List<SongEntity>> playlistSongs(String playlistId) async {
    final raw = SongSource.decodeNetease(playlistId);
    final numeric = raw != null ? int.tryParse(raw.toString()) : null;
    if (numeric == null) return const [];
    try {
      return _toEntities(await _api.playlistTracks(numeric));
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEaseSource] playlistSongs error: ${e.message}');
      return const [];
    }
  }
}
