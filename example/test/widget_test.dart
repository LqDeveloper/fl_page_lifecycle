import 'package:flutter_test/flutter_test.dart';

import 'package:example/main.dart';
import 'package:example/src/home_page.dart';

void main() {
  testWidgets('the home page lists every demo entry', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('fl_page_lifecycle 示例'), findsOneWidget);
    expect(find.text('FlPageLifecycleMixin'), findsOneWidget);
  });

  testWidgets('tapping an entry pushes its demo route', (tester) async {
    await tester.pumpWidget(const MyApp());

    // The named routes in MyApp are what the cards push; a broken route table
    // only shows up once one is actually navigated to.
    // The list is a lazy ListView, so an entry far enough down is not in the
    // tree at all — scroll to it rather than assuming it was built. Using
    // ensureVisible here breaks the moment a new demo entry is added above it.
    final entry = find.text('FlAppLifecycleMixin');
    await tester.scrollUntilVisible(entry, 200);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsNothing);

    // Back out so the demo page's dispose path runs inside the test too.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
  });
}
