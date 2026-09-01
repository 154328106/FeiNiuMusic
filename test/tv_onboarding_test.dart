import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/components/focus/tv_focusable.dart';
import 'package:feiniu_music/pages/onboarding/onboarding_page.dart';

/// 引导页 TV 适配：页3 播放器样式选择卡（GestureDetector 非 Material）
/// 在 TV 模式下被 TvFocusable 包裹（可遥控聚焦），非 TV 模式保持原样。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
  });

  Future<void> pumpToPage3(WidgetTester tester) async {
    // 页面含常驻动画，不能用 pumpAndSettle。
    await tester.pumpWidget(const MaterialApp(home: OnboardingPage()));
    await tester.pump();

    // 「下一步」前进到页3（页1→页2→页3）。每次点击后多 pump 几次推进动画。
    final nextBtn = find.widgetWithText(FilledButton, '下一步');
    expect(nextBtn, findsWidgets);
    for (var page = 0; page < 2; page++) {
      await tester.tap(nextBtn.first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
    }
  }

  testWidgets('非 TV：页3 样式卡不被 TvFocusable 包裹（原样渲染）',
      (tester) async {
    await pumpToPage3(tester);

    expect(find.text('播放器外观'), findsOneWidget);
    // 封面样式选择卡（CD 碟片 / 黑胶唱片）渲染。
    // 引导页这一屏原来选的是「默认 / 海报歌词」的布局，现在改成选封面样式，
    // 布局那两项留在设置里，所以这里的锚点文案跟着换。
    expect(find.text('CD 碟片'), findsOneWidget);
    expect(find.text('黑胶唱片'), findsOneWidget);
    // 非 TV 模式不引入焦点环。
    expect(find.byType(TvFocusable), findsNothing);
  });

  testWidgets('TV 模式：页3 样式卡被 TvFocusable 包裹（可遥控聚焦）',
      (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await pumpToPage3(tester);

    expect(find.text('播放器外观'), findsOneWidget);
    expect(find.text('CD 碟片'), findsOneWidget);
    expect(find.text('黑胶唱片'), findsOneWidget);
    // TV 模式：两个样式卡各一个焦点环。
    expect(find.byType(TvFocusable), findsWidgets);
  });
}
