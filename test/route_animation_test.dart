import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
import 'package:fl_page_lifecycle/src/delegate/fl_route_animation_binding.dart';

// Same-package import: the binding is @internal, but its repeat-emission
// behaviour is part of the documented contract of every mixin that exposes
// these callbacks, so it gets pinned directly.

/// Guards `FlRouteAnimationBinding`, the transition-animation listener shared
/// by `FlPageRouteDelegate` (and through it `FlPageLifecycleMixin` /
/// `FlPageRouteMixin`) and `FlAnimationLifecycleMixin`.
///
/// The two used to carry separate copies of the same status switch, one of
/// which had drifted. These tests pin the behaviour both now route through.

class _Recorder {
  final List<String> events = <String>[];

  void clear() => events.clear();
}

/// Animation callbacks via the full state machine.
class _LifecyclePage extends StatefulWidget {
  const _LifecyclePage(this.recorder);

  final _Recorder recorder;

  @override
  State<_LifecyclePage> createState() => _LifecyclePageState();
}

class _LifecyclePageState extends State<_LifecyclePage>
    with FlPageLifecycleMixin {
  @override
  void onPageEnterAnimationStart() => widget.recorder.events.add('enterStart');

  @override
  void onPageEnterAnimationEnd() => widget.recorder.events.add('enterEnd');

  @override
  void onPageLeaveAnimationStart() => widget.recorder.events.add('leaveStart');

  @override
  void onPageLeaveAnimationEnd() => widget.recorder.events.add('leaveEnd');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Animation callbacks via the standalone mixin.
class _AnimationPage extends StatefulWidget {
  const _AnimationPage(this.recorder);

  final _Recorder recorder;

  @override
  State<_AnimationPage> createState() => _AnimationPageState();
}

class _AnimationPageState extends State<_AnimationPage>
    with FlAnimationLifecycleMixin {
  @override
  void onPageEnterAnimationStart() => widget.recorder.events.add('enterStart');

  @override
  void onPageEnterAnimationEnd() => widget.recorder.events.add('enterEnd');

  @override
  void onPageLeaveAnimationStart() => widget.recorder.events.add('leaveStart');

  @override
  void onPageLeaveAnimationEnd() => widget.recorder.events.add('leaveEnd');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<NavigatorState> _pumpApp(WidgetTester tester) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: key,
      navigatorObservers: <NavigatorObserver>[FlRouteObserver.instance],
      home: const SizedBox.shrink(),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

/// Pushes [page], lets the transition finish, then pops it and lets the
/// reverse transition finish. Returns everything [rec] recorded across both.
Future<List<String>> _pushThenPop(
  WidgetTester tester,
  Widget page,
  _Recorder rec,
) async {
  final nav = await _pumpApp(tester);

  unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => page)));
  await tester.pumpAndSettle();
  final afterPush = List<String>.of(rec.events);
  rec.clear();

  nav.pop();
  await tester.pumpAndSettle();

  return <String>[...afterPush, ...rec.events];
}

void main() {
  group('FlRouteAnimationBinding repeat emission', () {
    // Every mixin exposing onPageEnterAnimationEnd documents that it MAY FIRE
    // MORE THAN ONCE, and tells callers to keep whatever they put there
    // idempotent. That warning was once missing from FlAnimationLifecycleMixin,
    // whose doc instead recommended firing network requests there — so the
    // behaviour is pinned here rather than left to prose.
    testWidgets('a cancelled swipe-back emits enterEnd a second time', (
      tester,
    ) async {
      final events = <String>[];
      final controller = AnimationController(
        duration: const Duration(milliseconds: 100),
        vsync: tester,
      );
      addTearDown(controller.dispose);

      final binding = FlRouteAnimationBinding(
        onEnterStart: () => events.add('enterStart'),
        onEnterEnd: () => events.add('enterEnd'),
        onLeaveStart: () => events.add('leaveStart'),
        onLeaveEnd: () => events.add('leaveEnd'),
      );
      addTearDown(binding.detach);
      binding.attach(controller.view);

      // Push completes: first enterEnd.
      await tester.pumpAndSettle();
      unawaited(controller.forward());
      await tester.pumpAndSettle();
      expect(events, <String>['enterStart', 'enterEnd']);

      // User drags back, then lets go without completing the pop: the route
      // animation reverses and then runs forward again to completed.
      unawaited(controller.reverse());
      await tester.pump(const Duration(milliseconds: 40));
      unawaited(controller.forward());
      await tester.pumpAndSettle();

      // The load-bearing fact: `completed` arrives a second time, so
      // onPageEnterAnimationEnd fires twice in one lifecycle. Asserted as a
      // count rather than an exact sequence — which statuses AnimationController
      // reports in between (here `forward` is not re-notified) is its own
      // implementation detail, and a real Navigator drives a ProxyAnimation
      // rather than a bare controller.
      expect(
        events.where((e) => e == 'enterEnd'),
        hasLength(2),
        reason: 'enterEnd must fire twice: $events',
      );
      expect(events, contains('leaveStart'));
    });

    testWidgets('attachOnceFrom retries until a ModalRoute is available', (
      tester,
    ) async {
      final binding = FlRouteAnimationBinding(
        onEnterStart: () {},
        onEnterEnd: () {},
        onLeaveStart: () {},
        onLeaveEnd: () {},
      );
      addTearDown(binding.detach);

      late BuildContext noRoute;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (c) {
              noRoute = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // No ModalRoute yet: must report failure and must NOT latch — a page can
      // be mounted as a plain child first and pushed into a route afterwards.
      expect(binding.attachOnceFrom(noRoute), isFalse);
      expect(binding.animation, isNull);

      late BuildContext withRoute;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              withRoute = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(binding.attachOnceFrom(withRoute), isTrue);
      expect(binding.animation, isNotNull);

      // ...and exactly once, so the host never double-subscribes.
      expect(binding.attachOnceFrom(withRoute), isFalse);
    });

    testWidgets('detach() stops emission even mid-notification', (
      tester,
    ) async {
      final events = <String>[];
      final controller = AnimationController(
        duration: const Duration(milliseconds: 100),
        vsync: tester,
      );
      addTearDown(controller.dispose);

      final binding = FlRouteAnimationBinding(
        onEnterStart: () => events.add('enterStart'),
        onEnterEnd: () => events.add('enterEnd'),
        onLeaveStart: () => events.add('leaveStart'),
        onLeaveEnd: () => events.add('leaveEnd'),
      );
      binding.attach(controller.view);
      binding.detach();

      unawaited(controller.forward());
      await tester.pumpAndSettle();

      expect(events, isEmpty);
    });
  });

  group('FlPageLifecycleMixin transition animation', () {
    testWidgets('reports enterEnd on push and leaveStart/leaveEnd on pop', (
      tester,
    ) async {
      final rec = _Recorder();
      final events = await _pushThenPop(tester, _LifecyclePage(rec), rec);

      // enterStart is not asserted: the listener is attached in
      // didChangeDependencies, after Navigator already drove the animation to
      // forward, so the first push may or may not catch it. The library
      // documents that and points callers at onPageContextReady instead.
      expect(events, containsAllInOrder(<String>['enterEnd', 'leaveEnd']));
      expect(events, contains('leaveStart'));
    });
  });

  group('FlAnimationLifecycleMixin', () {
    testWidgets('reports the same transitions as the full mixin', (
      tester,
    ) async {
      final rec = _Recorder();
      final events = await _pushThenPop(tester, _AnimationPage(rec), rec);

      expect(events, containsAllInOrder(<String>['enterEnd', 'leaveEnd']));
      expect(events, contains('leaveStart'));
    });

    testWidgets(
      'a page with no ModalRoute reports nothing and does not throw',
      (tester) async {
        final rec = _Recorder();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: _AnimationPage(rec),
          ),
        );
        await tester.pumpAndSettle();

        // attach() is never reached, so dispose() must still be safe.
        await tester.pumpWidget(const SizedBox.shrink());

        expect(rec.events, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('FlRouteObserver.didReplace', () {
    testWidgets('stops the replaced route and starts the new one', (
      tester,
    ) async {
      final visibility = <String>[];

      final nav = await _pumpApp(tester);
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => _VisibilityPage('old', visibility),
          ),
        ),
      );
      await tester.pumpAndSettle();
      visibility.clear();

      // didReplace shares _handleRouteGone with didPop/didRemove, passing
      // previousRoute: null — the layer below stays covered by the new route
      // and must not be woken up.
      unawaited(
        nav.pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => _VisibilityPage('new', visibility),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(visibility, containsAllInOrder(<String>['old:stop', 'new:start']));
    });
  });
}

/// Minimal page that records only start/stop, for the didReplace test.
class _VisibilityPage extends StatefulWidget {
  const _VisibilityPage(this.tag, this.log);

  final String tag;
  final List<String> log;

  @override
  State<_VisibilityPage> createState() => _VisibilityPageState();
}

class _VisibilityPageState extends State<_VisibilityPage>
    with FlPageLifecycleMixin {
  @override
  void onPageStart() => widget.log.add('${widget.tag}:start');

  @override
  void onPageStop() => widget.log.add('${widget.tag}:stop');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
