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

  /// 入场动画开始（`AnimationStatus.forward`）。
  ///
  /// **首次 push 入场时通常不会触发**：动画监听器在首次 `didChangeDependencies`
  /// 才绑定，而 `Navigator` 在更早的 `didPush` 里就已把动画推进到 `forward`，
  /// 状态变更发生在绑定之前就收不到。需要「页面开始进场」这个时机，
  /// 请放在 `initState` 里。
  ///
  /// 实际能收到的主要是**动画折返**：iOS 侧滑返回拖到一半放弃，动画由 `reverse`
  /// 回到 `forward`，此时触发，随后是 [onPageEnterAnimationEnd]。
  @protected
  void onPageEnterAnimationStart() {}

  /// 入场动画结束（`AnimationStatus.completed`）。
  ///
  /// 适合把重量级操作（大图解码、复杂列表构建、自动弹出的引导层）推迟到转场
  /// 结束后执行，避免掉帧。
  ///
  /// **但本回调可能重复发出**：iOS 侧滑返回拖到一半放弃时，动画走
  /// `reverse → forward → completed`，`completed` 第二次到达，本回调再触发一次。
  /// 因此放在这里的网络请求、埋点上报**必须自己做幂等或去重**——否则一个常见的
  /// iOS 手势就会让它执行两遍。
  @protected
  void onPageEnterAnimationEnd() {}

  /// 退场动画开始（`AnimationStatus.reverse`）。
  ///
  /// 触发来源：自身被 pop 时动画开始反向；iOS 侧滑返回手势开始拖动。
  /// 此时页面仍然可见，适合暂停视频 / 动画、收起键盘。
  ///
  /// **不代表页面一定会退出**：侧滑手势中途放弃时也会触发，随后是
  /// [onPageEnterAnimationStart] → [onPageEnterAnimationEnd]，而**不是**
  /// [onPageLeaveAnimationEnd]。因此释放资源、上报离开埋点这类不可逆操作
  /// 应放在 [onPageLeaveAnimationEnd] 或 `dispose` 中。也因为同一次生命周期里
  /// 可以反复拖动，本回调可能多次触发。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 退场动画结束（`AnimationStatus.dismissed`）。
  ///
  /// 页面已完全移出屏幕，通常紧随其后就是 `dispose`。与
  /// [onPageLeaveAnimationStart] 不同，走到这里页面**确实**退出了，
  /// 适合做最后的状态上报。
  @protected
  void onPageLeaveAnimationEnd() {}
}
