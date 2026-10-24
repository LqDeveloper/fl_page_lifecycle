import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// 控制器被外部持有、整层的 Scope 全部销毁又重建时的行为。
///
/// 这个场景一度被写错过：当时把「本层停在第几页」的**实时采样值**也做成了
/// `_FlPageIndexLayer` 上的层级共享状态，于是它跨过了那段一个 Scope 都不剩的
/// 空窗，让重建出来的页沿用了早已过时的页码，把首帧判成不可见；而首次布局用
/// `correctPixels` 落位、**不发通知**，没有任何后续事件来纠正——那一页就永远
/// 停在「看得见却没 start」。
///
/// 那次改动已经撤销（采样回到每个 Scope 各自进行），本用例留下来当防线。
void main() {
  testWidgets('控制器外部持有、PageView 拆掉再重建：重建出来的当前页仍会 start', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    final show = ValueNotifier<bool>(true);
    addTearDown(show.dispose);
    final log = <String>[];

    Widget build() => MaterialApp(
      navigatorObservers: [FlRouteObserver.instance],
      home: ValueListenableBuilder<bool>(
        valueListenable: show,
        builder: (_, visible, _) => visible
            ? PageView.builder(
                controller: controller,
                itemCount: 4,
                itemBuilder: FlPageIndexScope.wrapItemBuilder(
                  controller: controller,
                  builder: (_, index) => _Probe(tag: 'S$index', log: log),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    controller.jumpToPage(2);
    await tester.pumpAndSettle();
    expect(log, <String>['S0:start', 'S0:stop', 'S2:start']);
    log.clear();

    // 整棵 PageView 拆掉：本层一个 Scope 都不剩，但控制器还被外面持有着。
    show.value = false;
    await tester.pumpAndSettle();
    expect(log, <String>['S2:stop']);
    log.clear();

    // 用同一个控制器重建。重建落在页 0，它必须 start。
    show.value = true;
    await tester.pumpAndSettle();
    expect(controller.page, 0.0, reason: '前提：重建后确实停在页 0');
    expect(log, <String>['S0:start']);
    expect(tester.takeException(), isNull);
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.tag, required this.log});
  final String tag;
  final List<String> log;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with FlPageLifecycleMixin<_Probe> {
  @override
  bool get observePageIndex => true;
  @override
  void onPageStart() => widget.log.add('${widget.tag}:start');
  @override
  void onPageStop() => widget.log.add('${widget.tag}:stop');
  @override
  Widget build(BuildContext context) => Center(child: Text(widget.tag));
}
