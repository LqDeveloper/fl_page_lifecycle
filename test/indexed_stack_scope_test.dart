import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// `FlPageIndexScope` 接 `ValueListenable<int>` 时的契约：支持 `IndexedStack`
/// 这类「子页全部 build 出来、只显示其中一个」的非滚动容器。
///
/// 与滚动容器的差别只有提交时机——这里没有「停稳才提交」的门禁，改了当场提交。
/// 其余（嵌套、深度、onPageIndexChanged、宿主侧开关）应当完全一致，
/// 因此这里也钉住与 `PageView` 互相嵌套的情形。
void main() {
  group('IndexedStack 基本可见性', () {
    testWidgets('首帧只有当前页可见', (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(_indexedStackApp(index, 3));
      await tester.pumpAndSettle();

      expect(_Probe.logOf('p0'), <String>['start', 'resume']);
      expect(_Probe.logOf('p1'), isEmpty, reason: '虽然 build 了，但没显示');
      expect(_Probe.logOf('p2'), isEmpty);
    });

    testWidgets('换页当场提交：旧页 pause+stop，新页 start+resume', (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(_indexedStackApp(index, 3));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      index.value = 2;
      await tester.pumpAndSettle();

      expect(_Probe.logOf('p0'), <String>['pause', 'stop']);
      expect(_Probe.logOf('p2'), <String>['start', 'resume']);
      expect(_Probe.logOf('p1'), isEmpty, reason: '没有被掠过的中间页可言');
    });

    testWidgets('来回切换：事件成对，不重复', (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(_indexedStackApp(index, 2));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      index.value = 1;
      await tester.pumpAndSettle();
      index.value = 0;
      await tester.pumpAndSettle();

      expect(_Probe.logOf('p0'), <String>['pause', 'stop', 'start', 'resume']);
      expect(_Probe.logOf('p1'), <String>['start', 'resume', 'pause', 'stop']);
    });

    testWidgets('index 为 null 时一页都不可见', (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(_indexedStackApp(index, 2));
      await tester.pumpAndSettle();

      _Probe.clearAll();
      index.value = -1; // IndexedStack.index 取 null，Scope 收到 -1，无页命中
      await tester.pumpAndSettle();

      expect(_Probe.logOf('p0'), <String>['pause', 'stop']);
      expect(_Probe.logOf('p1'), isEmpty);
    });

    testWidgets('onPageIndexChanged 报到位的 (from, to)', (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(_indexedStackApp(index, 4));
      await tester.pumpAndSettle();

      _Probe.changes.clear();
      index.value = 3;
      await tester.pumpAndSettle();

      expect(_Probe.changes, contains('p0:0->3'), reason: '本层每个已挂载的页都拿到同一对下标');
      expect(_Probe.changes, contains('p3:0->3'));
    });
  });

  group('嵌套', () {
    testWidgets('IndexedStack 套在 PageView 里：外层滑走，内层当前页也 stop', (tester) async {
      final pageController = PageController();
      addTearDown(pageController.dispose);
      final inner = ValueNotifier<int>(0);
      addTearDown(inner.dispose);

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
          home: Scaffold(
            body: PageView(
              controller: pageController,
              children: FlPageIndexScope.wrapChildren(
                controller: pageController,
                children: [
                  _IndexedStackLayer(index: inner, count: 2, prefix: 'inner'),
                  const _Probe('outer1'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_Probe.logOf('inner0'), <String>['start', 'resume']);

      _Probe.clearAll();
      pageController.jumpToPage(1);
      await tester.pumpAndSettle();

      expect(_Probe.logOf('inner0'), <String>[
        'pause',
        'stop',
      ], reason: '外层滑走，内层当前页跟着不可见');
      expect(_Probe.logOf('outer1'), <String>['start', 'resume']);

      _Probe.clearAll();
      pageController.jumpToPage(0);
      await tester.pumpAndSettle();
      expect(_Probe.logOf('inner0'), <String>['start', 'resume']);
      expect(_Probe.logOf('inner1'), isEmpty, reason: '内层不是当前页，外层滑回来也不该让它可见');
    });

    testWidgets('深度：内层为 1，外层为 0', (tester) async {
      final pageController = PageController();
      addTearDown(pageController.dispose);
      final inner = ValueNotifier<int>(0);
      addTearDown(inner.dispose);

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
          home: Scaffold(
            body: PageView(
              controller: pageController,
              children: FlPageIndexScope.wrapChildren(
                controller: pageController,
                children: [
                  _IndexedStackLayer(index: inner, count: 2, prefix: 'inner'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_Probe.depthOf('inner0'), 1);
      expect(_Probe.pageIndexOf('inner0'), 0);
    });
  });

  group('非滚动容器不受滚动状态影响', () {
    testWidgets('IndexedStack 放在 ListView 里，滚动不影响换页提交', (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                const SizedBox(height: 400),
                SizedBox(
                  height: 200,
                  child: _IndexedStackLayer(
                    index: index,
                    count: 2,
                    prefix: 'p',
                  ),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 让外层列表处于滚动中，再换页：提交不该被它挡住。
      scroll.jumpTo(100);
      _Probe.clearAll();
      index.value = 1;
      await tester.pump();
      await tester.pump();

      expect(_Probe.logOf('p1'), <String>[
        'start',
        'resume',
      ], reason: '非滚动容器不绑外层 Scrollable，换页当场提交');
      expect(_Probe.logOf('p0'), <String>['pause', 'stop']);
    });
  });
}

/// `IndexedStack` + Scope 的标准接法，供各用例复用。
class _IndexedStackLayer extends StatelessWidget {
  const _IndexedStackLayer({
    required this.index,
    required this.count,
    required this.prefix,
  });

  final ValueNotifier<int> index;
  final int count;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final children = FlPageIndexScope.wrapChildren(
      controller: index,
      children: List<Widget>.generate(
        count,
        (i) => _Probe('$prefix$i'),
        growable: false,
      ),
    );
    return ValueListenableBuilder<int>(
      valueListenable: index,
      builder: (context, value, _) =>
          IndexedStack(index: value < 0 ? null : value, children: children),
    );
  }
}

Widget _indexedStackApp(ValueNotifier<int> index, int count) => MaterialApp(
  navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
  home: Scaffold(
    body: _IndexedStackLayer(index: index, count: count, prefix: 'p'),
  ),
);

class _Probe extends StatefulWidget {
  const _Probe(this.name);

  final String name;

  static final Map<String, List<String>> _logs = <String, List<String>>{};
  static final List<String> changes = <String>[];
  static final Map<String, int> _depths = <String, int>{};
  static final Map<String, int> _pageIndexes = <String, int>{};

  static List<String> logOf(String name) => _logs[name] ?? const <String>[];

  static int? depthOf(String name) => _depths[name];

  static int? pageIndexOf(String name) => _pageIndexes[name];

  static void clearAll() {
    _logs.clear();
    changes.clear();
  }

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with FlPageLifecycleMixin {
  @override
  bool get observePageIndex => true;

  void _log(String event) =>
      _Probe._logs.putIfAbsent(widget.name, () => <String>[]).add(event);

  @override
  void onPageStart() {
    _Probe._depths[widget.name] = pageScopeDepth;
    _Probe._pageIndexes[widget.name] = pageIndex;
    _log('start');
  }

  @override
  void onPageResume() => _log('resume');

  @override
  void onPagePause() => _log('pause');

  @override
  void onPageStop() => _log('stop');

  @override
  void onPageIndexChanged(int from, int to) =>
      _Probe.changes.add('${widget.name}:$from->$to');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
