import 'package:flutter/material.dart';

import '../../state/song_state.dart';
import '../feiniu/api_client.dart';
import '../feiniu/auth_service.dart';
import '../feiniu/track_service.dart';
import 'music_source.dart';

/// 飞牛 NAS 数据源。把原来首页直接调的那几个接口包了一层。
class FeiniuSource implements MusicSource {
  FeiniuSource._();

  static final FeiniuSource instance = FeiniuSource._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _tracks = FeiNiuTrackService.instance;

  /// 当前漫游链 id，`refreshHero` 靠它取下一首。
  String? _roamId;

  @override
  String get id => 'feiniu';

  @override
  String get label => '飞牛音乐';

  @override
  IconData get icon => Icons.dns_rounded;

  @override
  String get assetIcon => 'assets/source/feiniu.png';

  @override
  Color get accent => const Color(0xFFE5405A);

  @override
  bool get isAvailable => _api.baseUrl.isNotEmpty;

  @override
  String get unavailableHint => '尚未连接飞牛服务器';

  @override
  Future<SourceHero?> hero() async {
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();
      final response = await _api.getRoamStart(deviceId);
      _roamId = response.current.roamId;
      final track = _tracks.trackToSongEntity(response.current.track.toJson());
      final queue = <SongEntity>[track];
      final next = response.next;
      if (next != null) {
        queue.add(_tracks.trackToSongEntity(next.track.toJson()));
      }
      return SourceHero(
        song: track,
        queue: queue,
        label: '漫游 · 随心听',
        chainId: _roamId,
      );
    } catch (e) {
      debugPrint('[FeiniuSource] hero error: $e');
      return null;
    }
  }

  @override
  Future<SourceHero?> refreshHero() async {
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();
      final current = _roamId;
      // 必须 await：不加的话这个 Future 的异常会绕过下面的 catch。
      if (current == null || current.isEmpty) return await hero();
      final next = await _api.getRoamNext(deviceId, current);
      final upcoming = next.next;
      if (upcoming == null) return null;
      // 推进 roamId：下一次请求要基于 current 的 roamId，用 next 的会跳歌。
      _roamId = next.current?.roamId ?? upcoming.roamId;
      final song = _tracks.trackToSongEntity(upcoming.track.toJson());
      return SourceHero(
        song: song,
        // 队列以当前显示的这首为队首：点播放时播的就是大图上这首。
        queue: [song],
        label: '漫游 · 随心听',
        chainId: _roamId,
      );
    } catch (e) {
      debugPrint('[FeiniuSource] refreshHero error: $e');
      return null;
    }
  }

  @override
  Future<List<SongEntity>> feed(HomeFeed kind, {int limit = 10}) =>
      fullFeed(kind, limit: limit);

  @override
  Future<List<SongEntity>> fullFeed(HomeFeed kind, {required int limit}) async {
    try {
      final page = switch (kind) {
        HomeFeed.favorites => await _api.getFavoriteList(size: limit),
        HomeFeed.recentPlayed => await _api.getPlayHistory(
          page: 1,
          size: limit,
        ),
        HomeFeed.latestSongs => await _api.getTrackList(
          page: 1,
          size: limit,
          sort: 'createdAt,desc',
        ),
      };
      return page.list
          .map((t) => _tracks.trackToSongEntity(t.toJson()))
          .toList();
    } catch (e) {
      debugPrint('[FeiniuSource] feed $kind error: $e');
      return const [];
    }
  }

  @override
  Future<List<SourcePlaylist>> playlists({int limit = 10}) async {
    try {
      final page = await _api.getPlaylistList(page: 1, size: limit);
      return page.list
          .map(
            (p) => SourcePlaylist(
              id: p.guid,
              name: p.name,
              coverId: p.coverId,
              trackCount: p.trackCount,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('[FeiniuSource] playlists error: $e');
      return const [];
    }
  }

  @override
  Future<List<SongEntity>> playlistSongs(String playlistId) async {
    try {
      final page = await _api.getPlaylistTracks(
        playlistGUID: playlistId,
        page: 1,
        size: 500,
      );
      return page.list
          .map((t) => _tracks.trackToSongEntity(t.toJson()))
          .toList();
    } catch (e) {
      debugPrint('[FeiniuSource] playlistSongs error: $e');
      return const [];
    }
  }

  /// 飞牛的流地址是稳定的（凭 Cookie 认证），起播前不用预取，原样返回。
  @override
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) async => songs;

  /// 飞牛有自己那套强类型搜索页（SearchPage），不走这个通用入口。
  @override
  Future<List<SongEntity>> search(String keyword, {int limit = 30}) async =>
      const [];
}
