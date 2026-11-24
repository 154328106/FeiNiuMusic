import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放日志：只记录「哪首歌、哪个平台、最终用了哪个音源取到链」。
///
/// 与 [DebugLogService] 的调试日志分开：调试日志抓全部 debugPrint 用来找 bug，
/// 这一份只给用户看「这一首为什么能播/播不了、走了谁」，可单独开关。
class PlaybackLogService {
  PlaybackLogService._();

  static final PlaybackLogService instance = PlaybackLogService._();

  static const String _prefsEnabled = 'playback_log_enabled';
  static const String _prefsLogs = 'playback_log_entries';
  static const int _maxEntries = 300;

  final ValueNotifier<bool> enabled = ValueNotifier(false);
  final ValueNotifier<List<String>> entries = ValueNotifier(<String>[]);

  static const Map<String, String> _platformNames = {
    'wy': '网易云',
    'tx': 'QQ音乐',
    'kg': '酷狗',
    'kw': '酷我',
    'mg': '咪咕',
    'fn': '飞牛',
  };

  Future<void>? _loading;
  bool _persistScheduled = false;

  Future<void> ensureLoaded() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    entries.value = prefs.getStringList(_prefsLogs) ?? <String>[];
  }

  Future<void> setEnabled(bool value) async {
    await ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }

  Future<void> clear() async {
    await ensureLoaded();
    entries.value = <String>[];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsLogs);
  }

  String exportText() {
    if (entries.value.isEmpty) return 'No playback logs.';
    return entries.value.reversed.join('\n');
  }

  /// 记一条「歌名 - 平台 - 音源」。
  void log({
    required String title,
    required String platform,
    required String source,
  }) {
    if (!enabled.value) return;
    final now = DateTime.now();
    final time =
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final p = _platformNames[platform] ?? platform;
    final line = '[$time] $title - $p - $source';
    final next = <String>[line, ...entries.value];
    if (next.length > _maxEntries) {
      next.removeRange(_maxEntries, next.length);
    }
    entries.value = next;
    _schedulePersist();
  }

  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      _persistScheduled = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsLogs, entries.value);
    });
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}
