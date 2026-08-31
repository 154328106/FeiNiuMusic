import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Subsonic 认证方式。
enum SubsonicAuthMode {
  /// `t` = md5(密码 + 盐)，`s` = 盐。Subsonic 1.13+ 的标准做法。
  token,

  /// `p` = `enc:` + 密码的十六进制。老服务端（返回 error code 41）才降级到这个。
  password,
}

/// 一个 Subsonic 服务端的连接配置。
///
/// Navidrome、以及 NAS 上那个 4000 端口的服务，说的都是 Subsonic 协议，
/// 因此共用这一套配置与客户端。
class SubsonicServerConfig {
  const SubsonicServerConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.authMode = SubsonicAuthMode.token,
  });

  /// 形如 `http://192.168.1.10:4000`，不带 `/rest`。
  final String baseUrl;
  final String username;
  final String password;
  final SubsonicAuthMode authMode;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && username.trim().isNotEmpty;

  SubsonicServerConfig copyWith({
    String? baseUrl,
    String? username,
    String? password,
    SubsonicAuthMode? authMode,
  }) {
    return SubsonicServerConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      authMode: authMode ?? this.authMode,
    );
  }

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'authMode': authMode.name,
  };

  static SubsonicServerConfig fromJson(Map<String, Object?> json) {
    return SubsonicServerConfig(
      baseUrl: json['baseUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      authMode: json['authMode'] == SubsonicAuthMode.password.name
          ? SubsonicAuthMode.password
          : SubsonicAuthMode.token,
    );
  }

  static const SubsonicServerConfig empty = SubsonicServerConfig(
    baseUrl: '',
    username: '',
    password: '',
  );
}

/// Subsonic 服务端配置的读写。
class SubsonicServerStore {
  SubsonicServerStore._();

  static final SubsonicServerStore instance = SubsonicServerStore._();

  static const String _prefsKey = 'subsonic.server';

  final ValueNotifier<SubsonicServerConfig> config = ValueNotifier(
    SubsonicServerConfig.empty,
  );

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        config.value = SubsonicServerConfig.fromJson(decoded);
      }
    } catch (_) {
      // 存档坏了就当没配过，别卡住启动。
    }
  }

  Future<void> save(SubsonicServerConfig value) async {
    config.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(value.toJson()));
    } catch (_) {}
  }

  Future<void> clear() async {
    config.value = SubsonicServerConfig.empty;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }
}

/// 生成 Subsonic 的鉴权查询参数。
///
/// [clientName] 会作为 `c` 参数发给服务端，服务端的「客户端」列表里显示它。
Map<String, String> subsonicAuthQuery(
  SubsonicServerConfig config, {
  String clientName = 'FeiNiuMusic',
}) {
  final query = <String, String>{'u': config.username};
  switch (config.authMode) {
    case SubsonicAuthMode.token:
      final salt = _randomSalt();
      query['t'] = crypto.md5
          .convert(utf8.encode('${config.password}$salt'))
          .toString();
      query['s'] = salt;
    case SubsonicAuthMode.password:
      // `enc:` + 十六进制：密码里的特殊字符不会把 query 打乱。
      final hex = utf8
          .encode(config.password)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      query['p'] = 'enc:$hex';
  }
  query['v'] = '1.16.1';
  query['c'] = clientName;
  query['f'] = 'json';
  return query;
}

final Random _random = Random.secure();

String _randomSalt() => List.generate(
  12,
  (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
).join();
