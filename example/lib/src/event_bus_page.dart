import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// 事件用普通类表示，靠类型区分，不需要注册或枚举。
class CounterEvent {
  const CounterEvent(this.from, this.value);

  /// 发布方，用来看清是谁发的。
  final String from;
  final int value;
}

/// `FlStateEventBusMixin` 演示页。
///
/// 两个要点：
/// 1. `observeEvent` 的订阅随 `dispose` 自动取消，不用自己存 `StreamSubscription`；
/// 2. 事件是**全局广播**的——跳到第二页后从那边发事件，本页虽然已经 stop，
///    照样会收到。返回后看本页日志即可验证。
class EventBusPage extends StatefulWidget {
  const EventBusPage({super.key});

  @override
  State<EventBusPage> createState() => _EventBusPageState();
}

class _EventBusPageState extends State<EventBusPage>
    with FlPageLifecycleMixin, DemoLogMixin, FlStateEventBusMixin {
  @override
  final log = LifecycleLogController(name: 'EventBusPage');

  int _sent = 0;

  @override
  void initState() {
    super.initState();
    // 不需要保存返回值，dispose 时会自动 cancel。
    observeEvent<CounterEvent>(
      (event) => log.log(
        '收到 CounterEvent',
        detail: '来自 ${event.from} · #${event.value}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FlStateEventBusMixin',
      hint:
          '订阅随 dispose 自动取消。事件是全局广播的——跳到第二页后从那边发事件，'
          '本页已经 stop 但照样会收到，返回后看日志即可验证。',
      log: log,
      actions: [
        DemoAction(
          icon: Icons.campaign_outlined,
          label: '发布事件',
          effect: 'dispatchEvent',
          onTap: () {
            _sent++;
            log.log('发布 CounterEvent', detail: '#$_sent');
            dispatchEvent(CounterEvent('第一页', _sent));
          },
        ),
        DemoAction(
          icon: Icons.arrow_forward,
          label: '跳转第二页',
          effect: '从那边发事件试试',
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const _SecondPage())),
        ),
      ],
    );
  }
}

/// 第二页：同样订阅并发布，用来验证跨页广播。
class _SecondPage extends StatefulWidget {
  const _SecondPage();

  @override
  State<_SecondPage> createState() => _SecondPageState();
}

class _SecondPageState extends State<_SecondPage>
    with FlPageLifecycleMixin, DemoLogMixin, FlStateEventBusMixin {
  @override
  final log = LifecycleLogController(name: 'EventBusPage/Second');

  int _sent = 0;

  @override
  void initState() {
    super.initState();
    observeEvent<CounterEvent>(
      (event) => log.log(
        '收到 CounterEvent',
        detail: '来自 ${event.from} · #${event.value}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FlStateEventBusMixin · 第二页',
      hint: '从这里发事件，第一页（已 stop）同样会收到。返回后对比两边的日志。',
      log: log,
      actions: [
        DemoAction(
          icon: Icons.campaign_outlined,
          label: '发布事件',
          effect: '两页都会收到',
          onTap: () {
            _sent++;
            log.log('发布 CounterEvent', detail: '#$_sent');
            dispatchEvent(CounterEvent('第二页', _sent));
          },
        ),
        DemoAction(
          icon: Icons.arrow_back,
          label: '返回',
          effect: '本页订阅随之解绑',
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
