import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

import '../delegate/fl_page_route_delegate.dart';
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
/// 它并非完全不做幂等：[onRouteStart] / [onRouteStop] 由 `_hasAppear` 保证
/// 一次性，未曾出现过就收到 resume 时会补发 start，`routePageStop` 会先补
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
  bool _hasAppear = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (_hasDispose) {
        return;
      }
      if (_hasAppear) {
        return;
      }
      // 已挂到路由上时只有栈顶才算露面：本 mixin 向 [FlRouteObserver] 订阅是在
      // `didChangeDependencies` 里，晚于 `Navigator` 同步发出的 `didPush`，所以
      // 「本页被 push、同一帧内又被别的路由盖住」时收不到那次 stop，不加判断就会
      // 给一个从未露面的页面发出 start。没有 `ModalRoute` 的页面 `isCurrent`
      // 恒为 false，不能用它挡——那会让非路由页面永久收不到任何回调。
      if (_routeDelegate.isAttached && !_routeDelegate.isCurrent) {
        return;
      }
      _hasAppear = true;
      FlLifecycleGuard.run(onRouteStart);
      FlLifecycleGuard.run(onRouteResume);
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
      if (_hasAppear) {
        FlLifecycleGuard.run(onRoutePause);
        FlLifecycleGuard.run(onRouteStop);
      }
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

  /// 入场转场动画开始播放（`AnimationStatus.forward`）。
  ///
  /// **首次 push 入场时通常不会触发**：动画监听器在 [onPageContextReady]
  /// （首次 `didChangeDependencies`）中才绑定，而 Navigator 在更早的
  /// `didPush` 里就已把动画推进到 `forward`。需要「页面开始进场」这个时机，
  /// 请用 [onPageContextReady]。
  ///
  /// 实际能收到的主要是**动画折返**：iOS 侧滑返回中途放弃，动画由
  /// `reverse` 回到 `forward`，此时触发，随后是 [onPageEnterAnimationEnd]。
  @protected
  void onPageEnterAnimationStart() {}

  /// 入场转场动画播放完毕。iOS 侧滑返回中途放弃时会重复发出。
  @protected
  void onPageEnterAnimationEnd() {}

  /// 退场转场动画开始播放（`AnimationStatus.reverse`）。
  ///
  /// 触发来源：自身被 pop 时动画开始反向；iOS 侧滑返回手势开始拖动。
  ///
  /// **不代表页面一定会退出**：iOS 侧滑返回中途放弃时也会发出，随后是
  /// [onPageEnterAnimationStart] → [onPageEnterAnimationEnd] 而非
  /// [onPageLeaveAnimationEnd]。因此释放资源、上报离开埋点这类不可逆操作
  /// 应放在 [onPageLeaveAnimationEnd] 或 `dispose` 中。
  ///
  /// 与 [onRouteStop] 相互独立：普通 pop 时两者几乎同时发生，先后不作保证；
  /// 侧滑手势场景下本回调远早于 [onRouteStop]（手势确认返回后才 pop）。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 退场转场动画播放完毕。
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
  void routePageStart() {
    if (_hasAppear) {
      return;
    }
    _hasAppear = true;
    FlLifecycleGuard.run(onRouteStart);
    FlLifecycleGuard.run(onRouteResume);
  }

  @internal
  @override
  void routePageResume() {
    // 尚未露面时补发 start + resume：页面可能在首帧就被同一帧 push 的弹窗盖住，
    // 被 `initState` 的栈顶判断挡掉了 start，此刻弹窗关闭正是它第一次真正露面。
    if (!_hasAppear) {
      routePageStart();
      return;
    }
    FlLifecycleGuard.run(onRouteResume);
  }

  @internal
  @override
  void routePagePause() {
    FlLifecycleGuard.run(onRoutePause);
  }

  @internal
  @override
  void routePageStop() {
    if (!_hasAppear) {
      return;
    }
    // 与 routePageStart 一致：标志位先翻转再回调，回调里再次触发时能被挡住。
    _hasAppear = false;
    FlLifecycleGuard.run(onRoutePause);
    FlLifecycleGuard.run(onRouteStop);
  }
}
