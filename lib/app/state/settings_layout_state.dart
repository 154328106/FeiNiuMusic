import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLayoutSettings {
  static const String _prefsTabletMode = 'setting_tablet_mode';

  static final ValueNotifier<bool> tabletMode = ValueNotifier(false);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    tabletMode.value = prefs.getBool(_prefsTabletMode) ?? false;
  }

  static Future<void> setTabletMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTabletMode, enabled);
    tabletMode.value = enabled;
  }
}
