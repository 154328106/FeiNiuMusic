import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../app/state/mini_player_collapse.dart';
import '../../../app/state/song_state.dart';
import '../../layout/modern_navigation_bar.dart' show primaryNavigationIndex;
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

  /// 底部导航胶囊的几何信息。给了就启用「一上一下」：整个变形画在更高一层
  /// （盖过导航）；收起时直接盖在导航前面，展开时把导航胶囊那一块抠掉，看起来
  /// 像从导航下面钻出来。null（平板/无底栏）= 照旧画在页面里。
  final MiniNavGeometry? nav;

  /// 本页在底部外壳里的标签序号（0 首页 / 1 歌曲 / 2 搜索 / 3 我的）。外壳里几个
  /// 标签页同时挂着、各有一条播放条，画到高层后只能让当前标签那条显示。
  /// null = 不在外壳里（独立页面），总是显示。
  final int? shellTabIndex;

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
    this.nav,
    this.shellTabIndex,
  });

  @override
  State<CollapsibleMiniPlayer> createState() => _CollapsibleMiniPlayerState();
}

class _CollapsibleMiniPlayerState extends State<CollapsibleMiniPlayer> {
  /// 播放条实测高度（含外层 padding）。首帧没量到前用估计值。
  double _h = MiniPlayerBar.estimatedHeight;

  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  void _onSize(Size s) {
    if ((s.height - _h).abs() > 0.5 && mounted) setState(() => _h = s.height);
  }

  /// 高层显示与否跟「是不是当前标签页」走。show/hide 不能在 build 里同步调。
  void _syncPortal(bool active) {
    if (active == _portal.isShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || active == _portal.isShowing) return;
      active ? _portal.show() : _portal.hide();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final full = box.maxWidth;
        final nav = widget.nav;
        if (nav == null) {
          // 平板 / 无底栏：照旧画在页面里。
          return ValueListenableBuilder<double>(
            valueListenable: MiniPlayerCollapse.instance.progress,
            builder: (context, p, _) => _morph(context, full, p, null),
          );
        }
        // 有底栏：整个变形画到高层（盖过导航），页面里只留一个同尺寸的占位锚点，
        // 高层那份用 CompositedTransformFollower 贴到锚点上。
        return ValueListenableBuilder<int>(
          valueListenable: primaryNavigationIndex,
          builder: (context, tab, _) {
            final tabIndex = widget.shellTabIndex;
            _syncPortal(tabIndex == null || tabIndex == tab);
            return OverlayPortal(
              controller: _portal,
              overlayChildBuilder: (context) => Align(
                alignment: Alignment.topLeft,
                child: CompositedTransformFollower(
                  link: _link,
                  showWhenUnlinked: false,
                  // 高度不给死：条按自然高度布局，_MeasureSize 才量得准。
                  child: SizedBox(
                    width: full,
                    child: ValueListenableBuilder<double>(
                      valueListenable: MiniPlayerCollapse.instance.progress,
                      builder: (context, p, _) => _morph(context, full, p, nav),
                    ),
                  ),
                ),
              ),
              child: CompositedTransformTarget(
                link: _link,
                child: SizedBox(width: full, height: _h),
              ),
            );
          },
        );
      },
    );
  }

  Widget _morph(
    BuildContext context,
    double full,
    double p,
    MiniNavGeometry? nav,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // v=0 时下面算出来的外形和原条完全重合，所以始终走同一套布局，
    // 子树不换、条里封面的旋转角度不会被重置。
    final v = MiniPlayerCollapse.curved(p);
    final ball = widget.ballSize;
    final pillTop = widget.padTop;
    final pillH = (_h - widget.padTop - widget.padBottom).clamp(
      ball,
      double.infinity,
    );
    final cy = pillTop + pillH / 2;

    // 底板外形：左端从 insetH 往右收到「只剩一个球」。不是整块等高平移，
    // 而是像液体一样「梯形伸缩」：左端保持主高度，往右那头在动画中段
    // 收细（见下方 taper），两头（v=0 / v=1）恢复等高。
    final right = full - widget.insetH;
    // 橡皮筋：右端（落点那头）跟着 v 走，左端按 v^1.5 滞后跟上 ——
    // 收的时候条先被拉长再缩进球；还原时细尖先伸出去、整条再跟上。
    final leftV = math.pow(v, 1.5).toDouble();
    final left = lerpDouble(widget.insetH, right - ball, leftV)!;
    // 左大右小：左端保持主高度（随 v 从条高过渡到球径），往右走的那头
    // 在中段收细（约为左端的 60%；45% 太尖），两头（v=0 / v=1）等高 ——
    // 收完正好合成一个圆球。（反过来「左细右粗」不对，原版是左边原大小、往右变小。）
    final hLeft = lerpDouble(pillH, ball, v)!;
    final taper = 1 - 0.4 * math.sin(math.pi * v);
    final hRight = hLeft * taper;
    final rRight = lerpDouble(
      widget.barRadius,
      hRight / 2,
      v,
    )!.clamp(0.0, hRight / 2);
    final rLeft = lerpDouble(
      widget.barRadius,
      hLeft / 2,
      v,
    )!.clamp(0.0, hLeft / 2);
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

    Widget morph = Transform.translate(
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

    // 一上一下：收起（目标是球）时整块盖在导航前面；展开（目标是条）
    // 时把导航胶囊当前占的那块抠掉，看起来像从导航下面钻出来。
    // 抠的是屏幕上导航的固定位置，所以放在 Transform.translate 外面。
    if (nav != null && v > 0 && !MiniPlayerCollapse.instance.collapsed.value) {
      final hole = nav.pillRect(
        full: full,
        boxHeight: _h,
        bottomOffset: widget.bottomOffset,
        progress: v,
      );
      morph = ClipPath(clipper: _HoleClipper(hole), child: morph);
    }
    return morph;
  }
}

/// 底部导航胶囊的几何信息（用来算「展开时要抠掉的那块」）。
class MiniNavGeometry {
  const MiniNavGeometry({
    required this.pillHeight,
    required this.bottomGap,
    required this.bottomInset,
    required this.shrink,
    this.insetH = 16,
    this.radius = 20,
  });

  /// 胶囊高度。
  final double pillHeight;

  /// 胶囊底到 SafeArea 底的间隙（玻璃 14 / 实色 12）。
  final double bottomGap;

  /// 屏幕底部安全区高度。
  final double bottomInset;

  /// 收成球时胶囊右侧让出的宽度（球径 + 间隙），随进度线性变化。
  final double shrink;

  final double insetH;
  final double radius;

  /// 胶囊在「迷你条自身坐标系」里的圆角矩形。[boxHeight] 是迷你条盒子高，
  /// [bottomOffset] 是迷你条盒子离屏幕底的距离 —— 二者换算出屏幕底在本地
  /// 坐标里的 y。
  RRect pillRect({
    required double full,
    required double boxHeight,
    required double bottomOffset,
    required double progress,
  }) {
    final screenBottomY = boxHeight + bottomOffset;
    final bottom = screenBottomY - bottomInset - bottomGap;
    final top = bottom - pillHeight;
    final right = full - insetH - shrink * progress;
    return RRect.fromLTRBR(insetH, top, right, bottom, Radius.circular(radius));
  }
}

/// 抠掉一个圆角矩形洞，其余照常显示（范围给足，变形下移超出盒子也不受影响）。
class _HoleClipper extends CustomClipper<Path> {
  _HoleClipper(this.hole);
  final RRect hole;

  @override
  Path getClip(Size size) {
    final all = Path()
      ..addRect(
        Rect.fromLTRB(-2000, -2000, size.width + 2000, size.height + 2000),
      );
    return Path.combine(PathOperation.difference, all, Path()..addRRect(hole));
  }

  @override
  bool shouldReclip(_HoleClipper old) => old.hole != hole;
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
    return Path()..addOval(
      Rect.fromCircle(center: Offset(left + d / 2, cy), radius: d / 2),
    );
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
