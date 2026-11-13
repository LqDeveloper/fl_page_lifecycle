import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

import '../delegate/fl_page_route_delegate.dart';
import '../delegate/fl_page_visibility_state.dart';
import '../lifecycle/fl_lifecycle_guard.dart';
import '../lifecycle/lifecycle_route_aware.dart';

/// 只关心 **路由** 的页面 mixin：路由信息、框架路由事件、转场动画。
///
/// 处理逻辑本身全部在 [FlPageRouteDelegate] 中，本 mixin 只做两件事：
/// 在 `didChangeDependencies` / `dispose` 中自动 attach / detach，并把委托的
/// 回调转成子类可覆写的模板方法。因此**不需要**手动调用任何初始化 / 释放方法。
///
/// 与 `FlPageLifecycleMixin` 的区别：本 mixin 只做**路由层面**的收敛，不做
/// PageView 页码判断，也不关心页面是否真的可见——弹窗覆盖同样按 pause 转发。
///
/// 它并非完全不做幂等：[onRouteStart] / [onRouteStop] 由 `FlPageVisibilityState` 保证
/// 一次性，未曾出现过就收到 resume 时会补发 start，已出现过又收到 start 时
/// 只补发 [onRouteResume]（弹窗被 `pushReplacement` / `pushAndRemoveUntil`
/// 换掉、随后上层被 pop 的情形；与 resume 路径一样不判重），`routePageStop` 会先补
/// [onRoutePause] 再发 [onRouteStop]，`dispose` 也会补发 pause / stop 对。
/// 真正**没有**守卫的是 [onRoutePause]——它无条件转发，页面从未出现过或
/// 已经处于 pause 时照样会发。
///
/// 需要完整的可见性状态机（弹窗只 pause 不 stop、PageView 按页码驱动）时用
/// `FlPageLifecycleMixin`，它已经内置了同一个委托，**两者不要叠加使用**。
///
/// 唯一不依赖路由的是首帧的 [onRouteStart] / [onRouteResume] 与 `dispose` 时
/// 补发的 [onRoutePause] / [onRouteStop]：没有 `ModalRoute` 时它们照常发出，
/// 因此这一对始终是配对的。
///
/// ```dart
/// class _DetailPageState extends State<DetailPage> with FlPageRouteMixin {
///   @override
///   void onPageContextReady(String? routeName, Object? arguments) {
///     _id = (arguments as Map?)?['id'] as String?;
///   }
///
///   @override
///   void onPageEnterAnimationEnd() => _loadHeavyStuff();
/// }
/// ```
mixin FlPageRouteMixin<T extends StatefulWidget> on State<T>
    implements LifecycleRouteAware {
  /// 路由相关处理（取路由、订阅路由事件、监听转场动画）全部委托给它。
  late final FlPageRouteDelegate _routeDelegate = FlPageRouteDelegate(
    host: this,
    onEnterAnimationEnd: onPageEnterAnimationEnd,
    onLeaveAnimationEnd: onPageLeaveAnimationEnd,
    onEnterAnimationStart: onPageEnterAnimationStart,
    onLeaveAnimationStart: onPageLeaveAnimationStart,
  );

  /// 页面所在的路由，页面不处于任何路由中或已 `dispose` 时为 null。
  ModalRoute? get modalRoute => _routeDelegate.modalRoute;

  /// 本页所在路由的名字（`RouteSettings.name`）。
  ///
  /// [onPageContextReady] 之前、以及页面不处于任何路由中时为 null。
  String? get routeName => _routeDelegate.routeName;

  /// 本页所在路由的参数（`RouteSettings.arguments`）。
  ///
  /// [onPageContextReady] 之前、以及页面不处于任何路由中时为 null。
  Object? get arguments => _routeDelegate.arguments;

  /// 本页是不是**所在 Navigator** 的栈顶路由。实时查询，不缓存。
  ///
  /// 三个容易踩的点：
  ///
  /// - 被弹窗（`PopupRoute`）盖住时为 false，但此刻页面**仍然可见**——弹窗只
  ///   触发 [onRoutePause] 不触发 [onRouteStop]；
  /// - 嵌套 Navigator 时只反映**本层**：内层栈顶页即使整个内层 Navigator 被
  ///   外层路由盖住，这里依然是 true；
  /// - 转场动画期间就已经翻转：被 pop 的路由在动画**开始**时就不再是栈顶，
  ///   要判断转场真的结束请用 [onPageEnterAnimationEnd] /
  ///   [onPageLeaveAnimationEnd]。
  ///
  /// 不在任何路由中（`ModalRoute.of` 为 null）时为 false，因此**不要**拿它去
  /// 过滤生命周期事件——那会把非路由页面永久挡死。
  bool get isCurrent => _routeDelegate.isCurrent;

  /// 是否已成功挂到某个路由上。为 false 时下面的路由回调都不会触发。
  bool get hasRoute => _routeDelegate.isAttached;
  bool _hasDispose = false;

  /// start / stop 的配对，规则见 [FlPageVisibilityState]，与 `FlPageLifecycleMixin`
  /// 共用同一份实现。`guardResume: false` 保留本 mixin 历来的行为：
  /// [onRouteResume] / [onRoutePause] 不判重、无条件转发。
  late final FlPageVisibilityState _visibility = FlPageVisibilityState(
    onStart: () => FlLifecycleGuard.run(onRouteStart),
    onResume: () => FlLifecycleGuard.run(onRouteResume),
    onPause: () => FlLifecycleGuard.run(onRoutePause),
    onStop: () => FlLifecycleGuard.run(onRouteStop),
    // 没有 `ModalRoute` 的页面 `isCurrent` 恒为 false，所以先判 `isAttached`。
    isCovered: () => _routeDelegate.isAttached && !_routeDelegate.isCurrent,
    guardResume: false,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (_hasDispose) {
        return;
      }
      if (_visibility.isAppeared) {
        return;
      }
      // 已挂到路由上时只有栈顶才算露面：本 mixin 向 [FlRouteObserver] 订阅是在
      // `didChangeDependencies` 里，晚于 `Navigator` 同步发出的 `didPush`，所以
      // 「本页被 push、同一帧内又被别的路由盖住」时收不到那次 stop，不加判断就会
      // 给一个从未露面的页面发出 start。没有 `ModalRoute` 的页面 `isCurrent`
      // 恒为 false，不能用它挡——那会让非路由页面永久收不到任何回调。
      if (_visibility.isCovered) {
        return;
      }
      _visibility.start();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 「首次成功才发事件、失败留到下次重试」的语义由委托持有，
    // 见 [FlPageRouteDelegate.attachOnce]。
    if (!_routeDelegate.attachOnce(context)) {
      return;
    }
    FlLifecycleGuard.run(
      () => onPageContextReady(
        _routeDelegate.routeName,
        _routeDelegate.arguments,
      ),
    );
  }

  @override
  void dispose() {
    _hasDispose = true;
    // 与 `FlPageLifecycleMixin.dispose` 同一套约定：宿主回调是外部代码，随时可能
    // 抛，而资源释放与 `super.dispose()` 一次都不能少。本方法的释放本来就排在
    // 回调之前，所以只需兜住 super。两个 mixin 的 dispose 请保持这个形状一致，
    // 时序契约由 test/dispose_contract_test.dart 对拍锁住。
    _routeDelegate.detach();
    try {
      _visibility.stop();
    } finally {
      super.dispose();
    }
  }

  /// 依赖就绪且成功拿到 `ModalRoute`，此时 [routeName] / [arguments] 可用。
  ///
  /// **可能永不触发**：页面不处于任何路由中时（`ModalRoute.of` 为 null），
  /// 本回调与两个转场动画回调都不会触发，[onRoutePause] / [onRouteStop] 也
  /// 只剩 `dispose` 时的补发。
  ///
  /// 但 [onRouteStart] / [onRouteResume] **仍会在首帧发出**——它们由首帧回调
  /// 驱动，不依赖路由，因此即使没有 `ModalRoute`，「首帧 start → dispose 时
  /// stop」这一对仍然是配对的。
  @protected
  void onPageContextReady(String? routeName, Object? arguments) {}

  /// 入场转场动画开始（`AnimationStatus.forward`）。
  ///
  /// 首次 push 入场时通常收不到，实际主要在动画折返（iOS 侧滑返回中途放弃）时触发。
  /// 需要「页面开始进场」这个时机请用 [onPageContextReady]。
  ///
  /// 完整的触发条件与时序见 `FlLifecycleState.onPageEnterAnimationStart`。
  @protected
  void onPageEnterAnimationStart() {}

  /// 入场转场动画结束（`AnimationStatus.completed`）。
  ///
  /// **可能触发两次**（iOS 侧滑返回中途放弃），放在这里的请求、埋点须自行幂等。
  ///
  /// 完整的触发条件与时序见 `FlLifecycleState.onPageEnterAnimationEnd`。
  @protected
  void onPageEnterAnimationEnd() {}

  /// 退场转场动画开始（`AnimationStatus.reverse`）。
  ///
  /// **不代表页面一定会退出**（侧滑中途放弃时也会触发），不可逆操作请放在
  /// [onPageLeaveAnimationEnd]。
  /// 与 [onRouteStop] 相互独立，先后顺序不作保证。
  ///
  /// 完整的触发条件与时序见 `FlLifecycleState.onPageLeaveAnimationStart`。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 退场转场动画结束（`AnimationStatus.dismissed`），页面确实退出了。
  ///
  /// 完整的触发条件与时序见 `FlLifecycleState.onPageLeaveAnimationEnd`。
  @protected
  void onPageLeaveAnimationEnd() {}

  /// 本页重新入栈顶（上层非弹窗路由被 pop / remove）。
  @protected
  void onRouteStart() {}

  /// 本页重新可交互（上层弹窗被 pop）。
  @protected
  void onRouteResume() {}

  /// 本页被弹窗盖住。
  @protected
  void onRoutePause() {}

  /// 本页被非弹窗路由盖住，或自身被 pop / remove / replace。
  @protected
  void onRouteStop() {}

  ///*********************RouteAware 框架路由生命周期，**不允许子类重写***************************

  @internal
  @override
  @nonVirtual
  void routePageStart() => _visibility.start();

  @internal
  @override
  @nonVirtual
  void routePageResume() {
    // 尚未露面时补发 start + resume：页面可能在首帧就被同一帧 push 的弹窗盖住，
    // 被 `initState` 的栈顶判断挡掉了 start，此刻弹窗关闭正是它第一次真正露面。
    if (!_visibility.isAppeared) {
      _visibility.start();
      return;
    }
    _visibility.resume();
  }

  @internal
  @override
  @nonVirtual
  void routePagePause() => _visibility.pause();

  @internal
  @override
  @nonVirtual
  void routePageStop() => _visibility.stop();
}
