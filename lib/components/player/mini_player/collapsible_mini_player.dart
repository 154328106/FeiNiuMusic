import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../app/state/mini_player_collapse.dart';
import '../../../app/state/song_state.dart';
import 'mini_player_bar.dart';

/// 迷你播放条「随滚动收成球」。
///
/// 不是淡出再冒一个球，而是**条本身连续变形**：外框从左往右收窄、高度收到球径、
/// 圆角收成正圆，同时整体下移，落到底部导航条同一行的右侧（导航条那边按同一个
/// [MiniPlayerCollapse.progress] 把右边让出来）。条里的歌名/按钮先淡掉，最后圆里
/// 淡入旋转封面。点球 = 开播放页。
class CollapsibleMiniPlayer extends StatefulWidget {
  /// 按「内容透明度」构建播放条（收缩时内容淡出、底板保留）。
  final Widget Function(double contentOpacity) barBuilder;
  final SongEntity? song;
  final VoidCallback onTap;

  /// 球的直径（和导航胶囊同高，两者才「平行」）。
  final double ballSize;

  /// 本组件在屏幕上的 bottom 偏移（Positioned 的 bottom）。
  final double bottomOffset;

  /// 球心要落到的位置（离屏幕底的距离）；null = 原地收缩不下移。
  final double? targetCenterFromBottom;

  /// 播放条外层 padding（底板相对本组件的内缩）。
  final double insetH;
  final double padTop;
  final double padBottom;

  /// 播放条底板圆角。
  final double barRadius;

  const CollapsibleMiniPlayer({
    super.key,
    required this.barBuilder,
    required this.song,
    required this.onTap,
    required this.ballSize,
    required this.bottomOffset,
    this.targetCenterFromBottom,
    this.insetH = 16,
    this.padTop = 4,
    this.padBottom = 0,
    this.barRadius = 20,
  });

  @override
  State<CollapsibleMiniPlayer> createState() => _CollapsibleMiniPlayerState();
}

class _CollapsibleMiniPlayerState extends State<CollapsibleMiniPlayer> {
  /// 播放条实测高度（含外层 padding）。首帧没量到前用估计值。
  double _h = MiniPlayerBar.estimatedHeight;

  void _onSize(Size s) {
    if ((s.height - _h).abs() > 0.5 && mounted) setState(() => _h = s.height);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, box) {
        final full = box.maxWidth;
        return ValueListenableBuilder<double>(
          valueListenable: MiniPlayerCollapse.instance.progress,
          builder: (context, p, _) {
            // v=0 时下面算出来的外形和原条完全重合，所以始终走同一套布局，
            // 子树不换、条里封面的旋转角度不会被重置。
            final v = MiniPlayerCollapse.curved(p);
            final ball = widget.ballSize;
            final pillTop = widget.padTop;
            final pillH = (_h - widget.padTop - widget.padBottom)
                .clamp(ball, double.infinity);
            final cy = pillTop + pillH / 2;

            // 底板外形：左端从 insetH 往右收到「只剩一个球」。不是整块等高平移，
            // 而是像液体一样「梯形伸缩」——右端高度跟着收到球径，左端在动画
            // 中段明显更细（右端的 35% 左右），两头（v=0 / v=1）恢复等高，
            // 所以收的时候由粗到细缩进去、还原时从细尖长回粗条。
            final right = full - widget.insetH;
            final left = lerpDouble(widget.insetH, right - ball, v)!;
            final hRight = lerpDouble(pillH, ball, v)!;
            final taper = 1 - 0.65 * math.sin(math.pi * v);
            final hLeft = hRight * taper;
            final rRight = lerpDouble(widget.barRadius, hRight / 2, v)!
                .clamp(0.0, hRight / 2);
            final rLeft = lerpDouble(widget.barRadius, hLeft / 2, v)!
                .clamp(0.0, hLeft / 2);
            final shape = _taperedCapsule(
              left: left,
              right: right,
              cy: cy,
              hLeft: hLeft,
              hRight: hRight,
              rLeft: rLeft,
              rRight: rRight,
              circle: v >= 0.999,
            );

            // 整体下移：把条心挪到目标球心。
            double dy = 0;
            final target = widget.targetCenterFromBottom;
            if (target != null) {
              final barCenterFromBottom =
                  widget.bottomOffset + widget.padBottom + pillH / 2;
              dy = (barCenterFromBottom - target) * v;
            }

            // 「滑进去」：条左边那张圆封面不淡掉，而是一路滑到右端、边走边长成
            // 球；外框在它四周同步收窄。歌名按钮早早淡掉，封面一开始就接手。
            final contentOpacity = (1 - v / 0.35).clamp(0.0, 1.0);
            final coverOpacity = (v / 0.12).clamp(0.0, 1.0);
            const coverInset = 3.0;
            // 起点：条里封面的位置（外层 inset + 条内 padding 10，尺寸 48）。
            const barArtSize = 48.0;
            final barArtCx = widget.insetH + 10 + barArtSize / 2;
            // 终点：球里的封面。
            final endSize = ball - coverInset * 2;
            final endCx = right - ball / 2;
            final coverCx = lerpDouble(barArtCx, endCx, v)!;
            final coverSize = lerpDouble(barArtSize, endSize, v)!;

            return Transform.translate(
              offset: Offset(0, dy),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 自己画投影，形状跟着梯形走（条原本的投影会被下面的裁剪切掉）。
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _ShapeShadowPainter(
                          shape,
                          Colors.black.withValues(alpha: isDark ? 0.22 : 0.12),
                        ),
                      ),
                    ),
                  ),
                  // 条：按外形裁剪，内容淡出；过半就不再接收点击（交给球）。
                  IgnorePointer(
                    ignoring: v > 0.5,
                    child: ClipPath(
                      clipper: _PathClipper(shape),
                      child: _MeasureSize(
                        onChange: _onSize,
                        child: widget.barBuilder(contentOpacity),
                      ),
                    ),
                  ),
                  // 滑行中的封面：按终点尺寸画一次、用缩放变大小（每帧改 size
                  // 会让图片按新尺寸重新解码，滑动中会闪）。
                  if (coverOpacity > 0)
                    Positioned(
                      left: coverCx - endSize / 2,
                      top: cy - endSize / 2,
                      width: endSize,
                      height: endSize,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: coverOpacity,
                          child: Transform.scale(
                            scale: coverSize / endSize,
                            child: MiniPlayerArtwork(
                              song: widget.song,
                              size: endSize,
                              borderRadius: endSize / 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 球态的点击区：开播放页。
                  if (v > 0.5)
                    Positioned(
                      left: right - ball,
                      top: cy - ball / 2,
                      width: ball,
                      height: ball,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onTap,
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 两端粗细可以不同的胶囊（梯形 + 圆角端头）。左端高 [hLeft]、右端高
/// [hRight]，上下沿是两端之间的斜线；四个角用二次贝塞尔近似圆角。
/// [circle] 为 true 时直接返回正圆（球态终点，避免贝塞尔近似出来是方圆）。
Path _taperedCapsule({
  required double left,
  required double right,
  required double cy,
  required double hLeft,
  required double hRight,
  required double rLeft,
  required double rRight,
  bool circle = false,
}) {
  if (circle) {
    final d = right - left;
    return Path()
      ..addOval(Rect.fromCircle(center: Offset(left + d / 2, cy), radius: d / 2));
  }
  final topL = cy - hLeft / 2, botL = cy + hLeft / 2;
  final topR = cy - hRight / 2, botR = cy + hRight / 2;
  return Path()
    ..moveTo(left, cy)
    ..lineTo(left, topL + rLeft)
    ..quadraticBezierTo(left, topL, left + rLeft, topL)
    ..lineTo(right - rRight, topR)
    ..quadraticBezierTo(right, topR, right, topR + rRight)
    ..lineTo(right, botR - rRight)
    ..quadraticBezierTo(right, botR, right - rRight, botR)
    ..lineTo(left + rLeft, botL)
    ..quadraticBezierTo(left, botL, left, botL - rLeft)
    ..close();
}

class _PathClipper extends CustomClipper<Path> {
  _PathClipper(this.path);
  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_PathClipper old) => !identical(old.path, path);
}

/// 沿外形画投影（形状是梯形 / 圆，BoxShadow 只能画矩形圆角）。
class _ShapeShadowPainter extends CustomPainter {
  _ShapeShadowPainter(this.path, this.color);
  final Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawShadow(path.shift(const Offset(0, 2)), color, 6, false);
  }

  @override
  bool shouldRepaint(_ShapeShadowPainter old) =>
      !identical(old.path, path) || old.color != color;
}

/// 布局后回报自身尺寸（只在变化时回调）。
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});
  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize ro) {
    ro.onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);
  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final s = size;
    if (_last == s) return;
    _last = s;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(s));
  }
}
