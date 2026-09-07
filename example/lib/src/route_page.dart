import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// `FlPageRouteMixin` 的第一个页面：可以往上再压一层。
class RouteOnePage extends StatelessWidget {
  const RouteOnePage({super.key});

  @override
  Widget build(BuildContext context) => const _RouteDemoPage(
    name: 'RouteOnePage',
    hint: '只转发路由事件，不做幂等与补发：route 事件原样到达，弹窗与跳转的差异一目了然。',
    pushRoute: '/FlPageRouteMixin_two',
  );
}

/// `FlPageRouteMixin` 的第二个页面：观察被 pop 时的事件顺序。
class RouteTwoPage extends StatelessWidget {
  const RouteTwoPage({super.key});

  @override
  Widget build(BuildContext context) => const _RouteDemoPage(
    name: 'RouteTwoPage',
    hint: '返回上一页时，本页会依次收到 onRoutePause / onRouteStop 与退场动画事件。',
  );
}

/// 两个页面唯一的差别只是标题和「再压一层 / 返回」，其余完全一致。
class _RouteDemoPage extends StatefulWidget {
  const _RouteDemoPage({
    required this.name,
    required this.hint,
    this.pushRoute,
  });

  final String name;
  final String hint;

  /// 非空则展示「跳转」按钮，否则展示「返回」。
  final String? pushRoute;

  @override
  State<_RouteDemoPage> createState() => _RouteDemoPageState();
}

class _RouteDemoPageState extends State<_RouteDemoPage> with FlPageRouteMixin {
  late final _log = LifecycleLogController(name: widget.name);

  @override
  Widget build(BuildContext context) {
    final push = widget.pushRoute;
    return DemoScaffold(
      title: 'FlPageRouteMixin · ${widget.name}',
      hint: widget.hint,
      log: _log,
      actions: [
        DemoAction(
          icon: Icons.chat_bubble_outline,
          label: '弹窗',
          effect: 'onRoutePause',
          onTap: () => DemoOverlays.showAlert(context),
        ),
        DemoAction(
          icon: Icons.vertical_align_bottom,
          label: 'BottomSheet',
          effect: 'onRoutePause',
          onTap: () => DemoOverlays.showSheet(context),
        ),
        if (push != null)
          DemoAction(
            icon: Icons.arrow_forward,
            label: '跳转下一页',
            effect: 'onRouteStop',
            onTap: () => Navigator.of(context).pushNamed(push),
          )
        else
          DemoAction(
            icon: Icons.arrow_back,
            label: '返回',
            effect: 'stop → LeaveAnimEnd',
            onTap: () => Navigator.of(context).pop(),
          ),
      ],
    );
  }

  // FlPageRouteMixin 没有 onLifecycleStateChanged 那样的统一出口，
  // 所以这里逐个覆写、逐个记日志。
  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    super.onPageContextReady(routeName, arguments);
    _log.log('onPageContextReady', detail: 'route=$routeName');
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

  @override
  void onRouteStart() {
    super.onRouteStart();
    _log.log('onRouteStart');
  }

  @override
  void onRouteResume() {
    super.onRouteResume();
    _log.log('onRouteResume');
  }

  @override
  void onRoutePause() {
    super.onRoutePause();
    _log.log('onRoutePause');
  }

  @override
  void onRouteStop() {
    super.onRouteStop();
    _log.log('onRouteStop');
  }
}
