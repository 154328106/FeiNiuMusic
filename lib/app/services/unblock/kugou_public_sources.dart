import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 酷狗会员曲的公益取址后端。
///
/// 这两家是从洛雪音乐的自定义音源脚本里实测出来的：它们按**酷狗 hash**
/// 取址，而我们手里本来就有 hash（`kg:` 前缀里那个），不需要像免费兜底
/// 那条链一样按歌名搜再比时长 —— 也就没有匹配到翻唱、现场版的风险。
///
/// 实测（用日志里真实的会员曲 hash）：5/5 都拿到 24–32MB 的 flac，其中两首
/// 是聆澜报过「密钥全部未命中」的。所以放在聆澜**前面**当第一层：
/// 大部分酷狗会员曲在这里就解决了，聆澜的额度留给它真正救得了的。
///
/// **顺序不能反过来。** 这是公益服务，没有任何可用性承诺，说没就没
/// （同一批脚本里 ikun 那家的域名已经不解析了）。放在前面时它挂了只是
/// 回落到聆澜；放在后面则会在某天早上突然满屏灰歌。
class KugouPublicSources {
  KugouPublicSources._();

  /// 请求之间的最小间隔。
  ///
  /// 这两家的作者都写了「公益音源，切勿短时间批量下载」。我们起播会一次
  /// 准备 25 首，对它们来说就是批量 —— 所以这里**串行 + 限速**，不复用
  /// 聆澜那条链的并发闸（那个是 8 并发）。慢一点无所谓：解析是在后台跑的，
  /// 而且命中一次就进缓存，一首歌 45 分钟内不会再问第二遍。
  static const Duration _minInterval = Duration(milliseconds: 200);

  /// 整条链的超时。两家都试完还没结果就交给聆澜，别让起播一直卡着。
  static const Duration _timeout = Duration(seconds: 5);

  /// 排队等待的上限。**按真实等待时间算**，不是估算。
  ///
  /// 没有这道闸的话，串行限速会跟起播打架：一次准备 25 首、其中 20 首是
  /// 会员曲，光排队就 7 秒起步，起播肉眼可见地变慢。
  ///
  /// 有了它，行为自然分成两种：零星播放（切歌、加载封面页）全部走公益源；
  /// 起播那种突发批量则只有前几首走，剩下的立刻回落到聆澜 —— 既没有拖慢
  /// 起播，又实实在在削掉了一部分聆澜的请求。而且命中的会进缓存，越用
  /// 越多的歌不需要再问任何人。
  ///
  /// 第一版是拿「排队人数 × 间隔」估算等待时间的，估错了四倍：实际每首
  /// 要 1.5 秒（因为上面那个 201 的 bug，每首都白等一家），闸门形同虚设，
  /// 起播要卡十几秒。现在改成进队时打时间戳、轮到自己再看真的过了多久。
  static const Duration _maxQueueWait = Duration(milliseconds: 1200);

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      sendTimeout: _timeout,
      responseType: ResponseType.plain,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
      // 4xx/5xx 自己判，不抛异常 —— 这条链失败是常态，不该走异常流程。
      validateStatus: (_) => true,
    ),
  );

  /// 并发通道数。
  ///
  /// 一开始是纯串行（一条），但一次请求要 ~600ms，而起播准备 25~30 首时
  /// 它就卡在关键路径上：实测 30 首要 11 秒。两条通道把这个减半，同时因为
  /// 排队上限是按时间算的，同样的 1.2 秒里能放行的歌反而变多了 —— 快和省
  /// 两头都好。两条 × ~600ms 约等于 3 次/秒的瞬时峰值，而且被排队上限
  /// 掐着，只在起播那一下出现，不构成作者说的「短时间批量下载」。
  static const int _lanes = 2;

  /// 每条通道一个串行链，进来的排到最空的那条。
  static final List<Future<void>> _gates = List.filled(_lanes, Future.value());
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  static int _nextLane = 0;

  /// 连续失败到这个时刻之前，整条链直接跳过。
  ///
  /// 服务挂掉时不该每首歌都去撞一次超时 —— 那会让起播平白多等 5 秒 × N。
  /// **按源分开记。** 一开始这两个是全局的，等到 QQ 也走这条链时就成了
  /// 定时炸弹：万一这两家不认 `tx`，连撞 5 次会把酷狗那条本来好好的链
  /// 一起熄火 10 分钟。
  static final Map<String, DateTime> _skipUntil = {};
  static final Map<String, int> _consecutiveFailures = {};
  static const int _failureThreshold = 5;
  static const Duration _skipCooldown = Duration(minutes: 10);

  /// 已确认不支持的「接口 × 源」组合，本次运行不再尝试。
  ///
  /// **只认接口自己说的话**（HTTP 语义的 400/401/403），不再用「连撞 N 次
  /// 没结果」去猜。第一版用的就是猜：真机日志里 haitangw 前面连中 50 次，
  /// 只因为碰上连着几首它真没货的歌（几首韩语歌）就被判成「不支持 tx」停掉，
  /// 还连锁触发了全局 10 分钟熄火。「不支持」和「这几首没货」这两件事，
  /// 从「没给地址」上根本分不出来，只有接口明说才算数：
  /// - zddyr 对 QQ 回 `code 403 / QQ 音乐仅对认证用户开放`
  /// - zddyr 对 tx 回 `code 400 / source 无效，支持 kg/kw/qq/...`
  static final Set<String> _unsupported = {};

  /// 每个「接口 × 源」组合只留一次原始返回，用来判断到底是不支持还是没货。
  /// 没法在本地联网验证这两家认不认 `tx`，只能让真机来回答。
  ///
  /// 各接口**最近一次**响应，连同它是给哪个 rid 的。key 是 `接口/源`。
  ///
  /// 早先这里是「本次运行只记第一条」，结果被 App 后台的解析抢先占了坑 ——
  /// 探测报告里贴出来的原始返回根本不是探测自己发的那次请求，我据此判过一次
  /// 「vkeys 会换歌」，是错的。现在每次都覆盖，并且带上 rid，让调用方能核对
  /// 这条到底是不是自己那次的。
  static final Map<String, ({String rid, String summary})> probes = {};
  static final Set<String> _probeLogged = {};

  /// 清掉一次探测的痕迹，让「探测」按钮可以反复按。
  ///
  /// 不碰 [_skipUntil] / [_consecutiveFailures]：那两个是真实的服务健康度，
  /// 不该被一次手动探测重置掉。
  static void resetProbes() {
    probes.clear();
    _probeLogged.clear();
    _unsupported.clear();
  }

  /// 取酷狗某个 hash 的播放地址，拿不到返回 null。
  ///
  /// [hash] 是酷狗的文件 hash（大写十六进制）。
  ///
  /// [allowBail] 表示「排队太久时可以放弃、交给下一层」。**只有下一层确实
  /// 存在时才该传 true。** 聆澜没配（或正被限流）的时候让出去，下一层就是
  /// 按歌名搜的免费链 —— 酷我那家现在多半返回「请到酷我APP收听」的提示音，
  /// 播不了、还会让播放器自动跳到下一首。宁可多等一会儿也比这个强。
  /// [source] 是洛雪系的源代号：酷狗 `kg`（[rid] 传文件 hash）、QQ `tx`
  /// （[rid] 传 songmid）。QQ 这条是推测 —— 这两家本来就是洛雪音源脚本里
  /// 扒出来的，`tx` 是那套约定里的标准代号，而我们手上正好有 songmid。
  /// 不支持也只是白问一次就自动停，不会比现在更差。
  /// [durationMs] 是这首歌应有的时长，用来拦试听片段（见 [_looksComplete]）。
  /// 传 0 表示不知道，那道闸就退化成一个很松的绝对下限。
  static Future<String?> resolve(
    String rid, {
    String source = 'kg',
    bool allowBail = true,
    int durationMs = 0,
  }) async {
    if (rid.isEmpty) return null;
    if (_allRefused(source)) return null;
    final skip = _skipUntil[source];
    if (skip != null && DateTime.now().isBefore(skip)) return null;

    final enqueuedAt = DateTime.now();
    final completer = Completer<String?>();
    // 排进某条通道。前一个的成败不影响后一个，所以用 then 而不是 await 链。
    final lane = _nextLane;
    _nextLane = (_nextLane + 1) % _lanes;
    _gates[lane] = _gates[lane].then((_) async {
      try {
        // 轮到自己了，先看已经等了多久。等太久说明前面排了一长串（起播那种
        // 突发），这时候再去问只会继续拖着播放器 —— 直接让给聆澜。
        if (allowBail &&
            DateTime.now().difference(enqueuedAt) > _maxQueueWait) {
          completer.complete(null);
          return;
        }
        final wait = _minInterval - DateTime.now().difference(_lastAt);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        final url = await _resolveOnce(rid, source, durationMs);
        _lastAt = DateTime.now();
        if (url != null) {
          _consecutiveFailures[source] = 0;
        } else {
          final n = (_consecutiveFailures[source] ?? 0) + 1;
          _consecutiveFailures[source] = n;
          if (n >= _failureThreshold) {
            _skipUntil[source] = DateTime.now().add(_skipCooldown);
            _consecutiveFailures[source] = 0;
            debugPrint(
              '[公益音源] $source 连续 $_failureThreshold 次没结果，'
              '${_skipCooldown.inMinutes} 分钟内不再尝试',
            );
          }
        }
        completer.complete(url);
      } catch (e) {
        _lastAt = DateTime.now();
        completer.complete(null);
      }
    });
    return completer.future;
  }

  /// 问的顺序。haitangw 排头是实测结果（QQ 那轮 50 首几乎全中）。
  ///
  /// **第三个兜底槽位试过三家，全躺，已经撤掉**（2026-09-10 真机逐个探过）：
  /// - `88.lxmusic.中国` → 404，`/lxmusicv3/` 没了，只剩 `/lxmusicv4/...?sign=`
  /// - `lxmusicapi.onrender.com` → 503 `Service Suspended`，实例被永久停用
  /// - `m-api.ceseet.me` → 403 `error code: 1000`（Cloudflare 拦截）
  ///
  /// 第四个候选 vkeys 只认 QQ（见 [_vkeys]），排最后。
  static const List<String> _endpoints = ['haitangw', 'zddyr', 'vkeys'];

  /// 上一次真正给出地址的那家，下次从它开始问。
  ///
  /// 一家挂了的时候，固定顺序意味着每首歌都要先白等它一次。记住赢家能把
  /// 这份浪费省掉 —— 这正是 201 那个 bug 被放大的原因。
  static String _lastGood = 'haitangw';

  static Future<String?> _call(String endpoint, String rid, String source) {
    switch (endpoint) {
      case 'zddyr':
        return _zddyr(rid, source);
      case 'vkeys':
        return _vkeys(rid, source);
      default:
        return _haitangw(rid, source);
    }
  }

  /// 会返回试听片段、需要验体积的接口。
  ///
  /// vkeys 真机实测 5 首里有 2 首回的是 0.9MB 的 30 秒片段（晴天、孤勇者），
  /// 地址和状态码都挑不出毛病 —— 只有体积不对。不拦的话播 30 秒就自动跳，
  /// 表现成「歌总是莫名跳过」，很难看出是音源的问题。
  ///
  /// haitangw / zddyr 不在此列：它们给的一直是完整文件，多花一次 HEAD 不值。
  static const Set<String> _needsSizeCheck = {'vkeys'};

  static Future<String?> _resolveOnce(
    String rid,
    String source,
    int durationMs,
  ) async {
    final order = [
      _lastGood,
      for (final e in _endpoints)
        if (e != _lastGood) e,
    ];
    for (final name in order) {
      final combo = '$name/$source';
      if (_unsupported.contains(combo)) continue;
      var url = await _call(name, rid, source);
      if (url != null && _needsSizeCheck.contains(name)) {
        if (!await _looksComplete(url, durationMs)) {
          debugPrint('[公益音源] $name 给的是试听片段，丢弃：$source/$rid');
          url = null;
        }
      }
      if (url != null) {
        _lastGood = name;
        debugPrint('[公益音源] $name 命中 $source/$rid');
        return url;
      }
    }
    return null;
  }

  /// 接口明说了不支持这个源就记下来，本次运行不再问它。
  ///
  /// 400/401/403 是「这个请求本身不该发」，和「这首歌我没有」（那是 code 0
  /// 但没 url，或者 404/5xx）是两回事，不会被没货的歌误触发。
  static void _noteRefusal(String endpoint, String source, Object? code) {
    if (code is! num) return;
    final n = code.toInt();
    if (n != 400 && n != 401 && n != 403) return;
    final combo = '$endpoint/$source';
    if (_unsupported.add(combo)) {
      debugPrint('[公益音源] $combo 被接口拒绝（code $n），本次运行不再尝试');
    }
  }

  /// 两家都拒了这个源 —— 直接不走这条链，也别去动服务健康度的计数。
  ///
  /// 不加这道判断的话，被拒之后每首歌都会「空转一次、记一笔失败」，攒够 5 次
  /// 就把整个源熄火 10 分钟 —— 真机日志里那两行 `tx 连续 5 次没结果` 就是
  /// 这么来的，跟服务好不好一点关系都没有。
  static bool _allRefused(String source) =>
      _endpoints.every((e) => _unsupported.contains('$e/$source'));

  /// 两家的源代号不一样，得分别翻译。
  ///
  /// haitangw 认 `tx`（实测 code 0 + 真地址）；zddyr 明说自己支持
  /// `kg/kw/qq/migu/kuwo/netease/wy` —— QQ 在它那儿叫 `qq`。我当初按洛雪
  /// 那套约定给两家都传 `tx`，zddyr 就一直回 400「source 无效」。
  static String _sourceCode(String endpoint, String platform) {
    if (platform != 'tx') return platform;
    return endpoint == 'zddyr' ? 'qq' : 'tx';
  }

  /// `{"code":0,"data":{"url":"..."}}`
  ///
  /// 它的 `rid` 本来就是通用的「这个源的曲目 id」，换源只要改 source。
  static Future<String?> _haitangw(String rid, String source) async {
    try {
      final res = await _dio.post<String>(
        'https://musicserver.haitangw.cc/v1/music/resolve-url',
        data: {
          'source': _sourceCode('haitangw', source),
          'rid': rid,
          'level': 'lossless',
        },
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      _probe('haitangw', source, rid, res);
      return _pickUrl(
        res,
        endpoint: 'haitangw',
        source: source,
        codeField: 'code',
        okCodes: const [0, 200],
      );
    } catch (_) {
      return null;
    }
  }

  /// `{"code":200,"url":"..."}`
  static Future<String?> _zddyr(String rid, String source) async {
    try {
      final res = await _dio.get<String>(
        'https://yy.zddyr.top/lx/api/',
        queryParameters: {
          'source': _sourceCode('zddyr', source),
          'quality': 'flac',
          // `mainHash` 是酷狗的叫法。非酷狗的源它到底收哪个参数名我没法在
          // 本地验证（沙箱连不上这两家），所以三个常见写法一起发 —— 用不上
          // 的参数被忽略就是了，总比猜错一个白跑一趟强。
          'mainHash': rid,
          if (source != 'kg') ...{'songmid': rid, 'id': rid},
        },
      );
      _probe('zddyr', source, rid, res);
      return _pickUrl(
        res,
        endpoint: 'zddyr',
        source: source,
        codeField: 'code',
        okCodes: const [0, 200],
      );
    } catch (_) {
      return null;
    }
  }

  /// 两道校验，都靠 vkeys 自己返回的元数据，不用额外请求。
  ///
  /// 1. **mid 要对得上**。它解不出某个 mid 时会不会去搜个同名的顶上，我**没有
  ///    证实** —— 两次看到的可疑样本后来都发现是探针被 App 后台解析污染了
  ///    （见 [probes] 的注释）。但这道比对精确又免费，对的响应一条都不会误杀，
  ///    留着当保险。真发生了日志会写明白。
  /// 2. **`quality` 里写着「试听」的丢掉**。这是实锤：解不开的会员曲它回的是
  ///    一分钟左右的试听片段（`quality: 音乐试听`、0.9MB 上下、几十 kbps），
  ///    地址和状态码都挑不出毛病。不拦就是播一小会儿自动跳。
  static bool _vkeysIsSameSong(Response<String> res, String rid) {
    final body = res.data;
    if (body == null || body.isEmpty) return true;
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return true;
    }
    if (json is! Map) return true;
    final data = json['data'];
    if (data is! Map) return true;
    final got = data['mid'];
    if (got is String && got.isNotEmpty && got != rid) {
      debugPrint(
        '[公益音源] vkeys 换了歌：要 $rid，回的是 $got'
        '（${data['song']} - ${data['singer']}），丢弃',
      );
      return false;
    }
    // mid 对得上也可能只给试听：它自己在 quality 里写明了。
    final quality = data['quality'];
    if (quality is String && quality.contains('试听')) {
      debugPrint('[公益音源] vkeys 只给试听（$quality），丢弃：$rid');
      return false;
    }
    return true;
  }

  /// 用体积反推：比「这个时长最低限度该有多大」还小的，就是试听片段。
  ///
  /// 下限按 96kbps（12000 字节/秒）算 —— 真曲子再怎么压也不会比这更小，
  /// 而 30 秒片段对一首四分钟的歌来说差着一个数量级，卡得很稳。
  /// 拿不到 content-length 就放行：探测本身失败不算证据，宁可放过也别误杀。
  static Future<bool> _looksComplete(String url, int durationMs) async {
    final bytes = await contentLength(url);
    if (bytes == null || bytes <= 0) return true;
    if (durationMs > 0) return bytes >= durationMs ~/ 1000 * 12000;
    return bytes >= 1024 * 1024;
  }

  /// vkeys 的 QQ 取址。**只认 QQ**，别的源直接跳过。
  ///
  /// 出处是「洛雪音乐源 1.0.0 v2-fix」，不要密钥。和前面三个候选不同，它不是
  /// lx-music-api-server 那套 `/url/{源}/{id}/{音质}`，而是自己的 v2 接口，
  /// 每个平台一条路径（这里只接 tencent —— 别的平台路径我没证据，不猜）。
  ///
  /// **`quality` 是数字不是字符串**：脚本里 tx 的映射表是
  /// `{'128k':'6','320k':'8','flac':'10','flac24bit':'11'}`，传进来的本来就是
  /// 映射后的值。这里要 `10`（无损 flac）—— 11 是 Hi-Res，但没把握服务端一定
  /// 给，而这一层是兜底：haitangw 漏掉时能拿到无损已经远好过退回官方 128k。
  static Future<String?> _vkeys(String rid, String source) async {
    if (source != 'tx') return null;
    try {
      final res = await _dio.get<String>(
        'https://api.vkeys.cn/v2/music/tencent/geturl',
        queryParameters: {'mid': rid, 'quality': 10},
      );
      _probe('vkeys', source, rid, res);
      if (!_vkeysIsSameSong(res, rid)) return null;
      return _pickUrl(
        res,
        endpoint: 'vkeys',
        source: source,
        codeField: 'code',
        okCodes: const [0, 200],
      );
    } catch (_) {
      return null;
    }
  }

  /// 每个「接口 × 源」组合打一次原始返回。
  ///
  /// 这两家认不认 `tx` 只能靠真机日志回答：如果返回里写着「不支持的源」
  /// 之类的话，一眼就能定论；如果是正常的「没有这首」，那就还有戏。
  static void _probe(
    String name,
    String source,
    String rid,
    Response<String> res,
  ) {
    if (source == 'kg') return;
    final combo = '$name/$source';
    final body = (res.data ?? '').replaceAll(RegExp(r'\s+'), ' ');
    final brief = body.length > 600 ? '${body.substring(0, 600)}…' : body;
    probes[combo] = (rid: rid, summary: 'HTTP ${res.statusCode}：$brief');
    // 日志只留第一条，免得起播时每首歌刷一屏。
    if (!_probeLogged.add(combo)) return;
    debugPrint('[公益音源] 探针 $combo HTTP ${res.statusCode}：$brief');
  }

  /// 诊断用：**每一家都**问一遍（不像 [_resolveOnce] 那样先命中先返回），
  /// 好知道各家分别认不认这个源。返回 `接口名 -> 地址(或 null)`。
  /// 返回 `接口名 -> (地址, 原始返回)`。
  ///
  /// `raw` 只在 [probes] 里那条**确实是本次 rid** 的时候才给 —— 否则说明中途
  /// 被 App 后台的解析插了队，这时候宁可报「没抓到」，也绝不贴一个标错了歌的
  /// 样本出来。上一版就是没这道核对，害我拿别人的响应下了个错结论。
  static Future<Map<String, ({String? url, String? raw})>> probeAll(
    String rid,
    String source,
  ) async {
    final out = <String, ({String? url, String? raw})>{};
    for (final name in _endpoints) {
      final url = await _call(name, rid, source);
      final p = probes['$name/$source'];
      out[name] = (url: url, raw: p != null && p.rid == rid ? p.summary : null);
    }
    return out;
  }

  /// 诊断用：取文件大小，用来反推时长、判断拿到的是不是同一首歌。
  static Future<int?> contentLength(String url) async {
    try {
      final res = await _dio.head<void>(url);
      return int.tryParse(res.headers.value('content-length') ?? '');
    } catch (_) {
      return null;
    }
  }

  /// 从返回里挑出播放地址。两家的结构不一样，路径都试一遍。
  static String? _pickUrl(
    Response<String> res, {
    required String endpoint,
    required String source,
    required String codeField,
    required List<int> okCodes,
  }) {
    // 2xx 都算成功：haitangw 返回的是 201，写死判 200 会把它的每一次成功
    // 响应都扔掉 —— 实测日志里它 110 次零命中就是这么来的，每首歌都白等
    // 它一次再去问下一家。
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) return null;
    final body = res.data;
    if (body == null || body.isEmpty) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (json is! Map) return null;
    final code = json[codeField];
    // 接口明说不支持这个源的话，记下来别再问了。
    _noteRefusal(endpoint, source, code);
    if (code is num && !okCodes.contains(code.toInt())) return null;

    final data = json['data'];
    final candidates = <Object?>[
      json['url'],
      // lx-music-api-server 的成功返回是 {"code":0,"data":"https://..."} ——
      // data 直接就是地址字符串，不是对象。
      if (data is String) data,
      if (data is Map) ...[data['url'], data['music'], data['play_url']],
    ];
    for (final value in candidates) {
      if (value is String && value.startsWith('http')) {
        // 酷狗的 CDN 走 http，播放器那边统一升到 https。
        return value.startsWith('http://')
            ? value.replaceFirst('http://', 'https://')
            : value;
      }
    }
    return null;
  }
}
