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

  /// 串行闸：保证任意时刻只有一个请求在飞，且两次之间隔够 [_minInterval]。
  static Future<void> _gate = Future.value();
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 连续失败到这个时刻之前，整条链直接跳过。
  ///
  /// 服务挂掉时不该每首歌都去撞一次超时 —— 那会让起播平白多等 5 秒 × N。
  static DateTime? _skipUntil;
  static int _consecutiveFailures = 0;
  static const int _failureThreshold = 5;
  static const Duration _skipCooldown = Duration(minutes: 10);

  /// 取酷狗某个 hash 的播放地址，拿不到返回 null。
  ///
  /// [hash] 是酷狗的文件 hash（大写十六进制）。
  static Future<String?> resolve(String hash) async {
    if (hash.isEmpty) return null;
    final skip = _skipUntil;
    if (skip != null && DateTime.now().isBefore(skip)) return null;

    final enqueuedAt = DateTime.now();
    final completer = Completer<String?>();
    // 排进串行队列。前一个的成败不影响后一个，所以用 then 而不是 await 链。
    _gate = _gate.then((_) async {
      try {
        // 轮到自己了，先看已经等了多久。等太久说明前面排了一长串（起播那种
        // 突发），这时候再去问只会继续拖着播放器 —— 直接让给聆澜。
        if (DateTime.now().difference(enqueuedAt) > _maxQueueWait) {
          completer.complete(null);
          return;
        }
        final wait = _minInterval - DateTime.now().difference(_lastAt);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        final url = await _resolveOnce(hash);
        _lastAt = DateTime.now();
        if (url != null) {
          _consecutiveFailures = 0;
        } else if (++_consecutiveFailures >= _failureThreshold) {
          _skipUntil = DateTime.now().add(_skipCooldown);
          _consecutiveFailures = 0;
          debugPrint(
            '[公益音源] 连续 $_failureThreshold 次没结果，'
            '${_skipCooldown.inMinutes} 分钟内不再尝试',
          );
        }
        completer.complete(url);
      } catch (e) {
        _lastAt = DateTime.now();
        completer.complete(null);
      }
    });
    return completer.future;
  }

  /// 上一次真正给出地址的那家，下次从它开始问。
  ///
  /// 一家挂了的时候，固定顺序意味着每首歌都要先白等它一次。记住赢家能把
  /// 这份浪费省掉 —— 这正是 201 那个 bug 被放大的原因。
  static String _lastGood = 'haitangw';

  static Future<String?> _resolveOnce(String hash) async {
    final order = _lastGood == 'zddyr'
        ? const ['zddyr', 'haitangw']
        : const ['haitangw', 'zddyr'];
    for (final name in order) {
      final url = name == 'haitangw'
          ? await _haitangw(hash)
          : await _zddyr(hash);
      if (url != null) {
        _lastGood = name;
        debugPrint('[公益音源] $name 命中 kg/$hash');
        return url;
      }
    }
    return null;
  }

  /// `{"code":0,"data":{"url":"..."}}`
  static Future<String?> _haitangw(String hash) async {
    try {
      final res = await _dio.post<String>(
        'https://musicserver.haitangw.cc/v1/music/resolve-url',
        data: {'source': 'kg', 'rid': hash, 'level': 'lossless'},
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      return _pickUrl(res, codeField: 'code', okCodes: const [0, 200]);
    } catch (_) {
      return null;
    }
  }

  /// `{"code":200,"url":"..."}`
  static Future<String?> _zddyr(String hash) async {
    try {
      final res = await _dio.get<String>(
        'https://yy.zddyr.top/lx/api/',
        queryParameters: {'source': 'kg', 'quality': 'flac', 'mainHash': hash},
      );
      return _pickUrl(res, codeField: 'code', okCodes: const [0, 200]);
    } catch (_) {
      return null;
    }
  }

  /// 从返回里挑出播放地址。两家的结构不一样，路径都试一遍。
  static String? _pickUrl(
    Response<String> res, {
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
    if (code is num && !okCodes.contains(code.toInt())) return null;

    final data = json['data'];
    final candidates = <Object?>[
      json['url'],
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
