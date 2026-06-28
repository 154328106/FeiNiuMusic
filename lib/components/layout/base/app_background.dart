import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'dart:ui' as ui;

import '../../../app/state/settings_state.dart';

class AppBackground extends StatefulWidget {
  final Widget child;

  const AppBackground({super.key, required this.child});

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground> {
  // Cache the existence check so we don't hit the filesystem on every rebuild
  // (e.g. when only mask opacity or glow toggles change).
  String? _checkedPath;
  bool _checkedExists = false;

  bool _imageExists(String? path) {
    if (path == null || path.isEmpty) return false;
    if (path == _checkedPath) return _checkedExists;
    _checkedPath = path;
    _checkedExists = File(path).existsSync();
    return _checkedExists;
  }

  @override
  void initState() {
    super.initState();
    AppBackgroundSettings.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: Listenable.merge([
        AppBackgroundSettings.backgroundImagePath,
        AppBackgroundSettings.backgroundMaskOpacity,
        AppBackgroundSettings.pageGlowEnabled,
      ]),
      builder: (context, _) {
        final path = AppBackgroundSettings.backgroundImagePath.value;
        final maskOpacity = AppBackgroundSettings.backgroundMaskOpacity.value;
        final glowEnabled = AppBackgroundSettings.pageGlowEnabled.value;
        final imagePath = path;
        final hasImage =
            imagePath != null && imagePath.isNotEmpty && _imageExists(imagePath);
        final baseColor = theme.scaffoldBackgroundColor;
        final maskColor = theme.scaffoldBackgroundColor.withValues(
          alpha: maskOpacity,
        );
        return Container(
          color: baseColor,
          child: Stack(
            children: [
              if (hasImage)
                Positioned.fill(
                  child: Image.file(File(imagePath), fit: BoxFit.cover),
                ),
              if (glowEnabled) ...[
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: Stack(
                        children: [
                          _glow(
                            alignment: const Alignment(0.88, -0.92),
                            size: 360,
                            scaleX: 1.15,
                            scaleY: 0.92,
                            blurSigma: 46,
                            colors: _glowColors(
                              colorScheme,
                              isDark: isDark,
                              primary: false,
                              strength: 0.9,
                            ),
                          ),
                          _glow(
                            alignment: const Alignment(-0.86, 0.82),
                            size: 330,
                            scaleX: 0.96,
                            scaleY: 1.1,
                            blurSigma: 42,
                            colors: _glowColors(
                              colorScheme,
                              isDark: isDark,
                              primary: true,
                              strength: 0.82,
                            ),
                          ),
                          _glow(
                            alignment: const Alignment(0.1, -0.05),
                            size: 300,
                            scaleX: 1.25,
                            scaleY: 0.8,
                            blurSigma: 50,
                            colors: _glowColors(
                              colorScheme,
                              isDark: isDark,
                              primary: true,
                              strength: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (hasImage && maskOpacity > 0)
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(color: maskColor),
                  ),
                ),
              widget.child,
            ],
          ),
        );
      },
    );
  }

  List<Color> _glowColors(
    ColorScheme colorScheme, {
    required bool isDark,
    required bool primary,
    required double strength,
  }) {
    // Derive both blobs from the theme (primary / tertiary) so the page glow
    // stays cohesive with the chosen seed color in both light and dark, and
    // keep alpha low so it reads as a soft ambient wash rather than a stain.
    final hue = primary ? colorScheme.primary : colorScheme.tertiary;
    final baseAlpha = (isDark ? 0.16 : 0.11) * strength;
    final seed = hue.withValues(alpha: baseAlpha);
    return [
      seed,
      seed.withValues(alpha: seed.a * 0.45),
      seed.withValues(alpha: 0.0),
    ];
  }

  Widget _glow({
    required Alignment alignment,
    required double size,
    required List<Color> colors,
    required double scaleX,
    required double scaleY,
    required double blurSigma,
  }) {
    return Align(
      alignment: alignment,
      child: Transform.scale(
        scaleX: scaleX,
        scaleY: scaleY,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: blurSigma,
            sigmaY: blurSigma,
          ),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                radius: 0.76,
                colors: colors,
                stops: const [0.0, 0.55, 1.0],
                transform: const GradientRotation(math.pi / 8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
