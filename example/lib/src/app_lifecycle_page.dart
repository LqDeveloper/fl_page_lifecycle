import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

class AppLifecyclePage extends StatefulWidget {
  const AppLifecyclePage({super.key});

  @override
  State<AppLifecyclePage> createState() => _AppLifecyclePageState();
}

/// 只混入 `FlAppLifecycleMixin`：本页只关心 App 前后台，不需要页面可见性那一套。
class _AppLifecyclePageState extends State<AppLifecyclePage>
    with FlAppLifecycleMixin {
  final _log = LifecycleLogController(name: 'AppLifecyclePage');

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FlAppLifecycleMixin',
      hint:
          '把 App 切到后台再切回来看事件。下拉通知栏这类短暂中断只会产生 '
          'inactive，不会触发 foreground / background。',
      log: _log,
      actions: [
        DemoAction(
          icon: Icons.info_outline,
          label: '当前状态',
          effect: '读取 isForeground',
          onTap: () =>
              _log.log('isForeground', detail: isForeground.toString()),
        ),
      ],
    );
  }

  @override
  void onAppForeground() {
    super.onAppForeground();
    _log.log('onAppForeground');
  }

  @override
  void onAppBackground() {
    super.onAppBackground();
    _log.log('onAppBackground');
  }

  @override
  void appLifecycleChanged(AppLifecycleState state) {
    super.appLifecycleChanged(state);
    _log.log('appLifecycleChanged', detail: state.name);
  }
}
