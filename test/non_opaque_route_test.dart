import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

// 非不透明路由（opaque: false）盖上来时下层页面仍在屏幕上，
// 应与 PopupRoute 一样只 pause 不 stop。

final _log = <String>[];

class _Page extends StatefulWidget {
  const _Page();
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with FlPageLifecycleMixin {
  @override
  void onPageStart() => _log.add('start');
  @override
  void onPageResume() => _log.add('resume');
  @override
  void onPagePause() => _log.add('pause');
  @override
  void onPageStop() => _log.add('stop');
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('page'));
}

Route<void> _sheetRoute({required bool opaque}) => PageRouteBuilder<void>(
  opaque: opaque,
  pageBuilder: (_, _, _) => const Align(
    alignment: Alignment.bottomCenter,
    child: SizedBox(height: 200, child: Material(child: Text('sheet'))),
  ),
);

void main() {
  setUp(_log.clear);

  testWidgets('a non-opaque route pauses the page below without stopping it', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [FlRouteObserver()],
        home: const _Page(),
      ),
    );
    await tester.pumpAndSettle();
    _log.clear();

    nav.currentState!.push(_sheetRoute(opaque: false));
    await tester.pumpAndSettle();
    // The page is still painted underneath. Before the fix: [pause, stop].
    expect(find.text('page'), findsOneWidget);
    expect(_log, ['pause']);

    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(_log, ['pause', 'resume']);
  });

  testWidgets('an opaque route still stops the page below', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [FlRouteObserver()],
        home: const _Page(),
      ),
    );
    await tester.pumpAndSettle();
    _log.clear();

    nav.currentState!.push(_sheetRoute(opaque: true));
    await tester.pumpAndSettle();
    expect(_log, ['pause', 'stop']);

    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(_log, ['pause', 'stop', 'start', 'resume']);
  });
}
