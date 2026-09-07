import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// Per-test event recorder.
///
/// Deliberately not a global: when a `testWidgets` body fails, the framework
/// leaves the widget tree standing, and its pages only dispose during the next
/// test's first `pumpWidget`. With shared state those late stop events would
/// land in the next test's log and turn one real failure into a cascade of
/// misleading ones. Each test owning its own list keeps failures local.
class _Recorder {
  final List<String> events = <String>[];

  void clear() => events.clear();
}

/// Only the four visibility events matter here; postFrame / animation / dispose
/// events would just add noise to the expectations.
const Set<FlLifecycleState> _tracked = <FlLifecycleState>{
  FlLifecycleState.onPageStart,
  FlLifecycleState.onPageResume,
  FlLifecycleState.onPagePause,
  FlLifecycleState.onPageStop,
};

/// A page driven by [FlPageLifecycleMixin], the full state machine.
class _Page extends StatefulWidget {
  const _Page(this.tag, this.recorder);

  final String tag;
  final _Recorder recorder;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with FlPageLifecycleMixin {
  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);
    if (_tracked.contains(state)) {
      widget.recorder.events.add('${widget.tag}:${state.name}');
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// A page driven by [FlPageRouteMixin], which forwards route events verbatim.
class _RoutePage extends StatefulWidget {
  const _RoutePage(this.tag, this.recorder);

  final String tag;
  final _Recorder recorder;

  @override
  State<_RoutePage> createState() => _RoutePageState();
}

class _RoutePageState extends State<_RoutePage> with FlPageRouteMixin {
  void _record(String event) =>
      widget.recorder.events.add('${widget.tag}:$event');

  @override
  void onRouteStart() => _record('onRouteStart');

  @override
  void onRouteResume() => _record('onRouteResume');

  @override
  void onRoutePause() => _record('onRoutePause');

  @override
  void onRouteStop() => _record('onRouteStop');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Pumps an app whose first route is [home], then clears the recorder so each
/// test starts from a clean slate.
Future<NavigatorState> _pumpApp(
  WidgetTester tester,
  Widget home,
  _Recorder recorder,
) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: key,
      navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
      home: home,
    ),
  );
  await tester.pumpAndSettle();
  recorder.clear();
  return key.currentState!;
}

MaterialPageRoute<void> _route(Widget page) =>
    MaterialPageRoute<void>(builder: (_) => page);

void main() {
  group('FlRouteObserver.didRemove', () {
    testWidgets('removing a PopupRoute resumes the page below', (tester) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _Page('A', rec), rec);

      final dialog = DialogRoute<void>(
        context: nav.context,
        builder: (_) => const SizedBox.shrink(),
      );
      unawaited(nav.push(dialog));
      await tester.pumpAndSettle();
      // A popup only pauses the page below; it never stops it.
      expect(rec.events, <String>['A:onPagePause']);
      rec.clear();

      // removeRoute goes through didRemove, not didPop. Before the fix this
      // emitted routePageStart(), which the host's `_hasAppeared` guard
      // swallowed entirely, leaving the page stuck in the paused state.
      nav.removeRoute(dialog);
      await tester.pumpAndSettle();

      expect(rec.events, <String>['A:onPageResume']);
    });

    testWidgets('popping a PopupRoute resumes the page below', (tester) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _Page('A', rec), rec);

      unawaited(
        nav.push(
          DialogRoute<void>(
            context: nav.context,
            builder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      rec.clear();

      nav.pop();
      await tester.pumpAndSettle();

      expect(rec.events, <String>['A:onPageResume']);
    });

    testWidgets('removing a normal route starts the page below', (
      tester,
    ) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _Page('A', rec), rec);

      final above = _route(_Page('B', rec));
      unawaited(nav.push(above));
      await tester.pumpAndSettle();
      expect(rec.events, <String>[
        'A:onPagePause',
        'A:onPageStop',
        'B:onPageStart',
        'B:onPageResume',
      ]);
      rec.clear();

      // A non-popup route must still go down the start path.
      nav.removeRoute(above);
      await tester.pumpAndSettle();

      expect(
        rec.events,
        containsAllInOrder(<String>['A:onPageStart', 'A:onPageResume']),
      );
    });
  });

  group('first-frame visibility gate', () {
    testWidgets('a plain push emits start and resume', (tester) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _Page('A', rec), rec);

      unawaited(nav.push(_route(_Page('B', rec))));
      await tester.pumpAndSettle();

      expect(
        rec.events,
        containsAllInOrder(<String>['B:onPageStart', 'B:onPageResume']),
      );
    });

    testWidgets('a page covered within its first frame does not start', (
      tester,
    ) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _Page('home', rec), rec);

      // A subscribes to FlRouteObserver in didChangeDependencies, which runs
      // after Navigator has already dispatched didPush for B. A therefore
      // never sees a stop, and before the fix its own post-frame callback
      // reported it as visible even though it never appeared on screen.
      unawaited(nav.push(_route(_Page('A', rec))));
      unawaited(nav.push(_route(_Page('B', rec))));
      await tester.pumpAndSettle();

      expect(rec.events, isNot(contains('A:onPageStart')));
      expect(
        rec.events,
        containsAllInOrder(<String>['B:onPageStart', 'B:onPageResume']),
      );
    });

    testWidgets('the covered page starts once the route above is popped', (
      tester,
    ) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _Page('home', rec), rec);

      unawaited(nav.push(_route(_Page('A', rec))));
      unawaited(nav.push(_route(_Page('B', rec))));
      await tester.pumpAndSettle();
      rec.clear();

      nav.pop();
      await tester.pumpAndSettle();

      // A appears for the first time here, so it gets a start, not a bare
      // resume — and exactly one of each.
      expect(
        rec.events,
        containsAllInOrder(<String>['A:onPageStart', 'A:onPageResume']),
      );
      expect(rec.events.where((e) => e == 'A:onPageStart'), hasLength(1));
      expect(rec.events.where((e) => e == 'A:onPageResume'), hasLength(1));
    });

    testWidgets('a multi-level initialRoute only starts the top page', (
      tester,
    ) async {
      final rec = _Recorder();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
          initialRoute: '/a/b',
          routes: <String, WidgetBuilder>{
            '/': (_) => _Page('root', rec),
            '/a': (_) => _Page('A', rec),
            '/a/b': (_) => _Page('B', rec),
          },
        ),
      );
      await tester.pumpAndSettle();

      // Navigator.defaultGenerateInitialRoutes builds a three-route stack;
      // only the topmost one is actually visible.
      expect(rec.events, <String>['B:onPageStart', 'B:onPageResume']);
    });

    testWidgets('a page with no ModalRoute still starts on its first frame', (
      tester,
    ) async {
      final rec = _Recorder();
      // isCurrent is false without a ModalRoute, so the gate must not apply
      // here or non-route pages would be blocked forever.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: _Page('plain', rec),
        ),
      );
      await tester.pumpAndSettle();

      expect(rec.events, <String>['plain:onPageStart', 'plain:onPageResume']);
    });

    testWidgets(
      'a page covered by a popup on its first frame starts when the popup '
      'closes',
      (tester) async {
        final rec = _Recorder();
        final nav = await _pumpApp(tester, _Page('home', rec), rec);

        final dialog = DialogRoute<void>(
          context: nav.context,
          builder: (_) => const SizedBox.shrink(),
        );
        unawaited(nav.push(_route(_Page('A', rec))));
        unawaited(nav.push(dialog));
        await tester.pumpAndSettle();
        expect(rec.events, isNot(contains('A:onPageStart')));
        rec.clear();

        // The gate suppressed A's start; the routePageResume path has to make up
        // for it, otherwise A would stay invisible for the rest of its life.
        nav.pop();
        await tester.pumpAndSettle();

        expect(
          rec.events,
          containsAllInOrder(<String>['A:onPageStart', 'A:onPageResume']),
        );
      },
    );
  });

  group('FlPageRouteMixin', () {
    testWidgets('a plain push emits start and resume', (tester) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _RoutePage('home', rec), rec);

      unawaited(nav.push(_route(_RoutePage('B', rec))));
      await tester.pumpAndSettle();

      expect(
        rec.events,
        containsAllInOrder(<String>['B:onRouteStart', 'B:onRouteResume']),
      );
    });

    testWidgets('a page covered within its first frame does not start', (
      tester,
    ) async {
      final rec = _Recorder();
      final nav = await _pumpApp(tester, _RoutePage('home', rec), rec);

      unawaited(nav.push(_route(_RoutePage('A', rec))));
      unawaited(nav.push(_route(_RoutePage('B', rec))));
      await tester.pumpAndSettle();

      expect(rec.events, isNot(contains('A:onRouteStart')));
      rec.clear();

      nav.pop();
      await tester.pumpAndSettle();

      expect(
        rec.events,
        containsAllInOrder(<String>['A:onRouteStart', 'A:onRouteResume']),
      );
    });

    testWidgets('a page with no ModalRoute still starts on its first frame', (
      tester,
    ) async {
      final rec = _Recorder();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: _RoutePage('plain', rec),
        ),
      );
      await tester.pumpAndSettle();

      expect(rec.events, <String>['plain:onRouteStart', 'plain:onRouteResume']);
    });
  });
}
