import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

class AnimationPage extends StatefulWidget {
  const AnimationPage({super.key});

  @override
  State<AnimationPage> createState() => _AnimationPageState();
}

class _AnimationPageState extends State<AnimationPage>
    with FlAnimationLifecycleMixin {
  final _log = LifecycleLogController(name: 'AnimationPage');

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FlAnimationLifecycleMixin',
      hint:
          '只关心转场动画。iOS 上从左边缘往右拖再松手放弃返回，可以看到 '
          'Leave 动画折返成 Enter 动画。',
      log: _log,
      actions: [
        DemoAction(
          icon: Icons.arrow_back,
          label: '返回',
          effect: 'LeaveStart → LeaveEnd',
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  @override
  void onPageEnterAnimationStart() {
    super.onPageEnterAnimationStart();
    _log.log('onPageEnterAnimationStart');
  }

  @override
  void onPageEnterAnimationEnd() {
    super.onPageEnterAnimationEnd();
    _log.log('onPageEnterAnimationEnd');
  }

  @override
  void onPageLeaveAnimationStart() {
    super.onPageLeaveAnimationStart();
    _log.log('onPageLeaveAnimationStart');
  }

  @override
  void onPageLeaveAnimationEnd() {
    super.onPageLeaveAnimationEnd();
    _log.log('onPageLeaveAnimationEnd');
  }
}
