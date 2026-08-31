import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/subsonic/subsonic_server.dart';

/// 登录页可选的音乐平台。
///
/// 除飞牛外，其余几个说的都是 **Subsonic 协议**，共用同一套客户端
/// （见 `SubsonicApiClient`）—— 分开列出来只是为了在登录页给出各自的品牌名，
/// 用户不必知道「道理鱼其实是 Subsonic」才会填。
enum AppPlatform {
  feiniu,
  navidrome,
  daoliyu,
  subsonic;

  /// 是不是 Subsonic 协议的服务端。
  bool get isSubsonic => this != AppPlatform.feiniu;

  String get label => switch (this) {
    AppPlatform.feiniu => '飞牛音乐',
    AppPlatform.navidrome => 'Navidrome',
    AppPlatform.daoliyu => '道理鱼音乐',
    AppPlatform.subsonic => 'Subsonic',
  };

  String get subtitle => switch (this) {
    AppPlatform.feiniu => 'FeiNiu Music',
    AppPlatform.navidrome => 'Subsonic 协议',
    AppPlatform.daoliyu => 'Subsonic 协议',
    AppPlatform.subsonic => 'Subsonic / Airsonic',
  };

  /// 登录页提示条上的说明。
  String get hint => switch (this) {
    AppPlatform.feiniu => '支持输入服务器地址或 FNID 快速连接',
    AppPlatform.navidrome => '默认端口 4533，填地址 + 用户名 + 密码',
    AppPlatform.daoliyu => '默认端口 4000，填地址 + 用户名 + 密码',
    AppPlatform.subsonic => '任何 Subsonic / Airsonic 服务端均可',
  };

  /// 平台图标。
  ///
  /// 用 Material 图标 + 各自的主色，而不是搬各家的官方 logo —— 那些是别人的
  /// 商标资源，塞进公开仓库分发不合适。
  IconData get icon => switch (this) {
    AppPlatform.feiniu => Icons.music_note_rounded,
    AppPlatform.navidrome => Icons.album_rounded,
    AppPlatform.daoliyu => Icons.waves_rounded,
    AppPlatform.subsonic => Icons.graphic_eq_rounded,
  };

  Color get accent => switch (this) {
    AppPlatform.feiniu => const Color(0xFFE5405A),
    AppPlatform.navidrome => const Color(0xFF2196F3),
    AppPlatform.daoliyu => const Color(0xFF34C759),
    AppPlatform.subsonic => const Color(0xFFF5B301),
  };

  static AppPlatform fromName(String? raw) => AppPlatform.values.firstWhere(
    (e) => e.name == raw,
    orElse: () => AppPlatform.feiniu,
  );
}

/// 当前选中的平台。
class AppPlatformSettings {
  AppPlatformSettings._();

  static const String _prefsKey = 'setting_active_platform';

  static final ValueNotifier<AppPlatform> active = ValueNotifier(
    AppPlatform.feiniu,
  );

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      active.value = AppPlatform.fromName(prefs.getString(_prefsKey));
    } catch (_) {}
  }

  /// 当前是不是一个「可用的 Subsonic 会话」：选了 Subsonic 系平台，且服务器
  /// 已经配好。
  ///
  /// 门控用它决定进不进主界面 —— 否则每次冷启动都会因为「飞牛没登录」而退回
  /// 登录页，逼用户把服务器信息重填一遍。
  static bool get hasSubsonicSession =>
      active.value.isSubsonic &&
      SubsonicServerStore.instance.config.value.isConfigured;

  /// 门控要监听的全部来源。
  static Listenable get sessionListenable =>
      Listenable.merge([active, SubsonicServerStore.instance.config]);

  static Future<void> setActive(AppPlatform platform) async {
    active.value = platform;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, platform.name);
    } catch (_) {}
  }
}
