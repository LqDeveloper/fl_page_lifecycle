import 'package:flutter/material.dart';

import 'fl_route_observer.dart';

/// 嵌套 `Navigator` 用的转发 observer：把路由事件原样交给
/// [FlRouteObserver.instance] 处理。
///
/// ## 为什么需要它
///
/// [FlRouteObserver] 是单例，而 Flutter 的 `Navigator.initState` 里有
/// `assert(observer.navigator == null)`——一个 `NavigatorObserver` 实例
/// **同一时刻只能绑定一个 `NavigatorState`**。把同一个 [FlRouteObserver] 同时挂到
/// 根 `Navigator` 和嵌套 `Navigator` 上，第二个挂载时 debug 下直接断言失败。
///
/// 本类每次构造都是新实例，因此能各自绑定一个 `Navigator`；四个路由事件转发给
/// [FlRouteObserver.instance]，订阅表全局仍然只有一份。页面侧无需任何改动——
/// `FlPageLifecycleMixin` 本来就是往那一份表里登记的，不关心事件从哪个
/// `Navigator` 来。
///
/// ## 用法
///
/// **根 `Navigator` 用 [FlRouteObserver]，其余每个嵌套 `Navigator` 各用一个新的
/// [FlRouteObserverProxy]**：
///
/// ```dart
/// // 根
/// MaterialApp(navigatorObservers: [FlRouteObserver()], home: ...);
///
/// // go_router 的 ShellRoute
/// ShellRoute(observers: [FlRouteObserverProxy()], builder: ...);
///
/// // StatefulShellRoute：每个分支各一个
/// StatefulShellBranch(observers: [FlRouteObserverProxy()], routes: [...]);
///
/// // auto_route：navigatorObservers 是 builder，每次都要返回新实例
/// appRouter.config(navigatorObservers: () => [FlRouteObserverProxy()]);
///
/// // 手写的 tab 内独立栈
/// Navigator(key: tabKey, observers: [FlRouteObserverProxy()], ...);
/// ```
///
/// 每个实例同样**只能挂一个 `Navigator`**：两个 `Navigator` 复用同一个 proxy
/// 会触发和上面一样的断言，该 new 就 new。反过来，proxy 是无状态的，创建成本
/// 只有一次对象分配，写在 `build` 里也无妨。
///
/// ## 维护约定
///
/// 本类逐个转发 [FlRouteObserver] **实际覆写过**的那四个方法
/// （`didPush` / `didPop` / `didRemove` / `didReplace`）。给 [FlRouteObserver]
/// 新增 `NavigatorObserver` 覆写时**这里必须同步加一条**，否则嵌套 `Navigator`
/// 会静默少一种事件、且没有任何报错。`test/nested_navigator_test.dart`
/// 对这四个方法逐个对拍，漏了会红。
class FlRouteObserverProxy extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FlRouteObserver.instance.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FlRouteObserver.instance.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FlRouteObserver.instance.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    FlRouteObserver.instance.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}
