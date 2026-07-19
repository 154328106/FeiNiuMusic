import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppNavigationStyle { drawer, bottomBar }

class AppLayoutSettings {
  static const String _prefsTabletMode = 'setting_tablet_mode';
  static const String _prefsNavigationStyle = 'setting_navigation_style';

  static final ValueNotifier<bool> tabletMode = ValueNotifier(false);
  static final ValueNotifier<AppNavigationStyle> navigationStyle =
      ValueNotifier(AppNavigationStyle.drawer);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    tabletMode.value = prefs.getBool(_prefsTabletMode) ?? false;
    final savedNavigationStyle = prefs.getString(_prefsNavigationStyle);
    navigationStyle.value = AppNavigationStyle.values.firstWhere(
      (style) => style.name == savedNavigationStyle,
      orElse: () => AppNavigationStyle.drawer,
    );
  }

  static Future<void> setTabletMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTabletMode, enabled);
    tabletMode.value = enabled;
  }

  static Future<void> setNavigationStyle(AppNavigationStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsNavigationStyle, style.name);
    navigationStyle.value = style;
  }
}
