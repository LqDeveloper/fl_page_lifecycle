import 'dart:async';

import 'package:flutter/material.dart';

/// App 前后台状态的全局单例：把 [AppLifecycleState] 转成两条流对外提供。
///
/// 两条流的区别是**过滤与否**，按需要选一条：
///
/// - [lifecycle] 透传所有原始状态，包括 `inactive` / `hidden` / `detached`；
/// - [stream] 只发「真的进后台了 / 真的回前台了」，把 `inactive → resumed`
///   这类短暂中断（来电、下拉通知栏、控制中心）过滤掉。
///
/// 要判断**当前**在不在前台，别去听流，直接读 [isForeground]——那是状态而不是
/// 事件，任何时机都可读，也不依赖有没有订阅过。
///
/// 页面侧一般不直接用本类：`FlPageLifecycleMixin`（打开 `observeAppLifecycle`）
/// 与 `FlAppLifecycleMixin` 已经封装好了订阅与释放。
class FlLifecycleManager extends WidgetsBindingObserver {
  /// 全局唯一实例。
  static final FlLifecycleManager instance = FlLifecycleManager._();

  FlLifecycleManager._();

  /// 返回 [instance]，`FlLifecycleManager()` 与 `FlLifecycleManager.instance`
  /// 拿到的是同一个对象。
  factory FlLifecycleManager() => instance;

  bool _hasListen = false;

  /// 标记是否从 paused 状态恢复
  ///
  /// 防止 resume 时 inactive→resumed 的短暂切换被误判为"从后台返回"。
  /// paused 时置 true，resumed 时消费后置 false。
  bool _isFromAppPause = false;

  /// 标记是否已经发送过初始前台事件（冷启动时首次 resumed）
  ///
  /// 用于区分冷启动的首次 resumed 和后续 inactive→resumed 短暂中断。
  /// listen() 时若 app 已处于 resumed 状态，也会将此置为 true。
  ///
  /// **一旦置位就不再复位**，[cancel] 也不复位——补发只该在整个进程的冷启动发生
  /// 一次；`cancel` → `listen` 之后再补发一次，对一直在听的订阅者就是个假事件。
  bool _hasEverSentForeground = false;

  /// 当前是否处于前台（同步读取，不依赖 stream）
  bool get isForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// 前后台事件的广播源。**从不关闭**，生命周期与进程等长，见 [cancel]。
  final StreamController<bool> _streamController =
      StreamController<bool>.broadcast();

  /// 前台/后台状态流（true=前台，false=后台）
  ///
  /// 基于 _isFromAppPause 判断，过滤掉 inactive→resumed 的 transient 状态。
  /// 仅当 paused→resumed 完整经过时发送 true。
  ///
  /// ## 冷启动的那一次 true 只有首个订阅者收得到
  ///
  /// [listen] 时若 App 已处于 resumed，会补发一次 `true`（见 [listen]），
  /// 但控制它的 `_hasEverSentForeground` 是**全局**标志位：整个进程只补发一次
  /// （[cancel] 也不会复位它），之后创建的页面**永远等不到**这个初始事件。
  ///
  /// 因此不要用「收到过 foreground」来判断当前在不在前台——那是个事件流，
  /// 不是状态。要判断状态请直接读 [isForeground]，它同步读
  /// `WidgetsBinding.instance.lifecycleState`，任何时机都可用，
  /// 也不依赖有没有订阅过。
  Stream<bool> get stream {
    listen();
    return _streamController.stream;
  }

  /// 原始 [AppLifecycleState] 的广播源。**从不关闭**，见 [cancel]。
  final StreamController<AppLifecycleState> _lifecycleController =
      StreamController<AppLifecycleState>.broadcast();

  /// 原始 AppLifecycleState 流（不过滤，透传所有状态）
  Stream<AppLifecycleState> get lifecycle {
    listen();
    return _lifecycleController.stream;
  }

  /// 开始把系统生命周期事件转发到两条流上。幂等，重复调用是空操作。
  ///
  /// 由 [stream] / [lifecycle] 两个 getter 自动调用，通常无需手动调。
  /// [cancel] 之后可再次调用恢复转发，**已有的订阅者会继续收到事件**。
  void listen() {
    if (_hasListen) {
      return;
    }
    _hasListen = true;
    WidgetsBinding.instance.addObserver(this);

    // 冷启动时，Flutter 引擎可能已在 listen() 之前发出了 resumed 事件。
    // 通过 scheduleMicrotask 让 subscriber 有机会先 attach 到 stream，
    // 然后补发一个 foreground=true 事件。
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        !_hasEverSentForeground) {
      _hasEverSentForeground = true;
      scheduleMicrotask(() => _emitForeground(true));
    }
  }

  /// 停止转发系统生命周期事件，并复位内部的前后台判定状态。
  ///
  /// 幂等，且**不关闭两条流**：已有订阅者不会失效，再次 [listen] 即恢复转发。
  /// 这是有意的——底层的 `broadcast` controller 只持有订阅者列表，关掉它换不来
  /// 任何内存收益（页面自己的订阅由 `FlAppLifecycleDelegate` 在 `dispose` 中
  /// 释放），却会让**所有存活页面**的 App 生命周期回调静默失效：这是个全局单例，
  /// 一处调用就影响全部订阅者。
  ///
  /// 页面级的订阅释放不需要也不应该调用本方法。
  void cancel() {
    if (!_hasListen) {
      return;
    }
    _hasListen = false;
    _isFromAppPause = false;
    // **不**复位 _hasEverSentForeground：两条流不再关闭（见上），已有订阅者仍然
    // 在听。复位会让下一次 [listen] 满足「resumed 且没发过初始事件」的条件，
    // 给它们补发一次 App 从未离开过的 foreground=true——宿主在 onAppForeground
    // 里刷新列表 / 重校验登录态 / 恢复轮询就会被无故触发一次。
    // 那次补发只该在冷启动发生一次，语义见 [_hasEverSentForeground]。
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _emitLifecycle(state);
    _notifyObserver(state);
  }

  /// 两条 controller 都是 `final` 且从不关闭（见 [cancel]），因此这里不需要
  /// 判 `isClosed`——[cancel] 与 `removeObserver` / 微任务补发之间不存在
  /// 「关闭后再 add」的竞态。
  void _emitForeground(bool isForeground) {
    _streamController.add(isForeground);
  }

  void _emitLifecycle(AppLifecycleState state) {
    _lifecycleController.add(state);
  }

  /// AppLifecycleState 各状态调用时机
  ///
  /// ┌────────────────────┬──────────────────────────────────────────────┐
  /// │ 状态               │ 触发时机                                      │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ resumed            │ 应用可见且可响应用户输入。                     │
  /// │                    │ iOS: applicationDidBecomeActive               │
  /// │                    │ Android: Activity.onResume → onWindowFocusChanged(true) │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ inactive           │ 应用可见但不可响应输入（临时中断）。            │
  /// │                    │ iOS: applicationWillResignActive              │
  /// │                    │   - 电话来了 / 控制中心拉起 / App Switcher    │
  /// │                    │ Android: 多任务键 / 下拉通知栏                │
  /// │                    │ 典型序列: resumed → inactive → resumed (未离开App) │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ hidden             │ (Flutter 3.13+) 应用被隐藏但仍可能可见于       │
  /// │                    │ App Switcher。                                │
  /// │                    │ iOS: applicationDidEnterBackground →          │
  /// │                    │   UISceneLifecycleState background            │
  /// │                    │ Android: Activity.onStop (部分设备)           │
  /// │                    │ 典型序列: inactive → hidden → paused          │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ paused             │ 应用不可见（进入后台）。                       │
  /// │                    │ iOS: applicationDidEnterBackground            │
  /// │                    │ Android: Activity.onStop                      │
  /// │                    │ 此时应释放不可见的资源、暂停动画、停止定时器。  │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ detached           │ (Flutter 3.13+) 应用从宿主视图分离。           │
  /// │                    │ Android 特有：Activity 被销毁但 Engine 缓存存活 │
  /// │                    │ iOS: 通常不会触发，除非 FlutterEngine 被手动释放 │
  /// │                    │ 典型序列: paused → detached                   │
  /// │                    │ 此时必须释放所有 Activity 级别资源（Camera、   │
  /// │                    │ Sensor、MethodChannel 注册），因为 Engine 仍   │
  /// │                    │ 可能被复用于新的 Activity。                    │
  /// └────────────────────┴──────────────────────────────────────────────┘
  ///
  /// 状态机流转（Flutter 3.13+）:
  ///
  /// iOS:
  ///   resumed ←→ inactive ←→ hidden ←→ paused
  ///                              ↑ 从 App Switcher 返回时跳过 paused
  ///
  /// Android:
  ///   resumed ←→ inactive ←→ paused → detached
  ///                              ↑ 冷启动新 Activity 时从 detached 重建
  ///                              resumeDetached → [inactive → resumed]
  void _notifyObserver(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_isFromAppPause) {
          // 完整经历了 paused → ... → resumed，确认从后台返回
          _isFromAppPause = false;
          _hasEverSentForeground = true;
          _emitForeground(true);
        } else if (!_hasEverSentForeground) {
          // 冷启动首次 resumed（或 cancel→listen 后的首次 resumed），
          // 订阅者尚未收到初始 foreground 事件，补发。
          _hasEverSentForeground = true;
          _emitForeground(true);
        }
        // 若 _isFromAppPause == false && _hasEverSentForeground == true，
        // 说明只是 inactive → resumed 短暂中断，不触发 foreground 通知。
        break;
      case AppLifecycleState.hidden:
        // hidden 是 iOS 14+/Flutter 3.13+ 新增状态。
        // 介于 inactive 和 paused 之间，暂时不做前台/后台切换判断。
        break;
      case AppLifecycleState.inactive:
        // inactive 发生在前台短暂中断时（电话、通知栏）。
        // 不做前台/后台状态切换，等待后续是 resumed 还是 paused。
        break;
      case AppLifecycleState.paused:
        _isFromAppPause = true;
        _emitForeground(false);
        break;
      case AppLifecycleState.detached:
        // detached 时不重置 _isFromAppPause，保留 paused 标记
        // 以支持 Android Activity 销毁重建后 resumed 时能正确发送 foreground 事件。
        // 注意：不在此处发送 _streamController 事件，
        // 因为 detached 不改变"前台/后台"语义（已在 paused 时发送过 false）。
        break;
    }
  }
}
