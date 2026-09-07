# Changelog

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
