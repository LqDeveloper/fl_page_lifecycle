# Changelog

## 0.0.4

Android-style page lifecycle for Flutter. Register `FlRouteObserver()` in
`navigatorObservers`, mix `FlPageLifecycleMixin` into a `State`, and override the callbacks
you need.

- `FlPageLifecycleMixin` — `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop`,
  paired and idempotent, plus first frame, route transition animations and app
  foreground/background. A popup or non-opaque route on top only pauses the page.
- `FlPageIndexScope` — the same events for children of `PageView`, `TabBarView` and
  `IndexedStack`, driven by page index.
- `FlRouteObserverProxy` — support for nested `Navigator`s.
- `FlPageLifecycleView` — the same events through callbacks, no mixin required.
- `FlPageControllerMixin` — receive the events in a Controller / ViewModel.
- `FlPageRouteMixin`, `FlAppLifecycleMixin`, `FlAnimationLifecycleMixin` — standalone mixins
  for route events, app foreground/background and transition animations.
- `FlStateEventBusMixin` / `FlGlobalEventBus` — a global event bus whose subscriptions are
  cancelled on `dispose`.

Changes since 0.0.3 (no public API added or removed):

- A non-opaque route (`opaque: false`) now pauses the page below instead of stopping it.
- `onAppForeground` is no longer replayed to the first subscriber when the app is already in
  the foreground; read `isForeground` for the current state.
- Fixed event ordering when a popup is replaced by a page, and when `onPageStart` pushes a
  route or shows a dialog synchronously.
