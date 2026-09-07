# 场景配方

可直接改造的完整代码。每个配方先说**为什么这么放**，再给代码——回调选错了编译照样通过，但行为在 dialog 覆盖、iOS 侧滑、切后台这些路径上就会错。

所有例子都假定 `FlRouteObserver.instance` 已注册在对应的 `Navigator` 上。

## 目录

1. [视频 / 音频播放器启停](#1-视频--音频播放器启停)
2. [页面曝光埋点与停留时长](#2-页面曝光埋点与停留时长)
3. [轮询 / WebSocket](#3-轮询--websocket)
4. [TabBarView / PageView 子页懒加载](#4-tabbarview--pageview-子页懒加载)
5. [切后台回来刷新过期数据](#5-切后台回来刷新过期数据)
6. [页面间事件总线](#6-页面间事件总线)
7. [Controller / ViewModel 接生命周期](#7-controller--viewmodel-接生命周期)
8. [StatelessWidget 或局部子树](#8-statelesswidget-或局部子树)
9. [go_router / 嵌套 Navigator 的注册位置](#9-go_router--嵌套-navigator-的注册位置)
10. [全项目统一埋点基类](#10-全项目统一埋点基类)

---

## 1. 视频 / 音频播放器启停

**放哪**：`onPageResume` / `onPagePause`。用 `resume/pause` 而不是 `start/stop`，因为 dialog 盖住页面时只发 `pause`——这正是用户期望「弹窗弹出来视频就停」的时机。用 `start/stop` 的话弹窗期间视频会继续响。

**为什么不用手写 `isCurrent`**：dialog 一盖 `isCurrent` 就是 `false`，你分不清「被弹窗挡住」和「跳去了别的页面」，也就没法决定该不该释放播放器。

```dart
class _VideoPageState extends State<VideoPage> with FlPageLifecycleMixin {
  late final VideoPlayerController _player;
  bool _wasPlaying = false;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        // 初始化可能晚于 onPageResume，所以这里补一次判断
        if (isPageResumed) _player.play();
      });
  }

  @override
  void onPageResume() {
    // 只在用户离开前确实在播的情况下续播，避免用户手动暂停后被强行恢复
    if (_wasPlaying || !_player.value.isInitialized) _player.play();
  }

  @override
  void onPagePause() {
    _wasPlaying = _player.value.isPlaying;
    _player.pause();
  }

  @override
  void dispose() {
    _player.dispose();   // dispose 里放自己的资源；super.dispose() 由 mixin 处理
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: VideoPlayer(_player));
}
```

**要不要开 `observeAppLifecycle`**：不用。切到后台时路由本身不变，但 `onPagePause` 也会走到——`FlPageLifecycleMixin` 的 App 事件只是**额外**的通知渠道。只有当你需要区分「被别的页面覆盖」和「整个 App 进后台」时才开它（比如后台要继续播音频，那就在 `onAppBackground` 里放行）。

**信息流里多个视频卡片自动播**：这个库负责「Feed 页面是否 resumed」，`visibility_detector` 负责「哪张卡在屏上」。两个一起用，不冲突——只用后者会在用户已经跳走的页面上继续播。

---

## 2. 页面曝光埋点与停留时长

**放哪**：`onPageStart` 记曝光和起始时间，`onPageStop` 结算时长。用 `start/stop` 而不是 `resume/pause`，因为 dialog 弹出不该算作离开页面（用户还在这个页面上）。

**为什么天然安全**：`start` 与 `stop` 严格配对且幂等，缺的那半在 `dispose` 时补发。所以不存在「用户直接杀进程/页面在 pause 时被销毁，时长丢了」的漏埋。

```dart
class _ArticlePageState extends State<ArticlePage> with FlPageLifecycleMixin {
  DateTime? _enterAt;

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    // 路由参数在这里才可用；比 initState 晚，比 onPageStart 早
    _pageId = routeName ?? 'unknown';
  }

  @override
  void onPageStart() {
    _enterAt = DateTime.now();
    Analytics.pageView(_pageId, args: arguments);
  }

  @override
  void onPageStop() {
    final at = _enterAt;
    if (at == null) return;
    _enterAt = null;
    // routeName 在 onPageStop 里还能读；到 onPageDispose 就是 null 了
    Analytics.pageDuration(_pageId, DateTime.now().difference(at));
  }
}
```

**要不要把切后台的时间刨掉**：要的话开 `observeAppLifecycle => true`，在 `onAppBackground` 里结算一段、`onAppForeground` 里重新开始计时。同一份累加器加起来就是真实停留时长。

---

## 3. 轮询 / WebSocket

**放哪**：`onPageStart` / `onPageStop` 成对起停，另外开 `observeAppLifecycle` 挡住切后台。

**为什么是 `start/stop` 而不是 `resume/pause`**：用户在这个页面上开个筛选 bottomSheet、或者点开一个确认 dialog，页面并没有离开——这时候轮询该继续，回来看到的才是新数据。`resume/pause` 会在弹窗弹出的瞬间就断掉刷新，这是很常见的线上问题。轮询的成本是后台默默花点流量，不是用户听得见看得见的东西，所以按 `start/stop` 走。

反过来，如果这个「轮询」其实会驱动可见的动画或者播放声音，那就该用 `resume/pause`。判断标准见 SKILL.md 的「最关键的一个判断」。

**为什么两层都要**：路由事件管「用户跳去了别的页面」，App 事件管「整个 App 进后台」。只做前者，App 在后台时定时器还在烧电和流量。

```dart
class _DashboardPageState extends State<DashboardPage> with FlPageLifecycleMixin {
  Timer? _timer;

  @override
  bool get observeAppLifecycle => true;   // 必须是常量，不能跟着 state 变

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _fetch());
    _fetch();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void onPageStart() => _start();      // 弹窗盖上来不会走到这里，轮询得以继续

  @override
  void onPageStop() => _stop();

  @override
  void onAppBackground() => _stop();

  @override
  void onAppForeground() {
    // 只在页面确实可见时才恢复——用户可能是在别的页面切出去的
    if (isPageAppeared) _start();
  }

  Future<void> _fetch() async {
    final data = await api.load();
    if (!mounted) return;      // await 之后必查 mounted
    setState(() => _data = data);
  }
}
```

**WebSocket 同理**，只是 `_start` / `_stop` 换成连接与断开。重连代价高的话，可以把两对回调都用上、分成两级：`onPagePause` 里只停 UI 侧的消费（不再 `setState`），`onPageStop` 里才真断连。因为 `pause` 的含义是「页面还在，可能马上回来」，`stop` 才是「确实被覆盖或离开了」。

---

## 4. TabBarView / PageView 子页懒加载

**为什么必须特殊处理**：`PageView` 的子页全部被 build 并保活，路由事件对它们全都一样，所以「哪个 tab 在屏上」路由说明不了。

**两步都要做**，缺一个就静默失效：

```dart
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
        children: FlPageViewScope.wrapChildren(       // 第 1 步：注入页码
          controller: _controller,
          children: const [FeedTab(), MessageTab(), ProfileTab()],
        ),
      ),
    );
  }
}

class _FeedTabState extends State<FeedTab>
    with FlPageLifecycleMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get observePageView => true;   // 第 2 步：否则首帧就 start，等于没懒加载

  @override
  bool get wantKeepAlive => true;

  bool _loaded = false;

  @override
  void onPageStart() {
    if (_loaded) return;    // 只首次划到时加载
    _loaded = true;
    _load();
  }

  @override
  void onPageResume() => _refreshIfStale();

  @override
  void onPagePause() => _pauseWork();

  @override
  void onPageViewChanged(int from, int to) {
    // 想知道从哪页划到哪页时用；首次解析页码不会触发
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);   // AutomaticKeepAliveClientMixin 要求
    return const SizedBox();
  }
}
```

`TabBarView` 换成传 `TabController`：

```dart
TabBarView(
  controller: _tabController,
  children: FlPageViewScope.wrapChildren(
    controller: _tabController,
    children: const [OneTab(), TwoTab()],
  ),
)
```

`PageView.builder` 用 `wrapItemBuilder`：

```dart
PageView.builder(
  controller: _controller,
  itemCount: items.length,
  itemBuilder: FlPageViewScope.wrapItemBuilder(
    controller: _controller,
    builder: (context, index) => ItemPage(item: items[index]),
  ),
)
```

注意点：

- `controller` 只接受 `PageController` 或 `TabController`，别的类型 debug 下 assert 挂掉。
- 构造函数**不是 `const`**，`const FlPageViewScope(...)` 编译不过。
- 一个 `PageController` 不要给多个 `PageView` 共用——`indexOf` 会返回 `null`，页码解析不出来。
- **嵌套是可以的**（外层 `PageView` + 内层 `TabBarView`），每一层都包，每个子页都开 `observePageView`。子页可见的条件是每一层祖先也都在自己宿主的当前页，所以外层划走时内层的当前 tab 也会 stop——这通常正是想要的。
- 子页的 `start` 到达时机是**帧末**（内部有帧末队列保证「同一帧内所有 hide 先于所有 show」），不是同步。要在 start 里量尺寸的话，`onPagePostFrame` 更稳。

---

## 5. 切后台回来刷新过期数据

**放哪**：`observeAppLifecycle => true` + `onAppForeground`。

**为什么不用 `WidgetsBindingObserver`**：库过滤掉了瞬时打断——来电话、下拉通知栏、控制中心这些只发 `inactive`，不会误判成「用户离开了 App」。自己写 `didChangeAppLifecycleState` 判 `resumed` 的话，每次划一下通知栏都会触发一次刷新。

```dart
class _ProfilePageState extends State<ProfilePage> with FlPageLifecycleMixin {
  @override
  bool get observeAppLifecycle => true;

  DateTime _lastLoad = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void onAppForeground() {
    if (!isPageAppeared) return;   // 只刷新用户真正看得见的页面
    if (DateTime.now().difference(_lastLoad) < const Duration(minutes: 5)) return;
    _load();
  }
}
```

**只需要 App 前后台、完全不关心路由**的页面，用 `FlAppLifecycleMixin` 更轻（但别和 `FlPageLifecycleMixin` 叠加）。如果连页面都不涉及（比如一个 service 单例），直接订 `FlLifecycleManager.instance.stream`：

```dart
final _sub = FlLifecycleManager.instance.stream.listen((foreground) {
  if (foreground) syncQueue.flush();
});
// 自己负责 _sub.cancel()。不要调 FlLifecycleManager.cancel()，那是全局的。
```

冷启动只有**第一个**订阅者会收到那次补发的 `true`，别依赖它做初始化——初始化就在初始化的地方做。

---

## 6. 页面间事件总线

**用在哪**：两个没有共同父级的页面要通信——设置页改主题、下单成功后购物车角标要变。

**为什么用它而不是自己开 `StreamController`**：`FlStateEventBusMixin` 的订阅在 `dispose` 时自动取消，不用留 `StreamSubscription` 字段。

```dart
/// 事件就是普通类，靠类型区分，不用注册
class CartChanged {
  const CartChanged(this.count);
  final int count;
}

class _CartBadgeState extends State<CartBadge> with FlStateEventBusMixin {
  int _count = 0;

  @override
  void initState() {
    super.initState();
    // 必须在 initState 里调一次。写进 build / onPageResume 会让订阅数随重建线性增长，
    // 而且重复的 (类型, 回调) 组合会被静默忽略 + debug assert。
    observeEvent<CartChanged>(_onCartChanged);
  }

  void _onCartChanged(CartChanged e) {
    if (!mounted) return;
    setState(() => _count = e.count);
  }

  void _addToCart() => dispatchEvent(CartChanged(_count + 1));
}
```

同时要生命周期就一起混入，两个 mixin 各管各的、不冲突：

```dart
class _S extends State<P> with FlPageLifecycleMixin, FlStateEventBusMixin { }
```

注意点：

- 事件是**全局广播**，处于 stop 的页面照样收到。后台页面不该反应就在处理函数开头 `if (!isPageAppeared) return;`。
- **绝不要在 `dispose` 或 pop 回调里调 `FlGlobalEventBus.destroy()`**——它关掉整条广播流，所有其他活着的页面的订阅都会收到 `done` 然后静默失活。页面级清理 `FlStateEventBusMixin` 已经做了。`destroy()` 只用于测试 `tearDown` 或 App 退出。
- `State` 之外用 `FlGlobalEventBus.observeEvent<T>()`（返回 `Stream<T>`，自己 cancel）和 `FlGlobalEventBus.dispatchEvent<T>(event)`。
- 想换实现（比如接项目里已有的总线）：`FlGlobalEventBus.configure(自己的 FlIEventBus 实现)`，在 `runApp` 之前调。

---

## 7. Controller / ViewModel 接生命周期

**关键前提**：`FlPageControllerMixin` **不订阅任何东西**。它只是入口 + 一组模板回调，事件必须由页面转发进去。一个回调都不触发时，先查转发写没写。

**签名陷阱**：它的 `onPageContextReady` 参数是 `BuildContext? context`，**和页面 mixin 上的 `(String? routeName, Object? arguments)` 不一样**。路由信息要靠 `setupRouteInfo` 单独喂。

```dart
class DetailController with FlPageControllerMixin {
  Timer? _poll;

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
  void onPageDispose() {
    _poll?.cancel();      // 它没有订阅所以没有 dispose，自己的资源在这里放
  }

  @override
  void onPageContextReady(BuildContext? context) {
    // 注意签名：不是 (routeName, arguments)。路由信息读 this.routeName / this.arguments
  }
}

class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  final _controller = DetailController();

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);          // 必须调 super
    _controller.onLifecycleChanged(state, context: context);
  }

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    _controller.setupRouteInfo(routeName, arguments);
  }
}
```

从 `FlPageLifecycleView.onStateChanged` 转发写法完全一样。

`onPageViewChanged(int from, int to)` 存在，但 `onLifecycleChanged` **不会分发它**，需要页面显式调 `_controller.onPageViewChanged(from, to)`。

Provider / Riverpod / GetX 里放这个 controller 都可以——它不依赖任何状态管理库，只是个普通类。

---

## 8. StatelessWidget 或局部子树

**用在哪**：页面是 `StatelessWidget`；`State` 上的 mixin 链已经很长不想再加；或者只想观测一个子树（比如给某张卡片做曝光）。

```dart
class ProductPage extends StatelessWidget {
  const ProductPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FlPageLifecycleView(
      onStateChanged: (context, state) {
        if (state.isPageResume) _player.play();
        if (state.isPagePause) _player.pause();
      },
      onRouteParam: (context, routeName, arguments) {
        Analytics.pageView(routeName, args: arguments);
      },
      child: const Scaffold(body: Text('Product')),
    );
  }
}
```

- 回调参数名是 `onRouteParam`（不是 `onContextReady`）。
- `child` 被原样返回，不加布局节点。
- mixin 的那些 getter（`isPageAppeared` 等）不对外暴露，需要它们就改用 mixin。
- 每个实例都是一个完整的 mixin（1 条路由订阅 + 1 个首帧回调，开 `observeAppLifecycle` 再加 2 条流）。一个页面用几个免费；长列表里每个 item 放一个要先算清成本。

---

## 9. go_router / 嵌套 Navigator 的注册位置

`FlRouteObserver.instance` 必须注册在**真正管这些页面的那个 Navigator** 上。漏注册不抛异常，只是可见性事件静默不来（debug 下打印一次提示，且**每进程只打一遍**）。

`MaterialApp`：

```dart
MaterialApp(navigatorObservers: [FlRouteObserver.instance], home: const HomePage())
```

`go_router`：

```dart
GoRouter(
  observers: [FlRouteObserver.instance],       // 根 Navigator
  routes: [
    ShellRoute(
      observers: [FlRouteObserver.instance],   // shell 内部的 Navigator 也要注册
      builder: (context, state, child) => ScaffoldWithNav(child: child),
      routes: [...],
    ),
  ],
)
```

`auto_route`：在 `AutoRouterConfig` 的 `navigatorObservers: () => [FlRouteObserver.instance]`；嵌套的 `AutoRouter` / `AutoTabsRouter` 各自也要给。

手写的嵌套 `Navigator`（常见于「每个 tab 一个独立栈」）：

```dart
Navigator(
  observers: [FlRouteObserver.instance],   // 同一个 instance 复用即可
  onGenerateRoute: ...,
)
```

**接入时先读用户的路由配置文件再决定加在哪里**，不要默认只加在 `MaterialApp` 上。判断依据：如果某个页面是被内层 `Navigator` push 的，那个内层就得注册。

**自检症状表**：

| 症状 | 原因 |
|---|---|
| 四个可见性回调全不来，动画回调正常 | 漏注册 observer |
| 只有某些页面不来 | 那些页面所在的嵌套 Navigator 漏注册 |
| PageView 子页首帧就全 start | 忘了 `observePageView => true` |
| PageView 子页可见性永远不变 | 忘了 `FlPageViewScope.wrapChildren` |
| `onAppForeground` 等不来 | 忘了 `observeAppLifecycle => true`，或重写 `appLifecycleChanged` 时漏了 `super` |

---

## 10. 全项目统一埋点基类

项目里所有页面都要埋点时，别在每个页面重复写。抽一个 mixin 叠在 `FlPageLifecycleMixin` 上（**这是叠加的唯一正确形式：叠自己的 mixin，不是叠库里的另一个入口 mixin**）：

```dart
mixin PageTrackMixin<T extends StatefulWidget> on State<T>, FlPageLifecycleMixin<T> {
  /// 子类给页面名；默认用路由名
  String get trackName => routeName ?? runtimeType.toString();

  DateTime? _enterAt;

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);   // 必须
    switch (state) {
      case FlLifecycleState.onPageStart:
        _enterAt = DateTime.now();
        Analytics.pageView(trackName, args: arguments);
      case FlLifecycleState.onPageStop:
        final at = _enterAt;
        if (at != null) {
          Analytics.pageDuration(trackName, DateTime.now().difference(at));
          _enterAt = null;
        }
      default:
        break;
    }
  }
}
```

用起来：

```dart
class _OrderPageState extends State<OrderPage>
    with FlPageLifecycleMixin, PageTrackMixin {
  // 业务代码里只写业务；埋点自动生效
}
```

用 `onLifecycleStateChanged` 这个统一出口，而不是重写每个模板回调，好处是子类可以自由重写 `onPageStart` / `onPageStop` 而不会不小心覆盖掉埋点逻辑（模板回调和统一出口是两条独立的分发路径，各自包在独立的异常守卫里，互不影响）。

**异常安全**：你的回调里抛异常不会阻断其他回调或后续事件——库把每次分发都包在守卫里，异常走 `FlutterError.reportError`。代价是 `try/catch` 抓不到它，要在控制台或 `FlutterError.onError` 里看。所以埋点上报这类可能失败的操作，自己也包一层 `try/catch` 更稳妥。
