import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'free_unblock_sources.dart';
import 'kugou_public_sources.dart';
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
  /// [skipPublicSources] 给已经自己问过公益源的调用方用（扣扣音乐那边
  /// 把公益源提到了官方地址**前面**，因为官方只给 128k）。不跳过的话每首
  /// 歌会把同一个请求对着公益服务打两遍 —— 作者明说了「切勿短时间批量」。
  /// [noCopyright]：网易云官方明确回了「无版权」（code 404，下架歌）。这类歌
  /// 按网易 id 取址的来源（GD / 星海 / 聆澜 / LX 脚本）实测全都拿不到，以前
  /// 每首要白跑一遍才掉到按歌名搜，约 8～9 秒、刷一大屏日志；现在直接按歌名搜。
  Future<String?> resolve({
    required String platform,
    required String songId,
    String? keyword,
    int durationMs = 0,
    bool skipPublicSources = false,
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

    // GD / 星海这两家 App 自己会问（只限网易云、且开着免费兜底）。告诉 LX 脚本
    // 一声，脚本里同样的后端就不用再打一遍 —— 之前一首没命中的歌，GD 和星海
    // 会被 App 和「网易专用」脚本各问一次。脚本认不认这个字段随它，不认也没坏处。
    final hostCovers = platform == 'wy' && freeFallbackActive
        ? const ['gdstudio', 'zddyr']
        : const <String>[];

    // 第〇层（可选）：优先走外置音源。开了「优先走外置音源」就先问用户导入的
    // LX/JS 脚本，命中直接用，官方 ID 源和兜底全让路。没命中则置 lxTried，下面
    // 那次脚本调用跳过 —— flutter_js 的运行时不经得起同一首歌连驱两遍。
    var lxTried = false;
    final background = isBackground;
    // 开了「优先」但没有能用的脚本（没导入 / 全关了 / 都不支持这个平台）：
    // 当没开，直接走内置链，不白等。
    if (preferLxEnabled.value &&
        !background &&
        LxSourceManager.instance.hasEnabledFor(platform)) {
      // 音质跟设置走（默认 320k），不要吃 [LxSourceManager.resolve] 的默认值
      // 'flac'：2026-11-12 实测三个主流五源脚本，flac 下网易云/QQ 经常跑满 6 秒
      // 超时（拿不到无损就一路试下家），连撞两次就被熔断 3 分钟；换 320k 后同样
      // 的歌 0.3~2.5 秒就给。下面 GD 那条路本来就用 cfg.quality，这里跟它对齐。
      final url = await LxSourceManager.instance.resolve(
        platform: platform,
        songId: songId,
        name: name,
        singer: singer,
        quality: cfg.quality,
        hostCovers: hostCovers,
      );
      lxTried = true;
      if (url != null) {
        debugPrint('[Unblock] LX 脚本（优先）命中 $platform/$songId');
        return url;
      }
    }

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
    if (!skipPublicSources && (platform == 'kg' || platform == 'tx')) {
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
    final gdNeteaseId = platform == 'wy' && freeFallbackActive
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

    // LX（洛雪）脚本音源：用户导入的第三方脚本，按平台代号匹配取址。
    // 前台：放在官方 ID 源（GD / zddyr / 聆澜）之后、关键词兜底之前 —— 它们
    // 按原始 id 取址更准，脚本作为补充。
    // 后台预取：提到聆澜**前面**。2026-11-05 日志：打开 95 首的酷狗歌单，整队
    // 预取 11 秒里把聆澜打了约 70 次、还吃了一次 429；而用户的「聚合音源-A」
    // 0.1～0.4 秒就能给、不花额度。聆澜是有额度的公益卡，留给脚本救不了的歌。
    Future<String?> tryLx() async {
      lxTried = true;
      // 音质跟设置走，同上（别吃 'flac' 默认值，会跑满超时触发熔断）。
      final lxUrl = await LxSourceManager.instance.resolve(
        platform: platform,
        songId: songId,
        name: name,
        singer: singer,
        quality: cfg.quality,
        background: background,
        hostCovers: hostCovers,
      );
      if (lxUrl != null) {
        debugPrint('[Unblock] LX 脚本命中 $platform/$songId');
      }
      return lxUrl;
    }

    if (background && !lxTried) {
      final lxUrl = await tryLx();
      if (lxUrl != null) return lxUrl;
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

    if (!lxTried) {
      final lxUrl = await tryLx();
      if (lxUrl != null) return lxUrl;
    }

    // 最后一层：按歌名搜的免费兜底（酷狗 → 酷我）。GD 上面已经试过了。
    //
    // 这里不按平台拦：那两家都是「搜歌名再比时长」，跟歌来自哪个平台无关。
    // 原来按 `platform != 'wy'` 直接返回，理由是「id 对不上 GD 的入参」——
    // 那只对 GD 成立，拦掉整条等于把 QQ / 酷狗的退路也堵死了。
    return _resolveByKeyword(
      cfg,
      keyword,
      durationMs,
      platform: platform,
      background: background,
    );
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
      quality: cfg.quality,
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
        quality: config.value.quality,
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
