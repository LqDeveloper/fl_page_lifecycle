import 'dart:async';

import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

import '../lifecycle/fl_lifecycle_guard.dart';
import '../lifecycle/fl_lifecycle_manager.dart';

/// `FlPageLifecycleMixin` 的 App 生命周期委托——把「页面与 App 前后台状态之间
/// 的关系」从页面生命周期状态机中独立出来。
///
/// 负责两件事，且**只**负责这两件事：
///
/// 1. 订阅 [FlLifecycleManager] 的前后台流，切换时回调宿主；
/// 2. 订阅原始的 [AppLifecycleState] 流，变化时回调宿主。
///
/// 不持有任何页面可见性状态，也不判断是否该发出对应事件——收到什么就转发
/// 什么，由宿主自行决定如何处理。
///
/// 生命周期：宿主在 `initState` 中调用一次 [attach]，在 `dispose` 中调用一次
/// [detach]。两者均幂等，[detach] 之后可再次 [attach]。
@internal
class FlAppLifecycleDelegate {
  FlAppLifecycleDelegate({
    required VoidCallback onForeground,
    required VoidCallback onBackground,
    required ValueChanged<AppLifecycleState> onStateChanged,
  }) : _onForeground = onForeground,
       _onBackground = onBackground,
       _onStateChanged = onStateChanged;

  /// App 切换到前台的回调（由 [FlLifecycleManager] 判定，过滤了 transient 中断）。
  final VoidCallback _onForeground;

  /// App 切换到后台的回调（由 [FlLifecycleManager] 判定）。
  final VoidCallback _onBackground;

  /// 原始 [AppLifecycleState] 变化的回调。
  final ValueChanged<AppLifecycleState> _onStateChanged;

  StreamSubscription<bool>? _foregroundSub;
  StreamSubscription<AppLifecycleState>? _lifecycleSub;

  /// 是否已订阅，[detach] 之后为 false。
  bool get isAttached => _foregroundSub != null;

  /// App 当前是否位于前台。不依赖是否已 [attach]，任何时机都可读。
  bool get isForeground => FlLifecycleManager.instance.isForeground;

  /// 订阅前后台流与 [AppLifecycleState] 流。重复调用无副作用。
  void attach() {
    if (isAttached) {
      return;
    }
    _foregroundSub = FlLifecycleManager.instance.stream.listen(
      _handlerForegroundChanged,
    );
    _lifecycleSub = FlLifecycleManager.instance.lifecycle.listen(
      _handlerAppLifecycleState,
    );
  }

  /// 取消两条订阅。可重复调用，之后可再次 [attach]。
  void detach() {
    unawaited(_foregroundSub?.cancel());
    _foregroundSub = null;
    unawaited(_lifecycleSub?.cancel());
    _lifecycleSub = null;
  }

  /// 下面两个回调都包 [FlLifecycleGuard]，理由与别处不同，记一下。
  ///
  /// 这里的调用方是 `StreamSubscription`，不是页面的调用链：宿主抛异常时**别的
  /// 订阅者本来就不受影响**（广播流逐个分发，一个监听器抛不影响下一个），
  /// 所以包它不是为了缩小爆炸半径，而是为了**统一上报通道**。
  ///
  /// 不包的话异常作为「未捕获的异步错误」交给 zone，与本库其余回调走的
  /// [FlutterError.onError] 是两条路：少了 `library: 'fl_page_lifecycle'` 与
  /// 「分发页面生命周期回调时」这层 context，崩溃收集端看不出是生命周期回调里
  /// 炸的；使用方给自己页面写 widget 测试时也没法用 `tester.takeException()`
  /// 消费掉它，测试直接失败且失败信息不指向回调。
  ///
  ///true -> 前台，false -> 后台
  void _handlerForegroundChanged(bool isForeground) {
    FlLifecycleGuard.run(isForeground ? _onForeground : _onBackground);
  }

  void _handlerAppLifecycleState(AppLifecycleState state) {
    FlLifecycleGuard.run(() => _onStateChanged(state));
  }
}
