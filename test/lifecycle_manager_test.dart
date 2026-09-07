import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

void main() {
  // FlLifecycleManager is a process-wide singleton, so every test has to hand
  // it back in a quiet state or it leaks a WidgetsBinding observer into the
  // next one.
  tearDown(FlLifecycleManager.instance.cancel);

  /// Drives a real lifecycle transition through the binding, so the manager
  /// only observes it while it is actually registered.
  ///
  /// `tester.idle()` — not `pumpEventQueue()` — flushes the broadcast stream's
  /// delivery microtasks: inside `testWidgets` the clock is faked, and
  /// `pumpEventQueue` waits on real timers that never fire, hanging the test.
  Future<void> dispatch(WidgetTester tester, AppLifecycleState state) async {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.idle();
  }

  testWidgets('an existing subscription survives cancel() + listen()', (
    tester,
  ) async {
    final manager = FlLifecycleManager.instance;
    final foreground = <bool>[];
    final states = <AppLifecycleState>[];

    final subF = manager.stream.listen(foreground.add);
    final subL = manager.lifecycle.listen(states.add);
    addTearDown(subF.cancel);
    addTearDown(subL.cancel);
    // Drain the cold-start foreground replay, whose timing depends on the
    // binding's current lifecycleState.
    await tester.idle();

    manager.cancel();
    manager.listen();
    await tester.idle();
    foreground.clear();
    states.clear();

    await dispatch(tester, AppLifecycleState.paused);

    // Before the fix, cancel() closed both controllers; these two subscribers
    // were silently dead from that point on, and re-listen() built fresh
    // controllers they were never migrated to.
    expect(foreground, <bool>[false]);
    expect(states, <AppLifecycleState>[AppLifecycleState.paused]);
  });

  testWidgets('cancel() + listen() does not replay a foreground event', (
    tester,
  ) async {
    final manager = FlLifecycleManager.instance;
    final foreground = <bool>[];
    final sub = manager.stream.listen(foreground.add);
    addTearDown(sub.cancel);
    // Make the resumed state explicit: the cold-start replay is conditional on
    // it, so without this the test would silently stop discriminating
    // depending on which case ran before it.
    await dispatch(tester, AppLifecycleState.resumed);
    foreground.clear();

    manager.cancel();
    manager.listen();
    await tester.idle();

    // The app never left the foreground, and this subscriber was listening the
    // whole time — it must not be told the app came back. cancel() used to
    // reset _hasEverSentForeground, which made the next listen() replay the
    // cold-start foreground event to everyone still attached.
    expect(foreground, isEmpty);
  });

  testWidgets('cancel() stops forwarding until listen() is called again', (
    tester,
  ) async {
    final manager = FlLifecycleManager.instance;
    final foreground = <bool>[];
    final sub = manager.stream.listen(foreground.add);
    addTearDown(sub.cancel);
    await tester.idle();
    foreground.clear();

    manager.cancel();
    await dispatch(tester, AppLifecycleState.paused);
    // Observer removed: nothing should come through.
    expect(foreground, isEmpty);

    manager.listen();
    await dispatch(tester, AppLifecycleState.paused);
    expect(foreground, <bool>[false]);
  });

  testWidgets('paused then resumed reports a real foreground transition', (
    tester,
  ) async {
    final manager = FlLifecycleManager.instance;
    final foreground = <bool>[];
    final sub = manager.stream.listen(foreground.add);
    addTearDown(sub.cancel);
    await tester.idle();
    foreground.clear();

    await dispatch(tester, AppLifecycleState.paused);
    await dispatch(tester, AppLifecycleState.resumed);

    expect(foreground, <bool>[false, true]);
  });

  testWidgets('an inactive to resumed blip is not a foreground transition', (
    tester,
  ) async {
    final manager = FlLifecycleManager.instance;
    final foreground = <bool>[];
    final sub = manager.stream.listen(foreground.add);
    addTearDown(sub.cancel);
    await tester.idle();

    // Burn the cold-start slot first: _hasEverSentForeground has to be set,
    // otherwise the resumed below counts as the initial foreground event.
    await dispatch(tester, AppLifecycleState.resumed);
    foreground.clear();

    await dispatch(tester, AppLifecycleState.inactive);
    await dispatch(tester, AppLifecycleState.resumed);

    // Phone call, notification shade, app switcher: the app never left.
    expect(foreground, isEmpty);
  });
}
