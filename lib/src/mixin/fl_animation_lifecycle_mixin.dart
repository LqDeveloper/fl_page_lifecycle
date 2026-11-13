import 'package:flutter/material.dart';

import '../delegate/fl_route_animation_binding.dart';

/// 页面入场/退场动画感知 Mixin — 独立版。
///
/// 只关心路由转场动画，不订阅路由事件、不参与可见性状态机。需要完整页面
/// 生命周期时用 `FlPageLifecycleMixin`（它已内置同一份动画监听），
/// **两者不要叠加使用**。
mixin FlAnimationLifecycleMixin<T extends StatefulWidget> on State<T> {
  /// 动画状态监听，与 `FlPageRouteDelegate` 共用同一份实现。
  late final FlRouteAnimationBinding _animation = FlRouteAnimationBinding(
    onEnterStart: onPageEnterAnimationStart,
    onEnterEnd: onPageEnterAnimationEnd,
    onLeaveStart: onPageLeaveAnimationStart,
    onLeaveEnd: onPageLeaveAnimationEnd,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 「首次成功才绑定、拿不到 ModalRoute 就留到下次重试」的语义由 binding 持有，
    // 见 [FlRouteAnimationBinding.attachOnceFrom]。
    _animation.attachOnceFrom(context);
  }

  @override
  void dispose() {
    _animation.detach();
    super.dispose();
  }

  /// 入场转场动画开始（`AnimationStatus.forward`）。
  ///
  /// 首次 push 入场时通常收不到，实际主要在动画折返（iOS 侧滑返回中途放弃）时触发。
  /// 本 mixin 没有 `onPageContextReady`，需要「页面开始进场」这个时机请用 `initState`。
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
  ///
  /// 完整的触发条件与时序见 `FlLifecycleState.onPageLeaveAnimationStart`。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 退场转场动画结束（`AnimationStatus.dismissed`），页面确实退出了。
  ///
  /// 完整的触发条件与时序见 `FlLifecycleState.onPageLeaveAnimationEnd`。
  @protected
  void onPageLeaveAnimationEnd() {}
}
