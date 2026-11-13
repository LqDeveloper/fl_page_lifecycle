import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// 可见性只在容器停下来时提交，见 `FlPageIndexScope` 的「提交时机」一节。
void main() {
  late List<String> log;

  setUp(() => log = <String>[]);

  Widget pages(
    PageController controller, {
    int count = 5,
    bool keepAlive = false,
  }) => MaterialApp(
    navigatorObservers: [FlRouteObserver.instance],
    home: PageView.builder(
      controller: controller,
      itemCount: count,
      itemBuilder: FlPageIndexScope.wrapItemBuilder(
        controller: controller,
        builder: (_, index) =>
            _Probe(tag: 'S$index', log: log, keepAlive: keepAlive),
      ),
    ),
  );

  testWidgets('animateToPage 掠过的中间页一个事件都不发', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(pages(controller));
    await tester.pumpAndSettle();
    expect(log, <String>['S0:start']);
    log.clear();

    unawaited(
      controller.animateToPage(
        4,
        duration: const Duration(milliseconds: 600),
        curve: Curves.linear,
      ),
    );
    await tester.pumpAndSettle();

    // 加门禁之前这里是：
    //   S0:stop, S0:idx 0->1, S1:start, S1:stop, S2:start, S2:idx 1->2,
    //   S2:stop, S2:idx 2->3, S3:start, S3:stop, S4:start, S4:idx 3->4
    // S1 / S2 / S3 各有一对假曝光，页码也在中间值上逐级跳。
    //
    // 这里没有 keepAlive，S0 的 stop 是被划出视口时由 dispose 补发的；
    // 常驻页的情形见下一个用例。S4 是在这趟掠过途中挂载的，仍然收得到页码变更
    // ——「旧页码」记在层上而不是各自页上，见 FlPageIndexScope 的 _FlPageIndexLayer。
    expect(log, <String>['S0:stop', 'S4:start', 'S4:idx 0->4']);
  });

  testWidgets('keepAlive 时掠过的中间页也不发事件，页码直接从 0 跳到 4', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(pages(controller, keepAlive: true));
    await tester.pumpAndSettle();
    log.clear();

    unawaited(
      controller.animateToPage(
        4,
        duration: const Duration(milliseconds: 600),
        curve: Curves.linear,
      ),
    );
    await tester.pumpAndSettle();

    // 页全部常驻，start / stop 都走可见性而不是 dispose，中间页仍然一个都不发。
    expect(log.where((e) => !e.contains(':idx ')), <String>[
      'S0:stop',
      'S4:start',
    ]);
    // 页码变更 fan-out 给本层每一个已挂载的页，参数完全一致：S1~S4 虽然是在这趟
    // 掠过途中才挂载的，读到的也是层上的 (0, 4)，而不是各自的 -1。
    expect(log.where((e) => e.contains(':idx ')).toList()..sort(), <String>[
      'S0:idx 0->4',
      'S1:idx 0->4',
      'S2:idx 0->4',
      'S3:idx 0->4',
      'S4:idx 0->4',
    ]);
    log.clear();

    // 这一趟五页都已常驻且都停在 4，于是每一页都报一次，且直达终点——加门禁之前
    // 是逐级跳的（0->1、1->2……），每个中间值都会 fan-out 给所有页。
    unawaited(
      controller.animateToPage(
        0,
        duration: const Duration(milliseconds: 600),
        curve: Curves.linear,
      ),
    );
    await tester.pumpAndSettle();

    expect(log.where((e) => !e.contains(':idx ')), <String>[
      'S4:stop',
      'S0:start',
    ]);
    expect(log.where((e) => e.contains(':idx ')).toList()..sort(), <String>[
      'S0:idx 4->0',
      'S1:idx 4->0',
      'S2:idx 4->0',
      'S3:idx 4->0',
      'S4:idx 4->0',
    ]);
  });

  testWidgets('半途放弃的拖动不发任何事件', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(pages(controller));
    await tester.pumpAndSettle();
    log.clear();

    // 拖过半页（翻页判定已经翻转），再拖回来松手。
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(-500, 0));
    await tester.pump();
    expect(log, isEmpty, reason: '拖动过程中不提交');

    await gesture.moveBy(const Offset(500, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(log, isEmpty);
  });

  testWidgets('正常翻一页：停下来时发出，事件成对', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(pages(controller));
    await tester.pumpAndSettle();
    log.clear();

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    expect(log, <String>['S0:stop', 'S1:start', 'S1:idx 0->1']);
  });

  testWidgets('jumpToPage 不产生滚动活动，当场提交', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(pages(controller));
    await tester.pumpAndSettle();
    log.clear();

    controller.jumpToPage(3);
    await tester.pump();

    expect(log, <String>['S0:stop', 'S3:start']);
  });

  testWidgets('TabBarView 跨多个 tab：中间 tab 不发事件，页码直达', (tester) async {
    final tab = TabController(length: 5, vsync: const TestVSync());
    addTearDown(tab.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [FlRouteObserver.instance],
        home: TabBarView(
          controller: tab,
          children: FlPageIndexScope.wrapChildren(
            controller: tab,
            children: List<Widget>.generate(
              5,
              (index) => _Probe(tag: 'T$index', log: log),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    log.clear();

    tab.animateTo(4);
    await tester.pumpAndSettle();

    // 加门禁之前页码是逐级跳的，且 T4 报的是 2->4：
    //   T0:stop, T0:idx 0->2, T0:idx 2->4, T4:start, T4:idx 2->4
    expect(log, <String>['T0:stop', 'T4:start', 'T4:idx 0->4']);
  });

  testWidgets('后插进来的宿主不会补发它出生之前的那次换页', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    final extra = ValueNotifier<bool>(false);
    addTearDown(extra.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [FlRouteObserver.instance],
        home: PageView.builder(
          controller: controller,
          itemCount: 3,
          itemBuilder: FlPageIndexScope.wrapItemBuilder(
            controller: controller,
            builder: (_, index) => Stack(
              children: <Widget>[
                _Probe(tag: 'S$index', log: log, keepAlive: true),
                // 页面里一个条件渲染的子树，稍后才挂上来。
                ValueListenableBuilder<bool>(
                  valueListenable: extra,
                  builder: (_, show, _) => show && index == 0
                      ? FlPageLifecycleView(
                          observePageIndex: true,
                          onStateChanged: (_, state) =>
                              log.add('late:${state.name}'),
                          onPageIndexChanged: (_, from, to) =>
                              log.add('late:idx $from->$to'),
                          child: const SizedBox.shrink(),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 先让本层真的换过页：0 -> 1 -> 0。
    controller.jumpToPage(1);
    await tester.pump();
    controller.jumpToPage(0);
    await tester.pump();
    log.clear();

    // 此刻本层已经换过两次页，现在才把 FlPageLifecycleView 插进当前页。
    extra.value = true;
    await tester.pumpAndSettle();

    // 它该正常拿到 start / resume，但**不该**补发一次 1->0——那次换页发生在它
    // 存在之前。没有 FlPageIndexDelegate._seed 的话这里会多出 'late:idx 1->0'。
    expect(log.where((e) => e.startsWith('late:idx ')), isEmpty);
    expect(log, contains('late:onPageStart'));
  });

  testWidgets('嵌套：外层滑动期间内层不提交，外层停下来才一起发出', (tester) async {
    final outer = PageController();
    addTearDown(outer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [FlRouteObserver.instance],
        home: PageView.builder(
          controller: outer,
          itemCount: 3,
          itemBuilder: FlPageIndexScope.wrapItemBuilder(
            controller: outer,
            builder: (_, index) => _InnerTabs(outer: index, log: log),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(log, <String>['P0T0:start']);
    log.clear();

    unawaited(
      outer.animateToPage(
        2,
        duration: const Duration(milliseconds: 400),
        curve: Curves.linear,
      ),
    );
    await tester.pumpAndSettle();

    // 中间那一页（P1）整页被掠过，它的内层子页同样一个事件都不该有。
    // 两个 P*T0 听的都是各自内层 TabBarView 那一层，外层翻页不算它们的页码变更。
    expect(log, <String>['P0T0:stop', 'P2T0:start']);
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.tag, required this.log, this.keepAlive = false});
  final String tag;
  final List<String> log;
  final bool keepAlive;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe>
    with AutomaticKeepAliveClientMixin<_Probe>, FlPageLifecycleMixin<_Probe> {
  @override
  bool get observePageIndex => true;
  @override
  bool get wantKeepAlive => widget.keepAlive;
  @override
  void onPageStart() => widget.log.add('${widget.tag}:start');
  @override
  void onPageStop() => widget.log.add('${widget.tag}:stop');
  @override
  void onPageIndexChanged(int from, int to) =>
      widget.log.add('${widget.tag}:idx $from->$to');
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Center(child: Text(widget.tag));
  }
}

class _InnerTabs extends StatefulWidget {
  const _InnerTabs({required this.outer, required this.log});
  final int outer;
  final List<String> log;
  @override
  State<_InnerTabs> createState() => _InnerTabsState();
}

class _InnerTabsState extends State<_InnerTabs>
    with SingleTickerProviderStateMixin {
  late final TabController tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TabBarView(
    controller: tab,
    children: FlPageIndexScope.wrapChildren(
      controller: tab,
      children: List<Widget>.generate(
        2,
        (index) => _Probe(tag: 'P${widget.outer}T$index', log: widget.log),
      ),
    ),
  );
}
