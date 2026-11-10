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

  /// 咪咕音乐网页端的 sourceid。2026-11-11 前用的 220001 也能扫码，但换 pacmtoken
  /// 的 token-validate 要和登录时的 sourceid 对上，统一用音乐这套（实测通）。
  static const String _sourceId = '220029';

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

  /// 备份还原后调用：丢掉内存里的旧状态，按存档重新读一遍（否则下次保存会把还原的数据覆盖回去）。
  Future<void> reloadFromStorage() {
    _cookies.clear();
    nickname = '';
    isLoggedIn.value = false;
    _loading = null;
    return ensureLoaded();
  }

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
      // 只有 pacmtoken 才是能取用户数据的登录态。2026-11-11 前的登录只收了
      // passport 的 cookie、没换 pacmtoken，等于没登录，要重新扫一次。
      isLoggedIn.value = pacmToken.isNotEmpty;
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

  /// 登录凭证：取「我喜欢」、今日推荐等用户数据都靠它，服务端每次响应可能换发新的。
  String get pacmToken => _cookies['pacmtoken'] ?? '';

  /// 收下响应里换发的新 pacmtoken（不收就会用着用着过期）。
  Future<void> absorbRenewal(List<String>? setCookies) async {
    if (setCookies == null) return;
    for (final line in setCookies) {
      final pair = line.split(';').first.trim();
      if (!pair.startsWith('pacmtoken=')) continue;
      final value = pair.substring('pacmtoken='.length).trim();
      if (value.isEmpty || value == _cookies['pacmtoken']) continue;
      _cookies['pacmtoken'] = value;
      await _persist();
    }
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
    final result = json['result'];
    // 只记字段名：原始返回里有 token，日志会被贴出去。
    debugPrint(
      '[MiguAuth] 登录成功，返回字段：${result is Map ? result.keys.toList() : '无'}',
    );
    if (result is Map) {
      final nick = (result['nickName'] ?? result['nickname'] ?? '').toString();
      if (nick.isNotEmpty) nickname = nick;
    }
    // 不要先跟 redirectURL 跳一下：ST token 很可能是一次性的，跳过去就被用掉了，
    // 2026-11-11 实测直接拿去换 pacmtoken 是通的。
    // passport 给的是一次性的 ST token，要拿去换咪咕音乐的 pacmtoken 才能取用户数据。
    final st = result is Map ? (result['token'] ?? '').toString() : '';
    if (st.isNotEmpty) await _exchangePacm(st);
    if (pacmToken.isEmpty) {
      return const MiguScanResult(
        MiguScanState.error,
        message: '扫码成功，但换取咪咕凭证失败（看日志），请重扫',
      );
    }
    isLoggedIn.value = true;
    await _persist();
    return MiguScanResult(MiguScanState.success, nickname: nickname);
  }

  /// ST token → pacmtoken（在 Set-Cookie 里）。
  Future<void> _exchangePacm(String st) async {
    try {
      final res = await _dio.get<String>(
        'https://c.musicapp.migu.cn/user/h5/token-validate/v3.0',
        queryParameters: {
          'token': st,
          'type': '2',
          'sourceId': _sourceId,
          'activityId': 'MUSIC-WWW',
        },
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'Cookie': 'idmpauth=true@passport.migu.cn',
            'Origin': 'https://music.migu.cn',
            'Referer': 'https://music.migu.cn/',
          },
        ),
      );
      _absorbCookies(res);
      if (pacmToken.isEmpty) {
        debugPrint('[MiguAuth] 换 pacmtoken 失败：${res.data}');
      }
    } on DioException catch (e) {
      debugPrint('[MiguAuth] 换 pacmtoken 失败：${e.message}');
    }
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
