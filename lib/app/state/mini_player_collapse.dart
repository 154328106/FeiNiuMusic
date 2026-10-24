import 'dart:async';

import 'package:flutter/widgets.dart';

/// 迷你播放器「滚动时收成球、停下回条」的全局状态。
///
/// 页面一滚就把迷你播放条收成一个小球（让出内容、不挡页面），停下约半秒再
/// 展开回条。逻辑放全局单例：滚动监听挂在最外层一处，迷你播放器在各处（手机
/// 外壳 / 平板外壳 / 独立页脚手架）只读这个状态做变形，不用各自接滚动。
class MiniPlayerCollapse {
  MiniPlayerCollapse._();
  static final MiniPlayerCollapse instance = MiniPlayerCollapse._();

  /// true = 已收成球。
  final ValueNotifier<bool> collapsed = ValueNotifier(false);

  /// 停止滚动多久后展开回条。
  static const Duration _expandDelay = Duration(milliseconds: 450);

  Timer? _expandTimer;

  /// 把一条滚动通知喂进来（挂在顶层 NotificationListener 里）。
  /// 只认竖向、有实际位移的用户滚动；停下 [_expandDelay] 后自动展开。
  bool handle(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    // 内容本来就撑不满一屏（没得滚）就别收，否则轻轻一碰也缩。
    if (n.metrics.maxScrollExtent <= 0) return false;

    final moving = (n is ScrollUpdateNotification &&
            (n.scrollDelta ?? 0).abs() > 0.5) ||
        n is ScrollStartNotification;
    if (moving) {
      if (!collapsed.value) collapsed.value = true;
      _expandTimer?.cancel();
      _expandTimer = Timer(_expandDelay, _expand);
    } else if (n is ScrollEndNotification) {
      _expandTimer?.cancel();
      _expandTimer = Timer(_expandDelay, _expand);
    }
    return false;
  }

  void _expand() {
    if (collapsed.value) collapsed.value = false;
  }

  /// 换页 / 进播放页等场景可手动展开，别让球态跟着带过去。
  void reset() {
    _expandTimer?.cancel();
    if (collapsed.value) collapsed.value = false;
  }
}
