import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// Regression tests for "a popup is replaced / removed from under a normal
/// route, and that route is later popped".
///
/// Sequence: page A is visible → a dialog is pushed (A is paused, never
/// stopped) → the dialog is swapped out by `pushReplacement(B)` or
/// `pushAndRemoveUntil(B)` → B is popped back to A.
///
/// `Navigator` reports the swap as `didReplace(B, dialog)` / `didRemove(dialog)`,
/// neither of which tells A anything, so A stays at `appeared && !resumed`.
/// Popping B then delivers `routePageStart` to A (B is not a `PopupRoute`),
/// and before the fix both mixins swallowed it on their "already appeared"
/// guard — A never got its resume back and stayed paused for good.
///
/// Known, accepted gap: while B covers A, A still reports `isPageAppeared`
/// (no stop is sent), because a `NavigatorObserver` cannot see what lies
/// beneath the replaced popup. These tests pin the resume, not the stop.
class _Recorder {
  final List<String> events = <String>[];

  void clear() => events.clear();
}

const Set<FlLifecycleState> _tracked = <FlLifecycleState>{
  FlLifecycleState.onPageStart,
  FlLifecycleState.onPageResume,
  FlLifecycleState.onPagePause,
  FlLifecycleState.onPageStop,
};

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

MaterialPageRoute<void> _route() =>
    MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink());

/// Pushes a dialog over the home page and asserts the page saw exactly one
/// pause, so every scenario starts from the same `appeared && !resumed` state.
Future<void> _showDialog(
  WidgetTester tester,
  NavigatorState nav,
  _Recorder rec,
  String pause,
) async {
  unawaited(
    nav.push(
      DialogRoute<void>(
        context: nav.context,
        builder: (_) => const SizedBox.shrink(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(rec.events, <String>[pause]);
  rec.clear();
}

/// The two ways the dialog can disappear without A being told.
enum _Swap { pushReplacement, pushAndRemoveUntil }

Future<void> _swapDialogFor(NavigatorState nav, _Swap how) async {
  switch (how) {
    case _Swap.pushReplacement:
      // Replaces the top route — the dialog itself — with B.
      unawaited(nav.pushReplacement(_route()));
    case _Swap.pushAndRemoveUntil:
      // Pushes B, then removes everything above A (i.e. the dialog).
      unawaited(nav.pushAndRemoveUntil(_route(), (route) => route.isFirst));
  }
}

void main() {
  for (final how in _Swap.values) {
    group('dialog swapped out via ${how.name}', () {
      testWidgets('FlPageLifecycleMixin: popping back resumes the page', (
        tester,
      ) async {
        final rec = _Recorder();
        final nav = await _pumpApp(tester, _Page('A', rec), rec);
        await _showDialog(tester, nav, rec, 'A:onPagePause');

        await _swapDialogFor(nav, how);
        await tester.pumpAndSettle();
        // Nothing reaches A here: the observer only sees the swap itself.
        expect(rec.events, isEmpty);

        nav.pop();
        await tester.pumpAndSettle();

        // A was never stopped, so this must be a bare resume — no second
        // start — and before the fix it was nothing at all.
        expect(rec.events, <String>['A:onPageResume']);
      });

      testWidgets('FlPageRouteMixin: popping back resumes the page', (
        tester,
      ) async {
        final rec = _Recorder();
        final nav = await _pumpApp(tester, _RoutePage('A', rec), rec);
        await _showDialog(tester, nav, rec, 'A:onRoutePause');

        await _swapDialogFor(nav, how);
        await tester.pumpAndSettle();
        expect(rec.events, isEmpty);

        nav.pop();
        await tester.pumpAndSettle();

        expect(rec.events, <String>['A:onRouteResume']);
      });
    });
  }
}
