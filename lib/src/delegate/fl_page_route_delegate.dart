import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

import '../lifecycle/fl_route_observer.dart';
import '../lifecycle/lifecycle_route_aware.dart';
import 'fl_route_animation_binding.dart';

/// `FlPageLifecycleMixin` 的路由处理委托——把「页面与 `ModalRoute` 之间的关系」
/// 从生命周期状态机中独立出来。
///
/// 负责三件事，且**只**负责这三件事：
///
/// 1. 取到页面所在的 [ModalRoute]，并暴露 [routeName] / [arguments]；
/// 2. 向 [FlRouteObserver] 订阅 / 取消订阅，把框架路由事件
///    （push / pop / remove / replace）转发给宿主；
/// 3. 监听路由转场动画，转场开始 / 结束时回调宿主
///    （`forward -> completed -> reverse -> dismissed`）。
///
/// 不持有任何页面可见性状态（`_hasAppeared` / `_hasResume` 等），
/// 是否要真正发出 start / resume / pause / stop 由宿主自行判断。
///
/// 生命周期：宿主在 `didChangeDependencies` 中调用一次 [attach]，
/// 在 `dispose` 中调用一次 [detach]。
@internal
class FlPageRouteDelegate implements LifecycleRouteAware {
  FlPageRouteDelegate({
    required LifecycleRouteAware host,
    required VoidCallback onEnterAnimationEnd,
    required VoidCallback onLeaveAnimationEnd,
    required VoidCallback onEnterAnimationStart,
    required VoidCallback onLeaveAnimationStart,
  }) : _host = host,
       _animation = FlRouteAnimationBinding(
         onEnterStart: onEnterAnimationStart,
         onEnterEnd: onEnterAnimationEnd,
         onLeaveStart: onLeaveAnimationStart,
         onLeaveEnd: onLeaveAnimationEnd,
       );

  /// 路由事件的接收方，即混入了 `FlPageLifecycleMixin` 的 `State`。
  final LifecycleRouteAware _host;

  /// 转场动画的状态监听，与 `FlAnimationLifecycleMixin` 共用同一份实现。
  final FlRouteAnimationBinding _animation;

  ModalRoute? _modalRoute;

  /// 本页是不是**所在 Navigator** 的栈顶路由。实时查询，不缓存。
  ///
  /// 三个容易踩的点：
  ///
  /// - 被弹窗（`PopupRoute`）盖住时为 false，但此刻页面**仍然可见**——本库的
  ///   语义是弹窗只发 pause 不发 stop，判断可见性请用宿主的 `isPageAppeared`；
  /// - 嵌套 Navigator 时只反映**本层**：内层栈顶页即使整个内层 Navigator 被
  ///   外层路由盖住，这里依然是 true；
  /// - 转场动画期间就已经翻转：被 pop 的路由在动画**开始**时就进入 `popping`、
  ///   不再算 present，所以动画还在播时栈顶身份已经交接完毕。要判断转场真的
  ///   结束，用 `onPageEnterAnimationEnd` / `onPageLeaveAnimationEnd`。
  ///
  /// 没有 `ModalRoute`（不在任何路由中）或已 [detach] 时为 false。因此**不要**
  /// 拿它去过滤生命周期事件——那会把非路由页面永久挡死。这一点与
  /// `FlPageViewDelegate.isCurrentPage` 的约定相反，后者在「不在 PageView 中」
  /// 时恒为 true，就是为了让宿主能无分支地做门禁。
  bool get isCurrent => _modalRoute?.isCurrent ?? false;

  /// 页面所在的路由，[attach] 失败或 [detach] 之后为 null。
  ModalRoute? get modalRoute => _modalRoute;

  String? get routeName => _modalRoute?.settings.name;

  Object? get arguments => _modalRoute?.settings.arguments;

  /// 是否已成功挂到某个路由上。
  bool get isAttached => _modalRoute != null;

  /// 只挂一次的 [attach]，供宿主在**每次** `didChangeDependencies` 中调用。
  ///
  /// 返回 true 仅在「本次调用是首次成功」时，宿主据此发出一次
  /// `onPageContextReady`。已经挂上、或本次仍拿不到 `ModalRoute`，都返回 false。
  ///
  /// 失败时**不**记录状态，留到下一次 `didChangeDependencies` 重试：页面可能先于
  /// `Navigator` 构建（例如先作为普通子 Widget 挂上、随后才被塞进路由），一次性
  /// 放弃会让这类页面永久收不到任何路由事件。已成功后不会再次 [attach]，
  /// 因此不存在重复订阅或重复挂动画监听。
  ///
  /// 这段「首次成功才置位、失败留到下次」的逻辑原本在
  /// `FlPageLifecycleMixin` 与 `FlPageRouteMixin` 里各写了一份（含注释逐字相同），
  /// 收到这里由委托统一持有。
  bool attachOnce(BuildContext context) {
    if (isAttached) {
      return false;
    }
    return attach(context);
  }

  /// 取路由、订阅路由事件、监听转场动画。
  ///
  /// 返回 false 表示页面不处于任何路由中（`ModalRoute.of` 为 null），
  /// 此时不会订阅任何事件，宿主的 start / resume / pause / stop 也无从触发。
  ///
  /// 宿主通常应该调 [attachOnce]，它带「只挂一次 + 失败重试」的语义。
  bool attach(BuildContext context) {
    final route = ModalRoute.of(context);
    _modalRoute = route;
    if (route == null) {
      return false;
    }
    assert(() {
      _debugCheckObserverRegistered(route);
      return true;
    }());
    FlRouteObserver.instance.subscribe(route, this);
    _animation.attach(route.animation);
    return true;
  }

  /// 整个进程只提示一次，避免每个页面刷一行。
  static bool _debugDidWarnObserverMissing = false;

  /// 检查 [route] 所属的 `Navigator` 有没有装上 [FlRouteObserver]。
  ///
  /// 没装的话本库的路由事件（start / resume / pause / stop）全部收不到，
  /// 且不会报任何错——这是新用户最容易踩、又最难自查的一个坑，
  /// 所以在 debug 下主动喊一声。用 `debugPrint` 而不是 `assert(false)`：
  /// 只用 App 前后台事件、不关心路由的用法是合法的，不该直接崩掉。
  void _debugCheckObserverRegistered(ModalRoute route) {
    if (_debugDidWarnObserverMissing) {
      return;
    }
    final observers = route.navigator?.widget.observers;
    // 拿不到 navigator（尚未 install）时不下结论，留到下次。
    if (observers == null || observers.contains(FlRouteObserver.instance)) {
      return;
    }
    _debugDidWarnObserverMissing = true;
    debugPrint(
      '[page_lifecycle] 当前 Navigator 没有注册 FlRouteObserver，'
      '页面的 onPageStart / onPageResume / onPagePause / onPageStop 不会触发'
      '（转场动画回调不受影响，它直接监听 ModalRoute.animation）。请加上：\n'
      '  MaterialApp(navigatorObservers: [FlRouteObserver.instance], ...)\n'
      '嵌套 Navigator 需要各自注册一次。（本提示每次运行只输出一遍）',
    );
  }

  /// 取消动画监听与路由订阅，释放对路由的引用。可重复调用。
  void detach() {
    _animation.detach();
    final route = _modalRoute;
    if (route != null) {
      FlRouteObserver.instance.unsubscribe(route, this);
    }
    _modalRoute = null;
  }

  ///*********************RouteAware 框架路由生命周期，转发给宿主***************************

  @internal
  @override
  void routePageStart() {
    _host.routePageStart();
  }

  @internal
  @override
  void routePageResume() {
    _host.routePageResume();
  }

  @internal
  @override
  void routePagePause() {
    _host.routePagePause();
  }

  @internal
  @override
  void routePageStop() {
    _host.routePageStop();
  }
}
