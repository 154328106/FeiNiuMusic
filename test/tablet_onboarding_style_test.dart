import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/onboarding/onboarding_page.dart';

/// 引导页页3（播放器外观）大屏适配：
/// - 平板横屏下样式预览卡不应占满全屏（限制宽度 + 固定横屏观感比例）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
  });

  Future<void> pumpToPage3(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: OnboardingPage()));
    await tester.pump();

    final nextBtn = find.widgetWithText(FilledButton, '下一步');
    expect(nextBtn, findsWidgets);
    for (var page = 0; page < 2; page++) {
      await tester.tap(nextBtn.first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
    }
  }

  testWidgets('平板横屏：页3 预览卡高度受限（非全屏）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AppLayoutSettings.tabletMode.value = true;

    await pumpToPage3(tester);

    expect(find.text('播放器外观'), findsOneWidget);
    // 找样式卡的圆角容器（ClipRRect radius 14），量它的高度。
    final previewClips = find.byWidgetPredicate(
      (w) => w is ClipRRect && w.borderRadius == BorderRadius.circular(14.0),
    );
    expect(previewClips, findsWidgets);
    final height = tester.getSize(previewClips.first).height;
    debugPrint('平板页3 预览卡高度: $height');
    // 平板横屏 800 高下，预览卡不应占满整屏高度（应 < 屏高）。
    expect(height, lessThan(700), reason: '预览卡不应几乎全屏');
  });
}
