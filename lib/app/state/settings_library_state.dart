import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LibraryRefreshSettings {
  static const String _prefsAutoRefreshLocalOnLaunch =
      'library_auto_refresh_local_on_launch';
  static const String _prefsAutoRefreshCloudOnLaunch =
      'library_auto_refresh_cloud_on_launch';

  static final ValueNotifier<bool> autoRefreshLocalOnLaunch = ValueNotifier(
    false,
  );
  static final ValueNotifier<bool> autoRefreshCloudOnLaunch = ValueNotifier(
    false,
  );

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    autoRefreshLocalOnLaunch.value =
        prefs.getBool(_prefsAutoRefreshLocalOnLaunch) ?? false;
    autoRefreshCloudOnLaunch.value =
        prefs.getBool(_prefsAutoRefreshCloudOnLaunch) ?? false;
  }

  static Future<void> setAutoRefreshLocalOnLaunch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoRefreshLocalOnLaunch, enabled);
    autoRefreshLocalOnLaunch.value = enabled;
  }

  static Future<void> setAutoRefreshCloudOnLaunch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoRefreshCloudOnLaunch, enabled);
    autoRefreshCloudOnLaunch.value = enabled;
  }
}
