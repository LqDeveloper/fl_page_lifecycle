import 'dart:async';

import 'package:flutter/material.dart';

import 'fl_global_event_bus.dart';

/// 在 `State` 中收发全局事件的 mixin，订阅由本 mixin 在 `dispose` 中自动取消。
///
/// 解决的是事件总线最常见的泄漏形态：页面订阅了全局流却忘了 cancel，闭包一直
/// 持有 `State`，整棵子树无法 GC。混入后只管 [observeEvent]，释放不用操心。
///
/// ```dart
/// class _FeedPageState extends State<FeedPage> with FlStateEventBusMixin {
///   @override
///   void initState() {
///     super.initState();
///     observeEvent<LoginSuccess>(_handleLogin);   // 传方法引用，不要写闭包
///   }
///
///   void _handleLogin(LoginSuccess event) => setState(() => _refresh());
/// }
/// ```
///
/// 覆写 `dispose` 时必须调 `super.dispose()`（已标注 `@mustCallSuper`），
/// 否则订阅不会被取消。
mixin FlStateEventBusMixin<S extends StatefulWidget> on State<S> {
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  /// 已登记的 (事件类型, 回调) 组合，用于挡掉重复订阅，见 [observeEvent]。
  final Set<(Type, Function)> _observed = <(Type, Function)>{};

  Stream<T> _on<T>() {
    return FlGlobalEventBus.observeEvent<T>();
  }

  /// 订阅 [T] 类型的事件，订阅会在 `dispose` 中自动取消。
  ///
  /// **只应在 `initState`（或 `onPageInit`）中调用一次。** 本方法不会解除任何
  /// 已有订阅，写进 `build` / `onPageResume` 这类会重复执行的地方，订阅数就会
  /// 随每次重建、每次回到前台线性增长：同一个事件回调多次，闭包持有的对象
  /// 也跟着堆积，症状通常表现为埋点重复上报或接口重复请求。
  ///
  /// 为此这里挡了一道：同一个 (T, [onData]) 组合重复登记时直接忽略，
  /// 并在 debug 模式下 `assert` 报错。注意**只有传方法引用**
  /// （`observeEvent<Foo>(_handleFoo)`）才拦得住——每次现写的闭包字面量
  /// 彼此不相等，识别不出来，仍然会重复订阅。
  ///
  /// 同一个事件类型配不同的回调是合法的，不受影响。
  @protected
  void observeEvent<T>(void Function(T event) onData) {
    if (!_observed.add((T, onData))) {
      assert(
        false,
        'observeEvent<$T> 重复订阅了同一个回调。'
        '请把它移到 initState 中只调用一次——写在 build / onPageResume 里会让'
        '订阅数随重建次数线性增长。本次订阅已被忽略。',
      );
      return;
    }
    _subscriptions.add(_on<T>().listen(onData));
  }

  /// 向全局总线发布一个 [T] 类型的事件。
  ///
  /// 所有 `observeEvent<T>()` 的订阅者都会收到，包括本页自己。
  @protected
  void dispatchEvent<T>(T event) {
    FlGlobalEventBus.dispatchEvent<T>(event);
  }

  @override
  @mustCallSuper
  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    _observed.clear();
    super.dispose();
  }
}
