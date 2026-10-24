import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 扫码状态。
enum MiguScanState { waiting, scanned, expired, success, error }

class MiguScanResult {
  const MiguScanResult(this.state, {this.nickname, this.message});
  final MiguScanState state;
  final String? nickname;
  final String? message;
}

/// 咪咕扫码登录。
///
/// 流程（实测 passport.migu.cn）：
/// 1. `qrcWeb/qrcLogin?isAsync=true&sourceid=220001` → `result.qrcUrl`
///    （`data:image/jpeg;base64,...`，直接是二维码图片）+ `result.qrc_sessionid`；
/// 2. `qrcWeb/qrcquery?...&qrc_sessionid=<SID>` 轮询：
///    - `status:4074` 未扫码 → waiting
///    - `status:4072` 二维码超时 → expired
///    - `status:2000` 成功 → 收 Cookie / token。
///
/// 登录后 cookie 用于咪咕自家直连播放（`listenSong.do` 返回 VIP 直链）。免登录
/// 时播放走聚合/LX 的 mg 后端，不受影响。
///
/// 成功那一步（status 2000）的确切返回体要真机扫一次才能看到，这里把所有
/// Set-Cookie 和原始 JSON 都收下 + 打日志，首次真扫后按实际返回收口。
class MiguAuth {
  MiguAuth._();
  static final MiguAuth instance = MiguAuth._();

  static const String _prefsKey = 'migu.auth.cookies';
  static const String _prefsNick = 'migu.auth.nickname';
  static const String _sourceId = '220001';

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  final Map<String, String> _cookies = {};
  String _sessionId = '';

  final ValueNotifier<bool> isLoggedIn = ValueNotifier(false);
  String nickname = '';

  Future<void>? _loading;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
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
      isLoggedIn.value = _cookies.isNotEmpty;
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

  /// 请求要带的 Cookie 头。未登录为空。
  String get cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<void> logout() async {
    _cookies.clear();
    _sessionId = '';
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

  /// 拉二维码图片（JPEG 字节），并记下 qrc_sessionid。
  Future<Uint8List?> fetchQrCode() async {
    await ensureLoaded();
    _sessionId = '';
    try {
      final res = await _dio.get<String>(
        'https://passport.migu.cn/api/qrcWeb/qrcLogin',
        queryParameters: {'isAsync': 'true', 'sourceid': _sourceId},
        options: Options(responseType: ResponseType.plain),
      );
      final json = _decode(res.data);
      final result = json is Map ? json['result'] : null;
      if (result is! Map) {
        debugPrint('[MiguAuth] 建码失败：${res.data}');
        return null;
      }
      final sid = (result['qrc_sessionid'] ?? '').toString();
      final qrcUrl = (result['qrcUrl'] ?? '').toString();
      if (sid.isEmpty || qrcUrl.isEmpty) return null;
      _sessionId = sid;
      return _decodeDataUri(qrcUrl);
    } on DioException catch (e) {
      debugPrint('[MiguAuth] 取二维码失败：${e.message}');
      return null;
    }
  }

  /// 轮询一次扫码状态。调用方按 ~2 秒间隔重复调用。
  Future<MiguScanResult> poll() async {
    if (_sessionId.isEmpty) {
      return const MiguScanResult(MiguScanState.expired);
    }
    final Response<String> res;
    try {
      res = await _dio.get<String>(
        'https://passport.migu.cn/api/qrcWeb/qrcquery',
        queryParameters: {
          'isAsync': 'true',
          'sourceid': _sourceId,
          'qrc_sessionid': _sessionId,
        },
        options: Options(responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      return MiguScanResult(MiguScanState.error, message: e.message);
    }
    _absorbCookies(res);
    final json = _decode(res.data);
    final status = (json is Map ? json['status'] : null)?.toString() ?? '';
    switch (status) {
      case '4074': // 未扫码
        return const MiguScanResult(MiguScanState.waiting);
      case '4073': // 已扫码待确认（猜测码；实际码以真机为准，归到 scanned）
      case '4071':
        return const MiguScanResult(MiguScanState.scanned);
      case '4072': // 二维码超时
        return const MiguScanResult(MiguScanState.expired);
      case '2000': // 成功
        return _onSuccess(json is Map ? json : const {});
      default:
        // 未知状态：打日志便于按真机返回收口，先当等待。
        debugPrint('[MiguAuth] 轮询未知 status=$status body=${res.data}');
        return const MiguScanResult(MiguScanState.waiting);
    }
  }

  /// 登录成功：收 Cookie + 可能的 token / 跳转，存档。
  ///
  /// 咪咕 passport 成功后把登录态放在 Set-Cookie 和/或 result 里；具体字段要
  /// 真机扫一次确认，这里尽量全收 + 打日志。
  Future<MiguScanResult> _onSuccess(Map<dynamic, dynamic> json) async {
    debugPrint('[MiguAuth] 登录成功原始返回：${jsonEncode(json)}');
    final result = json['result'];
    if (result is Map) {
      // 常见 token 字段名，收进 cookie 池备用。
      for (final k in const ['token', 'ssoToken', 'tokenId', 'sidTk']) {
        final v = (result[k] ?? '').toString();
        if (v.isNotEmpty) _cookies[k] = v;
      }
      final nick = (result['nickName'] ?? result['nickname'] ?? '').toString();
      if (nick.isNotEmpty) nickname = nick;
      // 若带跳转，手动跟一跳收 Cookie（music.migu.cn 的会话 cookie 可能在这里）。
      final redirect = (result['returnURL'] ?? result['redirectURL'] ?? '')
          .toString();
      if (redirect.startsWith('http')) {
        await _followOnce(redirect);
      }
    }
    if (_cookies.isEmpty) {
      return const MiguScanResult(
        MiguScanState.error,
        message: '登录成功但没拿到凭证（看日志里的原始返回）',
      );
    }
    isLoggedIn.value = true;
    await _persist();
    return MiguScanResult(MiguScanState.success, nickname: nickname);
  }

  Future<void> _followOnce(String url) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Cookie': cookieHeader},
        ),
      );
      _absorbCookies(res);
    } catch (_) {}
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
      if (value.isEmpty || value == '""' || value.toUpperCase() == 'EXPIRED') {
        continue;
      }
      // JSESSIONID 是 passport 的临时会话，不是登录态，别存。
      if (name.toUpperCase() == 'JSESSIONID') continue;
      _cookies[name] = value;
    }
  }

  static dynamic _decode(dynamic data) {
    if (data is Map || data is List) return data;
    if (data is String && data.isNotEmpty) {
      try {
        return jsonDecode(data);
      } catch (_) {}
    }
    return null;
  }

  /// 解 `data:image/jpeg;base64,xxxx` → 字节。
  static Uint8List? _decodeDataUri(String uri) {
    final idx = uri.indexOf('base64,');
    if (idx < 0) return null;
    try {
      return base64Decode(uri.substring(idx + 7));
    } catch (_) {
      return null;
    }
  }
}
