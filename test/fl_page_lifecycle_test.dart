import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class _DemoEvent {
  const _DemoEvent(this.value);

  final int value;
}

void main() {
  group('FlEventBus', () {
    test('delivers events to subscribers of the matching type', () async {
      final bus = FlEventBus(sync: true);
      final received = <String>[];
      final sub = bus.on<String>().listen(received.add);

      bus.fire('hello');
      bus.fire(42); // Different type: must be filtered out.
      bus.fire('world');

      expect(received, <String>['hello', 'world']);
      await sub.cancel();
      await bus.destroy();
    });

    test('on<dynamic>() delivers every event without filtering', () async {
      final bus = FlEventBus(sync: true);
      final received = <dynamic>[];
      final sub = bus.on<dynamic>().listen(received.add);

      bus.fire('hello');
      bus.fire(42);

      expect(received, <dynamic>['hello', 42]);
      await sub.cancel();
      await bus.destroy();
    });

    test('customController accepts a matching dynamic controller', () async {
      final controller = StreamController<dynamic>.broadcast(sync: true);
      // The caller owns a controller it brought itself; destroy() below closes
      // it too, and closing twice is a no-op.
      addTearDown(controller.close);
      final bus = FlEventBus.customController(controller);
      final received = <dynamic>[];
      final sub = bus.on<dynamic>().listen(received.add);

      bus.fire('text');
      bus.fire(42);

      expect(received, <dynamic>['text', 42]);
      await sub.cancel();
      await bus.destroy();
    });

    test('a narrowed custom controller throws on a mismatched fire', () {
      // Pinned on purpose: Dart generics are covariant, so a
      // StreamController<String> passes as StreamController<dynamic> and no
      // signature or `is` check can reject it at construction time. The
      // mismatch only surfaces here, on the first incompatible fire.
      final controller = StreamController<String>.broadcast(sync: true);
      addTearDown(controller.close);
      final bus = FlEventBus.customController(controller);

      expect(() => bus.fire('fine'), returnsNormally);
      expect(() => bus.fire(42), throwsA(isA<TypeError>()));
    });

    test('fire is a no-op after destroy', () async {
      final bus = FlEventBus(sync: true);
      final received = <String>[];
      final sub = bus.on<String>().listen(received.add);

      await bus.destroy();
      bus.fire('after-close'); // Must not throw.

      expect(received, isEmpty);
      await sub.cancel();
    });
  });

  group('FlGlobalEventBus', () {
    setUp(() async {
      await FlGlobalEventBus.destroy();
    });

    tearDown(() async {
      await FlGlobalEventBus.destroy();
    });

    test('dispatches and observes typed events', () async {
      final received = <_DemoEvent>[];
      final sub = FlGlobalEventBus.observeEvent<_DemoEvent>().listen(
        received.add,
      );

      FlGlobalEventBus.dispatchEvent(const _DemoEvent(1));
      FlGlobalEventBus.dispatchEvent(const _DemoEvent(2));
      await pumpEventQueue();

      expect(received.map((e) => e.value), <int>[1, 2]);
      await sub.cancel();
    });

    test('observers of other types do not receive the event', () async {
      final strings = <String>[];
      final ints = <int>[];
      final subS = FlGlobalEventBus.observeEvent<String>().listen(strings.add);
      final subI = FlGlobalEventBus.observeEvent<int>().listen(ints.add);

      FlGlobalEventBus.dispatchEvent('text');
      await pumpEventQueue();

      expect(strings, <String>['text']);
      expect(ints, isEmpty);
      await subS.cancel();
      await subI.cancel();
    });

    test('is lazily re-created after destroy', () async {
      final received = <String>[];
      final sub = FlGlobalEventBus.observeEvent<String>().listen(received.add);

      await FlGlobalEventBus.destroy();
      // Using the bus again must transparently recreate the instance.
      FlGlobalEventBus.dispatchEvent('after-destroy');
      await pumpEventQueue();

      // The previous subscription died with the old controller.
      expect(received, isEmpty);
      await sub.cancel();
    });
  });

  group('FlLifecycleState', () {
    test('exposes page resume/pause flags', () {
      expect(FlLifecycleState.onPageResume.isPageResume, isTrue);
      expect(FlLifecycleState.onPagePause.isPagePause, isTrue);
      expect(FlLifecycleState.onPageStart.isPageResume, isFalse);
      expect(FlLifecycleState.onPageStop.isPagePause, isFalse);
    });
  });
}
