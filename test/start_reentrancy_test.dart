import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

// 宿主在 start 回调里同步改路由栈（未登录跳登录页、进页弹公告）时，
// start 之后不能无条件接着发 resume。

final _log = <String>[];

class _Page extends StatefulWidget {
  const _Page({required this.onFirstStart});
  final void Function(BuildContext context) onFirstStart;
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with FlPageLifecycleMixin {
  bool _didRedirect = false;

  @override
  void onPageStart() {
    _log.add('start');
    if (!_didRedirect) {
      _didRedirect = true;
      widget.onFirstStart(context);
    }
  }

  @override
  void onPageResume() => _log.add('resume');
  @override
  void onPagePause() => _log.add('pause');
  @override
  void onPageStop() => _log.add('stop');
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('page'));
}

class _RoutePage extends StatefulWidget {
  const _RoutePage({required this.onFirstStart});
  final void Function(BuildContext context) onFirstStart;
  @override
  State<_RoutePage> createState() => _RoutePageState();
}

class _RoutePageState extends State<_RoutePage> with FlPageRouteMixin {
  bool _didRedirect = false;

  @override
  void onRouteStart() {
    _log.add('start');
    if (!_didRedirect) {
      _didRedirect = true;
      widget.onFirstStart(context);
    }
  }

  @override
  void onRouteResume() => _log.add('resume');
  @override
  void onRoutePause() => _log.add('pause');
  @override
  void onRouteStop() => _log.add('stop');
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('page'));
}

void _pushPage(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('login')),
    ),
  );
}

void _showNotice(BuildContext context) {
  unawaited(
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(content: Text('notice')),
    ),
  );
}

void main() {
  setUp(_log.clear);

  group('FlPageLifecycleMixin', () {
    testWidgets('pushing a page from onPageStart does not resume the covered '
        'page', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [FlRouteObserver()],
          home: const _Page(onFirstStart: _pushPage),
        ),
      );
      await tester.pumpAndSettle();
      // Before the fix this was [start, stop, resume]: resumed while covered.
      expect(_log, ['start', 'stop']);

      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_log, ['start', 'stop', 'start', 'resume']);
    });

    testWidgets('showing a dialog from onPageStart defers resume until the '
        'dialog closes', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [FlRouteObserver()],
          home: const _Page(onFirstStart: _showNotice),
        ),
      );
      await tester.pumpAndSettle();
      // Before the fix this was [start, resume] with the dialog still open.
      expect(_log, ['start']);

      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_log, ['start', 'resume']);
    });
  });

  group('FlPageRouteMixin', () {
    testWidgets('pushing a page from onRouteStart does not resume the covered '
        'page', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [FlRouteObserver()],
          home: const _RoutePage(onFirstStart: _pushPage),
        ),
      );
      await tester.pumpAndSettle();
      // Before the fix a trailing resume followed the stop.
      expect(_log, ['start', 'pause', 'stop']);

      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_log, ['start', 'pause', 'stop', 'start', 'resume']);
    });

    testWidgets('showing a dialog from onRouteStart defers resume until the '
        'dialog closes', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [FlRouteObserver()],
          home: const _RoutePage(onFirstStart: _showNotice),
        ),
      );
      await tester.pumpAndSettle();
      expect(_log.contains('resume'), isFalse);

      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_log.last, 'resume');
    });
  });
}
