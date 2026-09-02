import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'free_unblock_sources.dart';

/// 第三方音源（解锁灰色 / 会员歌曲的播放地址）。
///
/// 协议照聆澜音源，与 Beans-Music 1.5.9 一致：
///
/// ```
/// GET <template>            占位符 {source} {id} {quality}
/// Header: X-API-Key: <密钥>
/// ```
///
/// - `source` 是平台代号：网易云 `wy`、QQ `tx`、酷狗 `kg`
/// - 返回里播放地址按 `data.music|data.url|url` 依次找，先命中先用 ——
///   不同后端返回结构不一样，多路径能一起兼容
/// - 有 `code` 字段时只有 0 / 200 算成功
///
/// **不内置任何密钥**：没填 key 就一个请求都不发。密钥属于用户，写死在代码里
/// 会随仓库公开泄露出去。
class UnblockSourceConfig {
  const UnblockSourceConfig({
    required this.template,
    required this.apiKeys,
    this.quality = '320k',
    this.enabled = true,
  });

  /// 请求模板，含 `{source}` `{id}` `{quality}` 三个占位符。
  final String template;

  /// 密钥池。当前 key 没命中就换下一个。
  final List<String> apiKeys;

  final String quality;
  final bool enabled;

  bool get isUsable => enabled && template.isNotEmpty && apiKeys.isNotEmpty;

  static const String defaultTemplate =
      'https://source.shiqianjiang.cn/api/music/url'
      '?source={source}&songId={id}&quality={quality}';

  static const UnblockSourceConfig empty = UnblockSourceConfig(
    template: defaultTemplate,
    apiKeys: [],
  );

  UnblockSourceConfig copyWith({
    String? template,
    List<String>? apiKeys,
    String? quality,
    bool? enabled,
  }) => UnblockSourceConfig(
    template: template ?? this.template,
    apiKeys: apiKeys ?? this.apiKeys,
    quality: quality ?? this.quality,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'template': template,
    'apiKeys': apiKeys,
    'quality': quality,
    'enabled': enabled,
  };

  static UnblockSourceConfig fromJson(Map<String, Object?> json) =>
      UnblockSourceConfig(
        template: json['template'] as String? ?? defaultTemplate,
        apiKeys:
            (json['apiKeys'] as List?)?.whereType<String>().toList() ??
            const [],
        quality: json['quality'] as String? ?? '320k',
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// 音源配置的读写 + 解析请求。
class UnblockSourceService {
  UnblockSourceService._();

  static final UnblockSourceService instance = UnblockSourceService._();

  static const String _prefsKey = 'unblock.source.config';
  static const String _prefsPreferredKey = 'unblock.source.preferredKeyIndex';

  final ValueNotifier<UnblockSourceConfig> config = ValueNotifier(
    UnblockSourceConfig.empty,
  );

  /// 最近一次命中的密钥下标，下次从它开始试。
  int _preferredKeyIndex = 0;

  /// 被限流到这个时刻之前，别再打聆澜了。
  ///
  /// 429 不是「这首没有」，是「你问太快了」。不区分的话会把整队歌都误判成
  /// 没货，还会继续拿请求去撞墙。撞上就歇一会儿，这期间直接走免费兜底。
  DateTime? _rateLimitedUntil;
  static const Duration _rateLimitCooldown = Duration(seconds: 20);

  bool _loaded = false;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 7),
      receiveTimeout: const Duration(seconds: 7),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      headers: {
        'Accept': 'application/json',
        'User-Agent': 'FeiNiuMusic-UserSource/1.0',
      },
    ),
  );

  /// 免费兜底音源的开关。默认开：不要密钥、不要账号，聆澜没配或没命中时
  /// 还能救回一部分歌。
  final ValueNotifier<bool> freeFallbackEnabled = ValueNotifier(true);

  static const String _prefsFreeKey = 'unblock.source.freeFallback';

  bool get isUsable => config.value.isUsable;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _preferredKeyIndex = prefs.getInt(_prefsPreferredKey) ?? 0;
      freeFallbackEnabled.value = prefs.getBool(_prefsFreeKey) ?? true;
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        config.value = UnblockSourceConfig.fromJson(decoded);
      }
    } catch (_) {
      // 存档坏了就当没配过，别卡住启动。
    }
  }

  Future<void> save(UnblockSourceConfig value) async {
    config.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(value.toJson()));
    } catch (_) {}
  }

  Future<void> setFreeFallbackEnabled(bool value) async {
    freeFallbackEnabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsFreeKey, value);
    } catch (_) {}
  }

  Future<void> _rememberKey(int index) async {
    if (_preferredKeyIndex == index) return;
    _preferredKeyIndex = index;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsPreferredKey, index);
    } catch (_) {}
  }

  /// 取歌曲播放地址。
  ///
  /// [platform] 用平台代号（`wy` / `tx` / `kg`）。拿不到返回 null，调用方
  /// 应当跳过这首而不是反复重试。
  ///
  /// [keyword]（「歌名 歌手」）和 [durationMs] 只有免费兜底音源用得上 ——
  /// 酷狗、酷我那两家是按关键词搜的，没有时长就没法从搜索结果里挑对版本，
  /// 很容易匹配到现场版或翻唱。
  Future<String?> resolve({
    required String platform,
    required String songId,
    String? keyword,
    int durationMs = 0,
  }) async {
    await load();
    final cfg = config.value;

    final limitedUntil = _rateLimitedUntil;
    final rateLimited =
        limitedUntil != null && DateTime.now().isBefore(limitedUntil);

    if (cfg.isUsable && !rateLimited) {
      final keys = cfg.apiKeys;
      // 从上次命中的那个开始轮，命中率最高的先试。
      for (var offset = 0; offset < keys.length; offset++) {
        final index = (_preferredKeyIndex + offset) % keys.length;
        final url = await _requestOnce(
          cfg: cfg,
          platform: platform,
          songId: songId,
          apiKey: keys[index],
        );
        if (url != null) {
          await _rememberKey(index);
          // 成功也留一行。之前只在失败时打日志，结果「明明救回来了」
          // 在日志里完全看不出来，排查时误以为音源没生效。
          debugPrint('[Unblock] 聆澜命中 $platform/$songId');
          return url;
        }
      }
      debugPrint('[Unblock] ${keys.length} 个密钥全部未命中：$platform/$songId');
    }

    // 聆澜没配、或者这首它也没有 —— 再试一遍免费的那几家。
    //
    // 原来这里按 `platform != 'wy'` 直接返回，理由是「另外两家的 id 对不上
    // GD Studio 的入参」。那只对 GD Studio 成立：链里的酷狗和酷我都是按
    // 歌名搜的，跟来源无关。拦掉整条等于把 QQ / 酷狗的退路堵死了。
    if (!freeFallbackEnabled.value) return null;
    final numericId = platform == 'wy' ? int.tryParse(songId) : null;
    final query = keyword ?? '';
    // 既没有网易云 id、也没有歌名，那就真没得查了。
    if (numericId == null && query.trim().isEmpty) return null;
    return FreeUnblockSources.resolve(
      neteaseId: numericId,
      keyword: query,
      durationMs: durationMs,
    );
  }

  Future<String?> _requestOnce({
    required UnblockSourceConfig cfg,
    required String platform,
    required String songId,
    required String apiKey,
  }) async {
    final url = cfg.template
        .replaceAll('{source}', platform)
        .replaceAll('{id}', songId)
        .replaceAll('{quality}', cfg.quality);

    final Response<String> response;
    try {
      response = await _dio.get<String>(
        url,
        options: Options(headers: {'X-API-Key': apiKey}),
      );
    } on DioException catch (e) {
      debugPrint('[Unblock] 请求失败：${e.message ?? e.type.name}');
      return null;
    }

    if (response.statusCode == 429) {
      // 限流：歇一会儿，别拿剩下的请求继续撞。
      _rateLimitedUntil = DateTime.now().add(_rateLimitCooldown);
      debugPrint('[Unblock] 被限流（429），${_rateLimitCooldown.inSeconds} 秒内改走免费音源');
      return null;
    }
    if (response.statusCode != 200) {
      debugPrint('[Unblock] HTTP ${response.statusCode}');
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.data ?? '');
    } catch (_) {
      debugPrint('[Unblock] 响应不是合法 JSON');
      return null;
    }
    if (decoded is! Map) return null;

    // 有 code 字段时只有 0 / 200 算成功。
    final code = decoded['code'];
    if (code is int && code != 0 && code != 200) {
      final message = decoded['message'] ?? decoded['msg'] ?? 'code=$code';
      debugPrint('[Unblock] 音源返回失败：$message');
      return null;
    }

    final resolved = _valueAtAnyPath(decoded, 'data.music|data.url|url');
    if (resolved is String && resolved.isNotEmpty) return resolved;
    debugPrint('[Unblock] 响应中没有播放地址');
    return null;
  }

  /// 多个点分路径依次取值，先命中先用。
  ///
  /// 不同音源后端把地址放在不同层级（`data.music` / `data.url` / `url`），
  /// 一次性都试掉，换服务商时多半不用改代码。
  static Object? _valueAtAnyPath(Object? root, String paths) {
    for (final path in paths.split('|')) {
      Object? node = root;
      for (final segment in path.split('.')) {
        if (node is Map && node.containsKey(segment)) {
          node = node[segment];
        } else {
          node = null;
          break;
        }
      }
      if (node != null) return node;
    }
    return null;
  }
}
