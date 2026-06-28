import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MediaNotificationSettings {
  static const String _prefsShowLyrics = 'notification_show_lyrics';
  static const String _prefsShowCloseAction = 'notification_show_close_action';
  static const String _prefsLyricOnTop = 'notification_lyric_on_top';
  static const String _prefsShowFavoriteAction =
      'notification_show_favorite_action';

  static final ValueNotifier<bool> showLyrics = ValueNotifier(true);
  static final ValueNotifier<bool> showCloseAction = ValueNotifier(true);
  static final ValueNotifier<bool> lyricOnTop = ValueNotifier(false);
  static final ValueNotifier<bool> showFavoriteAction = ValueNotifier(true);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    showLyrics.value = prefs.getBool(_prefsShowLyrics) ?? true;
    showCloseAction.value = prefs.getBool(_prefsShowCloseAction) ?? true;
    lyricOnTop.value = prefs.getBool(_prefsLyricOnTop) ?? false;
    showFavoriteAction.value = prefs.getBool(_prefsShowFavoriteAction) ?? true;
  }

  static Future<void> setShowLyrics(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowLyrics, enabled);
    showLyrics.value = enabled;
  }

  static Future<void> setShowCloseAction(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowCloseAction, enabled);
    showCloseAction.value = enabled;
  }

  static Future<void> setLyricOnTop(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsLyricOnTop, enabled);
    lyricOnTop.value = enabled;
  }

  static Future<void> setShowFavoriteAction(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowFavoriteAction, enabled);
    showFavoriteAction.value = enabled;
  }
}
