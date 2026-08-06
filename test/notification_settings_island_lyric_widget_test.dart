import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_island_lyric.dart';
import 'package:feiniu_music/components/index.dart';

/// 回归测试：灵动岛设置区块里，
/// 主开关关闭时「显示播放进度」子开关不应被禁用（onChanged 非空）。
///
/// 直接从 components 构建区块（不依赖设置页的完整异步加载），
/// 专注验证 UI 交互性。持久化行为由 test/settings_island_lyric_test.dart 覆盖。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IslandLyricSettings.resetForTest();
  });

  testWidgets('灵动岛设置：主开关关闭时「显示播放进度」仍可独立点击', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              AppSettingSection(
                title: '通知歌词灵动岛',
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: IslandLyricSettings.enabled,
                    builder: (context, enabled, _) {
                      return AppSettingSwitchTile(
                        title: '灵动岛歌词',
                        value: enabled,
                        onChanged: (value) {
                          IslandLyricSettings.setEnabled(value);
                        },
                      );
                    },
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: IslandLyricSettings.showProgress,
                    builder: (context, showProgress, _) {
                      return AppSettingSwitchTile(
                        title: '显示播放进度',
                        value: showProgress,
                        onChanged: (value) {
                          IslandLyricSettings.setShowProgress(value);
                        },
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // 主开关默认关闭
    expect(IslandLyricSettings.enabled.value, isFalse);

    // 「显示播放进度」开关存在
    final progressTileText = find.text('显示播放进度');
    expect(progressTileText, findsOneWidget);

    // 该行 Switch 应可交互（onChanged 非空）—— 这是回归点：修复前为 null
    final progressSwitchWidget = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: progressTileText,
          matching: find.byType(ListTile),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(progressSwitchWidget.onChanged, isNotNull,
        reason: '主开关关闭时「显示播放进度」也应能独立点击');
  });
}
