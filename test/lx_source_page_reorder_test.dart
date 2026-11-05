import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/lxscript/lx_source_manager.dart';
import 'package:feiniu_music/pages/settings/lx_source_page.dart';

/// 音源脚本页：长按卡片拖动、菜单上移 / 下移，都改的是取址顺序。
void main() {
  Future<void> setUpScripts() async {
    SharedPreferences.setMockInitialValues({
      'lx_sources_index': jsonEncode([
        for (final id in ['a', 'b', 'c'])
          {
            'id': id,
            'name': '脚本$id',
            'enabled': false,
            'sources': ['kg'],
          },
      ]),
    });
    await LxSourceManager.instance.reloadFromStorage();
  }

  // 页面里有一直在跑的动画（迷你播放条等），pumpAndSettle 等不到静止
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  List<String> order() =>
      LxSourceManager.instance.list().map((m) => m.id).toList();

  testWidgets('显示「第 N 个问」，菜单下移改顺序', (tester) async {
    await tester.runAsync(setUpScripts);
    await tester.pumpWidget(const MaterialApp(home: LxSourcePage()));
    await settle(tester);

    expect(find.textContaining('第 1 个问'), findsOneWidget);
    expect(find.textContaining('第 3 个问'), findsOneWidget);

    // 第一个脚本的「更多」→ 下移
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await settle(tester);
    expect(find.text('上移'), findsNothing, reason: '第一个没有上移');
    await tester.tap(find.text('下移'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
    expect(order(), ['b', 'a', 'c']);
  });

  testWidgets('长按卡片往下拖到最后', (tester) async {
    await tester.runAsync(setUpScripts);
    await tester.pumpWidget(const MaterialApp(home: LxSourcePage()));
    await settle(tester);

    final first = find.text('脚本a');
    final last = find.text('脚本c');
    final from = tester.getCenter(first);
    final to = tester.getCenter(last);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 700)); // 长按
    // 像真手指一样一点点往下拖（一下跳过去列表来不及让位）
    final total = (to.dy - from.dy) + 40;
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(Offset(0, total / 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
    expect(order(), ['b', 'c', 'a']);
  });
}
