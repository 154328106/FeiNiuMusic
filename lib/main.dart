import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

import 'app/app.dart';
import 'app/services/debug_log_service.dart';
import 'app/state/settings_state.dart';
import 'app/services/media_notification_service.dart';
import 'app/services/db/dao/song_dao.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DebugLogService.instance.ensureLoaded();
  await FlutterDisplayMode.setHighRefreshRate();
  await MediaNotificationService.init();
  await AppThemeSettings.ensureLoaded();
  await AppLayoutSettings.ensureLoaded();
  await AppBackgroundSettings.ensureLoaded();
  await PlayerStyleSettings.ensureLoaded();
  runApp(const NagoMusicApp());
  SongDao().fetchAllCached();
}
