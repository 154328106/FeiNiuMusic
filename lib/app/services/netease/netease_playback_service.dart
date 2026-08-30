import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import 'netease_api_client.dart';
import 'netease_models.dart';

/// 一条已解析的网易云播放地址及其有效期。
class _ResolvedUrl {
  _ResolvedUrl(this.url, this.resolvedAt);

  final String url;
  final DateTime resolvedAt;

  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > NetEasePlaybackService.urlTtl;
}

/// 网易云歌曲的播放地址解析与模型转换。
///
/// 与飞牛最大的不同：**飞牛的流地址是稳定的**（`/track/stream?guid=…`，凭
/// Cookie 认证，可以直接存进数据库反复用），**网易云的是带签名和时效的临时
/// 直链**，存进数据库过几小时就 403。所以网易云歌曲的 `SongEntity.uri` 只是
/// 一个「上次拿到的地址」占位，真正播放前必须调 [resolveStreamUrl] 重新取。
class NetEasePlaybackService {
  NetEasePlaybackService._();

  static final NetEasePlaybackService instance = NetEasePlaybackService._();

  /// 直链有效期。网易云实际给的时效通常更长，这里保守取 20 分钟，
  /// 避免长队列播到后面时地址已过期。
  static const Duration urlTtl = Duration(minutes: 20);

  final Map<int, _ResolvedUrl> _cache = {};
  final Map<int, Future<String?>> _inflight = {};

  /// 当前音质档位。免费账号拿不到 lossless 会自动降级。
  String level = 'exhigh';

  /// 解析某首网易云歌曲的可播放直链。
  ///
  /// 返回 null 表示拿不到地址——灰色歌曲、无版权、或未登录的 VIP 曲目。
  /// 调用方应把这首跳过而不是反复重试。
  Future<String?> resolveStreamUrl(int neteaseId, {bool force = false}) async {
    if (!force) {
      final cached = _cache[neteaseId];
      if (cached != null && !cached.isExpired) return cached.url;
    }

    // 同一首歌并发请求合并，避免切歌抖动时打出多个请求。
    final inflight = _inflight[neteaseId];
    if (inflight != null) return inflight;

    final future = _fetch(neteaseId);
    _inflight[neteaseId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(neteaseId);
    }
  }

  Future<String?> _fetch(int neteaseId) async {
    try {
      final result = await NetEaseApiClient.instance.songUrls([
        neteaseId,
      ], level: level);
      final info = result[neteaseId];
      final url = info?.url;
      if (url == null) {
        debugPrint('[NetEase] $neteaseId 无可用播放地址（灰色/无版权/需要会员）');
        return null;
      }
      if (info!.freeTrial) {
        debugPrint('[NetEase] $neteaseId 只返回了试听片段');
      }
      // 网易云返回的直链有 http 和 https 两种，统一升到 https：
      // Android 9+ 默认禁止明文 HTTP，http 直链会被系统拦掉。
      final secure = url.startsWith('http://')
          ? url.replaceFirst('http://', 'https://')
          : url;
      _cache[neteaseId] = _ResolvedUrl(secure, DateTime.now());
      return secure;
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEase] 取播放地址失败 $neteaseId：${e.message}');
      return null;
    }
  }

  /// 丢弃某首歌的地址缓存（播放失败后重取用）。
  void invalidate(int neteaseId) => _cache.remove(neteaseId);

  void clear() => _cache.clear();

  /// 播放网易云歌曲时要带的请求头。
  ///
  /// 音频 CDN 会校验 Referer，缺了会 403。注意**不能带飞牛的 Cookie**。
  static Map<String, String> streamHeaders() => const {
    'Referer': 'https://music.163.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  /// 把网易云搜索结果转成 App 内部的 [SongEntity]。
  ///
  /// `artist` / `album` 按仓库既有约定写成 JSON（飞牛那边存的是带 guid 的
  /// JSON），这样 `artistDisplayName` / `albumDisplayName` 以及直接
  /// `jsonDecode` 的消费方都走正常路径，不必依赖解析失败的兜底分支。
  /// 网易云没有飞牛的 guid 概念，guid 一律留空串。
  static SongEntity toSongEntity(NetEaseSong song, {String? resolvedUrl}) {
    return SongEntity(
      id: SongSource.encodeNetease(song.id),
      title: song.name,
      artist: jsonEncode([
        for (final name in song.artists.split(' / ').where((n) => n.isNotEmpty))
          {'guid': '', 'name': name},
      ]),
      album: jsonEncode({'guid': '', 'name': song.album}),
      // 临时直链，播放前会被 resolveStreamUrl 重新解析。存一份是为了让
      // player_service 里「uri 非空才算可播」的既有判断成立。
      uri: resolvedUrl ?? 'https://music.163.com/song?id=${song.id}',
      headersJson: jsonEncode(streamHeaders()),
      durationMs: song.durationMs,
      // 网易云封面是公网直链，直接放进 coverId；ArtworkWidget 按来源分流，
      // 认出是 http 就当完整 URL 用，不去拼飞牛的 /static/cover。
      coverId: song.coverUrl,
      format: 'mp3',
    );
  }
}
