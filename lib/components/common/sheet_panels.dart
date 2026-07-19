import 'package:flutter/material.dart';

import '../../app/theme/app_visual_theme.dart';

class AppSheetPanel extends StatelessWidget {
  final String? title;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final bool expand;

  const AppSheetPanel({
    super.key,
    this.title,
    required this.child,
    this.padding,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final miuix = context.usesMiuix;
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.cardTheme.color ?? theme.cardColor;
    final secondaryTextColor = isDark
        ? Colors.white70
        : const Color.fromARGB(255, 100, 100, 100);

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(miuix ? 30 : 22),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: secondaryTextColor.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            if (title != null)
              Padding(
                padding: EdgeInsets.fromLTRB(20, miuix ? 18 : 16, 20, 10),
                child: Text(
                  title!,
                  style: miuix
                      ? theme.textTheme.titleLarge?.copyWith(fontSize: 20)
                      : TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                ),
              ),
            if (expand)
              Expanded(
                child: Padding(
                  padding: padding ?? EdgeInsets.zero,
                  child: child,
                ),
              )
            else
              Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ],
        ),
      ),
    );
  }
}
