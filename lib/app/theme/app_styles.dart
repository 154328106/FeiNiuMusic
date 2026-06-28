import 'package:flutter/material.dart';

import '../state/settings_background_state.dart';

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class CoverPageTransitionsBuilder extends PageTransitionsBuilder {
  const CoverPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Incoming page: ease in from the right with a short fade.
    final inCurve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final slideIn = inCurve.drive(
      Tween(begin: const Offset(0.16, 0), end: Offset.zero),
    );
    final fadeIn = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
      reverseCurve: const Interval(0.45, 1.0, curve: Curves.easeIn),
    );

    Widget result = SlideTransition(
      position: slideIn,
      child: FadeTransition(opacity: fadeIn, child: child),
    );

    // Outgoing page (covered by a new route): subtle parallax to the left so
    // the stack feels layered instead of a flat cross-slide.
    if (secondaryAnimation.status != AnimationStatus.dismissed) {
      final outCurve = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      result = SlideTransition(
        position: outCurve.drive(
          Tween(begin: Offset.zero, end: const Offset(-0.08, 0)),
        ),
        child: result,
      );
    }
    return result;
  }
}

extension AppThemeSurfaceX on ThemeData {
  bool get hasAmbientBackground {
    final backgroundPath = AppBackgroundSettings.backgroundImagePath.value;
    return AppBackgroundSettings.pageGlowEnabled.value ||
        (backgroundPath != null && backgroundPath.trim().isNotEmpty);
  }

  Color get appPanelColor {
    final isDark = brightness == Brightness.dark;
    final glassEnabled = AppBackgroundSettings.glassEffectEnabled.value;
    final panelOpacity = glassEnabled
        ? AppBackgroundSettings.panelOpacity.value
        : 1.0;
    if (panelOpacity <= 0) return Colors.transparent;
    final base = isDark
        ? Color.alphaBlend(
            colorScheme.primary.withValues(alpha: 0.08),
            colorScheme.surfaceContainerHigh,
          )
        : Color.alphaBlend(
            colorScheme.primary.withValues(alpha: 0.12),
            Colors.white,
          );
    if (!glassEnabled || !hasAmbientBackground) {
      return base.withValues(alpha: panelOpacity);
    }

    final overlayColor = isDark
        ? colorScheme.surfaceContainerHighest.withValues(alpha: panelOpacity)
        : Colors.white.withValues(alpha: panelOpacity);

    return Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.06),
      overlayColor,
    );
  }

  Color get appPanelShadowColor {
    final isDark = brightness == Brightness.dark;
    return isDark
        ? Colors.black.withValues(alpha: 0.35)
        : colorScheme.primary.withValues(alpha: 0.16);
  }

  Color get appPanelBorderColor {
    final isDark = brightness == Brightness.dark;
    return isDark
        ? colorScheme.outline.withValues(alpha: 0.36)
        : colorScheme.primary.withValues(alpha: 0.12);
  }

  Color get appPanelElevatedColor {
    final base = appPanelColor;
    if (base.a <= 0) return Colors.transparent;
    final overlay = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.25);
    return Color.alphaBlend(overlay, base);
  }
}
