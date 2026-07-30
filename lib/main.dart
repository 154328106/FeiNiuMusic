import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/services/debug_log_service.dart';
import 'app/services/fn_auto_reconnect_service.dart';
import 'app/services/media_notification_service.dart';
import 'app/services/feiniu/auth_service.dart';
import 'app/state/settings_fn_state.dart';
import 'app/state/settings_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DebugLogService.instance.ensureLoaded();
  await FlutterDisplayMode.setHighRefreshRate();
  await MediaNotificationService.init();
  await AppThemeSettings.ensureLoaded();
  await AppLayoutSettings.ensureLoaded();
  await AppBackgroundSettings.ensureLoaded();
  await AppFnConnectionSettings.ensureLoaded();
  await PlayerStyleSettings.ensureLoaded();
  // 初始化认证状态（从 SharedPreferences 恢复 token）
  await AuthService.instance.init();
  // 初始化自动重连服务（监听网络变化 + API 失败）
  FnAutoReconnectService.instance.init();
  runApp(const FeiNiuMusicApp());
  // Fire-and-forget warm-ups that run in parallel with the first frame so
  // per-page initState calls don't have to pay for these cold starts:
  //   - SharedPreferences.getInstance() reads its backing file once, then
  //     serves subsequent callers from the in-memory instance.
  SharedPreferences.getInstance();
}
