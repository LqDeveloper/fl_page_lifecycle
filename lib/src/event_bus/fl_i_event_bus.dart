import 'dart:async';

/// 事件总线抽象接口
///
/// 定义事件发布/订阅的最小协议。通过此接口，
/// 上层代码可以脱离具体实现进行单元测试：
///
/// ```dart
/// class MockEventBus implements FlIEventBus {
///   final controller = StreamController<dynamic>.broadcast();
///   @override Stream<T> on<T>() => controller.stream.whereType<T>();
///   @override void fire(dynamic event) => controller.add(event);
///   @override Future<void> destroy() => controller.close();
/// }
///
/// void main() {
///   FlGlobalEventBus.configure(MockEventBus());
///   // 所有 Controller 现在通过 mock 总线通信
/// }
/// ```
abstract class FlIEventBus {
  /// 订阅指定类型的事件流
  ///
  /// 泛型 [T] 为事件类型。[T == dynamic] 时不进行类型过滤。
  Stream<T> on<T>();

  /// 发布一个事件
  ///
  /// 所有通过 [on] 订阅了对应类型的监听者会收到此事件。
  void fire(dynamic event);

  /// 销毁总线，释放内部资源
  ///
  /// 调用后所有 Stream 订阅被取消，不可再 [fire] 事件。
  Future<void> destroy();
}
