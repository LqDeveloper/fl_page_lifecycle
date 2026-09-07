import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// `FlPageLifecycleView` 示例：不混入任何 mixin，事件通过回调拿到。
///
/// 本页 State 里**没有** `FlPageLifecycleMixin`——所有事件都来自
/// [FlPageLifecycleView] 的回调。State 存在的唯一理由是持有日志控制器，
/// 真实业务里被观测的页面可以是纯 `StatelessWidget`。
///
/// 顺带演示第二种用法：`FlPageLifecycleView` 也可以只包住页面里的一小块子树
/// （下方那张卡片），用来给单个组件做曝光统计。两个 View 各自独立订阅，
/// 因此日志里会看到 `page` 与 `card` 两组事件。
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
      onStateChanged: (context, state) => log.log(state.name, tag: 'page'),
      // 注意回调名是 onRouteParam，不是 onContextReady。
      onRouteParam: (context, routeName, arguments) => log.log(
        'onRouteParam',
        detail: 'name=$routeName args=$arguments',
        tag: 'page',
      ),
      child: DemoScaffold(
        title: 'FlPageLifecycleView',
        hint:
            '页面本身没有混入 mixin，事件全部来自回调。'
            '日志里 page 是整页的 View，card 是只包住下方卡片的那个 View。',
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
        logTitle: '事件日志（page / card 两个 View）',
        footer: ImpressionCard(log: log),
      ),
    );
  }
}

/// 只观测一个子树：给单张卡片做曝光统计时就是这么用的。
///
/// 它和整页那个 [FlPageLifecycleView] 互不相干，各自持有一份订阅——
/// 一页放几个是免费的，长列表里每项都放一个则要先算清成本。
class ImpressionCard extends StatelessWidget {
  const ImpressionCard({super.key, required this.log});

  final LifecycleLogController log;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FlPageLifecycleView(
      onStateChanged: (context, state) {
        // 只关心「这张卡片可交互了」这一个时刻。
        if (state.isPageResume) log.log('曝光', tag: 'card');
        if (state.isPagePause) log.log('曝光结束', tag: 'card');
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '被单独观测的卡片：它自己也是一个 FlPageLifecycleView',
          style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12),
        ),
      ),
    );
  }
}
