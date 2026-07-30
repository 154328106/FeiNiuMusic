import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppCacheSettings {
  static const String _prefsAudioCacheLimitGb = 'audio_cache_limit_gb';

  static final ValueNotifier<int> audioCacheLimitGb = ValueNotifier(0);
  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    audioCacheLimitGb.value = (prefs.getInt(_prefsAudioCacheLimitGb) ?? 0)
        .clamp(0, 5);
  }

  static Future<void> setAudioCacheLimitGb(int gb) async {
    final prefs = await SharedPreferences.getInstance();
    final value = gb.clamp(0, 5);
    await prefs.setInt(_prefsAudioCacheLimitGb, value);
    audioCacheLimitGb.value = value;
  }
}
