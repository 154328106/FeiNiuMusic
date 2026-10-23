import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/unblock_source.dart';
import 'kuwo_models.dart';

class _Resolved {
  _Resolved(this.url, this.at);
  final String url;
  final DateTime at;
  bool get isExpired =>
      DateTime.now().difference(at) > KuwoPlaybackService.urlTtl;
}

class _Meta {
  const _Meta({required this.keyword, required this.durationMs});
  final String keyword;
  final int durationMs;
}

/// 酷我播放地址解析与模型转换（MVP）。
///
/// 取址优先级：海棠 kw.php（lossless 给完整 FLAC）→ 解灰链 `resolve(kw)`
/// （走 LX 的回避聚合等）→ 酷我自家 antiserver（纯文本，有时是「请到 APP
/// 收听」提示音，放最后）。
class KuwoPlaybackService {
  KuwoPlaybackService._();
  static final KuwoPlaybackService instance = KuwoPlaybackService._();

  static const Duration urlTtl = Duration(minutes: 45);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  final Map<String, _Resolved> _cache = {};
  final Set<String> _unresolvable = {};
  final Map<String, _Meta> _meta = {};
  final Map<String, Future<String?>> _inflight = {};

  // 全局并发闸（和酷狗同理，避免冷启动多路请求叠加被限流）。
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

  Future<String?> resolveStreamUrl(String rid, {bool force = false}) async {
    if (!force) {
      final cached = _cache[rid];
      if (cached != null && !cached.isExpired) return cached.url;
      if (_unresolvable.contains(rid)) return null;
      final pending = _inflight[rid];
      if (pending != null) return pending;
    }
    final future = _guarded(rid);
    _inflight[rid] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(rid);
    }
  }

  Future<String?> _guarded(String rid) async {
    await _acquire();
    try {
      return await _resolveOnce(rid);
    } finally {
      _release();
    }
  }

  Future<String?> _resolveOnce(String rid) async {
    final meta = _meta[rid];
    final quality = UnblockSourceService.instance.config.value.quality;
    String? url;
    try {
      url = await _viaHaitangw(rid, quality);
      url ??= await UnblockSourceService.instance.resolve(
        platform: 'kw',
        songId: rid,
        keyword: meta?.keyword,
        durationMs: meta?.durationMs ?? 0,
      );
      url ??= await _viaAntiserver(rid);
    } catch (e) {
      debugPrint('[Kuwo] 取址异常 $rid：$e');
    }
    if (url == null || url.isEmpty) {
      if (!UnblockSourceService.instance.isRateLimited) {
        _unresolvable.add(rid);
      }
      return null;
    }
    final secure = url.startsWith('http://')
        ? url.replaceFirst('http://', 'https://')
        : url;
    _cache[rid] = _Resolved(secure, DateTime.now());
    return secure;
  }

  /// 海棠酷我：302 重定向，地址在 Location 头；关掉跟随别把整首下进内存。
  Future<String?> _viaHaitangw(String rid, String quality) async {
    try {
      final res = await _dio.get<void>(
        'https://musicapi.haitangw.net/music/kw.php',
        queryParameters: {'type': 'mp3', 'id': rid, 'level': _htLevel(quality)},
        options: Options(
          followRedirects: false,
          validateStatus: (c) => c != null && c < 400,
        ),
      );
      final loc = res.headers.value('location');
      if (loc == null || loc.isEmpty) return null;
      return loc;
    } on DioException {
      return null;
    }
  }

  static String _htLevel(String quality) {
    switch (quality.trim().toLowerCase()) {
      case 'flac':
      case 'flac24bit':
      case 'hires':
      case 'lossless':
        return 'lossless';
      default:
        return '320k';
    }
  }

  /// 酷我自家 antiserver：返回纯文本地址，必须用 okhttp UA（浏览器 UA 给空串）。
  Future<String?> _viaAntiserver(String rid) async {
    try {
      final res = await _dio.get<String>(
        'https://antiserver.kuwo.cn/anti.s',
        queryParameters: {
          'type': 'convert_url',
          'format': 'mp3',
          'response': 'url',
          'rid': 'MUSIC_$rid',
        },
        options: Options(
          responseType: ResponseType.plain,
          headers: {'User-Agent': 'okhttp/3.10.0'},
        ),
      );
      final text = res.data ?? '';
      final m = RegExp(r'http[^\s"]+').firstMatch(text);
      return m?.group(0);
    } on DioException {
      return null;
    }
  }

  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) async {
    final pending = <String>[];
    for (final song in songs) {
      final rid = SongSource.decodeKuwo(song.id);
      if (rid == null) continue;
      _remember(song, rid);
      if (_cache[rid]?.isExpired == false) continue;
      if (_unresolvable.contains(rid)) continue;
      pending.add(rid);
    }
    await Future.wait([for (final rid in pending) resolveStreamUrl(rid)]);

    final playable = <SongEntity>[];
    var dropped = 0;
    for (final song in songs) {
      final rid = SongSource.decodeKuwo(song.id);
      if (rid == null) {
        playable.add(song);
        continue;
      }
      if (_unresolvable.contains(rid)) {
        dropped++;
        continue;
      }
      playable.add(song);
    }
    debugPrint('[Kuwo] 队列 ${songs.length} 首：可播 ${playable.length}，跳过 $dropped');
    return playable;
  }

  void _remember(SongEntity song, String rid) {
    if (_meta.containsKey(rid)) return;
    _meta[rid] = _Meta(
      keyword: '${song.title} ${song.artistDisplayName}'.trim(),
      durationMs: song.durationMs ?? 0,
    );
  }

  void invalidate(String rid) {
    _cache.remove(rid);
    _unresolvable.remove(rid);
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

  static SongEntity toSongEntity(KuwoSong song) {
    return SongEntity(
      id: SongSource.encodeKuwo(song.rid),
      title: song.name,
      artist: jsonEncode([
        for (final name in song.artists.split(' / ').where((n) => n.isNotEmpty))
          {'guid': '', 'name': name},
      ]),
      album: jsonEncode({'guid': '', 'name': song.album}),
      uri: 'https://www.kuwo.cn/play_detail/${song.rid}',
      headersJson: jsonEncode(streamHeaders()),
      durationMs: song.durationMs,
      coverId: song.coverUrl,
      format: 'mp3',
      isVip: song.isVip,
    );
  }
}
