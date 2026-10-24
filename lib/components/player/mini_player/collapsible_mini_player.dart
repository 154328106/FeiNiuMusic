import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../app/state/mini_player_collapse.dart';
import '../../../app/state/song_state.dart';
import 'mini_player_bar.dart';

/// 把迷你播放条包成「可随滚动收成球」的样子。
///
/// 展开态 = 原来的播放条 [bar]；收起态 = 右端一个旋转圆封面小球。两态之间按
/// [MiniPlayerCollapse.collapsed] 丝滑伸缩：条靠右裁剪 + 淡出，球淡入。点球和点
/// 条一样开播放页。
class CollapsibleMiniPlayer extends StatefulWidget {
  final Widget bar;
  final SongEntity? song;
  final VoidCallback onTap;
  final double ballSize;

  const CollapsibleMiniPlayer({
    super.key,
    required this.bar,
    required this.song,
    required this.onTap,
    this.ballSize = 52,
  });

  @override
  State<CollapsibleMiniPlayer> createState() => _CollapsibleMiniPlayerState();
}

class _CollapsibleMiniPlayerState extends State<CollapsibleMiniPlayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: MiniPlayerCollapse.instance.collapsed.value ? 1 : 0,
  );
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Curves.easeInOutCubic);

  @override
  void initState() {
    super.initState();
    MiniPlayerCollapse.instance.collapsed.addListener(_sync);
  }

  @override
  void dispose() {
    MiniPlayerCollapse.instance.collapsed.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    if (MiniPlayerCollapse.instance.collapsed.value) {
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final full = box.maxWidth;
        final ball = widget.ballSize;
        return AnimatedBuilder(
          animation: _t,
          builder: (context, _) {
            final v = _t.value; // 0 条 .. 1 球
            if (v == 0) return widget.bar; // 完全展开，直接用原条，零开销。
            final w = lerpDouble(full, ball, v)!;
            return Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: w,
                child: ClipRect(
                  child: Stack(
                    alignment: Alignment.centerRight,
                    children: [
                      // 条：保持完整布局（OverflowBox 给足宽度），靠右裁剪 + 淡出。
                      if (v < 0.98)
                        Opacity(
                          opacity: (1 - v * 1.6).clamp(0.0, 1.0),
                          child: IgnorePointer(
                            ignoring: v > 0.5,
                            child: OverflowBox(
                              minWidth: full,
                              maxWidth: full,
                              alignment: Alignment.centerRight,
                              child: widget.bar,
                            ),
                          ),
                        ),
                      // 球：旋转圆封面，淡入，点一下开播放页。
                      if (v > 0.1)
                        Opacity(
                          opacity: ((v - 0.35) / 0.65).clamp(0.0, 1.0),
                          child: GestureDetector(
                            onTap: widget.onTap,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: MiniPlayerArtwork(
                                song: widget.song,
                                size: ball,
                                borderRadius: ball / 2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
