# 避坑详解

每条都给出**症状 → 原因 → 怎么做**。按踩到的概率从高到低排。

最后一节是**几个最容易想反的语义**，以及 `example/` 里可以直接对照的写法。

---

## 1. 漏注册 `FlRouteObserver`

**症状**：`onPageStart` / `onPageResume` / `onPagePause` / `onPageStop` 一个都不来，但转场动画那四个回调正常。

**原因**：这四个可见性事件由 `FlRouteObserver` 翻译路由变化而来；不注册就没有源。**不会抛异常**。转场动画回调直接监听 `ModalRoute.animation`，不受注册影响——所以「动画有、可见性没有」是漏注册的确诊症状。

**怎么做**：

```dart
MaterialApp(navigatorObservers: [FlRouteObserver.instance], ...)
```

**嵌套 `Navigator` 各自注册一次**，复用同一个 `instance`。go_router 的 `ShellRoute`、auto_route 的嵌套 router、手写的 tab 内独立栈，都是常漏的地方。具体写法见 `recipes.md` 第 9 节。

debug 下会 `debugPrint` 一条提示，但**每进程只打一遍**——多处漏注册只会看到一次，别以为只有一处。

---

## 2. 用 `isCurrent` 判断可见性

**症状**：dialog / bottomSheet / popupMenu 弹出时，页面被当成「已离开」，资源被释放；或者反过来，明明还在页面上却停掉了刷新。

**原因**：`ModalRoute.isCurrent` 在任何路由压上来时都变 `false`，包括 `PopupRoute`。而 `PopupRoute` 压上来时页面是**完全可见**的，库只发 `pause` 不发 `stop`。

**怎么做**：

| 想知道 | 读 |
|---|---|
| 页面可见吗 | `isPageAppeared` |
| 页面可交互吗 | `isPageResumed` |
| 真的想知道是不是栈顶 | `isCurrent`（这是它唯一的正当用途） |

---

## 3. 叠加库里的多个入口 mixin

**症状**：事件收到两遍；或者更怪——某个状态机完全不跑，回调时序错乱；或者编译时成员冲突。

**原因**：`FlPageRouteMixin`、`FlAnimationLifecycleMixin`、`FlAppLifecycleMixin` 和 `FlPageLifecycleMixin` 订阅同一批源，而且成员名会撞：

- 都声明 `routePageStart` / `routePageResume` / `routePagePause` / `routePageStop`（`FlPageLifecycleMixin` 的那几个是 `@nonVirtual`）
- 都声明 `isCurrent` / `routeName` / `arguments` / `onPageContextReady`
- `FlAppLifecycleMixin` 和 `FlPageLifecycleMixin` 都声明 `isForeground` / `appLifecycleChanged`，但前者的 `appLifecycleChanged` 是空实现且**不是** `@mustCallSuper`，后者的方法体才是真正分发三个原始 App 事件的地方

结果是：最后混入的那个 mixin 的实现被调两次（各自的 delegate 都单独订阅了 `FlRouteObserver`），另一个状态机根本不跑。

**怎么做**：**选一个入口**。需要的能力 `FlPageLifecycleMixin` 全都有（App 事件开 `observeAppLifecycle`，转场动画四个回调本来就在）。

**唯一正确的叠加形式**是叠自己写的 mixin：

```dart
mixin MyMixin<T extends StatefulWidget> on State<T>, FlPageLifecycleMixin<T> { }

class _S extends State<P> with FlPageLifecycleMixin, MyMixin { }
```

`FlStateEventBusMixin` 是例外——它和生命周期无关，可以放心一起混入。

---

## 4. PageView / TabBarView 子页只做了一半

**症状 A**：子页在首帧全部 `start`，懒加载没生效。
**原因**：包了 `FlPageViewScope` 但子页没写 `observePageView => true`，可见性还是按路由算的。

**症状 B**：子页可见性永远不变，划来划去没反应。
**原因**：子页开了 `observePageView` 但外面没包 `FlPageViewScope`，拿不到页码。

**怎么做**：两步都做，见 `recipes.md` 第 4 节。

其他会踩的：

- `controller` 只接受 `PageController` 或 `TabController`，别的类型 debug assert。
- 构造函数**不是 `const`**（带 assert），`const FlPageViewScope(...)` 编译不过。
- 一个 `PageController` 给多个 `PageView` 共用 → `indexOf` 返回 `null`，页码解析不出来。
- 子页的 `start` 在**帧末**到达（内部帧末队列保证同一帧内所有 hide 先于所有 show），不是同步。要量尺寸用 `onPagePostFrame`。
- 嵌套作用域下，子页可见要求**每一层祖先也都在自己宿主的当前页**。外层划走，内层当前 tab 也 stop。

---

## 5. 开关不是常量

**症状**：debug 下 assert 挂掉；release 下可见性状态机停在对不齐的中间态（比如永远收不到 `stop`）。

**原因**：`observePageView` 在 `initState` / `didChangeDependencies` 读取，`observeAppLifecycle` 只在 `initState` 读一次。中途改变值状态机就对不齐了。

**错**：

```dart
@override
bool get observeAppLifecycle => widget.needApp;   // widget 更新后值会变
@override
bool get observePageView => _isInTab;             // 跟着 state 变
```

**对**：

```dart
@override
bool get observeAppLifecycle => true;             // 字面常量
```

真需要按条件走不同行为，就在回调内部判断，而不是改开关。

---

## 6. 重写时漏了 `super`

**症状**：重写 `onLifecycleStateChanged` 后 `FlPageLifecycleView` 的回调不来、自己叠的埋点 mixin 不生效；或者重写 `appLifecycleChanged` 后 `onAppResume` / `onAppInactive` / `onAppPause` 静默失效。

**原因**：这两个是 `@mustCallSuper` 的分发器。`appLifecycleChanged` 特别容易被忽略——它的方法体就是发那三个原始 App 事件的地方。

**怎么做**：

```dart
@override
void onLifecycleStateChanged(FlLifecycleState state) {
  super.onLifecycleStateChanged(state);   // 先调
  // 自己的逻辑
}

@override
void appLifecycleChanged(AppLifecycleState state) {
  super.appLifecycleChanged(state);       // 漏了它，三个 onApp* 就没了
}
```

大多数情况**根本不需要重写这两个**——重写具体的模板回调（`onPageResume` 等）就够，它们不需要 `super`。

---

## 7. `observeEvent` 调在了错误的地方

**症状**：订阅数随页面重建线性增长（内存和 CPU 都在涨）；或者第二次订阅静默不生效 + debug assert。

**原因**：`FlStateEventBusMixin` 用 `(类型, 回调)` 组合去重，重复的**本次订阅被忽略**。但只有**方法引用**能被去重，现场写的闭包字面量每次都是新对象，去不掉。

**错**：

```dart
@override
Widget build(BuildContext context) {
  observeEvent<CartChanged>((e) => setState(...));   // 每次 build 都新增一条
  return ...;
}
```

**对**：

```dart
@override
void initState() {
  super.initState();
  observeEvent<CartChanged>(_onCartChanged);   // 一次，方法引用
}
```

---

## 8. 调了全局的销毁方法

**症状**：某个页面 pop 之后，**所有其他页面**的事件总线订阅或 App 事件全部静默失活。

**原因**：这两个方法是**进程级**的：

- `FlGlobalEventBus.destroy()` 关掉整条广播流，所有活着的订阅都收到 `done` 然后死掉。之后下次使用会惰性重建总线，但**旧订阅不会迁移**。
- `FlLifecycleManager.cancel()` 移除 `WidgetsBinding` 观察者，所有页面都收不到 App 事件了。

**怎么做**：页面级清理什么都不用做——`FlStateEventBusMixin.dispose` 已经取消了自己的订阅。这两个方法只用于**测试的 `tearDown`** 或 **App 真的要退出时**。绝不要出现在 `State.dispose()` 或 pop 回调里。

自己订 `FlLifecycleManager.instance.stream` 的话，自己 `cancel()` 那个 `StreamSubscription`，不要调 manager 的 `cancel()`。

---

## 9. `FlPageControllerMixin` 一个回调都不触发

**原因**：它**不订阅任何东西**。就是入口 + 模板回调，事件必须由页面转发。

**怎么做**：见 `recipes.md` 第 7 节。要转发两处：

```dart
onLifecycleStateChanged  →  _controller.onLifecycleChanged(state, context: context)
onPageContextReady       →  _controller.setupRouteInfo(routeName, arguments)
```

**签名陷阱**：controller 上的 `onPageContextReady` 参数是 `BuildContext? context`，**和页面 mixin 上的 `(String? routeName, Object? arguments)` 不同**。写成后者会编译不过（或者更糟，如果你只是新增了一个同名不同参的方法，它永远不会被调用）。

`onPageViewChanged(int from, int to)` 存在但 `onLifecycleChanged` **不分发它**，页面要显式调。

时序与幂等**完全由转发方决定**。绕过 `FlPageLifecycleMixin` 自己驱动的话，「start 后必有 resume」之类的保证不再成立。

---

## 10. 以为异常能被 `try/catch` 抓到

**原因**：库把每次回调分发都包在 `FlLifecycleGuard.run` 里，异常走 `FlutterError.reportError`（library `'fl_page_lifecycle'`），**不传播给调用方**。

好的一面：你的回调抛异常不会阻断另一个回调、后续事件、或者其他页面的事件（`FlRouteObserver` 里每个订阅者也各自包了守卫）。而且 `dispose` 时即使 `onPageStop` 抛异常，路由订阅**仍然会被解绑**，不会泄漏。

要留意的：这些异常只在控制台或 `FlutterError.onError` 里能看到。所以埋点上报、网络请求这类可能失败的操作，回调里自己再包一层 `try/catch` 更稳妥。

---

## 11. 转场动画回调的语义没对上

- **`onPageEnterAnimationStart` 首次进入通常不发**：动画监听器在 `onPageContextReady` 时才绑上，那时入场动画已经开始了。想表达「页面正在出现」用 `onPageContextReady`。首次进入你能收到的是**动画反转**——iOS 侧滑放弃。
- **`onPageEnterAnimationEnd` 一个生命周期里可能触发两次**：正常入场一次，iOS 侧滑放弃后回弹又一次。计数逻辑要幂等。
- **`onPageLeaveAnimationStart` 不代表页面会离开**：iOS 侧滑放弃时它后面跟的是 `onPageEnterAnimationStart` → `onPageEnterAnimationEnd`，永远不会有 `onPageLeaveAnimationEnd`，也不会有 pause / stop。它也可能反复触发。
- **不可逆的收尾**（提交表单、上报、清缓存）放 `onPageLeaveAnimationEnd` 或 `onPageDispose`，别放 `onPageLeaveAnimationStart`。
- **首页（`home`）没有转场**，两个入场动画事件都不发。

---

## 12. 在 `onPageDispose` 里读路由信息

**症状**：`routeName` 是 `null`。

**原因**：`dispose` 的执行顺序是：补发 pause/stop → **路由委托 detach** → 发 `onPageDispose`。到 `onPageDispose` 时路由已经解绑了。

**怎么做**：路由信息在 `onPageStop` 里读（那时还在），或者在 `onPageContextReady` 时存到字段里。

---

## 13. 事件总线不区分可见性

**症状**：处于 stop 状态的后台页面也在响应事件、也在 `setState`。

**原因**：设计如此——全局广播。

**怎么做**：需要的话自己卡：

```dart
void _onEvent(SomeEvent e) {
  if (!isPageAppeared) return;
  ...
}
```

（这需要同时混入 `FlPageLifecycleMixin` 才有 `isPageAppeared`。）

---

## 14. 选型选错了库

这个库回答**导航层面**的问题：「用户此刻在不在这个页面上」。它**不检测**：

- widget 滚出 `ListView` 视口 → 用 `visibility_detector`
- 同一路由内被不透明 widget 盖住 → 两个库都不检测
- 想知道「卡片露出了百分之多少」→ 用 `visibility_detector`

信息流里自动播视频这类场景**两个一起用**：这个库确认 Feed 页面本身是 resumed 的（否则会在用户已经跳走的页面上继续播），`visibility_detector` 确认哪张卡在屏上。两者观测的东西不同，不冲突。

反过来，纯 App 前后台且不需要过滤瞬时打断的话，Flutter 自带的 `WidgetsBindingObserver` 就够，不必引这个库。需要过滤来电/通知栏这类打断，才值得用 `FlLifecycleManager` 或 `observeAppLifecycle`。

---

## 15. 几个容易误解的语义（README 未必讲透）

下面几条以前 README 写错或没写，现已修正；这里保留结论，因为它们仍然是最容易想反的地方。

### 没有 `ModalRoute` 时，并非四个可见性事件全废

失效的只有**路由驱动的转场**——被覆盖 / 被揭开时的 pause/stop/start/resume，以及两个转场动画事件和 `onPageContextReady` 本身。

首帧的 `onPageStart` + `onPageResume` **照常触发**（首帧门禁只在已拿到 `ModalRoute` 时才生效），`onPagePause` + `onPageStop` 在 `dispose` 时补发。测试 `'a page with no ModalRoute still starts on its first frame'`（`FlPageLifecycleMixin` 和 `FlPageRouteMixin` 各一份）钉的就是这个。

**实用含义**：给一个不在任何路由里的 widget 混入 mixin 是有意义的——能拿到「这个 widget 活着的这段时间」的成对启停。

### `FlPageRouteMixin` 是有幂等和补发的

`_hasAppear` 让 `onRouteStart` / `onRouteStop` 一次性；`routePageResume()` 在从未出现过时会补发 start+resume；`routePageStop()` 先发 `onRoutePause` 再发 `onRouteStop`；`dispose` 补发 pause/stop 对。

真正**没有**守卫的只有 `routePagePause()`——无条件触发，哪怕页面从未出现或已经 pause 过。它与 `FlPageLifecycleMixin` 的真实差别是：不区分弹窗（`PopupRoute` 覆盖也按 pause 转发）、不管 PageView 页码。

### `dispose` 的顺序决定了哪些字段还能读

顺序是：App 委托 detach → 补发 pause/stop → 路由委托 detach（退订 observer + 解绑动画）→ PageView 委托 detach → `onPageDispose`。

补发早于注销是有意的，所以 `routeName` / `arguments` 在 `onPageStop` 里仍可读，到 `onPageDispose` 就是 `null` 了。

### `example/` 里能对照的写法

`example/` 覆盖全部入口，每个 demo 带一块实时事件日志面板，想确认某个事件的真实时序时跑一遍最快。几个值得抄的：

- `example/lib/src/widgets/lifecycle_log.dart` 的 `DemoLogMixin`：`mixin X<T extends StatefulWidget> on State<T>, FlPageLifecycleMixin<T>` 加单一 `onLifecycleStateChanged` 出口——项目里统一埋点就是这个形状。
- `example/lib/src/page_view_page.dart`：嵌套 `PageView` + `TabBarView`，每个子页 `observePageView => true` 配 `AutomaticKeepAliveClientMixin`。
- `example/lib/src/controller_page.dart`：`FlPageControllerMixin` 的两处转发，以及 `onPageContextReady(BuildContext?)` 这个签名差异。
- `example/lib/src/lifecycle_view_page.dart`：`FlPageLifecycleView` 的整页用法，和只包一小块子树做曝光统计的用法。
