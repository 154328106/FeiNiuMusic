import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'free_unblock_sources.dart';
import 'kugou_public_sources.dart';

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

  /// 当前是否处在限流冷却里。
  ///
  /// 调用方要用它区分「这首真没有」和「刚才问太快了」：后者不能把歌记成
  /// 永久不可播，否则一次 429 就能让半个队列在这次启动里彻底消失。
  bool get isRateLimited {
    final until = _rateLimitedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

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
    final paidAvailable = cfg.isUsable && !rateLimited;

    // 第一层：酷狗的公益取址后端。
    //
    // 它们按 hash 取址，正好是我们手里已有的东西，而且实测覆盖了聆澜
    // 「密钥全部未命中」的那几首。放在最前面能把大部分酷狗会员曲挡下来，
    // 聆澜的额度留给它真正救得了的（网易云那边没有替代品）。
    //
    // 只有聆澜确实可用时才允许它「排队太久就让路」。否则让出去等于跌进
    // 按歌名搜的免费链，酷我那家现在多半给一段「请到酷我APP收听」的提示音
    // —— 播不了还会触发自动跳曲，比多等一会儿糟得多。
    //
    // QQ（`tx`）也走这一层：songId 传的就是 songmid，格式和洛雪那套约定
    // 对得上。以前 QQ 的歌**按 id 取址的只有聆澜一家**（GD 只认网易云、
    // 这两家写死了酷狗），剩下的只能掉进按歌名搜的兜底 —— 那条会串到同名
    // 翻唱，酷我还常给「请到酷我APP收听」的提示音。
    //
    // 这两家认不认 `tx` 我没能在本地验证（沙箱连不上它们），所以
    // KugouPublicSources 里带了自熄火：非酷狗的源连撞 3 次没结果就判定
    // 这家不支持，本次运行不再问它，不会每首 QQ 歌都白等两个请求。
    if (platform == 'kg' || platform == 'tx') {
      final url = await KugouPublicSources.resolve(
        songId,
        source: platform,
        allowBail: paidAvailable,
      );
      if (url != null) return url;
    }

    // 第二层：GD 音乐台（只有网易云走得到）。
    //
    // 放在聆澜**前面**，理由是它几乎没有下行风险：按网易云原始 id 取址，
    // 不像酷狗/酷我那两家是搜歌名，串不到同名翻唱上；免费；实测连会员曲都
    // 给，还能按设置里的音质给到无损。命中就省一次聆澜额度，没命中也只是
    // 多一个请求 —— 它本来就在链里，只是从聆澜后面挪到了前面。
    //
    // 注意它只认网易云 id：QQ / 酷狗的歌 [FreeUnblockSources.gdStudio] 用不上，
    // 那两家仍然走后面的关键词兜底。
    final gdNeteaseId = platform == 'wy' && freeFallbackEnabled.value
        ? int.tryParse(songId)
        : null;
    if (gdNeteaseId != null) {
      final url = await FreeUnblockSources.gdStudio(
        gdNeteaseId,
        quality: cfg.quality,
      );
      if (url != null) {
        debugPrint('[Unblock] GD Studio 命中 $platform/$songId');
        return url;
      }
    }

    // 第三层：星海（zddyr）的网易云，给 GD 当备份。
    //
    // 网易云这条链原本单点挂在 GD 上，它一挂就直接掉进付费的聆澜。zddyr
    // 同样按原始 id 取址（已验证不串歌），域名也是酷狗兜底那家、可靠性有底。
    // 放在 GD 后面是因为它明说了有 QPS 限制，GD 命中就不会走到这儿。
    if (gdNeteaseId != null) {
      final url = await FreeUnblockSources.zddyrNetease(
        gdNeteaseId,
        quality: cfg.quality,
      );
      if (url != null) {
        debugPrint('[Unblock] zddyr 命中 $platform/$songId');
        return url;
      }
    }

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

    // 最后一层：按歌名搜的免费兜底（酷狗 → 酷我）。GD 上面已经试过了。
    //
    // 这里不按平台拦：那两家都是「搜歌名再比时长」，跟歌来自哪个平台无关。
    // 原来按 `platform != 'wy'` 直接返回，理由是「id 对不上 GD 的入参」——
    // 那只对 GD 成立，拦掉整条等于把 QQ / 酷狗的退路也堵死了。
    if (!freeFallbackEnabled.value) return null;
    final query = keyword ?? '';
    // 没有歌名就真没得查了（GD 那条按 id 的路在上面已经走完）。
    if (query.trim().isEmpty) return null;
    return FreeUnblockSources.resolve(
      keyword: query,
      durationMs: durationMs,
      quality: cfg.quality,
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
