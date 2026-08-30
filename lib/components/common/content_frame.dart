import 'package:flutter/material.dart';

import '../../app/state/settings_background_state.dart';

/// 列表区块的「加框」方式。
enum AppContentFrameStyle {
  /// 不加框，保持原样。
  none,

  /// 整块描边：一圈圆角描边把整个列表框起来，行之间用内缩分隔线。
  outlined,

  /// 逐行卡片：每一行各自是一张圆角卡片，行与行之间留空隙。
  cards;

  String get label => switch (this) {
    AppContentFrameStyle.none => '不加框',
    AppContentFrameStyle.outlined => '整块描边',
    AppContentFrameStyle.cards => '逐行卡片',
  };

  String get description => switch (this) {
    AppContentFrameStyle.none => '列表直接贴在背景上',
    AppContentFrameStyle.outlined => '整个列表套一圈圆角描边',
    AppContentFrameStyle.cards => '每首歌单独一张圆角卡片',
  };

  static AppContentFrameStyle fromName(String? raw) =>
      AppContentFrameStyle.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => AppContentFrameStyle.none,
      );
}

/// 描边实际用色：优先自定义颜色，否则跟随主题的 outlineVariant；
/// 两种情况都再乘上用户设定的不透明度。
Color _frameBorderColor(BuildContext context, {double scale = 1.0}) {
  final scheme = Theme.of(context).colorScheme;
  final custom = AppBackgroundSettings.contentFrameColor.value;
  final opacity = (AppBackgroundSettings.contentFrameOpacity.value * scale)
      .clamp(0.0, 1.0);
  return (custom ?? scheme.outlineVariant).withValues(alpha: opacity);
}

/// 颜色/透明度这两个设置也要触发重建，否则改完要重进页面才生效。
Widget _watchFrameSettings(BuildContext context, WidgetBuilder builder) {
  return ListenableBuilder(
    listenable: Listenable.merge([
      AppBackgroundSettings.contentFrameColor,
      AppBackgroundSettings.contentFrameOpacity,
    ]),
    builder: (context, _) => builder(context),
  );
}

/// 列表区块的外框。仅在「整块描边」样式下生效。
///
/// 其余样式**原样透传**子组件，不额外包一层 widget —— 没开这个效果的用户
/// 不该平白多一层布局开销。
class AppContentFrame extends StatelessWidget {
  final Widget child;
  final double borderRadius;

  const AppContentFrame({
    super.key,
    required this.child,
    this.borderRadius = 20,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppContentFrameStyle>(
      valueListenable: AppBackgroundSettings.contentFrameStyle,
      builder: (context, style, child) {
        if (style != AppContentFrameStyle.outlined) return child!;
        return _watchFrameSettings(context, (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(color: _frameBorderColor(context), width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            // 描边是圆角的，内容也要跟着裁，否则行的点击高亮会顶出圆角。
            child: ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius - 1.2),
              child: child,
            ),
          );
        });
      },
      child: child,
    );
  }
}

/// 列表中单行的外观。
///
/// - 「逐行卡片」：包成一张圆角卡片（浅底 + 描边 + 轻投影）；
/// - 「整块描边」：行本身不加装饰，但除最后一行外补一条**内缩**分隔线
///   （顶到边会和外框的圆角打架）；
/// - 「不加框」：原样透传。
class AppContentRow extends StatelessWidget {
  final Widget child;

  /// 是否是所在列表的最后一行（决定要不要画分隔线 / 留底部间距）。
  final bool isLast;

  const AppContentRow({super.key, required this.child, this.isLast = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppContentFrameStyle>(
      valueListenable: AppBackgroundSettings.contentFrameStyle,
      builder: (context, style, child) {
        if (style == AppContentFrameStyle.none) return child!;
        return _watchFrameSettings(context, (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final isDark = theme.brightness == Brightness.dark;
          switch (style) {
            case AppContentFrameStyle.none:
              return child!;
            case AppContentFrameStyle.outlined:
              if (isLast) return child!;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  child!,
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Divider(
                      height: 1,
                      thickness: 1,
                      // 分隔线比外框淡一档，不然一列横线太抢眼。
                      color: _frameBorderColor(context, scale: 0.6),
                    ),
                  ),
                ],
              );
            case AppContentFrameStyle.cards:
              return Padding(
                padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _frameBorderColor(context, scale: 0.75),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.18 : 0.05,
                        ),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: child,
                  ),
                ),
              );
          }
        });
      },
      child: child,
    );
  }
}
