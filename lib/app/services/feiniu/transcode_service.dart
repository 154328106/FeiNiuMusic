import 'package:flutter/foundation.dart';

import '../../state/song_state.dart';
import 'api_client.dart';

/// 服务器转码服务（单例）
///
/// 保留的功能：**格式解析**（`resolvedFormatFor` / `resolvedFormatForSync`，
/// 判断某首歌是否需要 media_kit）与黑名单判定（`isMediaKitFormat`）。
///
/// 转码 HLS（`hlsUrlForFlac`）当前已不再被播放器调用——media_kit 直连原始
/// 流（mpv FFmpeg 原生解码 DSF/APE/WMA…），转码链路保留仅供测试与未来
/// 回退。
///
/// 历史流程：DSF/DSD/WMA/APE/DTS/AIFF 等（ExoPlayer 无法解码）统一转成
/// FLAC HLS（`codec: 'flac'`）交给 media_kit 解码。现已改为直连原始流。
class FeiNiuTranscodeService {
  FeiNiuTranscodeService._();

  static final FeiNiuTranscodeService instance = FeiNiuTranscodeService._();

  /// 需服务器转码（本地 ExoPlayer 不支持）的格式黑名单。
  static const Set<String> unsupportedFormats = {
    'dsf', 'dff', 'dsd',
    'wma', 'ape', 'dts',
    'aiff', 'ra', 'au',
    'dvf', 'tta', 'dss', 'mmf',
  };

  /// 交给 media_kit（FFmpeg）解码的格式：黑名单格式（DSF/APE/WMA…）。
  ///
  /// 普通 FLAC **不在此列**——它走 just_audio 直连流（原本就工作、有缓存）。
  /// 仅当 just_audio 解码 FLAC 触发 32KB 帧缓冲上限（`Buffer too small`）时，
  /// 由 PlayerService 运行时升级到 media_kit 解码（见 player_service 的
  /// `_mediaKitEscalateSongIds`）。
  static bool isMediaKitFormat(String format) {
    final f = format.trim().toLowerCase();
    return unsupportedFormats.contains(f);
  }

  /// 交给 media_kit（FFmpeg）解码的**编码**黑名单：M4A/MP4 容器内常见的
  /// 环绕声/无损编码。ExoPlayer 的设备解码器（MediaCodec）对这些 codec 的
  /// 支持因设备而异：解码器不可用/静默失败时，进度条照常走但无声音。
  /// FFmpeg 全部原生解码，交给 media_kit 必定出声。
  ///
  /// `eac3`/`ac3`：杜比数字（Plus）；`alac`：Apple 无损；`dts`/`truehd`/`mlp`：
  /// 家庭影院环绕编码。
  static const Set<String> mediaKitCodecs = {
    'eac3', 'ac3', 'alac', 'dts', 'truehd', 'mlp',
  };

  /// codec 是否为 media_kit 专属（ExoPlayer 设备解码不可靠）。
  static bool isMediaKitCodec(String? codec) {
    if (codec == null || codec.isEmpty) return false;
    return mediaKitCodecs.contains(codec.trim().toLowerCase());
  }

  /// 可能内嵌风险 codec（EAC3/ALAC…）的容器格式。codec 未知（null）时，
  /// 这些容器需要无声看门狗兜底。
  static const Set<String> riskySilenceContainers = {
    'm4a', 'm4b', 'm4p', 'mp4', 'aac', 'mov', '3gp', 'mka', 'mkv',
  };

  /// 容器是否可能内嵌风险 codec（codec 未知时据此判断是否需要看门狗）。
  static bool isRiskySilenceContainer(String? format) {
    if (format == null || format.isEmpty) return false;
    return riskySilenceContainers.contains(format.trim().toLowerCase());
  }

  static const Duration _ttl = Duration(minutes: 30);

  FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final Map<String, _CachedHls> _cache = {};
  final Map<String, Future<Map<String, dynamic>?>> _formatInflight = {};
  final Map<String, String> _formats = {};
  final Map<String, String> _codecs = {};

  /// 该格式是否需要在服务器侧转码。
  bool isTranscodeNeeded(String? format) {
    if (format == null || format.isEmpty) return false;
    return unsupportedFormats.contains(format.trim().toLowerCase());
  }

  /// 获取某首歌的**有效格式**：优先 `song.format`（列表接口已带则直接用，
  /// 零网络开销）；为空时先查会话内格式缓存，未命中再请求
  /// `/track/metadata` 确认（DSF/DSD 等曲目在列表接口里常不返回 audioSpec）。
  ///
  /// 返回 null 表示无法确认格式（无需转码 / metadata 失败）。
  Future<String?> resolvedFormatFor(SongEntity song) async {
    final local = song.format;
    if (local != null && local.trim().isNotEmpty) return local.trim();

    final cached = _formats[song.id];
    if (cached != null) return cached;

    // 与 resolvedCodecFor 共享同一次 metadata 请求：拉取时同时提取并缓存
    // format 与 codec，避免各发一次网络请求。
    final spec = await _resolveSpec(song);
    if (spec == null) return null;
    final format = _extractFormat(spec)?.trim();
    if (format != null && format.isNotEmpty) {
      _formats[song.id] = format;
    }
    _cacheCodecFromSpec(song.id, spec);
    return format;
  }

  /// 获取某首歌的**有效编码**（audioSpec.codec，如 eac3/alac/aac）。优先
  /// `song.codec`（列表接口已带则直接用，零网络开销）；为空时先查会话内
  /// codec 缓存，未命中再请求 `/track/metadata` 确认。
  ///
  /// 返回 null 表示无法确认编码（无需处理 / metadata 失败）。
  Future<String?> resolvedCodecFor(SongEntity song) async {
    final local = song.codec;
    if (local != null && local.trim().isNotEmpty) return local.trim();

    final cached = _codecs[song.id];
    if (cached != null) return cached;

    // 与 resolvedFormatFor 共享同一次 metadata 请求。
    final spec = await _resolveSpec(song);
    if (spec == null) return null;
    final codec = _extractCodec(spec)?.trim();
    if (codec != null && codec.isNotEmpty) {
      _codecs[song.id] = codec;
    }
    _cacheFormatFromSpec(song.id, spec);
    return codec;
  }

  /// 拉取一次 metadata。并发调用去重：复用同一个在途 Future。
  /// metadata 失败返回 null（按无需处理，不阻塞播放）。
  Future<Map<String, dynamic>?> _resolveSpec(SongEntity song) async {
    final inflight = _formatInflight[song.id];
    if (inflight != null) return inflight;

    final future = () async {
      try {
        return await _api.trackMetadata(song.id);
      } catch (_) {
        return null;
      }
    }();
    _formatInflight[song.id] = future;
    future.whenComplete(() => _formatInflight.remove(song.id));
    return future;
  }

  void _cacheFormatFromSpec(String songId, Map<String, dynamic> spec) {
    final format = _extractFormat(spec)?.trim();
    if (format != null && format.isNotEmpty) {
      _formats[songId] = format;
    }
  }

  void _cacheCodecFromSpec(String songId, Map<String, dynamic> spec) {
    final codec = _extractCodec(spec)?.trim();
    if (codec != null && codec.isNotEmpty) {
      _codecs[songId] = codec;
    }
  }

  /// 获取某首歌的 **FLAC HLS** 播放绝对地址。
  ///
  /// ⚠️ 当前播放器已不再调用（media_kit 直连原始流），保留仅供测试与未来
  /// 回退。
  ///
  /// - 非 media_kit 格式（flac/mp3/aac/…，或 metadata 无法确认）→ 返回 null；
  /// - 转码成功 → 缓存（TTL）并返回绝对 URL；
  /// - 网络异常 / 服务器未返回地址 → 抛异常，由调用方回退直连。
  ///
  /// 仅对黑名单格式（DSF/APE/WMA…）请求 FLAC 转码——无损优先、不降级 MP3。
  /// 普通 FLAC 不转码（just_audio 直连播放）。当 [force] 为 true 时（该歌
  /// 已由 PlayerService 升级到 media_kit，如 just_audio 解码 FLAC 帧超限），
  /// 无视格式强制请求 FLAC 转码。
  Future<String?> hlsUrlForFlac(SongEntity song, {bool force = false}) async {
    final format = await resolvedFormatFor(song);
    if (!force && !isMediaKitFormat(format ?? '')) return null;

    final hit = _cache[song.id];
    if (hit != null && hit.isValid()) return hit.url;

    final rel = await _api.trackTranscode(song.id, codec: 'flac');
    if (rel == null) return null;

    final url = _api.resolveHlsUrl(rel);
    _cache[song.id] = _CachedHls(url, DateTime.now().add(_ttl));
    return url;
  }

  /// 同步读取会话内已缓存的格式（不发起网络请求）。
  /// 用于 [PlayerService] 构建 media_kit 条目时的快速判断。
  String? resolvedFormatForSync(SongEntity song) {
    final local = song.format;
    if (local != null && local.trim().isNotEmpty) return local.trim();
    return _formats[song.id];
  }

  /// 读取已缓存的转码 HLS 地址（不发起网络请求）。未缓存/已过期返回 null。
  String? cachedHlsUrlFor(String songId) {
    final hit = _cache[songId];
    if (hit != null && hit.isValid()) return hit.url;
    return null;
  }

  /// 清除某首歌的转码缓存（播放出错强制刷新时调用）。
  void invalidate(String songId) {
    _cache.remove(songId);
    _formatInflight.remove(songId);
    _formats.remove(songId);
    _codecs.remove(songId);
  }

  /// 从 metadata 响应中提取格式（`data.audioSpec.format` 或
  /// `data.track.audioSpec.format`，两者都存在）。
  String? _extractFormat(Map<String, dynamic>? meta) {
    if (meta == null) return null;
    final audioSpec = meta['audioSpec'];
    if (audioSpec is Map<String, dynamic>) {
      final format = audioSpec['format'];
      if (format is String && format.isNotEmpty) return format;
    }
    final track = meta['track'];
    if (track is Map<String, dynamic>) {
      final trackSpec = track['audioSpec'];
      if (trackSpec is Map<String, dynamic>) {
        final format = trackSpec['format'];
        if (format is String && format.isNotEmpty) return format;
      }
    }
    return null;
  }

  /// 从 metadata 响应中提取编码（`data.audioSpec.codec` 或
  /// `data.track.audioSpec.codec`，两者都存在）。镜像 [_extractFormat]。
  String? _extractCodec(Map<String, dynamic>? meta) {
    if (meta == null) return null;
    final audioSpec = meta['audioSpec'];
    if (audioSpec is Map<String, dynamic>) {
      final codec = audioSpec['codec'];
      if (codec is String && codec.isNotEmpty) return codec;
    }
    final track = meta['track'];
    if (track is Map<String, dynamic>) {
      final trackSpec = track['audioSpec'];
      if (trackSpec is Map<String, dynamic>) {
        final codec = trackSpec['codec'];
        if (codec is String && codec.isNotEmpty) return codec;
      }
    }
    return null;
  }

  @visibleForTesting
  void setApiForTest(FeiNiuApiClient api) => _api = api;

  @visibleForTesting
  void clearCacheForTest() {
    _cache.clear();
    _formatInflight.clear();
    _formats.clear();
    _codecs.clear();
  }

  @visibleForTesting
  void resetForTest() {
    _api = FeiNiuApiClient.instance;
    _cache.clear();
    _formatInflight.clear();
    _formats.clear();
    _codecs.clear();
  }
}

/// 转码缓存项：HLS 地址 + 过期时间。
class _CachedHls {
  final String url;
  final DateTime expiresAt;

  _CachedHls(this.url, this.expiresAt);

  bool isValid() => DateTime.now().isBefore(expiresAt);
}
