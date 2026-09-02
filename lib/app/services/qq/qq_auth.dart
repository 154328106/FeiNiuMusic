import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 扫码状态。
enum QQScanState { waiting, scanned, expired, success, error }

class QQScanResult {
  const QQScanResult(this.state, {this.nickname, this.message});

  final QQScanState state;
  final String? nickname;
  final String? message;
}

/// QQ 音乐扫码登录。
///
/// 流程（照搬 Beans-Music 的 QQMusicAuth）：
/// 1. `ptqrshow` 拿二维码图片，同时从 Set-Cookie 里取 `qrsig`；
/// 2. `ptqrlogin` 轮询扫码状态，`ptqrtoken` = hash33(qrsig)；
/// 3. 扫码通过后拿到一条 check_sig 跳转链，**手动**跟到底并一路收 Cookie
///    （skey / p_skey 就在这几跳的 Set-Cookie 里，自动重定向会丢）；
/// 4. `graph.qq.com/oauth2.0/authorize` 换 code；
/// 5. `musicu.fcg` 的 QQConnectLogin 用 code 换 musickey。
///
/// 麻烦全在第 3 步：必须关掉自动重定向、自己按 Location 一跳跳走，
/// 并且每一跳都要把 `qrsig` 一起带上，否则 check_sig 校验不过。
class QQAuth {
  QQAuth._();

  static final QQAuth instance = QQAuth._();

  static const String _prefsKey = 'qq.auth.cookies';
  static const String _prefsNick = 'qq.auth.nickname';

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  final Map<String, String> _cookies = {};
  String _qrsig = '';

  final ValueNotifier<bool> isLoggedIn = ValueNotifier(false);
  String nickname = '';

  Future<void>? _loading;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      // 重定向必须自己处理：跳转链上的 Set-Cookie 才是我们要的东西。
      followRedirects: false,
      validateStatus: (_) => true,
      headers: {'User-Agent': _ua},
    ),
  );

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k is String && v is String) _cookies[k] = v;
          });
        }
      }
      nickname = prefs.getString(_prefsNick) ?? '';
      isLoggedIn.value = _musicKey.isNotEmpty;
    } catch (_) {
      // 存档坏了就当没登录过。
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_cookies));
      await prefs.setString(_prefsNick, nickname);
    } catch (_) {}
  }

  String get _musicKey =>
      _cookies['qm_keyst'] ??
      _cookies['qqmusic_key'] ??
      _cookies['musickey'] ??
      '';

  /// 登录用户的 QQ 号（musicid）。未登录为 '0'。
  String get uin {
    final value = _cookies['uin'] ?? '';
    return value.isEmpty ? '0' : value;
  }

  /// 请求要带的 Cookie 头。未登录时给一份最小的游客 Cookie。
  String get cookieHeader {
    if (_cookies.isEmpty) return 'uin=0; qqmusic_fromtag=66';
    return _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 取播放地址时 `comm` 里要带的 authst。未登录为空串。
  String get authst => _musicKey;

  Future<void> logout() async {
    _cookies.clear();
    _qrsig = '';
    nickname = '';
    isLoggedIn.value = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
      await prefs.remove(_prefsNick);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // 扫码
  // ---------------------------------------------------------------------

  /// 拉二维码图片（PNG 字节），并记下 qrsig。
  Future<Uint8List?> fetchQrCode() async {
    await ensureLoaded();
    _qrsig = '';
    try {
      final response = await _dio.get<List<int>>(
        'https://ssl.ptlogin2.qq.com/ptqrshow',
        queryParameters: {
          'appid': '716027609',
          'e': '2',
          'l': 'M',
          's': '3',
          'd': '72',
          'v': '4',
          't': Random().nextDouble().toStringAsFixed(6),
          'daid': '383',
          'pt_3rd_aid': '100497308',
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Referer': 'https://xui.ptlogin2.qq.com/'},
        ),
      );
      _absorbCookies(response);
      final sig = _cookies['qrsig'] ?? '';
      if (sig.isEmpty) {
        debugPrint('[QQAuth] 拿不到 qrsig，二维码作废');
        return null;
      }
      _qrsig = sig;
      final data = response.data;
      return data == null ? null : Uint8List.fromList(data);
    } on DioException catch (e) {
      debugPrint('[QQAuth] 取二维码失败：${e.message}');
      return null;
    }
  }

  /// 轮询一次扫码状态。调用方按 ~2 秒间隔重复调用。
  Future<QQScanResult> poll() async {
    if (_qrsig.isEmpty) {
      return const QQScanResult(QQScanState.expired);
    }
    final Response<String> response;
    try {
      response = await _dio.get<String>(
        'https://ssl.ptlogin2.qq.com/ptqrlogin',
        queryParameters: {
          'u1': 'https://graph.qq.com/oauth2.0/login_jump',
          'ptqrtoken': '${_hash33(_qrsig)}',
          'ptredirect': '0',
          'h': '1',
          't': '1',
          'g': '1',
          'from_ui': '1',
          'ptlang': '2052',
          'action': '0-0-${DateTime.now().millisecondsSinceEpoch}',
          'js_ver': '22080914',
          'js_type': '1',
          'login_sig': '',
          'pt_uistyle': '40',
          'aid': '716027609',
          'daid': '383',
          'pt_3rd_aid': '100497308',
        },
        options: Options(
          headers: {
            'Referer': 'https://xui.ptlogin2.qq.com/',
            'Cookie': 'qrsig=$_qrsig',
          },
        ),
      );
    } on DioException catch (e) {
      return QQScanResult(QQScanState.error, message: e.message);
    }
    _absorbCookies(response);

    // 返回形如 ptuiCB('66','0','','0','二维码未失效。', '')
    final parts = _parsePtui(response.data ?? '');
    if (parts.isEmpty) {
      return const QQScanResult(QQScanState.error, message: 'QQ 登录接口异常');
    }
    switch (parts[0]) {
      case '0':
        final url = parts.length > 2 ? parts[2] : '';
        if (url.isEmpty) {
          return const QQScanResult(QQScanState.error, message: '登录成功但没拿到凭证');
        }
        final nick = parts.length > 5 ? parts[5] : '';
        try {
          await _completeOAuth(url);
        } catch (e) {
          return QQScanResult(QQScanState.error, message: '$e');
        }
        if (_musicKey.isEmpty) {
          return const QQScanResult(
            QQScanState.error,
            message: '授权完成但没换到 musickey',
          );
        }
        nickname = nick;
        isLoggedIn.value = true;
        await _persist();
        return QQScanResult(QQScanState.success, nickname: nick);
      case '65':
      case '68':
        return const QQScanResult(QQScanState.expired);
      case '67':
        return const QQScanResult(QQScanState.scanned);
      default:
        return const QQScanResult(QQScanState.waiting);
    }
  }

  // ---------------------------------------------------------------------
  // 授权换 musickey
  // ---------------------------------------------------------------------

  Future<void> _completeOAuth(String redirectUrl) async {
    // 1. 手动跟 check_sig 跳转链，一路收 Cookie（skey / p_skey 在这几跳里）。
    //    每一跳都要带 qrsig，否则 check_sig 校验不过。
    var current = redirectUrl;
    for (var hop = 0; hop < 6; hop++) {
      final Response<String> response;
      try {
        response = await _dio.get<String>(
          current,
          options: Options(
            headers: {
              'Referer': 'https://xui.ptlogin2.qq.com/',
              'Cookie': _cookieHeaderWithQrsig(),
            },
          ),
        );
      } on DioException {
        break;
      }
      _absorbCookies(response);
      final status = response.statusCode ?? 0;
      if (status < 300 || status > 399) break;
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) break;
      current = Uri.parse(current).resolve(location).toString();
    }

    // 2. graph.qq.com 换 code。
    final gtk = _hash5381(
      _cookies['qqmusic_key'] ?? _cookies['p_skey'] ?? _cookies['skey'] ?? '',
    );
    final Response<String> authResponse;
    try {
      authResponse = await _dio.post<String>(
        'https://graph.qq.com/oauth2.0/authorize',
        data: {
          'response_type': 'code',
          'client_id': '100497308',
          'redirect_uri':
              'https://y.qq.com/portal/wx_redirect.html'
              '?login_type=1&surl=https://y.qq.com/',
          'scope': 'all',
          'state': 'state',
          'switch': '',
          'from_ptlogin': '1',
          'src': '1',
          'update_auth': '1',
          'openapi': '80901010_1030',
          'g_tk': '$gtk',
          'auth_time': '${DateTime.now().millisecondsSinceEpoch}',
          'ui': 'DFEC5395-9E69-4D3E-96A6-300BB770874D',
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {'Referer': 'https://graph.qq.com/', 'Cookie': cookieHeader},
        ),
      );
    } on DioException catch (e) {
      throw Exception('QQ 授权失败：${e.message}');
    }
    _absorbCookies(authResponse);
    final location = authResponse.headers.value('location') ?? '';
    final code = RegExp(r'code=([^&]+)').firstMatch(location)?.group(1);
    if (code == null || code.isEmpty) {
      throw Exception('QQ 授权失败，请重新扫码');
    }

    // 3. 用 code 换 musickey。
    //    注意：部分响应把凭证放在 JSON 里而不是 Set-Cookie，两边都要收。
    final Response<String> loginResponse;
    try {
      loginResponse = await _dio.post<String>(
        'https://u.y.qq.com/cgi-bin/musicu.fcg',
        data: jsonEncode({
          'comm': {'g_tk': 5381, 'platform': 'yqq', 'ct': 24, 'cv': 0},
          'req': {
            'module': 'QQConnectLogin.LoginServer',
            'method': 'QQLogin',
            'param': {'code': code},
          },
        }),
        options: Options(
          contentType: Headers.jsonContentType,
          headers: {'Referer': 'https://y.qq.com/', 'Cookie': cookieHeader},
        ),
      );
    } on DioException catch (e) {
      throw Exception('换取登录态失败：${e.message}');
    }
    _absorbCookies(loginResponse);
    try {
      // 分步取，别写成一行三元 —— `?[` 跟三元的 `?` 撞在一起，Dart 会
      // 解析歧义（analyze 报 "Conditions must have a static type of bool"）。
      final root = jsonDecode(loginResponse.data ?? '{}');
      final req = root is Map ? root['req'] : null;
      final data = req is Map ? req['data'] : null;
      if (data is Map) {
        final musicKey = data['musickey'] as String?;
        if (musicKey != null && musicKey.isNotEmpty) {
          _cookies['musickey'] = musicKey;
          _cookies['qm_keyst'] = musicKey;
          _cookies['qqmusic_key'] = musicKey;
        }
        final musicId = data['musicid'];
        if (musicId is int && musicId > 0) {
          _cookies['uin'] = '$musicId';
        } else if (musicId is String && musicId.isNotEmpty) {
          _cookies['uin'] = musicId;
        }
      }
    } catch (_) {
      // JSON 里没有就靠 Set-Cookie 那份。
    }
  }

  String _cookieHeaderWithQrsig() {
    final base = _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    if (_qrsig.isEmpty) return base;
    return base.isEmpty ? 'qrsig=$_qrsig' : 'qrsig=$_qrsig; $base';
  }

  void _absorbCookies(Response<Object?> response) {
    final raw = response.headers.map['set-cookie'];
    if (raw == null) return;
    for (final line in raw) {
      final pair = line.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      // 服务端用空值/占位值删 Cookie，别把它们存下来。
      if (value.isEmpty || value == '""' || value.toUpperCase() == 'EXPIRED') {
        continue;
      }
      _cookies[name] = value;
    }
  }

  /// 解析 `ptuiCB('0','0','url','0','msg','nick')`。
  static List<String> _parsePtui(String text) {
    final start = text.indexOf('(');
    final end = text.lastIndexOf(')');
    if (start < 0 || end <= start) return const [];
    return text
        .substring(start + 1, end)
        .split(',')
        .map((e) => e.trim().replaceAll("'", ''))
        .toList();
  }

  /// 对应 JS：`e += (e << 5) + charCode`，初值 0 —— ptqrtoken 用。
  ///
  /// JS 里 e 是双精度浮点，累加过程**不截断**到 32 位，只有 `<<` 那一步按
  /// 32 位算。用整数模拟会在长 qrsig 上溢出，算出来的 token 是错的。
  static int _hash33(String text) => _jsHash(text, 0);

  /// 同上，初值 5381 —— oauth 的 g_tk 用。
  static int _hash5381(String text) => _jsHash(text, 5381);

  static int _jsHash(String text, double seed) {
    var e = seed;
    for (final unit in text.codeUnits) {
      e = e + _toInt32(e) * 32 + unit;
    }
    return _toInt32(e) & 0x7FFFFFFF;
  }

  /// JS 的 ToInt32：取模 2^32 后按有符号解释。
  static int _toInt32(double value) {
    final truncated = value.truncateToDouble();
    var n = truncated % 4294967296;
    if (n < 0) n += 4294967296;
    var result = n.toInt();
    if (result >= 2147483648) result -= 4294967296;
    return result;
  }
}
