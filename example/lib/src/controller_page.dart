import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// `FlPageControllerMixin` 示例：生命周期送进 Controller / ViewModel。
///
/// 要点是 [FlPageControllerMixin] **不订阅任何东西**——它只是一个入口加一组
/// 模板回调，事件必须由页面转发进来。所以页面里有两处转发，缺一个 Controller
/// 就收不到东西：
///
/// 1. 页面的 `onLifecycleStateChanged` → Controller 的 `onLifecycleChanged`
/// 2. 页面的 `onPageContextReady` → Controller 的 `setupRouteInfo`
///
/// 日志里 `page` 是页面 mixin 发出的，`controller` 是 Controller 收到的，
/// 两组一一对应就说明转发通了。
class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});

  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage>
    with FlPageLifecycleMixin, DemoLogMixin {
  @override
  final log = LifecycleLogController(name: 'ControllerPage');

  @override
  String? get logTag => 'page';

  late final DemoController _controller = DemoController(log: log);

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state); // 必须调 super
    // 转发之一：把 18 个事件原样交给 Controller。
    _controller.onLifecycleChanged(state, context: context);
  }

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    // 转发之二：路由信息得单独喂，Controller 那边的 onPageContextReady
    // 参数是 BuildContext? 而不是 (routeName, arguments)。
    _controller.setupRouteInfo(routeName, arguments);
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FlPageControllerMixin',
      hint:
          'Controller 自己不订阅任何东西，事件靠页面转发。'
          '日志里 page 与 controller 两组一一对应，说明转发通了。',
      log: log,
      actions: [
        DemoAction(
          icon: Icons.chat_bubble_outline,
          label: '弹窗',
          effect: 'pause → resume',
          onTap: () => DemoOverlays.showAlert(context),
        ),
        DemoAction(
          icon: Icons.arrow_forward,
          label: '跳转下一页',
          effect: 'pause → stop → start',
          onTap: () => Navigator.of(context).pushNamed('/FlPageRouteMixin_two'),
        ),
        DemoAction(
          icon: Icons.info_outline,
          label: '读 Controller 状态',
          effect: 'lifecycleState 等',
          onTap: _controller.dumpState,
        ),
      ],
      logTitle: '事件日志（page / controller 两侧）',
    );
  }
}

/// 一个普通类，不依赖任何状态管理库。
///
/// [FlPageControllerMixin] 没有 `on` 约束，所以 Presenter / ViewModel / Service
/// 都能混入；也因为它不持有订阅，所以没有 `dispose`——自己的资源在
/// [onPageDispose] 里放。
class DemoController with FlPageControllerMixin {
  DemoController({required this.log});

  final LifecycleLogController log;

  Timer? _poll;

  /// 统一出口：先调 super 缓存状态，再记一条日志。
  @override
  void onLifecycleChanged(FlLifecycleState state, {BuildContext? context}) {
    super.onLifecycleChanged(state, context: context);
    log.log(state.name, tag: 'controller');
  }

  /// 注意签名：这里是 `BuildContext?`，不是页面 mixin 上的
  /// `(String? routeName, Object? arguments)`。路由信息读 [routeName] /
  /// [arguments]（由页面的 `setupRouteInfo` 喂进来）。
  @override
  void onPageContextReady(BuildContext? context) {
    log.log(
      '拿到路由信息',
      detail: 'name=$routeName args=$arguments',
      tag: 'controller',
    );
  }

  @override
  void onPageResume() {
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      log.log('轮询一次', tag: 'controller');
    });
    log.log('轮询已启动', tag: 'controller');
  }

  @override
  void onPagePause() {
    _poll?.cancel();
    _poll = null;
    log.log('轮询已停止', tag: 'controller');
  }

  /// Controller 没有 dispose，收尾放这里。
  @override
  void onPageDispose() {
    _poll?.cancel();
    _poll = null;
  }

  /// 演示随时可读的那几个 getter。
  void dumpState() {
    log.log(
      '当前状态',
      detail:
          'lifecycleState=${lifecycleState.name} '
          'isPageResume=$isPageResume isForeground=$isForeground',
      tag: 'controller',
    );
  }
}
