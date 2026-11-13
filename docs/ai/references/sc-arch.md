# 场景：架构（节号全局唯一，勿改）

## 10. 跨页事件总线

```dart
class _CartBadgeState extends State<CartBadge> with FlPageLifecycleMixin, FlStateEventBusMixin {
  @override
  void initState() {
    super.initState();
    observeEvent<CartChanged>(_onCartChanged);   // 只在 initState 调一次，传方法引用
  }

  void _onCartChanged(CartChanged e) {
    if (!mounted || !isPageAppeared) return;     // 全局广播，stop 的页面也会收到
    setState(() => _count = e.count);
  }

  void _add() => dispatchEvent(CartChanged(_count + 1));
}
```

- 事件是普通类，按类型区分；订阅随 `dispose` 自动取消。
- 写进 `build` / `onPageResume` 会让订阅数增长；闭包字面量无法去重。
- 页面里别调 `FlGlobalEventBus.destroy()`，它会让所有页面的订阅失活。
- `State` 之外：`FlGlobalEventBus.observeEvent<T>()`（返回 `Stream<T>`，自己 cancel）、`FlGlobalEventBus.dispatchEvent<T>(e)`。

## 11. 局部子树观测

```dart
FlPageLifecycleView(
  onStateChanged: (context, state) {
    if (state.isPageResume) _player.play();
    if (state.isPagePause) _player.pause();
  },
  onRouteParam: (context, routeName, arguments) => Analytics.pageView(routeName),
  child: const Scaffold(),
)
```

- 适用：`StatelessWidget` 页面、只给一张卡片做曝光。
- `onPageInit` / `onPageDispose` 时别用回调里的 `context` 查 `InheritedWidget`。
- 每个实例是一套完整状态机，长列表每项一个要算成本。

## 12. Controller / ViewModel

`FlPageControllerMixin` 不订阅任何东西，由页面转发：

```dart
class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  late final _controller = DetailController();

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);                      // 必须
    _controller.onLifecycleChanged(state, context: context);
  }

  @override
  void onPageContextReady(String? routeName, Object? arguments) =>
      _controller.setupRouteInfo(routeName, arguments);
}

class DetailController with FlPageControllerMixin {
  @override
  void onPageResume() => _startPolling();
  @override
  void onPagePause() => _stopPolling();
  @override
  void onPageDispose() => _stopPolling();                      // 它没有 dispose
  @override
  void onPageContextReady(BuildContext? context) {}            // ⚠️ 签名是 BuildContext?
}
```

- `onPageIndexChanged(int, int)` 不经 `onLifecycleChanged` 分发，要页面单独转发。
- `isPageResume` / `isPagePause` 只是「最后一个事件」，App 事件会冲掉。
- `onPageInit` / `onPageContextReady` 在构建期，Controller 里别改会触发重建的状态。

## 13. 全项目统一埋点

```dart
mixin PageTrackMixin<T extends StatefulWidget> on State<T>, FlPageLifecycleMixin<T> {
  DateTime? _enterAt;

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);    // 必须
    switch (state) {
      case FlLifecycleState.onPageStart:
        _enterAt = DateTime.now();
        Analytics.pageView(routeName ?? '$runtimeType', args: arguments);
      case FlLifecycleState.onPageStop:
        final at = _enterAt;
        if (at != null) Analytics.pageDuration(routeName ?? '$runtimeType', DateTime.now().difference(at));
        _enterAt = null;
      default:
        break;
    }
  }
}

class _OrderPageState extends State<OrderPage> with FlPageLifecycleMixin, PageTrackMixin {}
```

- 这是唯一正确的叠加形式：叠自己的 mixin，约束在主 mixin 上。
- 走统一出口，子类重写 `onPageStart` 不会覆盖埋点。
- 回调里的异常被守卫上报到 `FlutterError.onError`，不会传播；可能失败的操作自己包 `try/catch`。

## 14. 回调里 setState 报错

`onPageInit`（`initState`）与 `onPageContextReady`（`didChangeDependencies`）在构建期，`setState` 会抛 `called during build`。这两处只赋值，要刷新就推到帧末：

```dart
WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() {}); });
```

`onPagePostFrame` 及之后的回调通常可以直接 `setState`；仍报这个错（声明式路由在构建期改栈时可能出现）就同样推到帧末。
