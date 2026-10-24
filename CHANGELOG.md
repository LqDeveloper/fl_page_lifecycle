# Changelog

## 0.0.4

No public API was added or removed. One fix to the route state machine, upgrade recommended
for anyone on 0.0.3.

- **Fix**: a page paused by a popup now gets its `resume` back when that popup is swapped out
  for a normal route and that route is later popped. The sequence is: page A is visible →
  `showDialog` (A is paused, never stopped) → `pushReplacement(B)` or `pushAndRemoveUntil(B, …)`
  replaces or removes the dialog → `pop()` back to A. `didReplace` and `didRemove` report only
  the route that left, not what sits beneath it, so A heard nothing during the swap. Popping B
  then delivered a *start* (B is not a `PopupRoute`), which A's "already appeared" guard
  swallowed whole. A stayed paused for good: `onPageResume` / `onRouteResume` never fired again
  and `isPageResumed` stayed `false`, so whatever the page restarts on resume — video, polling,
  exposure timers — stayed stopped. `FlPageLifecycleMixin` and `FlPageRouteMixin` now treat a
  start that arrives while the page is already appeared as a resume; `onPageStart` is still
  idempotent and is not emitted a second time.
- **Known gap, unchanged**: between the swap and the pop, A is fully covered by B yet still
  reports `isPageAppeared == true` and receives no `stop`. Closing it would need the observer to
  keep its own copy of the route stack. Exposure-duration tracking counts that interval as
  visible; close the popup before navigating (`pop`, then `push`) if that matters.
- `FlPageRouteMixin`'s four internal `routePageXxx` forwarders are now `@nonVirtual`, matching
  `FlPageLifecycleMixin`. They were already documented as not to be overridden, and overriding
  one without calling `super` silently broke start/stop pairing. They are `@internal`, so no
  supported use is affected.
- Added regression tests for both swap methods on both mixins (`test/popup_replaced_test.dart`).

## 0.0.3

The scope mechanism now also serves `IndexedStack`, nested `Navigator`s are supported, and the
`PageView`-flavoured names were corrected to match what the mechanism actually does. **The
rename is breaking** — see the rename entry below before upgrading.

- **`FlPageIndexScope.controller` accepts `ValueListenable<int>`**, alongside `PageController`
  and `TabController`. This is what makes `IndexedStack` — and any other container that shows
  one of N children by index — work: those children stay built and alive when they are switched
  away, so nothing else tells them they went off screen. Non-scrolling containers commit
  visibility immediately; they have no intermediate state, so the "settle first" gate that
  exists for `PageView` does not apply and is not bound (it would otherwise latch onto whatever
  unrelated `Scrollable` happens to be above the scope).
- **`FlRouteObserverProxy`** — a forwarding `NavigatorObserver` for nested `Navigator`s
  (go_router's `ShellRoute`, auto_route's nested routers, hand-written per-tab stacks).
  `FlRouteObserver` is a singleton and Flutter asserts that one observer instance binds to at
  most one `NavigatorState`, so a second `Navigator` could not be observed at all before. Give
  the root the singleton and every nested `Navigator` its own proxy; they all forward into the
  same subscription table, so pages need no changes.
- **Breaking rename, no compatibility shims.** Every old name is gone; 0.0.3 does not interop
  with 0.0.1 or 0.0.2.

  | Old | New |
  |---|---|
  | `FlPageViewScope` | `FlPageIndexScope` |
  | `FlPageViewChangedCallback` | `FlPageIndexChangedCallback` |
  | `observePageView` | `observePageIndex` |
  | `onPageViewChanged` | `onPageIndexChanged` |
  | `isInPageView` | `isInPageScope` |
  | `pageViewDepth` | `pageScopeDepth` |

  The two type names and the `FlPageLifecycleView` constructor parameters fail to compile, which
  is what you want. **The two `FlPageLifecycleMixin` members do not**: an
  `@override bool get observePageView` draws only an `override_on_non_overriding_member`
  *warning*, so the code keeps building and running while that override sits there dead and the
  page silently stops receiving index-driven events. Grep for those two names before upgrading.
- **Behaviour change**: a page driven by page index no longer emits `onPageStart` when its
  container scrolls back to it while the page is not the top route of its own `Navigator`. The
  first-frame path already had this check; the paging path did not. Without it, a nested route
  stack inside a `PageView` page would wake up *every* layer on the way back, not just the
  visible one, and a `jumpToPage` performed while the host route was covered would start a page
  nobody could see.
- **Fix**: swapping `FlPageIndexScope.controller` between a scrolling controller and a
  `ValueListenable<int>` now re-evaluates the settle-gate binding. It previously kept listening
  to the old `ScrollPosition`, so paging could not commit while that now-unrelated scrollable
  was moving.
- **Fix**: an exception thrown from `onAppForeground` / `onAppBackground` /
  `appLifecycleChanged`, or from an `observeEvent` subscriber, now reaches `FlutterError.onError`
  like every other callback in this package. These four are driven directly by a
  `StreamSubscription` rather than by the page's own call chain, so they were never wrapped — the
  blast radius was already contained (one broadcast-stream listener throwing does not stop the
  next), but the exception escaped as an *uncaught async error* to the zone. That meant no
  `library: 'fl_page_lifecycle'` and no "while dispatching a page lifecycle callback" context for
  crash reporters, and `tester.takeException()` could not consume it, so a host's own widget test
  failed with a message pointing nowhere near the callback.
- Removed the unused internal `FlPageIndexScope.read`; added `@internal debugResetWarnings()`
  hooks so tests can isolate the print-once debug diagnostics, whose process-wide state
  otherwise leaks between test cases and can turn "should warn" assertions into silent passes.

## 0.0.2

No public API was added or removed. Two behaviour changes in `PageView` / `TabBarView` paging,
both aimed at the events analytics code relies on.

- **`FlPageViewScope` now commits visibility only once the container settles on a page**, instead
  of the moment it scrolls past the halfway point. `animateToPage(0 → 4)` used to raise a full
  `onPageStart` / `onPageStop` pair on each of the three pages it swept over — three phantom page
  views for exposure tracking, and a start/stop cycle for anything those pages had running. Those
  pages now raise nothing at all, and a drag taken past halfway and then abandoned raises nothing
  either. The cost is that `onPageStart` / `onPageStop` arrive about one settle animation later
  than before; `jumpToPage` creates no scroll activity and still commits immediately. If the
  container never settles, visibility is never committed — see the class docs.
- **`onPageViewChanged` now reports the page index kept per layer**, so every mounted page of that
  layer receives the same `(from, to)` — including the page just switched to, which previously got
  nothing because it had no index of its own to compare against. The pair also reports the move in
  one step: `animateToPage(0 → 4)` is `(0, 4)`, no longer `(0, 1)`, `(1, 2)`… An index change that
  happened before a host was mounted is not replayed to it; use `onPageStart` for "this page became
  current".
- Two debug-only diagnostics, both printed once and only in debug builds. One fires when the
  nearest `PageView` / `TabBarView` above a page is not wrapped in `FlPageViewScope` — the page
  then silently binds to an outer scope and never stops when its own container pages away. The
  other fires when a hand-constructed `FlPageViewScope` sits below a scrollable inside the page, so
  the settle check binds to the wrong `Scrollable`.
- Documented the repeat emission of `onPageEnterAnimationEnd` (an abandoned iOS back-swipe fires it
  twice) at every entry point that exposes it, not just one — work started there must be idempotent.

## 0.0.1

Initial release.

- `FlPageLifecycleMixin` — full page visibility state machine (`onPageStart` / `onPageResume` /
  `onPagePause` / `onPageStop`), plus first frame, hot reload, transition animations, app
  foreground/background and `PageView` paging. Events are paired and idempotent.
- `FlRouteObserver` — translates `Navigator` changes into page events. Popups pause without
  stopping; routes still covered after `pushAndRemoveUntil` / `popUntil` get no false start.
- `FlLifecycleState` — the 18 lifecycle events; its dartdoc is the timing contract.
- `FlPageRouteMixin`, `FlAppLifecycleMixin`, `FlAnimationLifecycleMixin` — standalone mixins for
  route events, app foreground/background and transition animations respectively.
- `FlPageLifecycleView` — same events via callbacks, no mixin required.
- `FlPageControllerMixin` — receive forwarded events in a Controller / ViewModel.
- `FlPageViewScope` — pushes page index and controller down to `PageView` / `TabBarView`
  children; supports nesting, with `wrapChildren` / `wrapItemBuilder` helpers.
- `FlStateEventBusMixin`, `FlGlobalEventBus`, `FlEventBus`, `FlIEventBus` — global event bus with
  subscriptions auto-cancelled on `dispose`.
