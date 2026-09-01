import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「不连飞牛也能用」的访客模式。
///
/// 飞牛账号原本是进 App 的唯一门票，可现在网易云那条线不登录也能听（推荐
/// 新歌、推荐歌单、排行榜、搜索都不需要账号）。为了这个把人挡在登录页外面
/// 没道理，于是加一个开关：打开后登录门控放行，音乐源默认切到网易云。
///
/// 一旦真的连上了飞牛，门控本来就会放行，这个开关留着也不碍事。
class AppGuestSettings {
  AppGuestSettings._();

  static const String _prefsKey = 'app.guest_mode';

  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      // 读不出来就按「没开」走，不影响启动。
    }
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {
      // 存不下只影响下次启动，这次照常生效。
    }
  }
}
