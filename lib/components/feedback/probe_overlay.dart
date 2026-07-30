import 'package:flutter/material.dart';

/// 探测连接加载动画浮层
///
/// 使用 [OverlayEntry] 插入到根 Overlay，全局居中展示。
/// 本浮层无固定超时关闭逻辑，完全跟随探测流程生命周期。
///
/// 用法：
/// ```dart
/// final entry = ProbeOverlay.show(context);
/// // ... 探测完成后
/// ProbeOverlay.hide(entry);
/// ```
class ProbeOverlay {
  ProbeOverlay._();

  /// 展示全局探测加载浮层
  ///
  /// 返回 [OverlayEntry] 引用，用于后续移除。
  static OverlayEntry show(BuildContext context) {
    final overlay = Overlay.of(context, rootOverlay: true);

    final entry = OverlayEntry(
      builder: (_) => _ProbeOverlayWidget(),
    );

    overlay.insert(entry);
    return entry;
  }

  /// 隐藏探测加载浮层
  static void hide(OverlayEntry? entry) {
    entry?.remove();
  }
}

class _ProbeOverlayWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: Container(
        color: isDark
            ? Colors.black.withValues(alpha: 0.5)
            : Colors.black.withValues(alpha: 0.3),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 48),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '正在探测最优连接中...',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '正在尝试多种连接方式，请稍候',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
