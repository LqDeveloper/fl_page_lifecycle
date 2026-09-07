import 'dart:async';

import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

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

  ///true -> 前台，false -> 后台
  void _handlerForegroundChanged(bool isForeground) {
    if (isForeground) {
      _onForeground();
    } else {
      _onBackground();
    }
  }

  void _handlerAppLifecycleState(AppLifecycleState state) {
    _onStateChanged(state);
  }
}
