import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/navigator_key.dart';

enum ToastType { info, success, error }

class AppToast {
  static OverlayEntry? _currentEntry;
  static Timer? _timer;

  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    _insert(
      _resolveOverlay(context),
      message,
      type: type,
      duration: duration,
    );
  }

  /// 找一个能用的 overlay。
  ///
  /// 不能只靠 `Overlay.of(context)`：全局提示传的是根 Navigator **自己的**
  /// context，而 Navigator 的 Overlay 是它的**子节点** —— 往上找找不到，
  /// 而 `Overlay.of` 内部是 `maybeOf(...)!`，于是抛「Null check operator used
  /// on a null value」。13 处全局提示因此一直是哑的。
  ///
  /// `NavigatorState.overlay` 直接给出 Navigator 自己那个 overlay，正是要的。
  static OverlayState? _resolveOverlay(BuildContext? context) {
    if (context != null) {
      final fromContext = Overlay.maybeOf(context, rootOverlay: true);
      if (fromContext != null) return fromContext;
    }
    return appNavigatorKey.currentState?.overlay;
  }

  static void _insert(
    OverlayState? overlay,
    String message, {
    required ToastType type,
    required Duration duration,
  }) {
    if (overlay == null || !overlay.mounted) return;
    _removeCurrent();

    final entry = OverlayEntry(
      builder: (context) => _ToastWidget(
        message: message,
        type: type,
        duration: duration,
        onDismiss: _removeCurrent,
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);

    _timer = Timer(duration + const Duration(milliseconds: 300), () {
      _removeCurrent();
    });
  }

  /// 无 BuildContext 时用的全局 toast：通过根 Navigator 的 context 弹。
  /// 根 Navigator 尚未就绪时静默丢弃（不崩溃）。
  static void showGlobal(
    String message, {
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    // 提示弹不出来是小事，绝不能把调用方掐断（酷狗扫码登录成功后不返回，
    // 查到最后就是这句抛异常把后面的 Navigator.pop 带走了）。
    try {
      _insert(
        _resolveOverlay(null),
        message,
        type: type,
        duration: duration,
      );
    } catch (e) {
      debugPrint('[AppToast] 弹提示失败（不影响主流程）：$e');
    }
  }

  static void _removeCurrent() {
    _timer?.cancel();
    _timer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final Duration duration;
  final VoidCallback onDismiss;

  const _ToastWidget({
    required this.message,
    required this.type,
    required this.duration,
    required this.onDismiss,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _offset;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 200),
    );

    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _controller.forward();

    _hideTimer = Timer(widget.duration, () {
      if (mounted) {
        _controller.reverse().then((_) => widget.onDismiss());
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _hideTimer?.cancel();
    super.dispose();
  }

  Color _getIconColor(bool isDark) {
    switch (widget.type) {
      case ToastType.success:
        return const Color(0xFF4CAF50);
      case ToastType.error:
        return const Color(0xFFE53935);
      case ToastType.info:
        return const Color(0xFF2196F3);
    }
  }

  IconData _getIcon() {
    switch (widget.type) {
      case ToastType.success:
        return Icons.check_circle;
      case ToastType.error:
        return Icons.error;
      case ToastType.info:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDark ? const Color(0xFF32363C) : Colors.white;
    final textColor = isDark ? Colors.white.withAlpha(230) : Colors.black87;
    final shadowColor =
        Colors.black.withAlpha(((isDark ? 0.3 : 0.1) * 255).round());

    final safeBottom = MediaQuery.of(context).padding.bottom;
    final bottomOffset = safeBottom + 24;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      bottom: bottomOffset,
      left: 24,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SlideTransition(
            position: _offset,
            child: FadeTransition(
              opacity: _opacity,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: shadowColor,
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _getIcon(),
                      size: 20,
                      color: _getIconColor(isDark),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.none,
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
