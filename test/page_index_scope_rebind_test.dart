import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

// 带 GlobalKey 的宿主从一个容器的子页挪到另一个容器的子页时，绑定的 Scope 换了。
// 新层此前的换页不是这个宿主经历过的，不该补发 onPageIndexChanged。

final _changes = <String>[];

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with FlPageLifecycleMixin {
  @override
  bool get observePageIndex => true;
  @override
  void onPageIndexChanged(int from, int to) => _changes.add('$from>$to');
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  setUp(_changes.clear);

  testWidgets('re-binding to another scope does not replay that layer\'s '
      'earlier page change', (tester) async {
    final hostKey = GlobalKey();
    final first = ValueNotifier<int>(0);
    final second = ValueNotifier<int>(0);
    final inSecond = ValueNotifier<bool>(false);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(inSecond.dispose);

    Widget stack(ValueNotifier<int> index, {required bool withHost}) =>
        ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (_, i, _) => IndexedStack(
            index: i,
            children: FlPageIndexScope.wrapChildren(
              controller: index,
              children: [
                if (withHost) _Host(key: hostKey) else const SizedBox(),
                const SizedBox(),
              ],
            ),
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [FlRouteObserver()],
        home: ValueListenableBuilder<bool>(
          valueListenable: inSecond,
          builder: (_, moved, _) => Column(
            children: [
              Expanded(child: stack(first, withHost: !moved)),
              Expanded(child: stack(second, withHost: moved)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The second container pages back and forth while the host lives in the
    // first one: its layer now has a non-zero generation and a previous index.
    second.value = 1;
    await tester.pumpAndSettle();
    second.value = 0;
    await tester.pumpAndSettle();
    expect(_changes, isEmpty);

    // Move the host (same State, GlobalKey) into the second container.
    inSecond.value = true;
    await tester.pumpAndSettle();
    expect(_changes, isEmpty);

    // Changes after the move are reported as usual.
    second.value = 1;
    await tester.pumpAndSettle();
    expect(_changes, ['0>1']);
  });
}
