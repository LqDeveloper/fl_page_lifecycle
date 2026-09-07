import 'package:flutter/material.dart';

import '../delegate/fl_app_lifecycle_delegate.dart';
import '../lifecycle/fl_lifecycle_manager.dart';

/// 只关心 **App 前后台 / [AppLifecycleState]** 的页面 mixin。
///
/// 订阅逻辑本身全部在 [FlAppLifecycleDelegate] 中，本 mixin 只做两件事：
/// 在 `initState` / `dispose` 中自动 attach / detach，并把委托的回调转成
/// 子类可覆写的模板方法。因此**不需要**手动调用任何初始化 / 释放方法。
///
/// 需要完整页面生命周期（start / resume / pause / stop 等）时用
/// `FlPageLifecycleMixin`，它已经内置了同一个委托，不要与本 mixin 叠加使用。
///
/// ```dart
/// class _VideoPageState extends State<VideoPage> with FlAppLifecycleMixin {
///   @override
///   void onAppBackground() => _player.pause();
///
///   @override
///   void onAppForeground() => _player.play();
/// }
/// ```
mixin FlAppLifecycleMixin<T extends StatefulWidget> on State<T> {
  /// App 生命周期相关处理（前后台切换、AppLifecycleState）全部委托给它。
  late final FlAppLifecycleDelegate _appDelegate = FlAppLifecycleDelegate(
    onForeground: onAppForeground,
    onBackground: onAppBackground,
    onStateChanged: appLifecycleChanged,
  );

  /// App 当前是否位于前台。任何时机都可读。
  bool get isForeground => _appDelegate.isForeground;

  /// 是否已订阅，`dispose` 之后为 false。
  bool get hasInit => _appDelegate.isAttached;

  @override
  void initState() {
    super.initState();
    _appDelegate.attach();
  }

  @override
  void dispose() {
    _appDelegate.detach();
    super.dispose();
  }

  /// App 切换到前台（由 [FlLifecycleManager] 判定，过滤了 transient 中断）。
  @protected
  void onAppForeground() {}

  /// App 切换到后台（由 [FlLifecycleManager] 判定）。
  @protected
  void onAppBackground() {}

  /// 原始的 [AppLifecycleState] 变化。
  @protected
  void appLifecycleChanged(AppLifecycleState state) {}
}
