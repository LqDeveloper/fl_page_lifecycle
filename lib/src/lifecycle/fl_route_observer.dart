import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

import 'fl_lifecycle_guard.dart';
import 'lifecycle_route_aware.dart';

/// 把 `Navigator` 的路由变化翻译成页面的 start / resume / pause / stop。
///
/// **必须注册到 `Navigator` 上**，否则本库的路由生命周期事件全部收不到，
/// 且不会有任何报错（debug 下会 `debugPrint` 提示一次）：
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [FlRouteObserver.instance],
///   // ...
/// )
/// ```
///
/// 嵌套 `Navigator` 需要各自注册一次，同一个 [instance] 可以复用。
/// 转场动画回调（`onPageEnterAnimationEnd` 等）不受影响，它们直接监听
/// `ModalRoute.animation`。
///
/// 语义上的两个要点：
///
/// - **弹窗只 pause 不 stop**：上层 push 的是 `PopupRoute`（dialog /
///   bottomSheet / PopupMenu）时，下方页面依然可见，因此只发 pause；关闭弹窗
///   只发 resume。上层是普通路由才走 stop / start。
/// - **只通知真正露出来的页面**：`pushAndRemoveUntil` / `popUntil` 的
///   `previousRoute` 常常仍被别的路由盖着，这类情况不会发出虚假的 start。
class FlRouteObserver extends NavigatorObserver {
  /// 全局唯一实例，注册到 `navigatorObservers` 时用它。
  static final FlRouteObserver instance = FlRouteObserver._();

  /// 返回 [instance]，`FlRouteObserver()` 与 `FlRouteObserver.instance`
  /// 拿到的是同一个对象。
  factory FlRouteObserver() => instance;

  FlRouteObserver._();

  final Map<Route<dynamic>, Set<LifecycleRouteAware>> _listeners =
      <Route<dynamic>, Set<LifecycleRouteAware>>{};

  /// 让 [routeAware] 开始接收 [route] 上的路由事件。
  ///
  /// 由 `FlPageRouteDelegate` 在页面首次 `didChangeDependencies` 时调用；
  /// 同一个路由可以有多个订阅者（一个页面里放了多个 `FlPageLifecycleView` 时）。
  /// 必须与 [unsubscribe] 配对，否则本表会一直持有对 `State` 的强引用。
  @internal
  void subscribe(ModalRoute route, LifecycleRouteAware routeAware) {
    final subscribers = _listeners.putIfAbsent(
      route,
      () => <LifecycleRouteAware>{},
    );
    subscribers.add(routeAware);
  }

  /// 取消 [routeAware] 在 [route] 上的订阅。
  ///
  /// 订阅方自己知道挂在哪个路由上（`FlPageRouteDelegate._modalRoute`），
  /// 因此这里按 key 直接删，不遍历整张表——页面销毁是高频操作，而一个页面里
  /// 可能同时存在多个订阅者（如多个 `FlPageLifecycleView`），它们会在同一帧集中销毁。
  ///
  /// [route] 已经被 pop / remove 时表内早已没有对应条目，此时是空操作。
  @internal
  void unsubscribe(ModalRoute route, LifecycleRouteAware routeAware) {
    final subscribers = _listeners[route];
    if (subscribers == null) {
      return;
    }
    subscribers.remove(routeAware);
    if (subscribers.isEmpty) {
      _listeners.remove(route);
    }
  }

  /// [route] 离开了栈：通知它自己的订阅者 stop，并在 [previousRoute] 真的因此
  /// 露出来时通知那一层。
  ///
  /// `didPop` / `didRemove` / `didReplace` 三处共用同一段逻辑。**必须合并**：
  /// 这三处原本是互相复制的，`didRemove` 曾经漏掉了下面的弹窗分支，导致
  /// `removeRoute` 移除弹窗后下方页面永久停在 paused——同一个分支不该有三份
  /// 各自演化的拷贝。
  ///
  /// [isPopup] 为 true（被移除的是 `PopupRoute`）时，下方页面只发 resume 不发
  /// start：它被弹窗盖住时只收到过 pause、从未 stop，宿主的 `_hasAppeared` 仍是
  /// true，此刻发 start 会被幂等判断整条吃掉，页面就再也收不到 resume。
  void _handleRouteGone(
    Route<dynamic> route,
    Route<dynamic>? previousRoute, {
    required bool isPopup,
  }) {
    // remove route atomically: 通知后不再持有已离栈的 route
    final subscribers = _listeners.remove(route)?.toList();
    if (subscribers != null) {
      for (final routeAware in subscribers) {
        // 逐个 guard：同一个路由上可能挂着多个订阅者（页面里放了多个
        // `FlPageLifecycleView`），其中一个抛异常不该让后面的收不到事件。
        FlLifecycleGuard.run(routeAware.routePageStop);
      }
    }

    // previousRoute 只是「被移除者在栈中的下一个」，不等于新的栈顶：
    // popUntil 连续 pop 时中间那些转瞬又被 pop，pushAndRemoveUntil 逐个 remove
    // 时 previousRoute 仍被新路由盖着。见 [_didBecomeVisible]。
    if (!_didBecomeVisible(previousRoute)) {
      return;
    }
    final previousSubscribers = _listeners[previousRoute]?.toList();
    if (previousSubscribers != null) {
      for (final routeAware in previousSubscribers) {
        // 同上，且这里还跨页面：上层页面的回调抛异常不该让下层页面收不到
        // start / resume——那会让它永久停在 stopped，且没有任何补发路径。
        FlLifecycleGuard.run(
          isPopup ? routeAware.routePageResume : routeAware.routePageStart,
        );
      }
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _handleRouteGone(route, previousRoute, isPopup: route is PopupRoute);
  }

  /// [route] 是不是**真的**因为上面那个消失而露了出来。
  ///
  /// `didPop` / `didRemove` 的 `previousRoute` 只是「被移除者在栈中的下一个」，
  /// 并不等于「新的栈顶」。两种常见情况下它仍被别的路由盖着：
  ///
  /// - `pushAndRemoveUntil`：新路由先 push 到顶，再逐个 remove 下面的旧路由，
  ///   每次 remove 的 previousRoute 都还在新路由底下；
  /// - `popUntil`：连续 pop 多个，中间几个的 previousRoute 转瞬又被 pop 掉。
  ///
  /// 不加这个判断，被盖住的页面会收到虚假的 start / resume，而且不会有配对的
  /// stop 来纠正——曝光埋点会把一个从没露面的页面记成可见。
  ///
  /// 用 `Route.isCurrent` 判定是安全的：`Navigator` 在 `_flushHistoryUpdates`
  /// 把整个历史整理完之后才 `_flushObserverNotifications`，此刻被 pop / remove
  /// 的条目已经进入 `popping` / `removing`，不再算 present，所以正常 pop 时
  /// 下面那个就是最后一个 present 项，判定为 true，不会被误伤。
  static bool _didBecomeVisible(Route<dynamic>? previousRoute) =>
      previousRoute?.isCurrent ?? false;

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    _handleRouteGone(route, previousRoute, isPopup: route is PopupRoute);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    final previousSubscribers = _listeners[previousRoute]?.toList();
    final isPopup = route is PopupRoute;
    if (previousSubscribers != null) {
      for (final routeAware in previousSubscribers) {
        FlLifecycleGuard.run(
          isPopup ? routeAware.routePagePause : routeAware.routePageStop,
        );
      }
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute == null) {
      return;
    }
    // pushReplacement: 旧路由立即从 _listeners 中移除并收到 stop。
    // 传 `previousRoute: null` 表示「没有任何页面因此露出来」——被替换掉的是
    // 栈顶，它下面那层仍然被新路由盖着，不该收到 start / resume；新路由自己的
    // start 由它的首帧回调发出。null 也让 isPopup 参数在这里不起作用。
    _handleRouteGone(oldRoute, null, isPopup: false);
  }
}
