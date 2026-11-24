import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'free_unblock_sources.dart';
import '../lxscript/lx_source_manager.dart';
import '../qq/qq_api_client.dart';
import '../qq/qq_models.dart';

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
    required this.apiKeys,
    this.ikunKey = '',
    this.quality = '320k',
    this.enabled = true,
  });

  /// 聆澜密钥池。当前 key 没命中就换下一个。
  final List<String> apiKeys;

  /// ikun（聚合音源-A / c.wwwweb.top）密钥，可空。
  final String ikunKey;

  final String quality;
  final bool enabled;

  bool get isUsable => enabled && (apiKeys.isNotEmpty || ikunKey.isNotEmpty);

  static const String lianlanEndpoint =
      'https://source.shiqianjiang.cn/api/music/url'
      '?source={source}&songId={id}&quality={quality}';

  static const String ikunEndpoint = 'https://c.wwwweb.top/music/url';

  static const UnblockSourceConfig empty = UnblockSourceConfig(apiKeys: []);

  UnblockSourceConfig copyWith({
    List<String>? apiKeys,
    String? ikunKey,
    String? quality,
    bool? enabled,
  }) => UnblockSourceConfig(
    apiKeys: apiKeys ?? this.apiKeys,
    ikunKey: ikunKey ?? this.ikunKey,
    quality: quality ?? this.quality,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'apiKeys': apiKeys,
    'ikunKey': ikunKey,
    'quality': quality,
    'enabled': enabled,
  };

  static UnblockSourceConfig fromJson(Map<String, Object?> json) =>
      UnblockSourceConfig(
        apiKeys:
            (json['apiKeys'] as List?)?.whereType<String>().toList() ??
            const [],
        ikunKey: json['ikunKey'] as String? ?? '',
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
  static const String _prefsPreferLxKey = 'unblock.source.preferLx';

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

  /// 最近一次 [resolve] 命中的音源标签（脚本 / GD / 聆澜 / ikun / 免费源…）。
  /// 供播放日志取「这首歌最终走了谁」。
  String? _lastSourceLabel;
  String? get lastSourceLabel => _lastSourceLabel;

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

  /// 优先走外置音源（用户导入的 LX/JS 脚本）。默认关：开了就把脚本提到取址链
  /// 最前面，官方 ID 源（公益 / GD / zddyr / 聆澜）和关键词兜底全往后排，脚本
  /// 没命中时再照常走内置那条链。适合自备优质脚本、想先吃脚本的无损/Hi-Res 的人。
  final ValueNotifier<bool> preferLxEnabled = ValueNotifier(false);

  /// 蜂窝数据下自动把取址音质降到 128k。**默认关** —— 悄悄换音质是会被察觉的，
  /// 得用户自己同意。开了之后只影响解灰/脚本取址这一路，不动已下载的本地文件，
  /// 也不动飞牛 NAS 的原始流（那是内网，不走流量）。
  final ValueNotifier<bool> cellularDowngradeEnabled = ValueNotifier(false);

  static const String _prefsCellularDowngradeKey =
      'unblock.source.cellularDowngrade';

  /// 蜂窝数据下用这个音质。128k 是取址成功率最高的档（实测各脚本在 flac 下
  /// 经常跑满超时，320k 好很多，128k 最稳），省流量只是顺带。
  static const String _cellularQuality = '128k';

  /// 当前是否在蜂窝数据上。由 [_watchConnectivity] 维护；拿不到就当不是
  /// （宁可按原音质走，也不要在 WiFi 上误降）。
  bool _onCellular = false;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// 这次取址实际该用的音质。
  ///
  /// 所有取址点都必须读它而不是 `config.value.quality` —— 否则加了开关也只有
  /// 一部分链路会降，表现成「开了没用」。
  String get effectiveQuality {
    if (cellularDowngradeEnabled.value && _onCellular) return _cellularQuality;
    return config.value.quality;
  }

  void _watchConnectivity() {
    if (_connectivitySub != null) return;
    void apply(List<ConnectivityResult> results) {
      final cellular = results.contains(ConnectivityResult.mobile);
      if (cellular == _onCellular) return;
      _onCellular = cellular;
      debugPrint(
        '[Unblock] 网络类型变化 → ${cellular ? "蜂窝数据" : "非蜂窝"}，'
        '自动降音质${cellularDowngradeEnabled.value ? "已开启" : "未开启"}，'
        '当前取址音质=$effectiveQuality',
      );
    }

    // 整个订阅必须兜住：拿不到网络类型只是「降音质这个增强用不了」，安静退回
    // 按原音质走就行，绝不能让它把调用方（load / 备份还原）带崩。
    // 单元测试里没有平台通道，Connectivity 会抛 MissingPluginException——
    // 以前漏了 onError，流上的错误成了未捕获异步异常，直接把 backup_service_test
    // 搞挂了。
    try {
      _connectivitySub = Connectivity().onConnectivityChanged.listen(
        apply,
        onError: (Object e) {
          debugPrint('[Unblock] 网络类型监听出错，降音质功能停用：$e');
        },
        cancelOnError: false,
      );
      // onConnectivityChanged 只在**变化**时才给值，冷启动后如果网络一直没变
      // 就一直收不到，_onCellular 会停在 false。所以这里先主动查一次当前状态。
      unawaited(
        Connectivity()
            .checkConnectivity()
            .then(apply)
            .catchError((Object _) {}),
      );
    } catch (e) {
      debugPrint('[Unblock] 订阅网络类型失败，降音质功能停用：$e');
    }
  }

  static const Object _backgroundZoneKey = #unblockBackground;

  /// 在「后台预取」上下文里跑 [body]：播放队列里除了点的那首，其余歌的取址都算后台。
  /// 后台取址不吃「优先走外置音源」（照常走内置链，LX 排在后面），在 LX 串行闸里
  /// 也排在前台请求后面 —— 否则一个几十首的队列会把闸堵死，切源/点歌/测试脚本全卡住。
  static Future<T> runInBackground<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_backgroundZoneKey: true});

  static bool get isBackground => Zone.current[_backgroundZoneKey] == true;

  bool get isUsable => config.value.isUsable;

  /// 免费音源（GD / 按歌名搜）这次到底用不用。
  ///
  /// 「保证能播」（2026-11-05 用户要求）：用户关了免费兜底，本意是「只用我配的
  /// 音源」；可要是聆澜没配好、也没启用任何音源脚本，那就等于什么都没有，一首
  /// 会员歌都放不出来。这种情况下照样用免费音源，设置页上也会提示。
  bool get freeFallbackActive =>
      freeFallbackEnabled.value ||
      (!config.value.isUsable && !LxSourceManager.instance.hasEnabled);

  /// 备份还原后调用：丢掉内存里的旧状态，按存档重新读一遍（否则下次保存会把还原的数据覆盖回去）。
  Future<void> reloadFromStorage() async {
    _loaded = false;
    config.value = UnblockSourceConfig.empty;
    await load();
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _preferredKeyIndex = prefs.getInt(_prefsPreferredKey) ?? 0;
      freeFallbackEnabled.value = prefs.getBool(_prefsFreeKey) ?? true;
      preferLxEnabled.value = prefs.getBool(_prefsPreferLxKey) ?? false;
      cellularDowngradeEnabled.value =
          prefs.getBool(_prefsCellularDowngradeKey) ?? false;
      // 开关关着就不订阅：既省掉一个常驻监听，也避免在没有平台通道的环境
      // （单元测试、binding 未初始化）里白白去碰 connectivity 插件。
      if (cellularDowngradeEnabled.value) _watchConnectivity();
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

  Future<void> setPreferLxEnabled(bool value) async {
    preferLxEnabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsPreferLxKey, value);
    } catch (_) {}
  }

  Future<void> setCellularDowngradeEnabled(bool value) async {
    cellularDowngradeEnabled.value = value;
    if (value) _watchConnectivity(); // 没开过开关时还没订阅，这里补上
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsCellularDowngradeKey, value);
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
  /// [noCopyright]：网易云官方明确回了「无版权」（code 404，下架歌）。这类歌
  /// 按网易 id 取址的来源（GD / 星海 / 聆澜 / LX 脚本）实测全都拿不到，以前
  /// 每首要白跑一遍才掉到按歌名搜，约 8～9 秒、刷一大屏日志；现在直接按歌名搜。
  Future<String?> resolve({
    required String platform,
    required String songId,
    String? keyword,
    int durationMs = 0,
    String? name,
    String? singer,
    bool noCopyright = false,
  }) async {
    await load();
    final cfg = config.value;

    if (noCopyright && platform == 'wy') {
      debugPrint('[Unblock] wy/$songId 网易无版权（下架），直接按歌名搜');
      return _resolveByKeyword(
        cfg,
        keyword,
        durationMs,
        platform: platform,
        background: isBackground,
      );
    }

    final background = isBackground;
    final hostCovers = platform == 'wy' && freeFallbackActive
        ? const ['gdstudio', 'zddyr']
        : const <String>[];

    final rateLimited = _rateLimitedUntil != null &&
        DateTime.now().isBefore(_rateLimitedUntil!);
    final paidAvailable = cfg.enabled && !rateLimited;
    final gdNeteaseId = platform == 'wy' && freeFallbackActive
        ? int.tryParse(songId)
        : null;
    final lxEnabled =
        preferLxEnabled.value && LxSourceManager.instance.hasEnabledFor(platform);

    Future<String?> tryLx(bool bg) => LxSourceManager.instance.resolve(
      platform: platform,
      songId: songId,
      name: name,
      singer: singer,
      quality: effectiveQuality,
      background: bg,
      hostCovers: hostCovers,
    );

    Future<String?> tryLianlan() => _requestLianlan(cfg, platform, songId);

    Future<String?> tryIkun() =>
        _ikunOnce(platform, songId, effectiveQuality, cfg.ikunKey);

    Future<String?> tryGd() => gdNeteaseId != null
        ? FreeUnblockSources.gdStudio(gdNeteaseId, quality: effectiveQuality)
        : Future.value(null);

    if (!background) {
      final candidates = <(String, Future<String?>)>[];
      if (lxEnabled) candidates.add(('脚本', guardNull(() => tryLx(false))));
      if (gdNeteaseId != null) candidates.add(('GD', guardNull(tryGd)));
      if (cfg.apiKeys.isNotEmpty && paidAvailable) {
        candidates.add(('聆澜', guardNull(tryLianlan)));
      }
      if (cfg.ikunKey.isNotEmpty && paidAvailable) {
        candidates.add(('爱酷', guardNull(tryIkun)));
      }
      final (url, label) = await firstLabeled(candidates);
      _lastSourceLabel = label.isEmpty ? null : label;
      if (url != null) {
        debugPrint('[Unblock] 竞速命中 $platform/$songId（$label）');
        return url;
      }
    } else {
      if (lxEnabled) {
        final lxUrl = await tryLx(true);
        if (lxUrl != null) {
          _lastSourceLabel = '脚本';
          return lxUrl;
        }
      }
      if (cfg.apiKeys.isNotEmpty && paidAvailable) {
        final lianlan = await tryLianlan();
        if (lianlan != null) {
          _lastSourceLabel = '聆澜';
          return lianlan;
        }
      }
      if (cfg.ikunKey.isNotEmpty && paidAvailable) {
        final ikun = await tryIkun();
        if (ikun != null) {
          _lastSourceLabel = '爱酷';
          return ikun;
        }
      }
    }

    final kwUrl = await _resolveByKeyword(
      cfg,
      keyword,
      durationMs,
      platform: platform,
      background: background,
    );
    if (kwUrl != null) _lastSourceLabel = '免费源';
    return kwUrl;
  }

  /// 跑一个可能抛异常的取址，异常一律折成 null，不拖垮竞速池。
  static Future<String?> guardNull(Future<String?> Function() body) async {
    try {
      return await body();
    } catch (e) {
      debugPrint('[Unblock] 竞速成员失败：$e');
      return null;
    }
  }

  /// 并发竞速：返回第一个非空结果；全空返回 null。
  static Future<String?> firstNonNull(List<Future<String?>> futures) {
    if (futures.isEmpty) return Future.value(null);
    final completer = Completer<String?>();
    var remaining = futures.length;
    for (final future in futures) {
      future.then((value) {
        if (completer.isCompleted) return;
        if (value != null && value.isNotEmpty) {
          completer.complete(value);
          return;
        }
        remaining--;
        if (remaining == 0) completer.complete(null);
      });
    }
    return completer.future;
  }

  /// 带标签的并发竞速：返回 (第一个非空地址, 它的标签)；全空返回 (null, '')。
  static Future<(String?, String)> firstLabeled(
    List<(String, Future<String?>)> items,
  ) {
    if (items.isEmpty) return Future.value((null, ''));
    final completer = Completer<(String?, String)>();
    var remaining = items.length;
    for (final (label, future) in items) {
      future.then((value) {
        if (completer.isCompleted) return;
        if (value != null && value.isNotEmpty) {
          completer.complete((value, label));
          return;
        }
        remaining--;
        if (remaining == 0) completer.complete((null, ''));
      });
    }
    return completer.future;
  }

  /// 聆澜（X-API-Key 协议）取址：从上次命中的密钥开始轮。
  Future<String?> _requestLianlan(
    UnblockSourceConfig cfg,
    String platform,
    String songId,
  ) async {
    final keys = cfg.apiKeys;
    for (var offset = 0; offset < keys.length; offset++) {
      final index = (_preferredKeyIndex + offset) % keys.length;
      final url = await _requestOnce(
        platform: platform,
        songId: songId,
        apiKey: keys[index],
      );
      if (url != null) {
        await _rememberKey(index);
        debugPrint('[Unblock] 聆澜命中 $platform/$songId');
        return url;
      }
    }
    debugPrint('[Unblock] ${keys.length} 个密钥全部未命中：$platform/$songId');
    return null;
  }

  /// ikun（聚合音源-A / c.wwwweb.top）取址。
  Future<String?> _ikunOnce(
    String platform,
    String songId,
    String quality,
    String apiKey,
  ) async {
    if (apiKey.isEmpty) return null;
    try {
      final response = await _dio.post<String>(
        UnblockSourceConfig.ikunEndpoint,
        data: {'source': platform, 'musicId': songId, 'quality': quality},
        options: Options(
          headers: {'Content-Type': 'application/json', 'X-Api-Key': apiKey},
        ),
      );
      if (response.statusCode != 200) {
        debugPrint(
          '[Unblock] ikun HTTP ${response.statusCode}：${_errorText(response.data)}',
        );
        return null;
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(response.data ?? '');
      } catch (_) {
        return null;
      }
      if (decoded is! Map) return null;
      final code = decoded['code'];
      if (code is int && code != 200 && code != 0) {
        final message = decoded['message'] ?? decoded['msg'] ?? 'code=$code';
        debugPrint('[Unblock] ikun 返回失败：$message');
        return null;
      }
      final resolved = _valueAtAnyPath(decoded, 'url|data.url');
      if (resolved is String && resolved.isNotEmpty) return resolved;
      return null;
    } on DioException catch (e) {
      debugPrint('[Unblock] ikun 请求失败：${e.message ?? e.type.name}');
      return null;
    }
  }

  /// 按「歌名 歌手」去别家找：酷狗 → 酷我 → QQ。
  Future<String?> _resolveByKeyword(
    UnblockSourceConfig cfg,
    String? keyword,
    int durationMs, {
    required String platform,
    required bool background,
  }) async {
    if (!freeFallbackActive) return null;
    final query = keyword ?? '';
    // 没有歌名就真没得查了（GD 那条按 id 的路在上面已经走完）。
    if (query.trim().isEmpty) return null;
    final url = await FreeUnblockSources.resolve(
      keyword: query,
      durationMs: durationMs,
      quality: effectiveQuality,
    );
    if (url != null) return url;
    // 本来就是 QQ 的歌，按 id 已经问过了，不再搜一遍自己。
    if (platform == 'tx') return null;
    return _qqByKeyword(query, durationMs, background: background);
  }

  /// 从 QQ 搜索结果里挑「就是这首」的那条，挑不到返回 null（宁可放弃不播错）。
  ///
  /// 歌名（去掉「(国语)」「(Live)」这类括号注记）必须出现在关键词里，有时长
  /// 时时长还要差 5 秒以内。只看时长不够：搜「不负如来不负卿 林峯」，第一条是
  /// 时长一模一样（267s）的粤语版《也无风雨也无月》。
  @visibleForTesting
  static QQSong? pickQQMatch(
    List<QQSong> songs,
    String keyword,
    int durationMs,
  ) {
    final kw = _normTitle(keyword);
    for (final s in songs) {
      final title = _normTitle(s.name);
      final nameOk = title.isNotEmpty && kw.contains(title);
      final timeOk =
          durationMs <= 0 ||
          (s.durationMs > 0 && (s.durationMs - durationMs).abs() < 5000);
      if (nameOk && timeOk) return s;
    }
    return null;
  }

  /// 去掉括号注记、空白和常见标点，转小写，用来比歌名。
  static String _normTitle(String s) => s
      .replaceAll(RegExp(r'[（(\[【][^）)\]】]*[）)\]】]'), '')
      .replaceAll(RegExp(r'[\s·・\-—_,，.。!！?？:：/&、]+'), '')
      .toLowerCase();

  /// QQ 按歌名兜底：用 QQ 自己的搜索找到这首的 mid，再交给声明支持 QQ 的
  /// 音源脚本取地址。
  ///
  /// 比酷狗 / 酷我那两家挑得严：那边对不上时长会退回第一条，这里**时长差
  /// 5 秒以内**才算（没有时长就要求歌名对得上），宁可放弃也不播错歌。
  Future<String?> _qqByKeyword(
    String keyword,
    int durationMs, {
    required bool background,
  }) async {
    try {
      final songs = await QQApiClient.instance.searchSongs(keyword, limit: 5);
      final match = pickQQMatch(songs, keyword, durationMs);
      if (match == null) return null;
      // 音质跟设置走，同上。这里不在 resolve() 作用域里，直接读 config。
      final url = await LxSourceManager.instance.resolve(
        platform: 'tx',
        songId: match.mid,
        name: match.name,
        singer: match.artists,
        quality: effectiveQuality,
        background: background,
      );
      if (url != null) {
        debugPrint('[Unblock] QQ 按歌名命中 $keyword → tx/${match.mid}');
      }
      return url;
    } catch (e) {
      debugPrint('[Unblock] QQ 按歌名搜失败：$e');
      return null;
    }
  }

  Future<String?> _requestOnce({
    required String platform,
    required String songId,
    required String apiKey,
  }) async {
    final url = UnblockSourceConfig.lianlanEndpoint
        .replaceAll('{source}', platform)
        .replaceAll('{id}', songId)
        .replaceAll('{quality}', effectiveQuality);

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
      // 把对方的原话带上：401「API密钥不存在或已被禁用」是密钥坏了，500 多半是
      // 这首歌它也没有。只打状态码时两者分不清，曾被误判成「聆澜整个挂了」。
      debugPrint(
        '[Unblock] 聆澜 HTTP ${response.statusCode} 密钥#${_keyTail(apiKey)}：'
        '${_errorText(response.data)}',
      );
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

  /// 日志里只露密钥末 5 位，够认是哪一把，又不把整把钥匙写进日志。
  static String _keyTail(String key) =>
      key.length <= 5 ? key : key.substring(key.length - 5);

  /// 错误响应里的人话：优先 JSON 的 message / msg，否则截正文前 80 字。
  static String _errorText(String? body) {
    final raw = (body ?? '').trim();
    if (raw.isEmpty) return '（无正文）';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final msg = decoded['message'] ?? decoded['msg'] ?? decoded['error'];
        if (msg != null && '$msg'.isNotEmpty) return '$msg';
      }
    } catch (_) {}
    return raw.length > 80 ? '${raw.substring(0, 80)}…' : raw;
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
