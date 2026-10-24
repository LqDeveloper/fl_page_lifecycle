# fl_page_lifecycle

Android-style page lifecycle for Flutter: `start` / `resume` / `pause` / `stop` on any `State`,
plus first frame, route transition animations, app foreground/background and index-driven
containers (`PageView`, `TabBarView`, `IndexedStack`).

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

English | [中文](README_zh.md)

---

- [Why](#why-fl_page_lifecycle)
- [Features](#features)
- [Which entry point do I need?](#which-entry-point-do-i-need)
- [Compared with `visibility_detector`](#compared-with-visibility_detector)
- [Compatibility](#compatibility)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Event timing](#event-timing)
- [API reference](#api-reference)
- [Dependencies](#dependencies)
- [Notes & caveats](#notes--caveats)

## Why fl_page_lifecycle?

Flutter gives you `initState` and `dispose`. It does not tell you when your page became
*visible* or *interactive* — and those are the moments that matter for video playback,
polling timers, analytics impressions and animations.

Answering "is my page visible right now?" by hand means combining `RouteAware`,
`WidgetsBindingObserver`, `ModalRoute.of(context)!.isCurrent`, a `PageController` listener
and a first-frame callback — and then getting the edge cases right:

- A dialog covers your page. It is still visible, so you want `pause`, not `stop`.
  `isCurrent` returns `false` and cannot tell the difference.
- `pushAndRemoveUntil` fires `didRemove` for a route that is *still* covered by another one.
  A naive `RouteAware` implementation emits a `start` for a page nobody can see.
- An iOS swipe-back gesture, abandoned halfway, plays a leave animation that never completes.
- Your page is disposed while paused, so the `resume` you were waiting on never arrives.

This package does that bookkeeping once and gives you paired, idempotent callbacks:
**every `start` is followed by a `stop`, every `pause` by a `resume` or a `stop`**, and the
missing half is emitted on `dispose`. Mix in one mixin, override the callbacks you care about;
there is nothing to initialize and nothing to release.

## Features

- Full visibility state machine — `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop`,
  paired and idempotent; popups pause but do not stop
- Route transition animation callbacks, including cancelled iOS swipe-back
- App foreground/background, with phone calls and the notification shade filtered out
- Children of `PageView`, `TabBarView` and `IndexedStack` driven by page index instead of routes
- Nested `Navigator`s supported via a forwarding observer
- Works without touching your class hierarchy — [mixin](#1-page-lifecycle-on-a-state),
  [wrapper widget](#4-no-mixin--wrap-a-widget-instead) or [plain Dart object](#5-lifecycle-in-a-controller--viewmodel)
- Page-scoped global event bus whose subscriptions cancel themselves on `dispose`
- One third-party dependency (`meta`), no platform channels, no code generation

## Which entry point do I need?

| You want | Use |
|---|---|
| The whole thing on a `State` | [`FlPageLifecycleMixin`](#1-page-lifecycle-on-a-state) |
| The same, for a `PageView` / `TabBarView` / `IndexedStack` child | [`FlPageIndexScope`](#2-pages-inside-an-index-driven-container) + `observePageIndex` |
| Pages inside a nested `Navigator` | [`FlRouteObserverProxy`](#3-nested-navigators) |
| Events without mixing into `State` | [`FlPageLifecycleView`](#4-no-mixin--wrap-a-widget-instead) |
| Events in a Controller / ViewModel | [`FlPageControllerMixin`](#5-lifecycle-in-a-controller--viewmodel) |
| Only app foreground/background | `FlAppLifecycleMixin` |
| Only route transition animations | `FlAnimationLifecycleMixin` |
| Only route events, without popup or page-index handling | `FlPageRouteMixin` |

The last three are standalone. **Do not stack them on top of `FlPageLifecycleMixin`** — it
already subscribes to the same sources, and you would receive every event twice.

## Compared with `visibility_detector`

[`visibility_detector`](https://pub.dev/packages/visibility_detector) answers a **geometric**
question: how much of this widget's bounding box is inside the viewport? This package answers a
**navigational** one: is this page the one the user is on? Neither subsumes the other.

| | `visibility_detector` | `fl_page_lifecycle` |
|---|---|---|
| Unit of observation | Any widget, identified by a unique `Key` | A route page or index-driven container child |
| What it reports | `visibleFraction`, `visibleBounds` — continuous | Discrete events: `start` / `resume` / `pause` / `stop` |
| Scrolled out of a `ListView` | Detected — its core use case | **Not** detected |
| Covered by a dialog / bottom sheet | Not accounted for | `pause`, then `resume` when it closes |
| Route push / pop | Not covered | Its core use case |
| App foreground / background | Not covered | Covered, transient interruptions filtered out |
| Setup | None — just wrap a widget | Register `FlRouteObserver` on the `Navigator` |

**Autoplaying video in a feed needs both**: this package tells you the feed page is resumed at
all — otherwise you autoplay on a page the user already left — and `visibility_detector` tells
you which card is on screen. Keep the two signals in separate fields and decide in one place;
do not call `play()` from both callbacks.

## Compatibility

| Item | Requirement |
|---|---|
| Dart SDK | `^3.11.5` |
| Flutter | `>=3.41.9` |
| Platforms | All platforms Flutter supports — no plugin, no platform channels, no `dart:io` |

Platform support is inherited from your Flutter version: this package contains no
platform-specific implementation of any kind.

## Installation

```yaml
dependencies:
  fl_page_lifecycle: ^0.0.4
```

```bash
flutter pub get
```

## Quick start

Two steps. **Skipping the first one is the single most common problem** — without the observer
the four visibility callbacks never fire, and nothing is logged or thrown.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Step 1 — register the observer. Nested Navigators need their own, see below.
      navigatorObservers: [FlRouteObserver()],
      home: const DetailPage(),
    );
  }
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

// Step 2 — mix it in and override what you need. No init, no dispose.
class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  @override
  void onPageResume() => debugPrint('visible and interactive');

  @override
  void onPagePause() => debugPrint('covered by a dialog, or leaving');

  @override
  Widget build(BuildContext context) => const Scaffold();
}
```

## Usage

### 1. Page lifecycle on a `State`

**When to use it**: a route page that has to stop doing something while the user is elsewhere —
a video, a polling timer, an animation — and resume when they come back.

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class _FeedPageState extends State<FeedPage> with FlPageLifecycleMixin {
  Timer? _poll;
  bool _didLoadHeavy = false;

  // Both switches default to false and must stay constant for the whole lifetime.
  @override
  bool get observeAppLifecycle => true;

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    // Earliest point where routeName / arguments are readable.
    debugPrint('opened $routeName with $arguments');
  }

  @override
  void onPageResume() {
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void onPagePause() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void onPageEnterAnimationEnd() {
    if (_didLoadHeavy) return; // may fire twice — see Notes
    _didLoadHeavy = true;
    _decodeLargeImages();
  }

  @override
  void onAppForeground() => _refresh(); // really came back, not just a notification shade

  @override
  void onPageDispose() => _poll?.cancel();

  void _refresh() {}
  void _decodeLargeImages() {}

  @override
  Widget build(BuildContext context) => const Scaffold();
}
```

**Switches**

| Name | Type | Default | Description |
|---|---|---|---|
| `observePageIndex` | `bool` | `false` | Drive visibility by page index instead of routes. Requires an enclosing `FlPageIndexScope` |
| `observeAppLifecycle` | `bool` | `false` | Subscribe to app foreground/background. Costs two global stream subscriptions per instance |

**Readable at any time**

`isPageAppeared`, `isPageResumed`, `isForeground`, `routeName`, `arguments`, `isCurrent`,
`isInPageScope`, `pageIndex`, `currentPageIndex`, `pageScopeDepth`.

**Notes**

- Use `isPageAppeared` to ask "is this page visible" — **not** `isCurrent`, which is `false`
  while a dialog is on top even though the page is fully visible.
- Both switches are read early and must be compile-time constants. Returning
  `widget.something` from them trips an assertion in debug.
- `onPageEnterAnimationEnd` can fire twice: an abandoned iOS swipe-back drives the animation
  `reverse → forward → completed`. Anything with side effects there must be idempotent.

### 2. Pages inside an index-driven container

**When to use it**: children of a `PageView`, `TabBarView` or `IndexedStack`. They all stay
alive when they scroll out of view, so nothing tells them they went away — `dispose` does not
run and the route did not change.

Wrap the children once on the container side; the page index is injected for you.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class _TabsPageState extends State<TabsPage> {
  final _controller = PageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _controller,
      children: FlPageIndexScope.wrapChildren(
        controller: _controller,
        children: const [HomeTab(), FeedTab(), MineTab()],
      ),
    );
  }
}

class _FeedTabState extends State<FeedTab> with FlPageLifecycleMixin {
  // Without this the child is treated as an ordinary page: it starts on the
  // first frame and never stops again.
  @override
  bool get observePageIndex => true;

  @override
  void onPageStart() => debugPrint('this tab is now the current page');

  @override
  void onPageStop() => debugPrint('swiped away');

  @override
  void onPageIndexChanged(int from, int to) => debugPrint('$from -> $to');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
```

`IndexedStack` has no controller, so pass the `ValueListenable<int>` that drives its `index` —
the same object feeds both, so they cannot disagree:

```dart
final _index = ValueNotifier<int>(0);
late final _pages = FlPageIndexScope.wrapChildren(
  controller: _index,
  children: const [HomeTab(), FeedTab(), MineTab()],
);

void onTap(int i) => _index.value = i;

@override
Widget build(BuildContext context) => ValueListenableBuilder<int>(
  valueListenable: _index,
  builder: (context, index, _) => IndexedStack(index: index, children: _pages),
);
```

**Statics on `FlPageIndexScope`**

| Name | Signature | Description |
|---|---|---|
| `wrapChildren` | `({required Listenable controller, required List<Widget> children}) → List<Widget>` | Wrap a child list; index = position |
| `wrapItemBuilder` | `({required Listenable controller, required NullableIndexedWidgetBuilder builder}) → NullableIndexedWidgetBuilder` | Wrap `PageView.builder`'s `itemBuilder` |
| `depthOf` | `(BuildContext) → int` | Scope nesting depth; outermost `0`, `-1` when not in a scope |
| `indexOf` | `(Listenable) → int?` | Current index of a controller; `null` when not yet available |
| `initialIndexOf` | `(Listenable) → int` | Fallback index used before `indexOf` is available |
| `listenableOf` | `(Listenable) → Listenable` | The object to subscribe to for paging notifications |

**Notes**

- `controller` accepts `PageController`, `TabController` or `ValueListenable<int>`; anything
  else trips an assertion in debug.
- **Scrolling containers commit visibility only once they settle.** `animateToPage(0 → 4)`
  sweeps across the pages in between, but they emit nothing at all — otherwise analytics would
  record three phantom page views. `jumpToPage` creates no scroll activity and commits at once.
  `IndexedStack` has no intermediate state and also commits immediately.
- **When nesting, wrap every layer.** Wrapping only the outer one is not an error: the inner
  child silently binds to the outer scope and never stops when its own container pages away.
  Debug builds print a warning once.

### 3. Nested `Navigator`s

**When to use it**: go_router's `ShellRoute` / `StatefulShellRoute`, auto_route's nested
routers, or a hand-written per-tab stack — anything where more than one `Navigator` is alive
at the same time.

`FlRouteObserver` is a singleton, and Flutter's `Navigator` asserts that one observer instance
is bound to at most one `NavigatorState`. Give the root the singleton and every nested
`Navigator` its own proxy, which forwards into the same subscription table:

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class TabStack extends StatelessWidget {
  const TabStack({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      // A fresh proxy per Navigator. Reusing one trips the same assertion.
      observers: [FlRouteObserverProxy()],
      onGenerateRoute: (settings) =>
          MaterialPageRoute<void>(settings: settings, builder: builder),
    );
  }
}
```

With go_router the shape is the same — `GoRouter(observers: [FlRouteObserver()])` for the root
and `ShellRoute(observers: [FlRouteObserverProxy()])` for each shell.

**Notes**

- A page only tracks **its own** `Navigator`. When an outer route covers the whole nested
  `Navigator`, the inner page is not notified. If you need that, put a
  `FlPageLifecycleView` around the nested `Navigator` and forward from there.
- `showDialog` defaults to `useRootNavigator: true`. Pass `false` if you want the pages in the
  nested stack to receive `onPagePause`.

### 4. No mixin — wrap a widget instead

**When to use it**: the page is a `StatelessWidget`, its `State` already has the mixins it can
take, or you only want to observe one subtree.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FlPageLifecycleView(
      onStateChanged: (context, state) {
        if (state == FlLifecycleState.onPageResume) debugPrint('resumed');
      },
      onRouteParam: (context, routeName, arguments) => debugPrint('$routeName'),
      child: const Scaffold(),
    );
  }
}
```

**Parameters**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `observePageIndex` | `bool` | `false` | Same meaning as on the mixin |
| `observeAppLifecycle` | `bool` | `false` | Same meaning as on the mixin |
| `onStateChanged` | `FlPageLifecycleCallback?` | `null` | Every `FlLifecycleState` event |
| `onRouteParam` | `FlPageRouteParamCallback?` | `null` | Route name and arguments, once ready |
| `onPageIndexChanged` | `FlPageIndexChangedCallback?` | `null` | Page index changed, `(from, to)` |
| `child` | `Widget` | required | Returned as-is; adds no layout node |

**Notes**

- Do not look up `InheritedWidget`s from the callback `context` during `onPageInit` or
  `onPageDispose`; the `State` is not attached yet, or is being unmounted.
- Each instance is a full state machine. A handful per page is free; a few hundred in a list
  is not, especially with `observeAppLifecycle: true` (two global subscriptions each).

### 5. Lifecycle in a Controller / ViewModel

**When to use it**: the code that starts and stops work lives outside the widget tree.

`FlPageControllerMixin` **subscribes to nothing** — the page has to forward events into it.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class DetailController with FlPageControllerMixin {
  @override
  void onPageResume() => debugPrint('start polling');

  @override
  void onPagePause() => debugPrint('stop polling');

  // Note the signature: BuildContext?, not (String?, Object?).
  @override
  void onPageContextReady(BuildContext? context) => debugPrint('$routeName');
}

class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  final _controller = DetailController();

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state); // required
    _controller.onLifecycleChanged(state, context: context);
  }

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    _controller.setupRouteInfo(routeName, arguments);
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
```

**Notes**

- Two forwards are required (`onLifecycleChanged` and `setupRouteInfo`); page index changes
  need a third, since they are not part of `FlLifecycleState`.
- The mixin holds no subscription and therefore has no `dispose` — release your own resources
  in `onPageDispose`.

### 6. Page-scoped global events

**When to use it**: one page has to react to something that happened on another — a login, a
cart update — without wiring a stream through the tree.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class LoginSuccess {
  const LoginSuccess(this.userId);
  final String userId;
}

class _HeaderState extends State<Header> with FlStateEventBusMixin {
  @override
  void initState() {
    super.initState();
    // Pass a method reference, not a closure literal — see Notes.
    observeEvent<LoginSuccess>(_onLogin);
  }

  void _onLogin(LoginSuccess event) => setState(() {});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// Anywhere else:
void publish() => FlGlobalEventBus.dispatchEvent(const LoginSuccess('u1'));
```

**Notes**

- Call `observeEvent` **once**, in `initState`. Calling it from `build` grows the subscription
  count on every rebuild. The mixin rejects a duplicate `(type, callback)` pair and asserts in
  debug, but only a method reference can be recognised — a fresh closure literal cannot.
- `FlGlobalEventBus.destroy()` is process-wide. Never call it from `State.dispose`; every other
  live subscription dies with it, silently. The mixin already cancels its own on `dispose`.

## Event timing

`FlLifecycleState` has 18 values and its dartdoc is the authoritative timing contract. The
common sequences:

```
push a page      onPageInit → onPageContextReady → onPagePostFrame
                 → onPageStart → onPageResume → onPageEnterAnimationEnd

covered by page  onPagePause → onPageStop   ...back...   onPageStart → onPageResume
covered by popup onPagePause               ...closed...  onPageResume
pop itself       onPageLeaveAnimationStart → onPagePause → onPageStop
                 → onPageLeaveAnimationEnd → onPageDispose
```

Four guarantees the state machine keeps for you:

- **Paired** — a `start` is always followed by a `stop`; `dispose` emits the missing half.
- **Idempotent** — repeated triggers are swallowed; you never get two `start`s in a row.
- **Ordered** — `onPagePostFrame` always precedes the first `onPageStart`, so sizes measured
  there are usable in `start`.
- **Popups pause, they do not stop** — the page is still on screen.

App events come in two flavours: `onAppResume` / `onAppInactive` / `onAppPause` are the raw
`AppLifecycleState`, while `onAppForeground` / `onAppBackground` are filtered — a pulled-down
notification shade or an incoming call does not trigger them.

## API reference

| Name | Kind | Purpose | See |
|---|---|---|---|
| `FlPageLifecycleMixin` | mixin | The full page lifecycle state machine | [1](#1-page-lifecycle-on-a-state) |
| `FlRouteObserver` | class | Translates `Navigator` changes into page events. **Must be registered** | [Quick start](#quick-start) |
| `FlRouteObserverProxy` | class | Forwarding observer for nested `Navigator`s | [3](#3-nested-navigators) |
| `FlLifecycleState` | enum | The 18 lifecycle events; `isPageResume` / `isPagePause` / `isAppEvent` helpers | [Event timing](#event-timing) |
| `FlPageIndexScope` | widget | Pushes the page index down to container children | [2](#2-pages-inside-an-index-driven-container) |
| `FlPageLifecycleView` | widget | Same events via callbacks, no mixin | [4](#4-no-mixin--wrap-a-widget-instead) |
| `FlPageLifecycleCallback` | typedef | `(BuildContext, FlLifecycleState) → void` | [4](#4-no-mixin--wrap-a-widget-instead) |
| `FlPageRouteParamCallback` | typedef | `(BuildContext, String?, Object?) → void` | [4](#4-no-mixin--wrap-a-widget-instead) |
| `FlPageIndexChangedCallback` | typedef | `(BuildContext, int, int) → void` | [4](#4-no-mixin--wrap-a-widget-instead) |
| `FlPageControllerMixin` | mixin | Receive forwarded events in a plain Dart object | [5](#5-lifecycle-in-a-controller--viewmodel) |
| `FlPageRouteMixin` | mixin | Route events and transition animations only | — |
| `FlAppLifecycleMixin` | mixin | App foreground/background only | — |
| `FlAnimationLifecycleMixin` | mixin | Route transition animations only | — |
| `FlLifecycleManager` | class | App foreground/background singleton: `isForeground`, `stream`, `lifecycle`, `listen()`, `cancel()` | [Notes](#notes--caveats) |
| `FlStateEventBusMixin` | mixin | `observeEvent` / `dispatchEvent` in a `State`, auto-cancelled | [6](#6-page-scoped-global-events) |
| `FlGlobalEventBus` | class | Static access point: `observeEvent`, `dispatchEvent`, `configure`, `destroy` | [6](#6-page-scoped-global-events) |
| `FlEventBus` | class | Default `FlIEventBus` implementation; `FlEventBus(sync: true)` dispatches synchronously | [6](#6-page-scoped-global-events) |
| `FlIEventBus` | class | Bus interface — implement it to inject a mock in tests | [6](#6-page-scoped-global-events) |

## Dependencies

| Dependency | Constraint | Purpose | Used in |
|---|---|---|---|
| `meta` | `^1.17.0` | `@internal` / `@nonVirtual` annotations that keep internal members out of the public contract | `lib/src/lifecycle/fl_route_observer.dart`, `lib/src/mixin/fl_page_route_mixin.dart`, and four more |

That is the only third-party dependency. No platform channels, no code generation, no
transitive UI packages.

## Notes & caveats

**Register `FlRouteObserver`, or nothing route-driven works.** Missing it produces no
exception — the four visibility callbacks simply never fire, while the transition-animation
callbacks keep working because they listen to `ModalRoute.animation` directly. "Animations yes,
visibility no" is the diagnostic signature. Debug builds print a hint once per process.

**Do not stack the entry-point mixins.** `FlPageLifecycleMixin`, `FlPageRouteMixin`,
`FlAppLifecycleMixin` and `FlAnimationLifecycleMixin` subscribe to the same sources and declare
overlapping members. Stacking them delivers some events twice and leaves one state machine
dead. `FlStateEventBusMixin` is the exception and composes with any of them.

**`onPageEnterAnimationEnd` can fire twice.** An abandoned iOS swipe-back runs the animation
`reverse → forward → completed`. Network calls or analytics started there must be idempotent.
Likewise `onPageLeaveAnimationStart` does **not** mean the page will actually leave — put
irreversible work in `onPageLeaveAnimationEnd` or `onPageDispose`.

**Route info is null by the time `onPageDispose` runs.** The mixin re-emits `onPagePause` /
`onPageStop` *before* unsubscribing, so `routeName` and `arguments` are still readable there,
but not in `onPageDispose`. Read them earlier, or cache them in `onPageContextReady`.

**Exceptions thrown from your callbacks do not propagate.** They are reported to
`FlutterError.onError` under the library name `fl_page_lifecycle` so that one page's failure
cannot break another page's events or leak a subscription. Wrap fallible work
(analytics upload, network) in your own `try`/`catch`.

**Two process-wide kill switches.** `FlGlobalEventBus.destroy()` and
`FlLifecycleManager.cancel()` affect every live page. They exist for test teardown and app
exit; page-level cleanup is automatic and needs neither.

**Do not use `onAppForeground` to ask whether the app is in the foreground.** It is an event,
and the cold-start replay only reaches the first subscriber in the process. Read
`isForeground` instead — it is a synchronous state read, valid at any time.

**When not to use this package.** It answers navigational questions. It does not detect a
widget scrolling out of a `ListView`, or a widget covered by an opaque sibling in the same
route — use `visibility_detector` for the first, and note that neither package handles the
second.

## Example

`example/` is a runnable app covering every entry point, each with a live on-screen event log:

```bash
cd example
flutter run
```

## Using this package with an AI coding assistant

This package is new, so an AI assistant has no training prior for it and will invent API names
that do not exist. [`docs/ai/`](docs/ai/) is a ready-made convention file you can copy into your
own project to prevent that — an `AGENTS.md` covering entry-point selection, the
`resume/pause` vs `start/stop` decision, event ordering and a pre-commit checklist, plus three
reference files with exact signatures, worked recipes and a pitfall guide.
[`docs/ai/README.md`](docs/ai/README.md) explains where to put it, including the equivalent
locations for Cursor, Copilot, Windsurf, Cline and Claude Code.

## Changelog · License

See [CHANGELOG.md](CHANGELOG.md). Licensed under [MIT](LICENSE).
