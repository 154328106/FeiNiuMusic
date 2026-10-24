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

  /// 停下（松手且惯性停了）后等多久再展开回条。
  static const Duration _expandDelay = Duration(milliseconds: 1500);
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

  /// 上一条处理过的通知：滚动通知从最内层往外冒泡，嵌套的页面脚手架会依次看到
  /// 同一条，只让最内层（离滚动区最近的那一页）决定一次。
  ScrollNotification? _lastSeen;

  /// 由各页 AppPageScaffold 调用。[pageHasMini] = 这一页显示迷你条；首页、
  /// 设置页等关掉迷你条的页面滚动不收（否则导航条白让一块空位）。
  bool handle(ScrollNotification n, {required bool pageHasMini}) {
    if (identical(n, _lastSeen)) return false;
    _lastSeen = n;
    if (!pageHasMini) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.metrics.maxScrollExtent <= 0) return false;

    if (n is ScrollStartNotification) {
      // 只认手指拖出来的滚动；程序滚动（点按钮自动滚到某处）没有 dragDetails。
      _dragging = n.dragDetails != null;
      _dragAccum = 0;
      if (_dragging) _expandTimer?.cancel(); // 按下去就别回条了
    } else if (n is ScrollUpdateNotification) {
      final d = (n.scrollDelta ?? 0).abs();
      if (_dragging) {
        _dragAccum += d;
        // 累计拖过阈值才收 —— 轻点 / 手指抖一下不算。
        if (!collapsed.value && _dragAccum >= _collapseThreshold) {
          if (!_miniVisible) {
            debugPrint('[MiniCollapse] 不收：迷你条不可见 '
                'song=${PlayerService.instance.currentSong.value != null}');
          } else {
            _set(true);
          }
        }
      }
      // 已经是球：拖动 / 惯性滚动途中都别回条（含手指按住没松）。
      if (collapsed.value && d > 0) _expandTimer?.cancel();
    } else if (n is ScrollEndNotification) {
      _dragging = false;
      _dragAccum = 0;
      scheduleExpand(); // 松手且惯性停了才倒计时
    }
    return false;
  }

  /// 一次拖动累计滑过多少像素才收成球。
  static const double _collapseThreshold = 16;
  bool _dragging = false;
  double _dragAccum = 0;

  /// 停下后约半秒展开回条。
  void scheduleExpand() {
    _expandTimer?.cancel();
    if (!collapsed.value) return;
    _expandTimer = Timer(_expandDelay, () => _set(false));
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

/// 挂在 App 最外层：提供推进收球进度的 AnimationController。
/// （滚动监听在各页 AppPageScaffold 里，由页面决定要不要收。）
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
  Widget build(BuildContext context) => widget.child;
}
