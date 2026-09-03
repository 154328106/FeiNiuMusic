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
    _removeCurrent();

    final overlay = Overlay.of(context, rootOverlay: true);

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
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    // 提示弹不出来是小事，绝不能把调用方掐断。
    //
    // `show` 里的 `Overlay.of(context, rootOverlay: true)` 找不到 overlay 时
    // 会抛 —— 而这里拿的是根 Navigator 自己的 context，overlay 在它**下面**
    // 不在上面。酷狗扫码登录成功后不自动返回，查到最后就是这个：toast 抛异常，
    // 后面那句 Navigator.pop 根本没机会执行，而调用方是 Timer 里没人 await 的
    // async 函数，异常被静默吞掉，表现成「什么都没发生」。
    try {
      show(context, message, type: type, duration: duration);
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
