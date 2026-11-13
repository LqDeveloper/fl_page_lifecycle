import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// 宿主回调抛异常时的两条保证：**异常走 [FlutterError]，且不牵连别的订阅者**。
///
/// 这里盯的是两处「由 `StreamSubscription` 直接驱动」的回调——App 前后台
/// （`FlAppLifecycleDelegate`）与事件总线（`FlStateEventBusMixin`）。它们和
/// 本库其余回调不同：调用方是流，不是页面的调用链，所以「别的订阅者不受影响」
/// 本来就由广播流保证，**包 `FlLifecycleGuard` 是为了上报通道**。
///
/// 不包的话异常会作为未捕获的异步错误交给 zone，`tester.takeException()` 拿到的
/// 是 null 而测试照样失败——正是下面每个用例里那句 `takeException` 断言在盯的
/// 东西。它一旦返回 null，就说明某处的 guard 被摘掉了。
void main() {
  final log = <String>[];

  setUp(() {
    log.clear();
    FlLifecycleManager.instance.listen();
  });

  tearDown(() async {
    FlLifecycleManager.instance.cancel();
    await FlGlobalEventBus.destroy();
  });

  Future<void> toBackground(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
  }

  Future<void> toForeground(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  group('App 前后台回调', () {
    testWidgets('onAppForeground 抛异常：上报给 FlutterError，后一个页面照常收到', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              _AppPage('A', log, boomOnForeground: true),
              _AppPage('B', log),
            ],
          ),
        ),
      );

      await toBackground(tester);
      await toForeground(tester);

      expect(tester.takeException(), isStateError);
      expect(log, <String>['A:bg', 'B:bg', 'A:fg', 'B:fg']);
    });

    testWidgets('appLifecycleChanged 抛异常：不影响同一页的前后台回调', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: _AppPage('A', log, boomOnRawState: true)),
      );

      await toBackground(tester);

      expect(tester.takeException(), isStateError);
      // raw 抛了，但 bg 走的是另一条流的订阅，照常发出。
      expect(log, <String>['A:raw', 'A:bg']);
    });
  });

  group('事件总线订阅回调', () {
    testWidgets('一个订阅者抛异常：上报给 FlutterError，另一个照常收到', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [_BusPage('A', log, boom: true), _BusPage('B', log)],
          ),
        ),
      );

      FlGlobalEventBus.dispatchEvent<String>('ping');
      await tester.pump();

      expect(tester.takeException(), isStateError);
      expect(log, <String>['A:ping', 'B:ping']);
    });
  });

  group('FlPageLifecycleMixin.appLifecycleChanged', () {
    testWidgets('抛异常：onAppBackground 与统一出口都照常发出', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
          home: _FullPage(log),
        ),
      );
      await tester.pumpAndSettle();
      log.clear();

      await toBackground(tester);

      expect(tester.takeException(), isStateError);
      expect(log, <String>[
        // super 先把 paused 翻译成 onAppPause 发出去，随后覆写里才抛。
        'S:${FlLifecycleState.onAppPause}',
        'raw',
        // 这一条来自另一条流的订阅，不受上面那次抛出影响。
        'bg',
        'S:${FlLifecycleState.onAppBackground}',
      ]);
    });
  });
}

class _AppPage extends StatefulWidget {
  const _AppPage(
    this.name,
    this.log, {
    this.boomOnForeground = false,
    this.boomOnRawState = false,
  });

  final String name;
  final List<String> log;
  final bool boomOnForeground;
  final bool boomOnRawState;

  @override
  State<_AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<_AppPage> with FlAppLifecycleMixin {
  @override
  void onAppForeground() {
    widget.log.add('${widget.name}:fg');
    if (widget.boomOnForeground) {
      throw StateError('boom-${widget.name}');
    }
  }

  @override
  void onAppBackground() => widget.log.add('${widget.name}:bg');

  @override
  void appLifecycleChanged(AppLifecycleState state) {
    if (!widget.boomOnRawState) {
      return;
    }
    widget.log.add('${widget.name}:raw');
    throw StateError('boom-raw-${widget.name}');
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _BusPage extends StatefulWidget {
  const _BusPage(this.name, this.log, {this.boom = false});

  final String name;
  final List<String> log;
  final bool boom;

  @override
  State<_BusPage> createState() => _BusPageState();
}

class _BusPageState extends State<_BusPage> with FlStateEventBusMixin {
  @override
  void initState() {
    super.initState();
    observeEvent<String>(_handle);
  }

  void _handle(String event) {
    widget.log.add('${widget.name}:$event');
    if (widget.boom) {
      throw StateError('boom-${widget.name}');
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _FullPage extends StatefulWidget {
  const _FullPage(this.log);

  final List<String> log;

  @override
  State<_FullPage> createState() => _FullPageState();
}

class _FullPageState extends State<_FullPage> with FlPageLifecycleMixin {
  @override
  bool get observeAppLifecycle => true;

  @override
  void appLifecycleChanged(AppLifecycleState state) {
    super.appLifecycleChanged(state);
    widget.log.add('raw');
    throw StateError('boom-raw');
  }

  @override
  void onAppBackground() => widget.log.add('bg');

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);
    widget.log.add('S:$state');
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
