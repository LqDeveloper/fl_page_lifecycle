import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// `FlPageLifecycleView` 示例：不混入任何 mixin，事件通过回调拿到。
///
/// 本页 State 里**没有** `FlPageLifecycleMixin`——所有事件都来自
/// [FlPageLifecycleView] 的回调。State 存在的唯一理由是持有日志控制器，
/// 真实业务里被观测的页面可以是纯 `StatelessWidget`。
class LifecycleViewPage extends StatefulWidget {
  const LifecycleViewPage({super.key});

  @override
  State<LifecycleViewPage> createState() => _LifecycleViewPageState();
}

class _LifecycleViewPageState extends State<LifecycleViewPage> {
  final log = LifecycleLogController(name: 'LifecycleViewPage');

  @override
  void dispose() {
    log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // child 被原样返回，不会多出布局节点，所以可以套在任意位置。
    return FlPageLifecycleView(
      onStateChanged: (context, state) => log.log(state.name),
      // 注意回调名是 onRouteParam，不是 onContextReady。
      onRouteParam: (context, routeName, arguments) =>
          log.log('onRouteParam', detail: 'name=$routeName args=$arguments'),
      child: DemoScaffold(
        title: 'FlPageLifecycleView',
        hint: '页面本身没有混入 mixin，事件全部来自 FlPageLifecycleView 的回调。',
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
            onTap: () =>
                Navigator.of(context).pushNamed('/FlPageRouteMixin_two'),
          ),
          DemoAction(
            icon: Icons.data_object,
            label: '带参数再开一层',
            effect: 'onRouteParam 带 args',
            onTap: () => Navigator.of(context).pushNamed(
              '/FlPageLifecycleView',
              arguments: const {'from': 'LifecycleViewPage'},
            ),
          ),
        ],
      ),
    );
  }
}
