import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// 换 controller 之后，「停稳才提交」的门禁绑定必须跟着重算。
///
/// 门禁的数据源 `_scrollPosition` 是从 `widget.controller` 派生的（滚动型才绑，
/// `ValueListenable<int>` 不绑）。`didUpdateWidget` 若只换监听源、不重算这个绑定，
/// 跨类别互换后旧的 `ScrollPosition` 会继续生效——本层的提交就被一个已经不相干的
/// 滚动容器卡住，它一滚，换页事件就发不出去。
///
/// 同类别互换不需要这条保护：`Scrollable` 的 position 换掉会触发
/// `didChangeDependencies`，那条路径本来就会重绑。
void main() {
  testWidgets('controller 从 PageController 换成 ValueListenable<int> 后，'
      '外层列表正在滚动也不该挡住换页提交', (tester) async {
    final pageController = PageController();
    addTearDown(pageController.dispose);
    final indexNotifier = ValueNotifier<int>(0);
    addTearDown(indexNotifier.dispose);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      _SwapApp(
        scroll: scroll,
        pageController: pageController,
        indexNotifier: indexNotifier,
      ),
    );
    await tester.pumpAndSettle();
    expect(_Probe.log, <String>['start'], reason: '前置条件：pageIndex 0 命中初始页');

    // 让外层 ListView 进入拖动中（isScrollingNotifier == true），并保持不松手。
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();

    // 就在列表滚动中把 controller 换成非滚动型，同时把当前页码切到 1。
    // 本页 pageIndex 是 0，因此应当立刻不可见。
    _Probe.log.clear();
    indexNotifier.value = 1;
    _SwapApp.swapTo(tester, useNotifier: true);
    await tester.pump();
    await tester.pump();

    expect(
      _Probe.log,
      <String>['stop'],
      reason:
          '换成非滚动型 controller 后门禁应已解绑；仍绑着的话这次提交会被'
          '外层列表的滚动状态挡住，拿到的是空事件',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}

class _SwapApp extends StatefulWidget {
  const _SwapApp({
    required this.scroll,
    required this.pageController,
    required this.indexNotifier,
  });

  final ScrollController scroll;
  final PageController pageController;
  final ValueNotifier<int> indexNotifier;

  static _SwapAppState? _state;

  /// 让用例在任意时刻把 controller 换掉。
  static void swapTo(WidgetTester tester, {required bool useNotifier}) {
    // ignore: invalid_use_of_protected_member
    _state!.setState(() => _state!._useNotifier = useNotifier);
  }

  @override
  State<_SwapApp> createState() => _SwapAppState();
}

class _SwapAppState extends State<_SwapApp> {
  bool _useNotifier = false;

  @override
  void initState() {
    super.initState();
    _SwapApp._state = this;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: <NavigatorObserver>[FlRouteObserver()],
      home: Scaffold(
        body: ListView(
          controller: widget.scroll,
          children: [
            const SizedBox(height: 400),
            SizedBox(
              height: 200,
              // Scope 的最近一层 Scrollable 是这个 ListView——正是「绑错对象」
              // 会发生的形状。用它来暴露门禁有没有跟着 controller 解绑。
              child: FlPageIndexScope(
                pageIndex: 0,
                controller: _useNotifier
                    ? widget.indexNotifier
                    : widget.pageController,
                child: const _Probe(),
              ),
            ),
            const SizedBox(height: 1200),
          ],
        ),
      ),
    );
  }
}

class _Probe extends StatefulWidget {
  const _Probe();

  static final List<String> log = <String>[];

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with FlPageLifecycleMixin {
  @override
  bool get observePageIndex => true;

  @override
  void onPageStart() => _Probe.log.add('start');

  @override
  void onPageStop() => _Probe.log.add('stop');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
