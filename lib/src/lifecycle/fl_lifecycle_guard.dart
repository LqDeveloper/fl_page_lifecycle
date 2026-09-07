import 'package:flutter/foundation.dart';

/// 调用宿主回调的统一入口：**捕获并上报异常，保证调用链继续往下走**。
///
/// 存在的理由是本库的回调几乎从不单独出现，而是成链：
/// `onPageStart` 之后要发 `onPageResume`，每个回调之后还要发一次对应的
/// `FlLifecycleState` 给统一出口 `onLifecycleStateChanged`。这些回调全是**外部
/// 代码**，任何一处抛异常，链上它之后的部分就整条丢失——而幂等标志位
/// （`_hasAppeared` / `_hasResume`）在抛出前已经置好，补发也补不回来，
/// 「start 之后必跟 resume」这类语义保证会被直接击穿。
///
/// 因此这里选择**上报而不是继续上抛**，与 `_FlPageViewFlushQueue._guard`
/// （`fl_page_view_delegate.dart`）是同一套约定：异常照常出现在控制台与
/// `FlutterError.onError` 上，不会被吞掉，但不再牵连别的回调、别的页面。
///
/// 代价是宿主回调里的异常不会再冒泡到调用方的 try/catch。这是有意的：
/// 这些回调的调用方是框架（首帧回调、路由通知、流订阅），冒泡上去只会连累
/// 同一批里的其他页面。
@internal
abstract final class FlLifecycleGuard {
  /// 执行 [callback]，捕获它抛出的任何异常并上报给 [FlutterError]。
  static void run(VoidCallback callback) {
    try {
      callback();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'fl_page_lifecycle',
          context: ErrorDescription('分发页面生命周期回调时'),
        ),
      );
    }
  }
}
