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

  /// 强调型缓动：起步干脆、收尾很慢地「滑」进位，比普通 easeInOut 更像滑进去。
  static double curved(double p) =>
      Curves.easeInOutCubicEmphasized.transform(p);

  /// 停下（松手且惯性停了）后等多久再展开回条。
  static const Duration _expandDelay = Duration(milliseconds: 450);
  static const int _fullMs = 420;

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
      // 新一次手指拖动：清零累计。程序滚动 / 惯性没有 dragDetails，不清。
      if (n.dragDetails != null) {
        _downAccum = 0;
        _upAccum = 0;
        _expandTimer?.cancel(); // 按下去就别回条了
      }
    } else if (n is ScrollUpdateNotification) {
      // scrollDelta > 0：内容往上走 = 往下浏览；< 0：往回（往上）滑。
      final delta = n.scrollDelta ?? 0;
      if (delta > 0 && n.dragDetails != null) {
        // 往下浏览（只认手指拖的帧）：累计过阈值收成球。轻点 / 抖动不算。
        _upAccum = 0;
        _downAccum += delta;
        if (!collapsed.value && _downAccum >= _threshold) {
          if (!_miniVisible) {
            debugPrint('[MiniCollapse] 不收：迷你条不可见 '
                'song=${PlayerService.instance.currentSong.value != null}');
          } else {
            _set(true);
          }
        }
      } else if (delta < 0) {
        // 往回滑（拖或惯性都算）：累计过阈值立刻展开，不用等停下。
        _downAccum = 0;
        _upAccum += -delta;
        if (collapsed.value && _upAccum >= _threshold) {
          _expandTimer?.cancel();
          _set(false);
        }
      }
      // 已经是球：往下拖 / 惯性途中都别回条（含手指按住没松）。
      if (collapsed.value && delta != 0) _expandTimer?.cancel();
    } else if (n is ScrollEndNotification) {
      _downAccum = 0;
      _upAccum = 0;
      scheduleExpand(); // 松手且惯性停了才倒计时
    }
    return false;
  }

  /// 往下 / 往回累计滑过多少像素才触发收起 / 展开。
  static const double _threshold = 16;
  double _downAccum = 0;
  double _upAccum = 0;

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
