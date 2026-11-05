import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/mini_player_collapse.dart';

/// 2026-11-05：安卓「我的」页往下拉，迷你条也会收成球（iOS 不会）。
/// 收起只认「手指确实往上推」的帧。
void main() {
  late BuildContext ctx;

  ScrollMetrics metrics(double pixels) => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 300,
    pixels: pixels,
    viewportDimension: 700,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 1,
  );

  ScrollUpdateNotification update(double scrollDelta, double fingerDy) =>
      ScrollUpdateNotification(
        metrics: metrics(100),
        context: ctx,
        scrollDelta: scrollDelta,
        dragDetails: DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: Offset(0, fingerDy),
          primaryDelta: fingerDy,
        ),
      );

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    Builder(
      builder: (c) {
        ctx = c;
        return const SizedBox();
      },
    ),
  );

  testWidgets('手指往下拉：列表位置哪怕往下走也不收', (tester) async {
    await pump(tester);
    final m = MiniPlayerCollapse.instance..reset();
    for (var i = 0; i < 5; i++) {
      m.handle(update(10, 12), pageHasMini: true);
    }
    expect(m.collapsed.value, isFalse);
  });

  testWidgets('手指往上推（往下浏览）：过阈值收成球', (tester) async {
    await pump(tester);
    final m = MiniPlayerCollapse.instance..reset();
    for (var i = 0; i < 3; i++) {
      m.handle(update(10, -10), pageHasMini: true);
    }
    expect(m.collapsed.value, isTrue);
    m.reset();
  });
}
