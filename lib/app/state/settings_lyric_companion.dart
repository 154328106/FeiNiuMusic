import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配套编辑服务（FnMusicLyricsEditor）设置。
///
/// FnMusicLyricsEditor 是运行在飞牛 NAS 上的配套应用，监听 38200 端口，
/// 提供歌词读写与歌手/专辑编辑（改名 + 封面写入）。仅非中继（5ddd.com）
/// 连接下可用。
class LyricCompanionSettings {
  static const String _prefsEnabled = 'lyric_companion_enabled';
  static const String _prefsApiKey = 'lyric_companion_api_key';

  /// 配套编辑服务开关。
  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  /// X-API-Key 服务密钥。
  static final ValueNotifier<String> apiKey = ValueNotifier('');

  static bool _loaded = false;

  static bool get loaded => _loaded;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    apiKey.value = prefs.getString(_prefsApiKey) ?? '';
    _loaded = true;
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
  }

  static Future<void> setApiKey(String value) async {
    apiKey.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsApiKey, value);
  }
}
