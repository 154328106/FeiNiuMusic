import 'dart:async';

import 'package:flutter/material.dart';

import '../services/player_service.dart';
import 'settings_state.dart';

/// 迷你播放器「滚动时收成球、停下回条」的全局状态。
///
/// 页面一滚，迷你播放条从左往右下连续收窄成一个圆，落到底部导航条同一行的右侧，
/// 导航条同时把右边让出来；停下约半秒再展开回条。
///
/// 迷你条（在各页脚手架里）和导航条（在外壳里）不在同一棵子树，所以用一个全局
/// [progress] 驱动：两边都读它，同一帧取同一个值，伸缩完全同步。进度由
/// [MiniPlayerCollapseHost]（挂在 App 最外层）里的 AnimationController 推进。
class MiniPlayerCollapse {
  MiniPlayerCollapse._();
  static final MiniPlayerCollapse instance = MiniPlayerCollapse._();

  /// true = 目标是球态。
  final ValueNotifier<bool> collapsed = ValueNotifier(false);

  /// 线性进度 0（条）→ 1（球）。用的地方自己套曲线（[curved]），中途反向也连续。
  final ValueNotifier<double> progress = ValueNotifier(0);

  static double curved(double p) => Curves.easeInOutCubic.transform(p);

  static const Duration _expandDelay = Duration(milliseconds: 450);
  static const int _fullMs = 340;

  Timer? _expandTimer;
  AnimationController? _controller;

  void _attach(AnimationController c) {
    _controller = c;
    c.addListener(_onTick);
  }

  void _detach(AnimationController c) {
    c.removeListener(_onTick);
    if (identical(_controller, c)) _controller = null;
  }

  void _onTick() {
    final c = _controller;
    if (c != null) progress.value = c.value;
  }

  /// 有歌在放（且没被「仅播放时显示」藏掉）才收，否则导航条会凭空让出空位。
  bool get _miniVisible {
    if (PlayerService.instance.currentSong.value == null) return false;
    if (AppBackgroundSettings.miniPlayerOnlyWhilePlaying.value &&
        !PlayerService.instance.isPlaying.value) {
      return false;
    }
    return true;
  }

  bool handle(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.metrics.maxScrollExtent <= 0) return false;

    final moving = (n is ScrollUpdateNotification &&
            (n.scrollDelta ?? 0).abs() > 0.5) ||
        n is ScrollStartNotification;
    if (moving) {
      if (!_miniVisible) {
        if (n is ScrollStartNotification) {
          debugPrint('[MiniCollapse] 不收：迷你条不可见 '
              'song=${PlayerService.instance.currentSong.value != null}');
        }
        return false;
      }
      _set(true);
      _expandTimer?.cancel();
      _expandTimer = Timer(_expandDelay, () => _set(false));
    } else if (n is ScrollEndNotification) {
      _expandTimer?.cancel();
      _expandTimer = Timer(_expandDelay, () => _set(false));
    }
    return false;
  }

  void _set(bool value) {
    if (collapsed.value == value) return;
    collapsed.value = value;
    final c = _controller;
    debugPrint('[MiniCollapse] ${value ? "收成球" : "展开回条"} '
        'controller=${c != null} from=${progress.value.toStringAsFixed(2)}');
    if (c == null) {
      progress.value = value ? 1 : 0; // 兜底：没有宿主就直接跳到终态。
      return;
    }
    final target = value ? 1.0 : 0.0;
    final dist = (target - c.value).abs();
    c.animateTo(
      target,
      duration: Duration(milliseconds: (_fullMs * dist).round().clamp(1, _fullMs)),
      curve: Curves.linear,
    );
  }

  /// 开播放页 / 换页等场景直接回到条态（不放动画）。
  void reset() {
    _expandTimer?.cancel();
    collapsed.value = false;
    _controller?.value = 0;
    progress.value = 0;
  }
}

/// 挂在 App 最外层：提供推进收球进度的 AnimationController，并监听所有页面的
/// 滚动通知（各页滚动都会冒泡到这里）。
class MiniPlayerCollapseHost extends StatefulWidget {
  const MiniPlayerCollapseHost({super.key, required this.child});
  final Widget child;

  @override
  State<MiniPlayerCollapseHost> createState() => _MiniPlayerCollapseHostState();
}

class _MiniPlayerCollapseHostState extends State<MiniPlayerCollapseHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    MiniPlayerCollapse.instance._attach(_c);
  }

  @override
  void dispose() {
    MiniPlayerCollapse.instance._detach(_c);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: MiniPlayerCollapse.instance.handle,
      child: widget.child,
    );
  }
}
