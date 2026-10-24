import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// Scope 放错位置的 debug 诊断，见
/// `_FlPageIndexScopeState._debugCheckScrollPositionBelongsToController`。
///
/// 诊断整个进程只提示一次，因此标志会跨用例残留。每个用例跑前调一次
/// [FlPageIndexScope.debugResetWarnings] 隔离——没有它的话，「会提示」的用例
/// 只能有一个且必须排在最后，否则它会把后面的提示吞掉，让那些用例变成
/// **永远通过的空壳**。
Future<List<String>> captureWarnings(Future<void> Function() body) async {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) {
      logs.add(message);
    }
  };
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return logs.where((m) => m.contains('离它最近的 Scrollable 不属于')).toList();
}

void main() {
  // 隔离进程级的「已提示过」标志，让用例之间互不影响、顺序无关。
  setUp(FlPageIndexScope.debugResetWarnings);

  testWidgets('wrapItemBuilder 正常包装：不提示', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: PageView.builder(
            controller: controller,
            itemCount: 3,
            // 页面内部自己有滚动容器——但 Scope 在它外面，不该误报。
            itemBuilder: FlPageIndexScope.wrapItemBuilder(
              controller: controller,
              builder: (_, index) =>
                  ListView(children: <Widget>[Text('page $index')]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(warnings, isEmpty);
  });

  testWidgets('嵌套 TabBarView：内层判不了，不误报', (tester) async {
    final tab = TabController(length: 2, vsync: const TestVSync());
    addTearDown(tab.dispose);
    final page = PageController();
    addTearDown(page.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: PageView.builder(
            controller: page,
            itemCount: 2,
            itemBuilder: FlPageIndexScope.wrapItemBuilder(
              controller: page,
              builder: (_, _) => TabBarView(
                controller: tab,
                children: FlPageIndexScope.wrapChildren(
                  controller: tab,
                  children: const <Widget>[
                    SizedBox.shrink(),
                    SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    // 内层 Scope 拿到的是 TabBarView 内部私有 PageController 的 position，
    // 与传进来的 TabController 比不了——这一支必须放行。
    expect(warnings, isEmpty);
  });

  testWidgets('Scope 不在任何 Scrollable 中：不提示', (tester) async {
    final tab = TabController(length: 2, vsync: const TestVSync());
    addTearDown(tab.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: FlPageIndexScope(
            pageIndex: 0,
            controller: tab,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(warnings, isEmpty);
  });

  // ↓ 唯一一个「会提示」的用例，必须排在最后：诊断每次运行只输出一遍。
  testWidgets('手写 Scope 放进页面内部的 ListView：提示一次', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: PageView.builder(
            controller: controller,
            itemCount: 3,
            // 没用 wrap 助手，而是把 Scope 手写到页面内部的 ListView 里：
            // 门禁会绑到 ListView 的 ScrollPosition 上。
            itemBuilder: (_, index) => ListView(
              children: <Widget>[
                FlPageIndexScope(
                  pageIndex: index,
                  controller: controller,
                  child: Text('page $index'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    // 视口里同时有多页、每页一个放错的 Scope，提示仍然只出一遍。
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('PageController'));
    expect(warnings.single, contains('wrapItemBuilder'));
  });
}
