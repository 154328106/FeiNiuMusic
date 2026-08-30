import 'package:flutter/material.dart';

import '../../app/state/settings_background_state.dart';

/// 内容描边框：给列表区块套一层圆角描边卡片，把内容从背景里「框」出来。
///
/// 由「应用外观 → 内容描边框」全局开关控制；关闭时**原样透传**子组件，
/// 不额外包一层 widget，避免给没开这个效果的用户平白增加一层布局。
class AppContentFrame extends StatelessWidget {
  final Widget child;

  /// 卡片内边距。列表自带行内边距时传 0 更贴合。
  final EdgeInsetsGeometry padding;

  final double borderRadius;

  const AppContentFrame({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = 16,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppBackgroundSettings.contentFrameEnabled,
      builder: (context, enabled, child) {
        if (!enabled) return child!;
        final scheme = Theme.of(context).colorScheme;
        return Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              // 用主题的 outlineVariant 而不是写死颜色：深浅色主题、以及
              // 用户换强调色时都能跟着走。
              color: scheme.outlineVariant.withValues(alpha: 0.9),
              width: 1,
            ),
          ),
          // 描边是圆角的，内容也要跟着裁，否则列表行的高亮/分隔线会顶出圆角。
          child: ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius - 1),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
