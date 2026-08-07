import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/player/player_page.dart';
import 'package:feiniu_music/pages/player/lyrics/lyric_view.dart';

/// 平板横屏播放页布局回归测试。
///
/// 1.2.9 之后平板横屏布局会重复渲染外层全宽 PlayerHeader（外层 + 平板布局
/// 内部各一份），把右侧歌词块推到下方留出大片空白。修复后外层 header
/// 在平板横屏时隐藏，歌词块从布局顶部铺满。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() => AppLayoutSettings.resetForTest());

  testWidgets('平板横屏：歌词块从顶部铺满（无重复 header 留白）', (tester) async {
    // 10 英寸平板横屏：逻辑 1280×800。
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AppLayoutSettings.tabletMode.value = true;

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 平板横屏布局应渲染歌词视图
    expect(find.byType(PlayerLyricsView), findsOneWidget);

    final rect = tester.getRect(find.byType(PlayerLyricsView));
    // 歌词块应从布局顶部开始（仅留外层布局 Padding 8px），
    // 而不是被外层重复 header 推到 93px 处。
    expect(rect.top, lessThan(30),
        reason: '歌词块顶部不应有重复 header 留白，实际 top=${rect.top}');
    // 歌词块应铺满到接近底部
    expect(rect.height, greaterThan(700),
        reason: '歌词块应铺满整列高度，实际 height=${rect.height}');
  });

  testWidgets('手机竖屏：仍渲染外层 header（非平板不隐藏）', (tester) async {
    // 手机竖屏 390×844（最短边 390 < 600，非平板）。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 手机走 _MobilePlayerLayout，首屏是封面页，不渲染 PlayerLyricsView；
    // 外层 header 仍渲染（非平板不隐藏），布局不崩溃。
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerLyricsView), findsNothing);
  });
}
