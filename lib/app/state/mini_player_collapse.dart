import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../services/player_service.dart';

/// 迷你播放器「滚动时收成球、停下回条」的全局状态。
///
/// 页面一滚，迷你播放条从左往右下连续收窄成一个圆，落到底部导航条同一行的右侧，
/// 导航条同时把右边让出来；停下约半秒再展开回条。
///
/// 迷你条（在各页脚手架里）和导航条（在外壳里）不在同一棵子树，所以用一个全局
/// [progress] 驱动：两边都读它，同一帧取同一个值，伸缩完全同步。
class MiniPlayerCollapse {
  MiniPlayerCollapse._();
  static final MiniPlayerCollapse instance = MiniPlayerCollapse._();

  /// true = 目标是球态。
  final ValueNotifier<bool> collapsed = ValueNotifier(false);

  /// 线性进度 0（条）→ 1（球）。用的地方自己套曲线
  /// （[curved]），保证中途反向时也连续不跳。
  final ValueNotifier<double> progress = ValueNotifier(0);

  /// 套好曲线的进度。
  static double curved(double p) => Curves.easeInOutCubic.transform(p);

  /// 停止滚动多久后展开回条。
  static const Duration _expandDelay = Duration(milliseconds: 450);

  /// 走完一整程（0→1）的时长；中途反向按剩余距离等比缩短。
  static const int _fullMs = 340;

  Timer? _expandTimer;
  Ticker? _ticker;
  double _from = 0;
  double _to = 0;
  Duration _total = Duration.zero;

  /// 当前挂载着的可收球迷你条数量（CollapsibleMiniPlayer 自己注册/注销）。
  /// 「仅播放时显示」且暂停、页面不显示迷你条时，它根本不会被建出来 → 计数为 0。
  int _mountedMinis = 0;
  void registerMini() => _mountedMinis++;
  void unregisterMini() {
    _mountedMinis = (_mountedMinis - 1).clamp(0, 1 << 30);
    // dispose 期间树是锁的，同步改 notifier 会报 setState-when-locked，帧后再收。
    if (_mountedMinis == 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_mountedMinis == 0) reset();
      });
    }
  }

  /// 迷你条此刻真的在 —— 没歌、没挂载就不收，否则导航条会凭空让出一块空位。
  /// （别用 miniPlayerSuppressedCount：那是平板外壳的计数，手机上页面栈里
  /// 任意一页不显示迷你条它就 >0，会把收起永久拦住。）
  bool get _miniVisible =>
      _mountedMinis > 0 && PlayerService.instance.currentSong.value != null;

  /// 把一条滚动通知喂进来（挂在顶层 NotificationListener 里）。
  bool handle(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    // 内容撑不满一屏（没得滚）就别收，否则轻轻一碰也缩。
    if (n.metrics.maxScrollExtent <= 0) return false;

    final moving = (n is ScrollUpdateNotification &&
            (n.scrollDelta ?? 0).abs() > 0.5) ||
        n is ScrollStartNotification;
    if (moving) {
      if (!_miniVisible) return false;
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
    _animateTo(value ? 1 : 0);
  }

  void _animateTo(double target) {
    _ticker?.dispose();
    _ticker = null;
    _from = progress.value;
    _to = target;
    final dist = (_to - _from).abs();
    if (dist == 0) return;
    _total = Duration(milliseconds: (_fullMs * dist).round().clamp(1, _fullMs));
    _ticker = Ticker((elapsed) {
      final t = (elapsed.inMicroseconds / _total.inMicroseconds).clamp(0.0, 1.0);
      progress.value = _from + (_to - _from) * t;
      if (t >= 1) _ticker?.stop();
    })
      ..start();
  }

  /// 开播放页 / 换页等场景直接回到条态（不放动画，别让球态被带过去）。
  void reset() {
    _expandTimer?.cancel();
    _ticker?.dispose();
    _ticker = null;
    collapsed.value = false;
    progress.value = 0;
  }
}
