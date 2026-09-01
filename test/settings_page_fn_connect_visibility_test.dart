import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_fn_state.dart';
import 'package:feiniu_music/pages/settings/settings_page.dart';

/// 设置页 FN Connect 入口的可见性。
///
/// 通过 FNID 连接（lastFnId 非空）时显示「FN Connect」入口（候选链路管理）；
/// 通过链接直连（lastFnId 为空）时该入口无意义，应隐藏。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppFnConnectionSettings.resetForTest();
    AppFnConnectionSettings.ensureLoaded();
  });

  tearDown(() {
    AppFnConnectionSettings.resetForTest();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // SettingsPage.build 同步读取 AppFnConnectionSettings.lastFnId，单次 pump 即可。
    // 页面含常驻动画，不能用 pumpAndSettle（会超时）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsPage())),
    );
    await tester.pump();
  }

  testWidgets('lastFnId 非空（FNID 连接）→ 显示 FN Connect 入口',
      (tester) async {
    AppFnConnectionSettings.lastFnId = 'myid';

    await pumpPage(tester);
    expect(find.text('FN Connect'), findsOneWidget);
  });

  testWidgets('lastFnId 为空（链接直连）→ 隐藏 FN Connect 入口',
      (tester) async {
    AppFnConnectionSettings.lastFnId = null;

    await pumpPage(tester);
    expect(find.text('FN Connect'), findsNothing);
  });

  testWidgets('其他功能项不受影响（音量设置仍在）', (tester) async {
    AppFnConnectionSettings.lastFnId = null;

    await pumpPage(tester);
    // 锚点原来是「播放器控制」，那一项已经搬到「我的 → 主题外观」里了。
    // 这条用例要验的是「FN Connect 隐藏时不误伤同单元的其它项」，
    // 换一个还留在「功能」里的条目当锚点即可。
    expect(find.text('音量设置'), findsOneWidget);
    expect(find.text('FN Connect'), findsNothing);
  });
}
