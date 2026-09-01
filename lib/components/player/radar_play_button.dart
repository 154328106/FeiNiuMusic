import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 雷达按钮：静止时是个 `((·))`，播放时一圈圈向外扩散。
///
/// 首页漫游卡、迷你播放条、播放页共用同一个 —— 三处各画一版必然会走形。
/// 点击语义由调用方给：漫游卡是「没在播就播、正在播就换一首」，播放条和
/// 播放页则是普通的播放/暂停。
class RadarPlayButton extends StatefulWidget {
  const RadarPlayButton({
    super.key,
    required this.isPlaying,
    required this.onPlay,
    this.onRefresh,
    this.size = 48,
    this.semanticsLabel,
  });

  /// 播放中：盘面染主色、波纹持续扩散。
  final bool isPlaying;

  /// 主动作。[onRefresh] 为 null 时，任何状态下点击都走它。
  final VoidCallback onPlay;

  /// 给了它就变成「正在播时点击 = 换一首」，漫游卡用的就是这个语义。
  final VoidCallback? onRefresh;

  final double size;

  /// 无障碍标签。不给就按有没有 [onRefresh] 自动取。
  final String? semanticsLabel;

  @override
  State<RadarPlayButton> createState() => RadarPlayButtonState();
}

class RadarPlayButtonState extends State<RadarPlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant RadarPlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying == oldWidget.isPlaying) return;
    if (widget.isPlaying) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _defaultLabel() {
    if (widget.onRefresh != null) {
      return widget.isPlaying ? '换一首' : '播放';
    }
    return widget.isPlaying ? '暂停' : '播放';
  }

  void _handleTap() {
    final refresh = widget.onRefresh;
    if (widget.isPlaying && refresh != null) {
      refresh();
      return;
    }
    widget.onPlay();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: widget.semanticsLabel ?? _defaultLabel(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _RadarPainter(
                color: scheme.onSurface,
                surface: scheme.surfaceContainerHighest,
                accent: scheme.primary,
                isDark: isDark,
                progress: widget.isPlaying ? _controller.value : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.color,
    required this.surface,
    required this.accent,
    required this.isDark,
    required this.progress,
  });

  /// 前景色（弧线与中心点）。
  final Color color;

  /// 按钮盘面的底色。
  final Color surface;

  /// 播放时给盘面染一点主色，看着「活着」。
  final Color accent;

  final bool isDark;

  /// null 表示静止；0~1 循环，驱动向外扩散的波。
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 1.5;
    final playing = progress != null;
    // 所有固定尺寸都按 48 的基准缩放，否则做小之后中心点和描边会糊成一坨。
    final k = size.shortestSide / 48.0;

    // 1) 投影：盘面往下沉一点，和卡片背景拉开层次。
    canvas.drawCircle(
      center.translate(0, 2.2 * k),
      radius,
      Paint()
        ..color = Colors.black.withValues(alpha: isDark ? 0.34 : 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5 * k),
    );

    // 2) 盘面：左上亮右下暗的斜向渐变，做出凸起的球面感。
    final base = playing
        ? Color.alphaBlend(accent.withValues(alpha: 0.20), surface)
        : surface;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              Colors.white.withValues(alpha: isDark ? 0.16 : 0.55),
              base,
            ),
            Color.alphaBlend(
              Colors.black.withValues(alpha: isDark ? 0.24 : 0.08),
              base,
            ),
          ],
        ).createShader(rect),
    );

    // 3) 外描边 + 上缘高光：两层边才有「厚度」，只画一圈会显得是贴纸。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 * k
        ..color = color.withValues(alpha: isDark ? 0.20 : 0.12),
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 1.1 * k),
      math.pi * 1.15,
      math.pi * 0.7,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 * k
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: isDark ? 0.22 : 0.75),
    );

    // 4) 中心点：自带一小圈光晕，像个发射源。
    final dot = playing ? accent : color;
    canvas.drawCircle(
      center,
      5.5 * k,
      Paint()
        ..color = dot.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3 * k),
    );
    canvas.drawCircle(center, 2.8 * k, Paint()..color = dot.withValues(alpha: 0.9));

    final p = progress;
    if (p == null) {
      for (var i = 0; i < 2; i++) {
        _drawWings(
          canvas,
          center,
          (7.0 + i * 5.5) * k,
          color.withValues(alpha: 0.45 - i * 0.16),
          1.4 * k,
        );
      }
      return;
    }

    // 播放中：两道波错开半个周期，依次从中心扩到边缘并淡出。
    for (var i = 0; i < 2; i++) {
      final t = (p + i / 2) % 1.0;
      final alpha = (1 - t) * 0.62;
      if (alpha <= 0.02) continue;
      _drawWings(
        canvas,
        center,
        6.5 * k + t * (radius - 8 * k),
        accent.withValues(alpha: alpha),
        1.5 * k,
      );
    }
  }

  /// 左右两道对称的弧 —— 雷达的「翅膀」。
  void _drawWings(Canvas canvas, Offset center, double r, Color c, double w) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = c;
    final rect = Rect.fromCircle(center: center, radius: r);
    const sweep = 1.74; // 约 100°
    canvas.drawArc(rect, -sweep / 2, sweep, false, paint);
    canvas.drawArc(rect, math.pi - sweep / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.surface != surface ||
      oldDelegate.accent != accent ||
      oldDelegate.isDark != isDark;
}
