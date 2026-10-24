import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// `FlPageIndexScope.depthOf` 是包外读取 Scope 嵌套深度的**唯一**公开入口
/// （`maybeOf` 是 `@internal`），此前没有任何调用点，也就没有任何东西挡住它退化。
///
/// 取值约定与 `ScrollNotification.depth` 对齐：最外层 0，每往里嵌一层加一，
/// 不在任何 Scope 中为 -1。
void main() {
  testWidgets('不在任何 Scope 中为 -1', (tester) async {
    int? observed;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            observed = FlPageIndexScope.depthOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(observed, -1);
  });

  testWidgets('最外层为 0，每往里嵌一层加一', (tester) async {
    final outer = PageController();
    addTearDown(outer.dispose);
    final inner = ValueNotifier<int>(0);
    addTearDown(inner.dispose);

    final depths = <String, int>{};

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: outer,
            children: FlPageIndexScope.wrapChildren(
              controller: outer,
              children: [
                Builder(
                  builder: (context) {
                    depths['outer'] = FlPageIndexScope.depthOf(context);
                    // 内层换一种 controller 类型，顺带确认深度与容器类型无关。
                    return FlPageIndexScope(
                      pageIndex: 0,
                      controller: inner,
                      child: Builder(
                        builder: (context) {
                          depths['inner'] = FlPageIndexScope.depthOf(context);
                          return const SizedBox.shrink();
                        },
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(depths['outer'], 0);
    expect(depths['inner'], 1);
  });
}
