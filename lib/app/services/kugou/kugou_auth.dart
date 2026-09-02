import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 酷狗账号与设备标识。
///
/// 拆成单独一份而不是塞进 [KugouApiClient]，是因为它有两半职责：
/// - **设备**（guid / mid / dfid）：免登录也要用，签名和取址都带；
/// - **账号**（userid / token / vipType）：扫码登录后才有。
///
/// 设备那半必须**持久化**。之前 mid 是每次启动随机生成的，等于每开一次
/// App 就换一台"新设备"，酷狗那边的风控和会员判定都对不上号。
class KugouAuth {
  KugouAuth._();

  static final KugouAuth instance = KugouAuth._();

  static const String _prefsKey = 'kugou.auth.v1';

  final Map<String, String> _data = {};

  /// 登录态。UI 直接监听它，登录/退出后那一行自己刷新。
  final ValueNotifier<bool> isLoggedIn = ValueNotifier(false);

  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k is String && v is String) _data[k] = v;
          });
        }
      }
    } catch (e) {
      debugPrint('[KugouAuth] 读取本地登录态失败：$e');
    }
    _ensureDevice();
    _apply();
    // 首次生成的设备标识要落盘，否则下次启动又是一台新设备。
    unawaited(_persist());
  }

  String get userId => _data['userid'] ?? '';

  String get token => _data['token'] ?? '';

  String get nickname => _data['nickname'] ?? '';

  String get avatar => _data['avatar'] ?? '';

  String get dfid => _data['dfid']?.isNotEmpty == true ? _data['dfid']! : '-';

  String get mid => _data['mid'] ?? '';

  int get vipType => int.tryParse(_data['vipType'] ?? '0') ?? 0;

  bool get isVip => vipType > 0;

  /// 请求头里的 Cookie。没登录时是空串，调用方据此决定带不带。
  String get cookieHeader {
    final items = <List<String>>[
      ['userid', userId],
      ['token', token],
      ['KUGOU_API_MID', mid],
      ['dfid', dfid],
      if (vipType > 0) ['vipType', '$vipType'],
      if (vipType > 0) ['viptype', '$vipType'],
    ];
    return items
        .where((e) => e[1].isNotEmpty && e[1] != '-')
        .map((e) => '${e[0]}=${e[1]}')
        .join('; ');
  }

  Future<void> saveLogin({
    required String userId,
    required String token,
    required String nickname,
    required String avatar,
    required int vipType,
  }) async {
    _data['userid'] = userId;
    _data['token'] = token;
    _data['nickname'] = nickname;
    _data['avatar'] = avatar;
    _data['vipType'] = '$vipType';
    _apply();
    await _persist();
  }

  Future<void> saveDfid(String value) async {
    if (value.isEmpty) return;
    _data['dfid'] = value;
    await _persist();
  }

  Future<void> logout() async {
    // 只清账号，设备标识留着：换个账号登进来还是同一台"设备"。
    for (final key in ['userid', 'token', 'nickname', 'avatar', 'vipType']) {
      _data.remove(key);
    }
    _apply();
    await _persist();
  }

  void _apply() {
    isLoggedIn.value = userId.isNotEmpty && token.isNotEmpty;
  }

  void _ensureDevice() {
    final rand = Random.secure();
    String hex(int n) {
      const chars = '0123456789abcdef';
      return List.generate(n, (_) => chars[rand.nextInt(16)]).join();
    }

    final guid = _data['guid'] ?? '${hex(8)}-${hex(4)}-${hex(4)}-${hex(12)}';
    _data['guid'] = guid;
    _data['mid'] ??= _midFromSeed(guid);
  }

  /// mid = md5(guid) 前 15 位十六进制转十进制。照抄官方端的算法，酷狗只
  /// 要求它稳定且长度合适。
  static String _midFromSeed(String seed) {
    final hex = md5.convert(utf8.encode(seed)).toString();
    final value = int.tryParse(hex.substring(0, 15), radix: 16);
    return value == null ? hex : '$value';
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_data));
    } catch (e) {
      debugPrint('[KugouAuth] 保存登录态失败：$e');
    }
  }
}
