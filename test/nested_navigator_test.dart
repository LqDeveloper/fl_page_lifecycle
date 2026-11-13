import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// `FlRouteObserverProxy` 的契约：让嵌套 `Navigator` 里的页面拿到与根
/// `Navigator` 完全一致的生命周期。
///
/// 存在的理由由第一组用例钉住：`FlRouteObserver` 是单例，而 Flutter 的
/// `Navigator.initState` 里有 `assert(observer.navigator == null)`，同一个实例
/// 挂不上第二个 `Navigator`。
///
/// 后面几组逐个覆盖 proxy 转发的四个方法——漏掉任意一个，嵌套 `Navigator`
/// 都会静默少一种事件且不报错，所以每个方法各有一条用例。
void main() {
  group('为什么需要 proxy', () {
    testWidgets('同一个 FlRouteObserver 挂两个存活的 Navigator 会触发 Flutter 断言', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
          home: Navigator(
            // FlRouteObserver() 是 factory，返回的还是同一个单例。
            observers: <NavigatorObserver>[FlRouteObserver()],
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => const _Probe('inner')),
          ),
        ),
      );

      expect(
        tester.takeException(),
        isAssertionError,
        reason: 'NavigatorObserver 实例同一时刻只能绑定一个 NavigatorState',
      );
    });

    testWidgets('换成 proxy 后两层 Navigator 可以共存', (tester) async {
      await tester.pumpWidget(_nestedApp());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_Probe.logOf('inner-A'), <String>['start', 'resume']);
    });
  });

  group('proxy 转发 didPush / didPop', () {
    testWidgets('内层 push 普通页：下层 stop，新页 start', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_nestedApp(nestedKey: nav));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _Probe('inner-B')),
        ),
      );
      await tester.pumpAndSettle();

      expect(_Probe.logOf('inner-A'), <String>['pause', 'stop']);
      expect(_Probe.logOf('inner-B'), <String>['start', 'resume']);
    });

    testWidgets('内层 pop：下层重新 start', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_nestedApp(nestedKey: nav));
      await tester.pumpAndSettle();

      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _Probe('inner-B')),
        ),
      );
      await tester.pumpAndSettle();

      _Probe.clearAll();
      nav.currentState!.pop();
      await tester.pumpAndSettle();

      expect(_Probe.logOf('inner-A'), <String>['start', 'resume']);
      expect(_Probe.logOf('inner-B'), <String>['pause', 'stop']);
    });

    testWidgets('内层弹窗只 pause 不 stop，关闭只补 resume', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_nestedApp(nestedKey: nav));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      unawaited(
        showDialog<void>(
          context: nav.currentContext!,
          // 默认是 true，弹窗会跑到根 Navigator 上去——那样内层页什么都收不到。
          useRootNavigator: false,
          builder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();
      expect(_Probe.logOf('inner-A'), <String>[
        'pause',
      ], reason: '弹窗是 PopupRoute，下层仍然可见');

      _Probe.clearAll();
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_Probe.logOf('inner-A'), <String>['resume']);
    });
  });

  group('proxy 转发 didRemove / didReplace', () {
    testWidgets('内层 removeRoute：被移除页 stop，露出来的那层 start', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_nestedApp(nestedKey: nav));
      await tester.pumpAndSettle();

      final routeB = MaterialPageRoute<void>(
        builder: (_) => const _Probe('inner-B'),
      );
      unawaited(nav.currentState!.push(routeB));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      nav.currentState!.removeRoute(routeB);
      await tester.pumpAndSettle();

      expect(_Probe.logOf('inner-B'), <String>['pause', 'stop']);
      expect(_Probe.logOf('inner-A'), <String>['start', 'resume']);
    });

    testWidgets('内层 pushReplacement：被替换页 stop', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_nestedApp(nestedKey: nav));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      unawaited(
        nav.currentState!.pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const _Probe('inner-C')),
        ),
      );
      await tester.pumpAndSettle();

      expect(_Probe.logOf('inner-A'), <String>[
        'pause',
        'stop',
      ], reason: 'didReplace 没转发的话，被替换页会永远停在 appeared');
      expect(_Probe.logOf('inner-C'), <String>['start', 'resume']);
    });
  });

  group('内外层互不干扰', () {
    testWidgets('外层 push 盖住整个内层：内层页收不到 stop——只跟本层，proxy 不改变这一点', (
      tester,
    ) async {
      final root = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_nestedApp(rootKey: root));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      unawaited(
        root.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _Probe('outer')),
        ),
      );
      await tester.pumpAndSettle();

      // 这是本库的已知语义，不是 proxy 的缺陷：页面订阅的是**自己那条**
      // ModalRoute，外层把整个内层 Navigator 盖住时，内层那条路由本身没有任何
      // 变化，于是内层页无从知情。`FlPageLifecycleMixin.isCurrent` 的文档里对
      // 同一件事有明确说明（"内层栈顶页即使整个内层 Navigator 被外层路由盖住，
      // 这里依然是 true"）。
      //
      // 需要「外层一盖住、内层就暂停」的，把内层容器那一层也挂上
      // FlPageLifecycleView，由它把外层的 stop 转发下去。
      expect(
        _Probe.logOf('inner-A'),
        isEmpty,
        reason: '生命周期只跟本层路由栈走；这条用例钉住这个边界，改了要先想清楚',
      );

      _Probe.clearAll();
      root.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_Probe.logOf('inner-A'), isEmpty, reason: '同上，揭开时也不补发');
    });

    testWidgets('页面销毁后订阅表不残留', (tester) async {
      await tester.pumpWidget(_nestedApp());
      await tester.pumpAndSettle();

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(_Probe.logOf('inner-A'), contains('stop'));
    });
  });

  // PageView 的每一页装一条嵌套栈，是 StatefulShellRoute / 手写 tab 的常见形状。
  // `example/lib/src/nested_navigator_page.dart` 教的就是这个结构，这里钉住它。
  group('PageView 装嵌套栈：observePageIndex 挂在容器层', () {
    testWidgets('滑动时容器层 start/stop，栈内页不受影响', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_pageViewOfStacks(controller));
      await tester.pumpAndSettle();
      expect(_Probe.logOf('A容器'), <String>['start', 'resume']);
      expect(_Probe.logOf('A#0'), <String>['start', 'resume']);

      _Probe.clearAll();
      controller.jumpToPage(1);
      await tester.pumpAndSettle();

      expect(_Probe.logOf('A容器'), <String>['pause', 'stop']);
      expect(_Probe.logOf('B容器'), <String>['start', 'resume']);
      expect(_Probe.logOf('A#0'), isEmpty, reason: '栈内页跟的是本栈路由，整条栈被划走它并不知情');
    });

    testWidgets('栈内 push 后滑走再滑回：被盖住的那页不能收到假 start', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      final navA = GlobalKey<NavigatorState>();

      await tester.pumpWidget(_pageViewOfStacks(controller, navA: navA));
      await tester.pumpAndSettle();

      unawaited(
        navA.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _Probe('A#1')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _Probe.logOf('A#0'),
        contains('stop'),
        reason: '前置条件：A#0 被 A#1 盖住',
      );

      controller.jumpToPage(1);
      await tester.pumpAndSettle();

      _Probe.clearAll();
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      // 这条是本组的重点。把 observePageIndex 挂到栈内页面上时，滑回来会让
      // A#0 与 A#1 一起收到 start——PageView 的可见性推送不查路由状态，而两页
      // 在划走时都被 stop 过，_hasAppeared 挡不住。挂在容器层就没有这个问题。
      expect(_Probe.logOf('A#0'), isEmpty, reason: 'A#0 仍被 A#1 盖着，滑回来不该让它重新可见');
      expect(_Probe.logOf('A容器'), <String>['start', 'resume']);
    });
  });

  // 栈内页面自己也开 observePageIndex：容器一不显示，栈里的当前页跟着走不显示
  // 逻辑；容器重新显示时，只有栈顶那页回来。
  group('子栈跟随容器可见性', () {
    testWidgets('容器被划走：栈内当前页 pause+stop', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _pageViewOfStacks(controller, stackPagesObserve: true),
      );
      await tester.pumpAndSettle();
      expect(_Probe.logOf('A#0'), <String>['start', 'resume']);

      _Probe.clearAll();
      controller.jumpToPage(1);
      await tester.pumpAndSettle();

      expect(_Probe.logOf('A#0'), <String>[
        'pause',
        'stop',
      ], reason: '容器不显示了，子栈里的页面也要走不显示逻辑');
      expect(_Probe.logOf('B#0'), <String>['start', 'resume']);
    });

    testWidgets('容器划回来：只有栈顶那页 start，被盖住的不复活', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      final navA = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        _pageViewOfStacks(controller, navA: navA, stackPagesObserve: true),
      );
      await tester.pumpAndSettle();

      unawaited(
        navA.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const _Probe('A#1', observePageIndex: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _Probe.logOf('A#0'),
        contains('stop'),
        reason: '前置条件：A#0 被 A#1 盖住',
      );

      _Probe.clearAll();
      controller.jumpToPage(1);
      await tester.pumpAndSettle();
      expect(_Probe.logOf('A#1'), <String>[
        'pause',
        'stop',
      ], reason: '栈顶页跟着容器一起不显示');

      _Probe.clearAll();
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      expect(_Probe.logOf('A#1'), <String>[
        'start',
        'resume',
      ], reason: '容器回来了，栈顶页跟着回来');
      // 这条是整组的关键：A#0 在划走时已被 stop，_hasAppeared 是 false，
      // 幂等挡不住——必须靠 _notifyPageIndexShow 里的栈顶门禁把它挡掉。
      expect(
        _Probe.logOf('A#0'),
        isEmpty,
        reason: 'A#0 仍被 A#1 盖着，容器回来不该让它一起 start',
      );
    });

    testWidgets('容器不显示期间在子栈里 pop：回来时新栈顶才是可见的那页', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      final navA = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        _pageViewOfStacks(controller, navA: navA, stackPagesObserve: true),
      );
      await tester.pumpAndSettle();

      unawaited(
        navA.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const _Probe('A#1', observePageIndex: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      controller.jumpToPage(1);
      await tester.pumpAndSettle();

      // 整条栈都不可见时 pop 掉栈顶：此刻谁都不该收到 start。
      _Probe.clearAll();
      navA.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_Probe.logOf('A#0'), isEmpty, reason: '容器不显示，pop 出来的新栈顶也还是不可见');

      _Probe.clearAll();
      controller.jumpToPage(0);
      await tester.pumpAndSettle();
      expect(_Probe.logOf('A#0'), <String>[
        'start',
        'resume',
      ], reason: '容器回来了，此时 A#0 已是栈顶，应当可见');
    });
  });
}

/// 一个 `PageView` 装两条嵌套栈，容器层挂 `observePageIndex`。
///
/// [stackPagesObserve] 为 true 时**栈内页面自己也开 `observePageIndex`**，
/// 于是它们跟着容器一起显示 / 不显示。
Widget _pageViewOfStacks(
  PageController controller, {
  GlobalKey<NavigatorState>? navA,
  bool stackPagesObserve = false,
}) {
  Widget stack(String name, GlobalKey<NavigatorState>? key) => _KeepAlive(
    child: FlPageLifecycleView(
      observePageIndex: true,
      onStateChanged: (_, state) => _Probe.log('$name容器', state),
      child: Navigator(
        key: key,
        observers: <NavigatorObserver>[FlRouteObserverProxy()],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) =>
              _Probe('$name#0', observePageIndex: stackPagesObserve),
        ),
      ),
    ),
  );

  return MaterialApp(
    navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
    home: Scaffold(
      body: PageView(
        controller: controller,
        children: FlPageIndexScope.wrapChildren(
          controller: controller,
          children: [stack('A', navA), stack('B', null)],
        ),
      ),
    ),
  );
}

/// 让 `PageView` 划走的子页常驻，否则整条嵌套栈会被销毁重建。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 根 `Navigator` 挂 [FlRouteObserver]，内层挂 [FlRouteObserverProxy]。
Widget _nestedApp({
  GlobalKey<NavigatorState>? rootKey,
  GlobalKey<NavigatorState>? nestedKey,
}) {
  return MaterialApp(
    navigatorKey: rootKey,
    navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
    home: Navigator(
      key: nestedKey,
      observers: <NavigatorObserver>[FlRouteObserverProxy()],
      onGenerateRoute: (_) =>
          MaterialPageRoute<void>(builder: (_) => const _Probe('inner-A')),
    ),
  );
}

/// 只记录四个可见性事件的探针页，按名字分桶。
class _Probe extends StatefulWidget {
  const _Probe(this.name, {this.observePageIndex = false});

  final String name;

  /// 栈内页面是否跟着 `PageView` 页码走。
  final bool observePageIndex;

  static final Map<String, List<String>> _logs = <String, List<String>>{};

  static List<String> logOf(String name) => _logs[name] ?? const <String>[];

  static void clearAll() => _logs.clear();

  /// 供容器层的 `FlPageLifecycleView` 记录：只留四个可见性事件。
  static void log(String name, FlLifecycleState state) {
    const keep = <FlLifecycleState>{
      FlLifecycleState.onPageStart,
      FlLifecycleState.onPageResume,
      FlLifecycleState.onPagePause,
      FlLifecycleState.onPageStop,
    };
    if (!keep.contains(state)) {
      return;
    }
    _logs
        .putIfAbsent(name, () => <String>[])
        .add(state.name.replaceFirst('onPage', '').toLowerCase());
  }

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with FlPageLifecycleMixin {
  // 每个 _Probe 实例在整个生命周期内取值恒定（由构造参数决定），满足开关必须
  // 是常量的约束。
  @override
  bool get observePageIndex => widget.observePageIndex;

  void _log(String event) =>
      _Probe._logs.putIfAbsent(widget.name, () => <String>[]).add(event);

  @override
  void onPageStart() => _log('start');

  @override
  void onPageResume() => _log('resume');

  @override
  void onPagePause() => _log('pause');

  @override
  void onPageStop() => _log('stop');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
