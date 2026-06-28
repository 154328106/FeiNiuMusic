import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/cache/audio_cache_service.dart';

class AppCacheSettings {
  static const String _prefsAudioCacheLimitGb = 'audio_cache_limit_gb';

  static final ValueNotifier<int> audioCacheLimitGb = ValueNotifier(0);
  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    audioCacheLimitGb.value = (prefs.getInt(_prefsAudioCacheLimitGb) ?? 0)
        .clamp(0, 5);
    _applyCacheSettings();
  }

  static Future<void> setAudioCacheLimitGb(int gb) async {
    final prefs = await SharedPreferences.getInstance();
    final value = gb.clamp(0, 5);
    await prefs.setInt(_prefsAudioCacheLimitGb, value);
    audioCacheLimitGb.value = value;
    _applyCacheSettings();
  }

  static void _applyCacheSettings() {
    final gb = audioCacheLimitGb.value;
    final bytes = gb <= 0 ? 0 : gb * 1024 * 1024 * 1024;
    AudioCacheService.instance.setMaxCacheBytes(bytes);
  }
}

class SongDownloadSettings {
  static const String _prefsCustomDirectory = 'song_download_custom_directory';
  static const String _prefsUseCustomDirectory =
      'song_download_use_custom_directory';

  static final ValueNotifier<String?> customDirectoryPath = ValueNotifier(null);
  static final ValueNotifier<bool> useCustomDirectory = ValueNotifier(false);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    customDirectoryPath.value = prefs.getString(_prefsCustomDirectory);
    useCustomDirectory.value = prefs.getBool(_prefsUseCustomDirectory) ?? false;
  }

  static Future<void> setCustomDirectoryPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.trim().isEmpty) {
      await prefs.remove(_prefsCustomDirectory);
      customDirectoryPath.value = null;
      return;
    }
    await prefs.setString(_prefsCustomDirectory, path);
    customDirectoryPath.value = path;
  }

  static Future<void> setUseCustomDirectory(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsUseCustomDirectory, enabled);
    useCustomDirectory.value = enabled;
  }
}
