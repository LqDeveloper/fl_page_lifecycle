import 'package:example/src/animation_page.dart';
import 'package:example/src/app_lifecycle_page.dart';
import 'package:example/src/controller_page.dart';
import 'package:example/src/event_bus_page.dart';
import 'package:example/src/home_page.dart';
import 'package:example/src/indexed_stack_page.dart';
import 'package:example/src/lifecycle_view_page.dart';
import 'package:example/src/nested_navigator_page.dart';
import 'package:example/src/page_lifecycle_page.dart';
import 'package:example/src/page_view_page.dart';
import 'package:example/src/route_page.dart';
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const HomePage(),
      navigatorObservers: [FlRouteObserver()],
      routes: {
        "/FlAnimationLifecycleMixin": (_) => AnimationPage(),
        "/FlAppLifecycleMixin": (_) => AppLifecyclePage(),
        "/FlPageRouteMixin_one": (_) => RouteOnePage(),
        "/FlPageRouteMixin_two": (_) => RouteTwoPage(),
        "/FlPageLifecycleMixin": (_) => PageLifecyclePage(),
        "/FlPageLifecycleView": (_) => LifecycleViewPage(),
        "/FlPageControllerMixin": (_) => ControllerPage(),
        "/PageViewPage": (_) => PageViewPage(),
        "/IndexedStackPage": (_) => IndexedStackPage(),
        '/NestedNavigatorPage': (_) => NestedNavigatorPage(),
        "/FlStateEventBusMixin": (_) => EventBusPage(),
      },
    );
  }
}
