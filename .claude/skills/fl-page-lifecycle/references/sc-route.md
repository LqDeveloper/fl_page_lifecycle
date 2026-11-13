# 场景：路由与注册（节号全局唯一，勿改）

## 9. 注册位置

根 `Navigator` 挂 `FlRouteObserver()`，其余每个 `Navigator` 各挂一个**新的** `FlRouteObserverProxy()`。同一实例挂两个会断言 `observer.navigator == null`。不注册不报错。

```dart
MaterialApp(navigatorObservers: [FlRouteObserver()])
GetMaterialApp(navigatorObservers: [FlRouteObserver()])
GoRouter(observers: [FlRouteObserver()])
ShellRoute(observers: [FlRouteObserverProxy()])
StatefulShellBranch(observers: [FlRouteObserverProxy()])                 // 每个分支各一个
appRouter.config(navigatorObservers: () => [FlRouteObserverProxy()])     // auto_route：builder，每次返回新实例
Navigator(key: tabKey, observers: [FlRouteObserverProxy()])              // 手写的 tab 内独立栈
```

## 6. 路由栈批量操作

- **`pushAndRemoveUntil`**：被移除的页面各自 stop；仍被新页盖着的底层页**不会**收到 start。
- **`popUntil`**：被跨过的中间层各闪一对 `start → resume → pause → stop`，埋点用时长阈值过滤。
- **弹窗开着时 `pushReplacement` / `pushAndRemoveUntil`，或直接在弹窗上 `push` 页面**：下层页面只收到过弹窗那次 pause，收不到 stop，`isPageAppeared` 仍为 true；上层 pop 回来时收到 resume（不重复 start）。要精确时长就先 `pop` 弹窗再 `push`。
- **在 `onPageStart` 里同步 `push` 页面**：本页只有 `start → stop`；同步弹窗则 resume 推迟到弹窗关闭。

## 8. 转场动画

```dart
class _DetailPageState extends State<DetailPage> with FlAnimationLifecycleMixin {
  @override
  void onPageEnterAnimationEnd() => _loadHeavyStuff();   // 重活推到转场播完
}
```

（用主 mixin 时这四个回调本来就有，不要叠加。）

- `onPageEnterAnimationStart` 首次进入通常不发。
- `onPageEnterAnimationEnd` 可能触发两次（iOS 侧滑放弃），须幂等。
- `onPageLeaveAnimationStart` 不代表会离开；不可逆操作放 `onPageLeaveAnimationEnd` / `onPageDispose`。
- `home` 页没有转场，两个入场事件都不发。

## 17. tab 内独立路由栈

```dart
PageView(
  controller: _controller,
  children: FlPageIndexScope.wrapChildren(controller: _controller, children: const [TabStack(), TabStack()]),
)

// 一个 tab
Navigator(
  observers: [FlRouteObserverProxy()],
  onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => const StackPage()),
)

// 栈内页面
class _StackPageState extends State<StackPage> with FlPageLifecycleMixin {
  @override
  bool get observePageIndex => true;   // 不开就无视外层翻页
}
```

- 可见性 =（本栈是当前页）且（本页是本栈栈顶）。划回来只有栈顶页复活，被盖住的下层保持 stopped，等上层 pop 才 start。
- 页面只跟踪自己所在的 `Navigator`：外层路由盖住整个嵌套栈时，内层页面收不到通知。
- 栈内弹窗要 `showDialog(useRootNavigator: false)`，否则弹到根 `Navigator` 上，内层页面收不到 pause。
