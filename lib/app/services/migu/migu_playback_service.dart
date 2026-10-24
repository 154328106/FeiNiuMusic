import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/unblock_source.dart';
import 'migu_auth.dart';
import 'migu_models.dart';

class _Resolved {
  _Resolved(this.url, this.at);
  final String url;
  final DateTime at;
  bool get isExpired =>
      DateTime.now().difference(at) > MiguPlaybackService.urlTtl;
}

class _Meta {
  const _Meta({
    required this.keyword,
    required this.durationMs,
    required this.contentId,
  });
  final String keyword;
  final int durationMs;
  final String contentId;
}

/// 咪咕播放地址解析与模型转换。
///
/// 取址优先级：
/// 1. 咪咕自家直连 `listenSong.do`（**登录后**才给 VIP 直链，未登录返回
///    「暂不提供试听地址」，此时跳过）；
/// 2. 解灰链 `resolve(mg)` —— 走聚合 / LX 的 mg 后端（回避、星海…），
///    免登录也能出地址，是免登录时的主力。
class MiguPlaybackService {
  MiguPlaybackService._();
  static final MiguPlaybackService instance = MiguPlaybackService._();

  static const Duration urlTtl = Duration(minutes: 45);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  final Map<String, _Resolved> _cache = {};
  final Set<String> _unresolvable = {};
  final Map<String, _Meta> _meta = {};
  final Map<String, Future<String?>> _inflight = {};

  static const int _maxConcurrent = 5;
  int _active = 0;
  final List<Completer<void>> _waiting = [];

  Future<void> _acquire() {
    if (_active < _maxConcurrent) {
      _active++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _active--;
  }

  Future<String?> resolveStreamUrl(String copyrightId, {bool force = false}) async {
    if (!force) {
      final cached = _cache[copyrightId];
      if (cached != null && !cached.isExpired) return cached.url;
      if (_unresolvable.contains(copyrightId)) return null;
      final pending = _inflight[copyrightId];
      if (pending != null) return pending;
    }
    final future = _guarded(copyrightId);
    _inflight[copyrightId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(copyrightId);
    }
  }

  Future<String?> _guarded(String copyrightId) async {
    await _acquire();
    try {
      return await _resolveOnce(copyrightId);
    } finally {
      _release();
    }
  }

  Future<String?> _resolveOnce(String copyrightId) async {
    final meta = _meta[copyrightId];
    final quality = UnblockSourceService.instance.config.value.quality;
    String? url;
    try {
      // 1. 登录了才试咪咕自家直连（未登录必返回「暂不提供试听地址」）。
      if (MiguAuth.instance.isLoggedIn.value && meta != null &&
          meta.contentId.isNotEmpty) {
        url = await _viaMiguDirect(copyrightId, meta.contentId, quality);
      }
      // 2. 解灰链（聚合 / LX 的 mg 后端）：免登录主力。
      url ??= await UnblockSourceService.instance.resolve(
        platform: 'mg',
        songId: copyrightId,
        keyword: meta?.keyword,
        durationMs: meta?.durationMs ?? 0,
      );
    } catch (e) {
      debugPrint('[Migu] 取址异常 $copyrightId：$e');
    }
    if (url == null || url.isEmpty) {
      if (!UnblockSourceService.instance.isRateLimited) {
        _unresolvable.add(copyrightId);
      }
      return null;
    }
    final secure = url.startsWith('http://')
        ? url.replaceFirst('http://', 'https://')
        : url;
    _cache[copyrightId] = _Resolved(secure, DateTime.now());
    return secure;
  }

  /// 咪咕自家直连：`listenSong.do`，要 contentId + copyrightId + channel，
  /// 登录 cookie 带上才给 VIP 直链。未登录 / 无权限返回 code 200000「暂不提供
  /// 试听地址」，此时给 null 让上层回落聚合。
  Future<String?> _viaMiguDirect(
    String copyrightId,
    String contentId,
    String quality,
  ) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listenSong.do',
        queryParameters: {
          'toneFlag': _toneFlag(quality),
          'netType': '01',
          'channel': '0146921',
          'ua': 'Android_migu',
          'version': '5.0.1',
          'copyrightId': copyrightId,
          'contentId': contentId,
          'resourceType': '2',
          'lowerQualityContentId': contentId,
        },
        options: Options(
          // 关自动跟随：302 时要自己读 Location，别把整首下进内存。
          followRedirects: false,
          validateStatus: (c) => c != null && c < 400,
          headers: {
            'User-Agent': 'okhttp/3.12.1',
            'channel': '0146921',
            if (MiguAuth.instance.cookieHeader.isNotEmpty)
              'Cookie': MiguAuth.instance.cookieHeader,
          },
        ),
      );
      // 多数情况下 listenSong.do 直接 302 到真实地址（followRedirects 默认开，
      // 这里关不掉就读 body 的 url 字段）；也可能回 JSON 带 url。
      final loc = res.headers.value('location');
      if (loc != null && loc.startsWith('http')) return loc;
      final data = res.data is String ? res.data as String : '${res.data}';
      if (data.trim().startsWith('http')) return data.trim();
      try {
        final json = jsonDecode(data);
        if (json is Map) {
          final url = json['url'] ??
              (json['data'] is Map ? (json['data'] as Map)['url'] : null) ??
              json['playUrl'];
          if (url is String && url.startsWith('http')) return url;
          debugPrint('[Migu] 直连 code=${json['code']} info=${json['info']}');
        }
      } catch (_) {}
      return null;
    } on DioException {
      return null;
    }
  }

  static String _toneFlag(String quality) {
    switch (quality.trim().toLowerCase()) {
      case 'flac':
      case 'lossless':
        return 'SQ';
      case 'flac24bit':
      case 'hires':
        return 'ZQ';
      case '320k':
        return 'HQ';
      default:
        return 'PQ';
    }
  }

  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) async {
    final pending = <String>[];
    for (final song in songs) {
      final cid = SongSource.decodeMigu(song.id);
      if (cid == null) continue;
      _remember(song, cid);
      if (_cache[cid]?.isExpired == false) continue;
      if (_unresolvable.contains(cid)) continue;
      pending.add(cid);
    }
    await Future.wait([for (final cid in pending) resolveStreamUrl(cid)]);

    final playable = <SongEntity>[];
    var dropped = 0;
    for (final song in songs) {
      final cid = SongSource.decodeMigu(song.id);
      if (cid == null) {
        playable.add(song);
        continue;
      }
      if (_unresolvable.contains(cid)) {
        dropped++;
        continue;
      }
      playable.add(song);
    }
    debugPrint('[Migu] 队列 ${songs.length} 首：可播 ${playable.length}，跳过 $dropped');
    return playable;
  }

  void _remember(SongEntity song, String copyrightId) {
    if (_meta.containsKey(copyrightId)) return;
    _meta[copyrightId] = _Meta(
      keyword: '${song.title} ${song.artistDisplayName}'.trim(),
      durationMs: song.durationMs ?? 0,
      // contentId 存在实体的 audioSpec 上（见 toSongEntity）。
      contentId: song.audioSpec ?? '',
    );
  }

  void invalidate(String copyrightId) {
    _cache.remove(copyrightId);
    _unresolvable.remove(copyrightId);
  }

  void clear() {
    _cache.clear();
    _unresolvable.clear();
    _inflight.clear();
  }

  static Map<String, String> streamHeaders() => const {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  static SongEntity toSongEntity(MiguSong song) {
    return SongEntity(
      id: SongSource.encodeMigu(song.copyrightId),
      title: song.name,
      artist: jsonEncode([
        for (final name in song.artists.split(' / ').where((n) => n.isNotEmpty))
          {'guid': '', 'name': name},
      ]),
      album: jsonEncode({'guid': '', 'name': song.album}),
      uri: 'https://music.migu.cn/v3/music/song/${song.copyrightId}',
      headersJson: jsonEncode(streamHeaders()),
      durationMs: song.durationMs == 0 ? null : song.durationMs,
      coverId: song.coverUrl,
      // contentId 留给直连播放，lyricUrl 留给歌词页。
      audioSpec: song.contentId,
      codec: song.lyricUrl,
      format: 'mp3',
      isVip: song.isVip,
    );
  }
}
