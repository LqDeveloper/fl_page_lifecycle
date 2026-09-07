# fl_page_lifecycle

Android-style page lifecycle for Flutter: `start` / `resume` / `pause` / `stop` on any `State`,
plus first frame, route transition animations, app foreground/background and `PageView` paging.

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
`WidgetsBindingObserver`, `ModalRoute.of(context).isCurrent`, a `PageController` listener
and a first-frame callback — and then getting the edge cases right:

- A dialog covers your page. It is still visible, so you want `pause`, not `stop`.
  `isCurrent` returns `false` and cannot tell you the difference.
- `pushAndRemoveUntil` fires `didPop` for a route that is *still* covered by another one.
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
- `PageView` / `TabBarView` children driven by page index instead of route changes
- Works without touching your class hierarchy — [mixin](#1-page-lifecycle-on-a-state),
  [wrapper widget](#3-no-mixin-wrap-a-widget-instead) or [plain Dart object](#4-lifecycle-in-a-controller--viewmodel)
- Page-scoped global event bus whose subscriptions cancel themselves on `dispose`
- One third-party dependency (`meta`), no platform channels, no code generation

## Which entry point do I need?

| You want | Use |
|---|---|
| The whole thing on a `State` | [`FlPageLifecycleMixin`](#1-page-lifecycle-on-a-state) |
| The same, for a `PageView` / `TabBarView` child | [`FlPageViewScope`](#2-pages-inside-a-pageview--tabbarview) + `observePageView` |
| Events without mixing into `State` | [`FlPageLifecycleView`](#3-no-mixin-wrap-a-widget-instead) |
| Events in a Controller / ViewModel | [`FlPageControllerMixin`](#4-lifecycle-in-a-controller--viewmodel) |
| Only app foreground/background | `FlAppLifecycleMixin` |
| Only route transition animations | `FlAnimationLifecycleMixin` |
| Only route events, without popup or `PageView` handling | `FlPageRouteMixin` |

The last three are standalone. **Do not stack them on top of `FlPageLifecycleMixin`** — it
already subscribes to the same sources, and you would receive every event twice.

## Compared with `visibility_detector`

[`visibility_detector`](https://pub.dev/packages/visibility_detector) (`google/flutter.widgets`)
answers a **geometric** question: how much of this widget's bounding box is inside the viewport?
This package answers a **navigational** one: is this page the one the user is on? Neither subsumes
the other, and the comparison below is drawn from `visibility_detector` 0.4.0+2.

| | `visibility_detector` | `fl_page_lifecycle` |
|---|---|---|
| Unit of observation | Any widget, identified by a unique `Key` | A route page or `PageView` child |
| What it reports | `visibleFraction`, `visibleBounds`, `size` — continuous | Discrete events: `start` / `resume` / `pause` / `stop` |
| Scrolled out of a `ListView` | Detected — its core use case | **Not** detected |
| Hidden behind an opaque widget in the same route | Not accounted for — [documented limitation](https://pub.dev/packages/visibility_detector#known-limitations) | **Not** detected |
| Covered by a dialog / bottom sheet | Not accounted for — same limitation | `pause`, then `resume` when it closes |
| Route push / pop | Not covered | Its core use case |
| App foreground / background | Not covered | Covered, transient interruptions filtered out |
| Route transition animations | Not covered | Four callbacks, incl. cancelled iOS swipe-back |
| Callback timing | Coalesced: at most once per `VisibilityDetectorController.updateInterval`, 500 ms by default | Synchronous with the route or frame event; `PageView` children are batched to frame end |
| Setup | None — just wrap a widget | Register `FlRouteObserver` on the `Navigator` |

**Which one for which job**

| Scenario | Reach for |
|---|---|
| Pause a video / poll / animation when the page is covered or left behind | `fl_page_lifecycle` |
| Measure page dwell time, or fire a page-view analytics event | `fl_page_lifecycle` |
| Start and stop work as a `TabBarView` tab is swiped in and out | `fl_page_lifecycle` (`observePageView`) |
| Refresh stale data when the user comes back from another app | `fl_page_lifecycle` (`observeAppLifecycle`) |
| Lazy-load an image once it scrolls into the viewport | `visibility_detector` |
| Count a feed card as *seen* after 50% of it was on screen | `visibility_detector` |
| Autoplay whichever video card is currently centred in a feed | **both** |

The last row is the common case worth spelling out: use this package to know the feed page is
resumed at all — otherwise you autoplay on a page the user already navigated away from — and
`visibility_detector` to know which card is on screen. They observe different things and do not
conflict.

## Compatibility

| Item | Requirement |
|---|---|
| Dart SDK | `^3.11.5` |
| Flutter | `>=3.41.9` — the stable release that ships Dart 3.11.5 |
| Platforms | All platforms Flutter supports — no plugin, no platform channels, no `dart:io` |

## Installation

```yaml
dependencies:
  fl_page_lifecycle: ^0.0.1
```

Not published to pub.dev yet — until then, depend on it by git:

```yaml
dependencies:
  fl_page_lifecycle:
    git:
      url: https://github.com/LqDeveloper/fl_page_lifecycle.git
```

```bash
flutter pub get
```

## Quick start

`FlRouteObserver` **must** be registered on your `Navigator`, otherwise the four route-driven
events never fire and nothing reports an error. This is the single most common setup mistake.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [FlRouteObserver.instance], // ← required
      home: const DetailPage(),
    );
  }
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  @override
  void onPageResume() => debugPrint('interactive — start the video');

  @override
  void onPagePause() => debugPrint('covered or leaving — pause the video');

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('Detail')));
}
```

Push another route on top and you will see `pause` then `stop`; open a dialog and you will see
only `pause`.

## Usage

### 1. Page lifecycle on a `State`

**When to use it**: the default choice for a route page — you need to know when the page became
visible or interactive so you can start and stop work that must not run in the background.

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> with FlPageLifecycleMixin {
  Timer? _poll;

  // Off by default; each instance saves two global stream subscriptions.
  @override
  bool get observeAppLifecycle => true;

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    debugPrint('route $routeName with $arguments');
  }

  @override
  void onPageResume() =>
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());

  @override
  void onPagePause() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void onAppBackground() => _poll?.cancel();

  void _refresh() {}

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Feed'));
}
```

**Switches** (override as getters; each must return a constant — a debug assert enforces it)

| Getter | Type | Default | Meaning |
|---|---|---|---|
| `observePageView` | `bool` | `false` | Drive visibility from `FlPageViewScope` page index instead of route changes |
| `observeAppLifecycle` | `bool` | `false` | Deliver the five app-level events; costs two global stream subscriptions per instance |

**State getters** (readable at any time, no subscription needed)

| Getter | Type | Meaning |
|---|---|---|
| `isPageAppeared` | `bool` | Visible: `onPageStart` fired and `onPageStop` has not |
| `isPageResumed` | `bool` | Interactive: `onPageResume` fired and `onPagePause` has not |
| `isForeground` | `bool` | The app is in the foreground |
| `isCurrent` | `bool` | This page is the top route of its `Navigator` (live, not cached) |
| `routeName` / `arguments` | `String?` / `Object?` | From `RouteSettings`; available from `onPageContextReady` onwards |
| `isInPageView` / `pageIndex` / `currentPageIndex` / `pageViewDepth` | `bool` / `int` | `PageView` position, see below |

**Notes**

- Use `isPageAppeared` for "is my page visible", **not** `isCurrent` — a dialog on top makes
  `isCurrent` false while the page is still fully visible.
- `onPagePostFrame` always fires before the first `onPageStart`, so you can measure a
  `RenderObject` there and use the size in `onPageStart`.
- Overriding `onLifecycleStateChanged` requires calling `super` (`@mustCallSuper`). So does
  overriding `appLifecycleChanged` — its body is what dispatches `onAppResume` / `onAppInactive` /
  `onAppPause`, so dropping `super` silently kills those three.

### 2. Pages inside a `PageView` / `TabBarView`

**When to use it**: children of a `PageView` are all built and kept alive, so route events say
nothing about which one is on screen. Wrap them in `FlPageViewScope` and visibility follows the
page index instead.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  final _controller = PageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _controller,
        // Injects each child's page index; children need no pageIndex of their own.
        children: FlPageViewScope.wrapChildren(
          controller: _controller,
          children: const [FeedTab(), Center(child: Text('Profile'))],
        ),
      ),
    );
  }
}

class FeedTab extends StatefulWidget {
  const FeedTab({super.key});

  @override
  State<FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<FeedTab> with FlPageLifecycleMixin {
  @override
  bool get observePageView => true; // ← without this the tab starts on its first frame

  @override
  void onPageStart() => debugPrint('feed tab scrolled into view');

  @override
  void onPageStop() => debugPrint('feed tab scrolled away');

  @override
  void onPageViewChanged(int from, int to) => debugPrint('page $from -> $to');

  @override
  Widget build(BuildContext context) => const Center(child: Text('Feed'));
}
```

**`FlPageViewScope` statics**

| Method | Signature | Purpose |
|---|---|---|
| `wrapChildren` | `({required Listenable controller, required List<Widget> children}) → List<Widget>` | Wrap a fixed child list; index becomes the page index |
| `wrapItemBuilder` | `({required Listenable controller, required NullableIndexedWidgetBuilder builder}) → NullableIndexedWidgetBuilder` | Same, for `PageView.builder` |
| `indexOf` | `(Listenable controller) → int?` | Current index, `null` while not yet resolvable |

`initialIndexOf`, `listenableOf` and `depthOf` cover the lower-level cases. The constructor takes
`pageIndex`, `controller` and `child` directly if you are not using the helpers; it carries an
assert and is therefore **not** `const`, so `const FlPageViewScope(...)` will not compile.
`controller` accepts a `PageController` or a `TabController` only — anything else trips an
assert. Scopes nest,
and a child is visible only when every ancestor scope is also on its host's page.

### 3. No mixin — wrap a widget instead

**When to use it**: the page is a `StatelessWidget`, the `State` already has a mixin chain you
would rather not extend, or you only want to instrument one subtree (an impression tracker on a
card, for instance).

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FlPageLifecycleView(
      onStateChanged: (context, state) {
        if (state == FlLifecycleState.onPageResume) debugPrint('visible & interactive');
      },
      onRouteParam: (context, routeName, arguments) =>
          debugPrint('opened $routeName with $arguments'),
      child: const Scaffold(body: Center(child: Text('Product'))),
    );
  }
}
```

**Parameters**

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `child` | `Widget` | required | Observed subtree, returned as-is by `build` — no extra layout node |
| `onStateChanged` | `FlPageLifecycleCallback?` | `null` | Every `FlLifecycleState` event |
| `onRouteParam` | `FlPageRouteParamCallback?` | `null` | Route name and arguments once available |
| `onPageViewChanged` | `FlPageViewChangedCallback?` | `null` | Page index changed, `(from, to)` |
| `observePageView` | `bool` | `false` | Same as the mixin's switch |
| `observeAppLifecycle` | `bool` | `false` | Same as the mixin's switch |

Each instance is a full `FlPageLifecycleMixin` internally: one route subscription, one first-frame
callback, plus two global stream subscriptions when `observeAppLifecycle` is on. A handful per
page is free; hundreds of them in a list is worth thinking about.

### 4. Lifecycle in a Controller / ViewModel

**When to use it**: the code that reacts to the lifecycle lives outside the widget tree — a
Controller, Presenter, ViewModel or Service.

`FlPageControllerMixin` **subscribes to nothing**. It is an entry point plus a set of template
callbacks; the page has to forward events into it. If no callback ever fires, check the
forwarding first.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class DetailController with FlPageControllerMixin {
  @override
  void onPageResume() => debugPrint('poll started, route=$routeName');

  @override
  void onPagePause() => debugPrint('poll stopped');
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key});

  @override
  State<DetailPage> createState() => _DetailPageState();
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
  Widget build(BuildContext context) => const Scaffold(body: Text('Detail'));
}
```

Forwarding from `FlPageLifecycleView.onStateChanged` works identically.

**Note**: timing and idempotency are entirely determined by whoever forwards the events. Drive
`onLifecycleChanged` yourself, bypassing `FlPageLifecycleMixin`, and guarantees like "start is
always followed by resume" no longer hold. The mixin holds no subscriptions and therefore has no
`dispose` — release your own resources in `onPageDispose`.

### 5. Page-scoped global events

**When to use it**: two pages need to talk without a shared parent — a settings page changing a
theme, a cart badge reacting to a purchase.

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// Events are plain classes, distinguished by type. Nothing to register.
class CartChanged {
  const CartChanged(this.count);

  final int count;
}

class CartBadge extends StatefulWidget {
  const CartBadge({super.key});

  @override
  State<CartBadge> createState() => _CartBadgeState();
}

class _CartBadgeState extends State<CartBadge> with FlStateEventBusMixin {
  int _count = 0;

  @override
  void initState() {
    super.initState();
    // No StreamSubscription to keep — cancelled automatically in dispose.
    observeEvent<CartChanged>((event) => setState(() => _count = event.count));
  }

  void _add() => dispatchEvent(CartChanged(_count + 1));

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: _add, child: Text('Cart $_count'));
}
```

Call `observeEvent` once, from `initState`. Called from `build` or `onPageResume` the subscription
count would grow with every rebuild, so a repeat registration of the same `(T, onData)` pair is
**ignored** and trips a debug assert. Only method references dedupe — a closure literal written at
the call site is a fresh object every time and cannot be recognised as a repeat.

Events are broadcast globally: a page that is currently stopped still receives them. If that is
not what you want, gate the handler on `isPageAppeared`.

Outside a `State`, use the statics on `FlGlobalEventBus` — `observeEvent<T>()` returns a
`Stream<T>` you cancel yourself, and `dispatchEvent<T>(T event)` publishes. Swap the backing
implementation with `FlGlobalEventBus.configure(FlEventBus())` or your own `FlIEventBus`.

## Event timing

The full contract lives in the `FlLifecycleState` dartdoc — it documents, per event, exactly when
it fires and when it does not. The common sequences:

```
push a route          onPageInit → onPageContextReady
                      → onPageEnterAnimationStart (not guaranteed, see below)
                      → onPagePostFrame
                      → onPageStart → onPageResume → onPageEnterAnimationEnd

covered by a route    onPagePause → onPageStop  ...  onPageStart → onPageResume
covered by a dialog   onPagePause               ...  onPageResume

pop itself            onPageLeaveAnimationStart → onPagePause → onPageStop
                      → onPageLeaveAnimationEnd → onPageDispose

iOS swipe-back,       onPageLeaveAnimationStart → onPageEnterAnimationStart
abandoned halfway     → onPageEnterAnimationEnd          (no pause, no stop)
```

The app's first page (`home`) has no transition, so neither enter-animation event fires.
`onPageDispose` is always the last event.

`onPageReassemble` sits outside these sequences: it fires on hot reload only (it is gated on
`kDebugMode`), so treat it as a debug-time hook rather than part of the contract.

For a `PageView` child, `start` and `stop` arrive at **frame end** rather than synchronously.
Within one frame every hide fires before every show, regardless of the order the children
registered, and a page that flips away and back inside one batch emits nothing at all — so two
children never both believe they are visible.

## API reference

| Name | Kind | Purpose | More |
|---|---|---|---|
| `FlPageLifecycleMixin` | mixin on `State` | Full page lifecycle — the main entry point | [Usage](#1-page-lifecycle-on-a-state) |
| `FlPageViewScope` | widget | Pushes page index + controller down to `PageView` children | [Usage](#2-pages-inside-a-pageview--tabbarview) |
| `FlPageLifecycleView` | widget | Same events as the mixin, delivered via callbacks | [Usage](#3-no-mixin-wrap-a-widget-instead) |
| `FlPageControllerMixin` | mixin | Receives forwarded events in a non-widget class | [Usage](#4-lifecycle-in-a-controller--viewmodel) |
| `FlStateEventBusMixin` | mixin on `State` | `observeEvent` / `dispatchEvent`, auto-cancelled on `dispose` | [Usage](#5-page-scoped-global-events) |
| `FlRouteObserver` | `NavigatorObserver` | Translates route changes into start/resume/pause/stop. Register `FlRouteObserver.instance` | [Quick start](#quick-start) |
| `FlLifecycleState` | enum | The 18 lifecycle events, plus `isPageResume` / `isPagePause` / `isAppEvent` | [Timing](#event-timing) |
| `FlAppLifecycleMixin` | mixin on `State` | App foreground/background only: `onAppForeground`, `onAppBackground`, `appLifecycleChanged`, `isForeground`, `hasInit` | — |
| `FlAnimationLifecycleMixin` | mixin on `State` | Transition animations only: the four `onPageEnter/LeaveAnimation*` callbacks | — |
| `FlPageRouteMixin` | mixin on `State` | Route events only — one-shot `onRouteStart` / `onRouteStop` and a pause/stop backfill on `dispose`, but no popup or `PageView` awareness and `onRoutePause` is unguarded: `onRouteStart` / `onRouteResume` / `onRoutePause` / `onRouteStop`, plus `modalRoute`, `hasRoute` | — |
| `FlLifecycleManager` | singleton | App foreground/background source: `instance`, `isForeground`, `stream`, `lifecycle`, `listen()`, `cancel()` | — |
| `FlGlobalEventBus` | static API | Global bus access: `observeEvent<T>()`, `dispatchEvent<T>()`, `configure()`, `destroy()` | [Usage](#5-page-scoped-global-events) |
| `FlIEventBus` | abstract class | Bus interface: `on<T>()`, `fire()`, `destroy()` — implement to swap in your own | — |
| `FlEventBus` | class | Default `FlIEventBus`: one broadcast stream. `FlEventBus({sync})`, `FlEventBus.customController()` | — |
| `FlPageLifecycleCallback` | typedef | `void Function(BuildContext, FlLifecycleState)` | [Usage](#3-no-mixin-wrap-a-widget-instead) |
| `FlPageRouteParamCallback` | typedef | `void Function(BuildContext, String?, Object?)` | [Usage](#3-no-mixin-wrap-a-widget-instead) |
| `FlPageViewChangedCallback` | typedef | `void Function(BuildContext, int from, int to)` | [Usage](#3-no-mixin-wrap-a-widget-instead) |

Lifecycle callbacks are `@protected` — override them in your class, never call them directly.
The exceptions are on `FlPageControllerMixin`, whose `onLifecycleChanged`, `setupRouteInfo` and
`onPageViewChanged` are public because the page has to call them. Note also that its
`onPageContextReady` takes a `BuildContext?`, not the `(String? routeName, Object? arguments)` the
`State` mixins pass, and that `onPageViewChanged` is not dispatched by `onLifecycleChanged` — the
page must forward it explicitly.

## Dependencies

| Package | Constraint | What for | Used in |
|---|---|---|---|
| `meta` | `^1.17.0` | `@internal` / `@protected` / `@mustCallSuper` / `@nonVirtual` annotations that mark the public surface | `lib/src/lifecycle/fl_route_observer.dart:3`, `lib/src/mixin/fl_page_route_mixin.dart:3`, `lib/src/delegate/*.dart` |

That is the only third-party dependency — no state management library, no code generation, no
platform channels.

## Notes & caveats

**Register `FlRouteObserver`, or nothing route-driven works.** Missing it produces no exception —
`start` / `resume` / `pause` / `stop` simply never arrive (debug builds print a hint once).
A nested `Navigator` needs its own registration; the same `instance` can be reused.

**`isCurrent` is not visibility.** A `PopupRoute` on top — dialog, bottom sheet, popup menu —
leaves the page fully visible, so only `pause` is emitted. Use `isPageAppeared`.

**`onPageContextReady` may never fire.** It requires `ModalRoute.of(context)` to be non-null. For
a widget that is not inside any route, what goes silent is only the *route-driven* half: the
`start` / `resume` / `pause` / `stop` a covering or uncovering route would have produced, plus both
transition-animation events. The first frame's `onPageStart` / `onPageResume` and the
`onPagePause` / `onPageStop` backfilled on `dispose` still fire — the first-frame visibility gate
only applies once a `ModalRoute` has been resolved — as do `onPageInit`, `onPagePostFrame` and
`onPageDispose`. So the mixin is still worth using on a routeless widget: you get a paired
start/stop over that widget's own lifetime.

**`onPageEnterAnimationStart` usually does not fire on first entry.** The animation listener is
bound at `onPageContextReady`, by which time the entry transition has already started. Use
`onPageContextReady` for "the page is appearing". What you do receive is the animation reversing —
an abandoned iOS swipe-back.

**`onPageLeaveAnimationStart` does not mean the page will leave.** Abandon an iOS swipe-back and
it is followed by `onPageEnterAnimationStart` → `onPageEnterAnimationEnd`, never
`onPageLeaveAnimationEnd`. Put irreversible work in `onPageLeaveAnimationEnd` or `onPageDispose`.

**Both switches must be constant per instance.** `observePageView` and `observeAppLifecycle` are
read once in `initState`; flipping one mid-life leaves the visibility state machine inconsistent.
A debug assert catches it.

**Do not stack the standalone mixins.** `FlPageRouteMixin`, `FlAnimationLifecycleMixin` and
`FlAppLifecycleMixin` subscribe to the same sources `FlPageLifecycleMixin` already uses. Pick one.

**The event bus ignores visibility.** A stopped page still receives every event. Gate on
`isPageAppeared` if a background page must not react.

**`FlLifecycleManager.cancel()` is global too.** It removes the `WidgetsBinding` observer, so
every live page stops receiving app events. Subscribe to `FlLifecycleManager.instance.stream`
yourself and cancel your own `StreamSubscription` — never the manager.

**`FlGlobalEventBus.destroy()` is global.** Call it only in a test `tearDown` or when the app is
detaching — never in `State.dispose()` or a pop callback. It closes the whole broadcast stream, so
every other live page's subscription receives `done` and dies silently. Page-level cleanup is what
`FlStateEventBusMixin` already does for you.

## Example

`example/` is a runnable app covering all seven entry points, each with a live on-screen event log:

```bash
cd example
flutter run
```

## Using this package with an AI coding assistant

This package is not on pub.dev, so an AI assistant has no training prior for it and will invent
API names that do not exist. [`docs/ai/`](docs/ai/) is a ready-made convention file you can copy
into your own project to prevent that — an `AGENTS.md` covering entry-point selection, the
`resume/pause` vs `start/stop` decision, event ordering and a pre-commit checklist, plus three
reference files with exact signatures, worked recipes and a pitfall guide.
[`docs/ai/README.md`](docs/ai/README.md) explains where to put it, including the equivalent
locations for Cursor, Copilot, Windsurf, Cline and Claude Code.

## Changelog · License

See [CHANGELOG.md](CHANGELOG.md). Licensed under [MIT](LICENSE).
