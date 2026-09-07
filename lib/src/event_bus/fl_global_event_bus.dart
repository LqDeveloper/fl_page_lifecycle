import 'dart:async';

import 'fl_event_bus.dart';
import 'fl_i_event_bus.dart';

/// 全局事件总线访问点
///
/// 提供静态方法访问全局事件总线。默认使用 [FlEventBus] 实现，
/// 通过 [configure] 可注入 mock 实现用于单元测试：
///
/// ```dart
/// class MockEventBus implements FlIEventBus { ... }
///
/// setUp(() => FlGlobalEventBus.configure(MockEventBus()));
/// tearDown(() => FlGlobalEventBus.destroy());
/// ```
///
/// ## 内存管理
///
/// 底层 `StreamController.broadcast()` 在应用生命周期内常驻，这是**预期行为**：
/// 它只持有订阅者列表，页面侧的订阅由 `FlStateEventBusMixin` 在 `dispose` 中
/// 自动 cancel，不会随页面进出堆积。
///
/// [destroy] 是**全局**操作，只用于测试 `tearDown` 与 App 退出，
/// 不要在页面 `dispose` 中调用，原因见 [destroy] 的说明。
class FlGlobalEventBus {
  static FlIEventBus? _bus;

  /// 配置全局事件总线实例
  ///
  /// 通常用于测试中注入 mock 实现。传入 [bus] 后，
  /// 所有通过 [observeEvent] / [dispatchEvent] 的调用都会路由到此实例。
  ///
  /// ## ⚠️ 与 [destroy] 同样是全局操作
  ///
  /// 旧实例会被 [destroy] 释放，因此**所有已经订阅在旧实例上的页面会一起失效**
  /// （收到 done 之后不会迁移到新实例，且不抛异常、不打日志）。只应在
  /// **App 启动时**或**测试 setUp 中**调用，不要在运行中途替换总线。
  static void configure(FlIEventBus bus) {
    if (_bus != null && _bus != bus) {
      unawaited(_bus!.destroy());
    }
    _bus = bus;
  }

  /// 销毁全局总线，释放 StreamController 资源
  ///
  /// 关闭底层 [StreamController]，断开所有订阅者引用链：
  /// ```
  /// _bus → FlEventBus._streamController → _BroadcastStreamController → _SubscriptionList
  ///                                                                       └─ 闭包 → State/Controller
  /// ```
  /// 调用后 GC 可回收旧实例及其关联对象（老生代 Mark-Sweep）。
  ///
  /// 如有代码继续调用 [observeEvent] / [dispatchEvent]，
  /// 触发延迟重建（lazy init），自动创建新实例，不会崩溃。
  ///
  /// ## ⚠️ 只能在这两个时机调用
  ///
  /// - 测试的 `tearDown` 中；
  /// - App 即将退出（`AppLifecycleState.detached`）时。
  ///
  /// **不要在 `State.dispose()` 或路由 pop 回调中调用。** 这是全局单例：
  /// 一个页面销毁就关闭整条 broadcast stream，此刻**所有其他存活页面**通过
  /// `FlStateEventBusMixin.observeEvent` 建立的订阅会一起收到 done 并永久失效。
  /// 之后的 [dispatchEvent] 虽然会 lazy 重建出新实例，但老订阅仍挂在旧实例上，
  /// **不会**迁移过去——既不抛异常也不打日志，是纯静默故障。
  ///
  /// 页面级的订阅释放请用 `FlStateEventBusMixin`，它会在 `dispose` 中
  /// 自动 cancel 自己的那几条订阅，不影响任何其他页面。
  static Future<void> destroy() async {
    final bus = _bus;
    _bus = null; // 先置空，确保并发调用安全
    if (bus != null) {
      await bus.destroy();
    }
  }

  static FlIEventBus get _instance => _bus ??= FlEventBus();

  /// 订阅指定类型的事件
  static Stream<T> observeEvent<T>() {
    return _instance.on<T>();
  }

  /// 发布事件
  static void dispatchEvent<T>(T event) {
    _instance.fire(event);
  }
}
