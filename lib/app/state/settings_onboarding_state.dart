import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动引导页完成状态。
///
/// 与登录态无关：未标记完成则启动一律显示引导页（含老用户升级后首次打开，
/// 缺省为 false）；完成后（setCompleted）永不再显示。
class AppOnboardingSettings {
  static const String _prefsCompleted = 'app_onboarding_completed';

  static final ValueNotifier<bool> completed = ValueNotifier(false);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    completed.value = prefs.getBool(_prefsCompleted) ?? false;
  }

  /// 标记引导完成：写持久化标记后更新 notifier，
  /// _AppStartupGate 外层监听随即切换到登录页/主外壳。
  static Future<void> setCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsCompleted, true);
    completed.value = true;
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    completed.value = false;
  }
}
