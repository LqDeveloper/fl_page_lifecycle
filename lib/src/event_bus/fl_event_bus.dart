import 'dart:async';

import 'fl_i_event_bus.dart';

/// [FlIEventBus] 的默认实现：单条 `broadcast` 流承载所有事件类型，
/// [on] 按运行时类型过滤。
///
/// 事件类型就是 Dart 类型本身，因此不需要注册表也不会有字符串 key 拼错的问题。
/// 代价是每个 [on] 调用都会派生一条 `where().cast()` 流——订阅数很大时留意。
///
/// 通常通过 [FlGlobalEventBus] 使用，不必自己 new；需要一条互不干扰的独立总线
/// （例如模块内部通信、或测试里隔离事件）时才直接构造。
class FlEventBus implements FlIEventBus {
  final StreamController<dynamic> _streamController;

  /// 底层的广播 controller，供需要直接接触 `Stream` API 的场景使用。
  ///
  /// 一般不需要碰它：发布用 [fire]、订阅用 [on]。
  StreamController<dynamic> get streamController => _streamController;

  /// 新建一条独立的事件总线。
  ///
  /// [sync] 为 true 时 [fire] 会**同步**派发给订阅者（`StreamController.broadcast`
  /// 的 `sync` 参数）。默认 false，即事件经微任务异步派发——这是更安全的默认值，
  /// 同步派发会在 `fire` 的调用栈里重入订阅者代码。测试中想省掉
  /// `await pumpEventQueue()` 时可以传 true。
  FlEventBus({bool sync = false})
    : _streamController = StreamController<dynamic>.broadcast(sync: sync);

  /// 用外部提供的 [controller] 建总线，由调用方负责它的关闭。
  ///
  /// 只在确实需要自带 controller 时用（例如要挂 `onListen` / `onCancel` 钩子）；
  /// 只想要同步派发的话用 `FlEventBus(sync: true)` 更省事。
  ///
  /// ## [controller] 必须是 `StreamController<dynamic>`，且编译器帮不了你
  ///
  /// 本总线用**单条流承载所有事件类型**，元素类型一收窄就装不下别的事件。但
  /// Dart 的泛型是协变的——`StreamController<String>` 本身就是
  /// `StreamController<dynamic>` 的子类型，所以传一个收窄的 controller
  /// **照样能通过编译**，把参数类型写成 `StreamController<dynamic>` 也拦不住。
  ///
  /// 也没有可靠的运行时判据：`is StreamController<dynamic>`、
  /// `controller.add is void Function(dynamic)`、
  /// `controller.stream is Stream<Object?>` 对收窄的 controller 全都返回 true
  /// （协变对 `is` 判断和方法 tearoff 同样生效）。
  ///
  /// 因此这里只能靠约定。传错的表现是：[fire] 一个与元素类型不匹配的事件时抛
  /// `TypeError`（`fire` 不会吞掉它），而不是在构造这一刻报错。
  FlEventBus.customController(StreamController<dynamic> controller)
    : _streamController = controller;

  @override
  Stream<T> on<T>() {
    if (T == dynamic) {
      return streamController.stream as Stream<T>;
    } else {
      return streamController.stream.where((event) => event is T).cast<T>();
    }
  }

  @override
  void fire(dynamic event) {
    if (streamController.isClosed) {
      return;
    }
    streamController.add(event);
  }

  @override
  Future<void> destroy() async {
    await _streamController.close();
  }
}
