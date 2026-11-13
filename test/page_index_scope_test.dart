import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

void main() {
  group('FlPageIndexScope.indexOf', () {
    testWidgets('returns null for a zero-length TabController', (tester) async {
      final controller = TabController(length: 0, vsync: const TestVSync());
      addTearDown(controller.dispose);

      // length - 1 is -1, and num.clamp throws an ArgumentError when
      // upperLimit < lowerLimit. Callers treat null as "not available yet".
      expect(FlPageIndexScope.indexOf(controller), isNull);
    });

    testWidgets('returns the current index for a normal TabController', (
      tester,
    ) async {
      final controller = TabController(
        length: 3,
        initialIndex: 1,
        vsync: const TestVSync(),
      );
      addTearDown(controller.dispose);

      expect(FlPageIndexScope.indexOf(controller), 1);
    });
  });

  group('FlPageIndexScope', () {
    testWidgets('builds with a zero-length TabController without throwing', (
      tester,
    ) async {
      final controller = TabController(length: 0, vsync: const TestVSync());
      addTearDown(controller.dispose);

      // The wrap helpers generate no Scope for an empty child list, but the
      // constructor is public and tabs loaded on demand start out empty.
      await tester.pumpWidget(
        MaterialApp(
          home: FlPageIndexScope(
            pageIndex: 0,
            controller: controller,
            child: const SizedBox.shrink(),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('tracks the selected tab of a normal TabController', (
      tester,
    ) async {
      final controller = TabController(length: 3, vsync: const TestVSync());
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: TabBarView(
            controller: controller,
            children: FlPageIndexScope.wrapChildren(
              controller: controller,
              children: const <Widget>[
                SizedBox.shrink(),
                SizedBox.shrink(),
                SizedBox.shrink(),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(FlPageIndexScope.indexOf(controller), 0);

      controller.animateTo(2);
      await tester.pumpAndSettle();

      expect(FlPageIndexScope.indexOf(controller), 2);
      expect(tester.takeException(), isNull);
    });
  });
}
