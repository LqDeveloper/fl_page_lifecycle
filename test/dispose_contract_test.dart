import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
import 'package:fl_page_lifecycle/src/lifecycle/lifecycle_route_aware.dart';

// 内部类型：用来构造一个会抛异常的订阅者，直接挂到路由上。

/// `FlPageLifecycleMixin` 与 `FlPageRouteMixin` 的 dispose 共享同一条时序契约：
///
/// **宿主回调是外部代码，随时可能抛；资源释放与 `super.dispose()` 一次都不能少。**
///
/// 两个 mixin 各自声明一份回调面是有意设计（幂等契约不同，合并会把三套保证压成
/// 一套），代价是这类跨 mixin 的不变量容易只在其中一处被改对——历史上就分叉过一次：
/// `FlPageRouteMixin` 先释放再回调，`FlPageLifecycleMixin` 却把释放夹在两组回调
/// 中间，宿主一抛异常就跳过 `_routeDelegate.detach()`，`FlRouteObserver` 继续持有
/// `State` 的强引用。
///
/// 所以这组用例是**对拍**：同一个断言对两个 mixin 各跑一遍。改动任一处 dispose
/// 的顺序，这里会立刻红。
void main() {
  group('dispose 时宿主回调抛异常，不能带走资源释放', () {
    testWidgets('FlPageLifecycleMixin：onPageStop 抛异常后路由仍被解绑', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
          home: const _ThrowOnStopPage(),
        ),
      );

      final state = _ThrowOnStopPage.lastState!;
      expect(state.routeName, '/', reason: '前置条件：页面已挂到 home 路由上');

      // 换掉整棵树，触发页面 dispose。
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      expect(
        tester.takeException(),
        isA<StateError>(),
        reason: 'finally 不该吞掉宿主的异常，它仍要照常上报',
      );
      // routeName 读的是委托持有的 ModalRoute，detach() 会把它置空。
      // 这里若非 null，说明 detach 被那个异常带走了——FlRouteObserver 的订阅表
      // 会一直持有这个 State，整棵子树无法回收。
      expect(
        state.routeName,
        isNull,
        reason: '宿主回调抛异常，_routeDelegate.detach() 仍必须执行',
      );
    });

    testWidgets('FlPageRouteMixin：onRouteStop 抛异常后路由仍被解绑', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
          home: const _ThrowOnRouteStopPage(),
        ),
      );

      final state = _ThrowOnRouteStopPage.lastState!;
      expect(state.hasRoute, isTrue, reason: '前置条件：页面已挂到 home 路由上');

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      expect(tester.takeException(), isA<StateError>());
      expect(
        state.hasRoute,
        isFalse,
        reason: '宿主回调抛异常，_routeDelegate.detach() 仍必须执行',
      );
    });
  });

  group('一个回调抛异常，不能带走调用链上后续的回调', () {
    testWidgets('FlPageLifecycleMixin：onPageStart 抛异常，onPageResume 仍然发出', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
          home: const _ThrowOnStartPage(),
        ),
      );

      final state = _ThrowOnStartPage.lastState!;
      expect(tester.takeException(), isA<StateError>());
      // onPageStart 抛出前 _hasAppeared 已置 true，这一步漏了就再也补不回来。
      expect(
        state.events,
        containsAllInOrder(<String>['onPageStart', 'onPageResume']),
        reason: 'start 之后必跟 resume 是本库的语义保证，不该被宿主异常击穿',
      );
      // 统一出口是 FlPageLifecycleView / FlPageControllerMixin 唯一的事件来源，
      // 模板回调抛异常不该让它收不到这个事件。
      expect(state.states, contains(FlLifecycleState.onPageStart));
      expect(state.states, contains(FlLifecycleState.onPageResume));
    });

    testWidgets('FlPageLifecycleMixin：onPageInit 抛异常，首帧回调链仍然建立', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
          home: const _ThrowOnInitPage(),
        ),
      );

      final state = _ThrowOnInitPage.lastState!;
      expect(tester.takeException(), isA<StateError>());
      // 这一条最致命：onPageInit 抛异常若把 addPostFrameCallback 的登记带走，
      // 该页面此后**整个生命周期**都收不到 postFrame / start / resume。
      expect(
        state.events,
        containsAllInOrder(<String>[
          'onPagePostFrame',
          'onPageStart',
          'onPageResume',
        ]),
      );
    });

    testWidgets('FlRouteObserver：一个订阅者抛异常，下层页面仍收到 start', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
          home: const _RecordingPage(),
        ),
      );
      final below = _RecordingPage.lastState!;

      final routeB = MaterialPageRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      unawaited(navKey.currentState!.push(routeB));
      await tester.pumpAndSettle();

      // 往被 pop 的那个路由上挂一个必抛的订阅者。它排在通知循环里，
      // 不 guard 的话循环会当场中断，循环之后「通知下层页面」的整段都不会执行。
      final aware = _ThrowingRouteAware();
      FlRouteObserver.instance.subscribe(routeB, aware);
      addTearDown(() => FlRouteObserver.instance.unsubscribe(routeB, aware));

      below.events.clear();
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(aware.called, isTrue, reason: '前置条件：抛异常的订阅者确实被通知到了');
      expect(tester.takeException(), isA<StateError>());
      expect(
        below.events,
        contains('onPageStart'),
        reason: '同一批里一个订阅者抛异常，不该让下层页面永久停在 stopped',
      );
    });
  });
}

/// 只记录事件、从不抛异常的页面，用作「下层页面」。
class _RecordingPage extends StatefulWidget {
  const _RecordingPage();

  static _RecordingPageState? lastState;

  @override
  State<_RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<_RecordingPage>
    with FlPageLifecycleMixin {
  final List<String> events = <String>[];

  @override
  void initState() {
    super.initState();
    _RecordingPage.lastState = this;
  }

  @override
  void onPageStart() => events.add('onPageStart');

  @override
  void onPageStop() => events.add('onPageStop');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 直接实现内部的 [LifecycleRouteAware]，收到任何路由事件都抛异常。
class _ThrowingRouteAware implements LifecycleRouteAware {
  bool called = false;

  Never _boom() {
    called = true;
    throw StateError('订阅者在路由回调中抛了异常');
  }

  @override
  void routePageStart() => _boom();

  @override
  void routePageResume() => _boom();

  @override
  void routePagePause() => _boom();

  @override
  void routePageStop() => _boom();
}

/// 在 `onPageStart` 中抛异常，用来验证 `onPageResume` 不被带走。
class _ThrowOnStartPage extends StatefulWidget {
  const _ThrowOnStartPage();

  static _ThrowOnStartPageState? lastState;

  @override
  State<_ThrowOnStartPage> createState() => _ThrowOnStartPageState();
}

class _ThrowOnStartPageState extends State<_ThrowOnStartPage>
    with FlPageLifecycleMixin {
  final List<String> events = <String>[];
  final List<FlLifecycleState> states = <FlLifecycleState>[];

  @override
  void initState() {
    super.initState();
    _ThrowOnStartPage.lastState = this;
  }

  @override
  void onPageStart() {
    events.add('onPageStart');
    throw StateError('宿主在 onPageStart 中抛了异常');
  }

  @override
  void onPageResume() => events.add('onPageResume');

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);
    states.add(state);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 在 `onPageInit` 中抛异常，用来验证首帧回调的登记不被带走。
class _ThrowOnInitPage extends StatefulWidget {
  const _ThrowOnInitPage();

  static _ThrowOnInitPageState? lastState;

  @override
  State<_ThrowOnInitPage> createState() => _ThrowOnInitPageState();
}

class _ThrowOnInitPageState extends State<_ThrowOnInitPage>
    with FlPageLifecycleMixin {
  final List<String> events = <String>[];

  @override
  void initState() {
    super.initState();
    _ThrowOnInitPage.lastState = this;
  }

  @override
  void onPageInit() => throw StateError('宿主在 onPageInit 中抛了异常');

  @override
  void onPagePostFrame() => events.add('onPagePostFrame');

  @override
  void onPageStart() => events.add('onPageStart');

  @override
  void onPageResume() => events.add('onPageResume');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 在 `onPageStop`（dispose 期间发出）中抛异常的页面。
class _ThrowOnStopPage extends StatefulWidget {
  const _ThrowOnStopPage();

  /// 供用例在 dispose **之后**仍能读到 State——`GlobalKey.currentState`
  /// 在元素卸载后就取不到了。
  static _ThrowOnStopPageState? lastState;

  @override
  State<_ThrowOnStopPage> createState() => _ThrowOnStopPageState();
}

class _ThrowOnStopPageState extends State<_ThrowOnStopPage>
    with FlPageLifecycleMixin {
  @override
  void initState() {
    super.initState();
    _ThrowOnStopPage.lastState = this;
  }

  @override
  void onPageStop() => throw StateError('宿主在 onPageStop 中抛了异常');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 在 `onRouteStop`（dispose 期间发出）中抛异常的页面。
class _ThrowOnRouteStopPage extends StatefulWidget {
  const _ThrowOnRouteStopPage();

  static _ThrowOnRouteStopPageState? lastState;

  @override
  State<_ThrowOnRouteStopPage> createState() => _ThrowOnRouteStopPageState();
}

class _ThrowOnRouteStopPageState extends State<_ThrowOnRouteStopPage>
    with FlPageRouteMixin {
  @override
  void initState() {
    super.initState();
    _ThrowOnRouteStopPage.lastState = this;
  }

  @override
  void onRouteStop() => throw StateError('宿主在 onRouteStop 中抛了异常');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
