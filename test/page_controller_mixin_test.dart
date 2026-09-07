import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// Records which template callback [FlPageControllerMixin] dispatched to.
class _Probe with FlPageControllerMixin {
  final List<String> fired = <String>[];

  @override
  void onPageInit() => fired.add('onPageInit');

  @override
  void onPageContextReady(BuildContext? context) =>
      fired.add('onPageContextReady');

  @override
  void onPagePostFrame() => fired.add('onPagePostFrame');

  @override
  void onPageReassemble() => fired.add('onPageReassemble');

  @override
  void onPageStart() => fired.add('onPageStart');

  @override
  void onPageResume() => fired.add('onPageResume');

  @override
  void onPageEnterAnimationStart() => fired.add('onPageEnterAnimationStart');

  @override
  void onPageEnterAnimationEnd() => fired.add('onPageEnterAnimationEnd');

  @override
  void onPagePause() => fired.add('onPagePause');

  @override
  void onPageStop() => fired.add('onPageStop');

  @override
  void onPageLeaveAnimationStart() => fired.add('onPageLeaveAnimationStart');

  @override
  void onPageLeaveAnimationEnd() => fired.add('onPageLeaveAnimationEnd');

  @override
  void onPageDispose() => fired.add('onPageDispose');

  @override
  void onAppResume() => fired.add('onAppResume');

  @override
  void onAppInactive() => fired.add('onAppInactive');

  @override
  void onAppPause() => fired.add('onAppPause');

  @override
  void onAppForeground() => fired.add('onAppForeground');

  @override
  void onAppBackground() => fired.add('onAppBackground');
}

void main() {
  group('FlPageControllerMixin.onLifecycleChanged', () {
    // FlPageLifecycleMixin, FlPageControllerMixin, FlPageRouteMixin and
    // FlAnimationLifecycleMixin each declare their own copy of this callback
    // surface on purpose — their idempotency contracts differ, so merging them
    // behind one base class would flatten three different guarantees into one.
    //
    // The cost of keeping them separate is that adding a lifecycle event means
    // touching several files. The 18-arm switch here is where a copy-paste slip
    // hides: two arms calling the same callback compiles fine and silently
    // drops an event. That is what this test pins down.
    test(
      'dispatches every FlLifecycleState to exactly one distinct callback',
      () {
        final mapping = <FlLifecycleState, String>{};

        for (final state in FlLifecycleState.values) {
          final probe = _Probe();
          probe.onLifecycleChanged(state);
          expect(
            probe.fired,
            hasLength(1),
            reason: '$state must reach exactly one template callback',
          );
          mapping[state] = probe.fired.single;
        }

        // A callback reached from two different states means one of them was
        // wired to the wrong arm.
        expect(
          mapping.values.toSet(),
          hasLength(FlLifecycleState.values.length),
          reason: 'two states share a callback: $mapping',
        );
      },
    );

    test('caches the last received state', () {
      final probe = _Probe();
      expect(probe.lifecycleState, FlLifecycleState.onPageInit);

      probe.onLifecycleChanged(FlLifecycleState.onPageResume);
      expect(probe.lifecycleState, FlLifecycleState.onPageResume);
      expect(probe.isPageResume, isTrue);
      expect(probe.isPagePause, isFalse);

      probe.onLifecycleChanged(FlLifecycleState.onPagePause);
      expect(probe.isPagePause, isTrue);
      expect(probe.isPageResume, isFalse);
    });

    test('setupRouteInfo exposes the route name and arguments', () {
      final probe = _Probe();
      expect(probe.routeName, isNull);
      expect(probe.arguments, isNull);

      probe.setupRouteInfo('/detail', <String, String>{'id': '7'});

      expect(probe.routeName, '/detail');
      expect(probe.arguments, <String, String>{'id': '7'});
    });
  });
}
