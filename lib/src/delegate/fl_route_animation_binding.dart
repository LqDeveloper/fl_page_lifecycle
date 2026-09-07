import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

/// 把 `ModalRoute.animation` 的状态变化翻译成四个转场回调。
///
/// 只做这一件事，不碰路由订阅、不持有页面可见性状态——`FlPageRouteDelegate`
/// （连带 `FlPageLifecycleMixin` / `FlPageRouteMixin`）与
/// `FlAnimationLifecycleMixin` 共用它。
///
/// 抽出来的原因是这段 switch 原本在两处各写了一份，且已经开始分叉：其中一份有
/// [detach] 之后的重入守卫，另一份没有。这个守卫是必要的，见 [detach]。
///
/// 生命周期：[attach] 传入动画（可为 null，表示没有转场动画，此后完全静默），
/// 用完调 [detach]。两者都可重复调用，[attach] 会先解绑旧的。
@internal
class FlRouteAnimationBinding {
  FlRouteAnimationBinding({
    required VoidCallback onEnterStart,
    required VoidCallback onEnterEnd,
    required VoidCallback onLeaveStart,
    required VoidCallback onLeaveEnd,
  }) : _onEnterStart = onEnterStart,
       _onEnterEnd = onEnterEnd,
       _onLeaveStart = onLeaveStart,
       _onLeaveEnd = onLeaveEnd;

  /// 入场动画开始播放（`AnimationStatus.forward`）。
  final VoidCallback _onEnterStart;

  /// 入场动画播放完毕（`AnimationStatus.completed`）。
  final VoidCallback _onEnterEnd;

  /// 退场动画开始播放（`AnimationStatus.reverse`）。
  final VoidCallback _onLeaveStart;

  /// 退场动画播放完毕（`AnimationStatus.dismissed`）。
  final VoidCallback _onLeaveEnd;

  Animation<double>? _animation;
  bool _detached = false;
  bool _didAttachFromContext = false;

  /// 当前绑定的动画，未绑定或已 [detach] 时为 null。
  Animation<double>? get animation => _animation;

  /// 从 [context] 取 `ModalRoute` 并绑定它的动画，**只成功一次**。
  ///
  /// 供宿主在**每次** `didChangeDependencies` 中调用。返回 true 仅在本次是首次
  /// 成功时。拿不到 `ModalRoute` 时**不**记录状态，留到下一次
  /// `didChangeDependencies` 重试：页面可能先于 `Navigator` 构建（例如先作为普通
  /// 子 Widget 挂上、随后才被塞进路由），一次性放弃会让这类页面永久收不到转场
  /// 回调。
  ///
  /// 与 `FlPageRouteDelegate.attachOnce` 是同一套「首次成功才置位、失败留到下次」
  /// 语义，但那边还要顺带订阅路由事件，所以自己解析 `ModalRoute`、走 [attach]。
  /// 只要转场动画的宿主不需要路由订阅，就该用本方法而不是再抄一份重试逻辑。
  bool attachOnceFrom(BuildContext context) {
    if (_didAttachFromContext) {
      return false;
    }
    final route = ModalRoute.of(context);
    if (route == null) {
      return false;
    }
    _didAttachFromContext = true;
    attach(route.animation);
    return true;
  }

  /// 绑定 [animation] 并开始监听状态变化。先解绑已有的，可重复调用。
  ///
  /// [animation] 为 null 时只做解绑（`ModalRoute.animation` 可能为 null）。
  void attach(Animation<double>? animation) {
    detach();
    _detached = false;
    _animation = animation;
    _animation?.addStatusListener(_handleStatus);
  }

  /// 解绑并置为终态：此后不再发出任何回调。可重复调用。
  ///
  /// 光是 `removeStatusListener` 不够，还要置 [_detached]：
  /// `AnimationLocalStatusListenersMixin.notifyStatusListeners` 遍历的是监听器
  /// 列表的**副本**，因此在同一轮通知中被移除的监听器仍会被回调一次。宿主已经
  /// 在 `dispose` 里了，那一次回调会打到一个正在销毁的 `State` 上。
  void detach() {
    _detached = true;
    _animation?.removeStatusListener(_handleStatus);
    _animation = null;
  }

  /// forward -> completed -> reverse -> dismissed
  void _handleStatus(AnimationStatus status) {
    if (_detached) {
      return;
    }
    switch (status) {
      case AnimationStatus.forward:
        _onEnterStart();
        break;
      case AnimationStatus.completed:
        _onEnterEnd();
        break;
      case AnimationStatus.reverse:
        _onLeaveStart();
        break;
      case AnimationStatus.dismissed:
        _onLeaveEnd();
        break;
    }
  }
}
