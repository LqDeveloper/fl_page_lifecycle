import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

class PageLifecyclePage extends StatefulWidget {
  const PageLifecyclePage({super.key});

  @override
  State<PageLifecyclePage> createState() => _PageLifecyclePageState();
}

class _PageLifecyclePageState extends State<PageLifecyclePage>
    with FlPageLifecycleMixin, DemoLogMixin {
  @override
  final log = LifecycleLogController(name: 'PageLifecyclePage');

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FlPageLifecycleMixin',
      hint: '完整可见性状态机。对比三种遮挡方式：弹窗只发 pause，跳转会发 pause + stop。',
      log: log,
      actions: [
        DemoAction(
          icon: Icons.chat_bubble_outline,
          label: '弹窗',
          effect: 'pause → resume',
          onTap: () => DemoOverlays.showAlert(context),
        ),
        DemoAction(
          icon: Icons.vertical_align_bottom,
          label: 'BottomSheet',
          effect: 'pause → resume',
          onTap: () => DemoOverlays.showSheet(context),
        ),
        DemoAction(
          icon: Icons.arrow_forward,
          label: '跳转下一页',
          effect: 'pause → stop → start',
          onTap: () => Navigator.of(context).pushNamed('/FlPageRouteMixin_two'),
        ),
      ],
    );
  }
}
