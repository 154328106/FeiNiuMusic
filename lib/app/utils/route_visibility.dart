import 'package:flutter/material.dart';

/// 全局路由观察者：跟踪当前可见的路由。
///
/// 供路由底层的持续动画（流光背景、封面旋转等）感知自身是否被新路由覆盖，
/// 被覆盖时暂停动画以释放 GPU 帧预算，避免页面切换转场期间掉帧。
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 让动画控制器在路由被覆盖时自动暂停、重新可见时恢复。
///
/// 用法：让持有常驻动画的 State 同时 `with SingleTickerProviderStateMixin,
/// AppRouteVisibilityMixin`，并覆写 [resumeVisibilityAnimation] 定义恢复行为
/// （默认 `controller.repeat()`）。当页面被 push 到其上（didPushNext）时暂停，
/// 回到当前页（didPopNext）时恢复。页面本身可见时动画不受影响。
mixin AppRouteVisibilityMixin<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T>
    implements RouteAware {
  /// 需要随可见性暂停/恢复的动画控制器。
  AnimationController get visibilityController;

  /// 页面重新成为当前路由时如何恢复动画。默认重新 repeat；
  /// 需要条件恢复（如仅播放中旋转封面）时覆写此方法。
  void resumeVisibilityAnimation() {
    visibilityController.repeat();
  }

  @override
  void didPush() {}

  @override
  void didPop() {}

  @override
  void didPushNext() {
    // 被其它路由覆盖：暂停动画，停止消耗 GPU 帧预算。
    visibilityController.stop();
  }

  @override
  void didPopNext() {
    // 重新回到当前页：恢复动画。
    if (mounted) resumeVisibilityAnimation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeToRoute();
  }

  /// 在 didChangeDependencies 里缓存路由引用（dispose 阶段不能再查祖先）。
  ModalRoute<void>? _subscribedRoute;

  void _subscribeToRoute() {
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _subscribedRoute)) return;
    if (_subscribedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    _subscribedRoute = route;
    appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    final route = _subscribedRoute;
    if (route != null) {
      appRouteObserver.unsubscribe(this);
      _subscribedRoute = null;
    }
    super.dispose();
  }
}

/// 记录当前还活着的路由，用来判断某个页面是不是已经在栈里了。
///
/// 侧边导航模式下，主导航目标是**压栈**打开的（这样返回键能回到来源页）。
/// 原来的防重复只看当前路由，不看整个栈：首页 →「我的」→ 再点首页，就会
/// 变成 `/`(首页) + `/profile` + `/home`(第二个首页)。栈里下面那层**不会被
/// 卸载**，State 还挂着、定时刷新照跑 —— 每次刷新、每次取数据都是两遍。
///
/// 按 Route 对象记而不是按名字：didRemove / didReplace 在有同名路由时靠
/// 名字对不准。
class LiveRouteTracker extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];

  /// 栈里是否已经有这个名字的页面。
  bool contains(String name) =>
      _routes.any((r) => r.settings.name == name);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
  }
}

final LiveRouteTracker liveRoutes = LiveRouteTracker();

/// 压栈打开一个页面；它要是已经在栈里了，就回到它，不再压一份。
///
/// 侧边导航模式下所有主导航目标都是压栈打开的，而同名页面压两次不会让下面
/// 那份卸载 —— 两个 State 一起活着、各自的定时刷新都在跑，请求量直接翻倍。
void pushOrReturnTo(NavigatorState navigator, String routeName) {
  if (liveRoutes.contains(routeName)) {
    navigator.popUntil((route) => route.settings.name == routeName);
    return;
  }
  navigator.pushNamed(routeName);
}
