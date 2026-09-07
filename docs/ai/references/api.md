# fl_page_lifecycle API 速查

所有签名照源码抄写。**写代码时对不上就来查，不要凭印象拼名字**——库里有同名不同参的回调。

## 目录

- [FlLifecycleState（18 个事件）](#fllifecyclestate)
- [FlPageLifecycleMixin](#flpagelifecyclemixin)
- [FlPageViewScope](#flpageviewscope)
- [FlPageLifecycleView](#flpagelifecycleview)
- [FlPageControllerMixin](#flpagecontrollermixin)
- [FlPageRouteMixin](#flpageroutemixin)
- [FlAppLifecycleMixin](#flapplifecyclemixin)
- [FlAnimationLifecycleMixin](#flanimationlifecyclemixin)
- [FlRouteObserver](#flrouteobserver)
- [事件总线](#事件总线)
- [FlLifecycleManager](#fllifecyclemanager)
- [全部 assert 与 debug 提示原文](#全部-assert-与-debug-提示原文)
- [导入](#导入)

---

## FlLifecycleState

`enum FlLifecycleState`，18 个值，**按声明顺序**：

```
1  onPageInit
2  onPageContextReady
3  onPagePostFrame
4  onPageReassemble
5  onPageEnterAnimationStart
6  onPageStart
7  onPageResume
8  onPageEnterAnimationEnd
9  onPagePause
10 onPageStop
11 onPageLeaveAnimationStart
12 onPageLeaveAnimationEnd
13 onPageDispose
14 onAppResume
15 onAppInactive
16 onAppPause
17 onAppForeground
18 onAppBackground
```

枚举自身的成员（不是 extension）：

```dart
bool get isPageResume;  // == onPageResume
bool get isPagePause;   // == onPagePause
bool get isAppEvent;    // ∈ {onAppForeground, onAppBackground, onAppResume, onAppInactive, onAppPause}
```

没有 `isPageEvent`，没有 `label`，没有别的 extension。

---

## FlPageLifecycleMixin

```dart
mixin FlPageLifecycleMixin<T extends StatefulWidget> on State<T>
    implements LifecycleRouteAware
```

重写了 `initState` / `didChangeDependencies` / `reassemble` / `dispose`（都调 `super`）。

### 开关 getter

| Getter | 类型 | 默认 |
|---|---|---|
| `observePageView` | `bool` | `false` |
| `observeAppLifecycle` | `bool` | `false` |

两者都只在 `initState`（`observePageView` 另在 `didChangeDependencies`）读取，运行期改变会触发 debug assert。

### 只读 getter

```dart
String? get routeName;        // ModalRoute.settings.name；dispose 后为 null
Object? get arguments;        // ModalRoute.settings.arguments
bool    get isInPageView;     // 首次 didChangeDependencies 之前为 false
int     get pageIndex;        // 不在 PageView 中时 -1
int     get currentPageIndex; // 未知时 -1
int     get pageViewDepth;    // 最外层 0，不在任何作用域中 -1
bool    get isForeground;     // 读 WidgetsBinding.lifecycleState，无需订阅
bool    get isPageAppeared;   // start 已发且 stop 未发 —— 判「可见」用这个
bool    get isPageResumed;    // resume 已发且 pause 未发 —— 判「可交互」用这个
bool    get isCurrent;        // ModalRoute.isCurrent，实时；无 ModalRoute 时 false
```

### 可重写回调

全部 `@protected`、`void`、空实现（除注明者）：

```dart
void onPageInit()
void onPageContextReady(String? routeName, Object? arguments)   // ← 两个参数
void onPagePostFrame()
void onPageReassemble()                       // 仅 debug（kDebugMode 门禁）
void onPageEnterAnimationStart()
void onPageStart()
void onPageResume()
void onPageEnterAnimationEnd()
void onPageLeaveAnimationStart()
void onPagePause()
void onPageStop()
void onPageLeaveAnimationEnd()
void onPageDispose()
void onAppResume()        // 需 observeAppLifecycle == true
void onAppInactive()      // 需 observeAppLifecycle == true
void onAppPause()         // 需 observeAppLifecycle == true
void onAppForeground()    // 需 observeAppLifecycle == true
void onAppBackground()    // 需 observeAppLifecycle == true
void onPageViewChanged(int from, int to)      // 仅 isInPageView 时；首次解析页码不发

@protected @mustCallSuper
void onLifecycleStateChanged(FlLifecycleState state)     // 统一出口，空实现

@mustCallSuper @protected
void appLifecycleChanged(AppLifecycleState state)        // 非空实现：它分发上面三个原始 App 事件
```

**只有这两个是 `@mustCallSuper`**：`onLifecycleStateChanged` 和 `appLifecycleChanged`。后者容易被忽略——它的方法体就是发 `onAppResume` / `onAppInactive` / `onAppPause` 的地方，漏 `super` 会让这三个静默失效。`hidden` 和 `detached` 被显式列出且刻意不发任何事件。

`@internal @override @nonVirtual`（不可重写，别碰）：`routePageStart()` / `routePageResume()` / `routePagePause()` / `routePageStop()`。

### 异常隔离

`_emit` 先调模板回调、再调 `onLifecycleStateChanged`，两者各自包在独立的 `FlLifecycleGuard.run` 里。所以：

- 你的回调里抛异常**不会阻断另一个回调，也不会阻断后续事件**；
- 异常走 `FlutterError.reportError`（library `'fl_page_lifecycle'`），**不会传播给调用方**，`try/catch` 抓不到。要在控制台或 `FlutterError.onError` 里看。

### 订阅与释放

- `initState`：`observeAppLifecycle` 为真 → 挂 2 条全局流订阅（`FlLifecycleManager.instance.stream` + `.lifecycle`）；发 `onPageInit`；注册一个 `addPostFrameCallback`。
- `didChangeDependencies`：`observePageView` 为真 → 订阅最近的 `FlPageViewScope`；随后 `attachOnce(context)` 订阅 `FlRouteObserver.instance` 并绑 `ModalRoute.animation` 状态监听，首次成功时发 `onPageContextReady`。失败**不锁定**，后续每次 `didChangeDependencies` 都会重试。
- `dispose` 顺序：App 委托 detach → 补发 `onPagePause` + `onPageStop`（若仍 appeared）→ 路由委托 detach（退订 observer、解绑动画）→ PageView 委托 detach → 发 `onPageDispose` → `super.dispose()`。**所以 `routeName` 在 `onPageStop` 里可读，在 `onPageDispose` 里是 `null`。**

### 首帧可见性门禁

`observePageView && isInPageView` 时首帧不 start（交给页码驱动）；否则若路由已 attach 且 `!isCurrent` 则不 start（首帧内就被盖住的页面不会误发 start）。**没有 `ModalRoute` 时不设门禁**——见 pitfalls.md 里的重要澄清。

---

## FlPageViewScope

```dart
class FlPageViewScope extends StatefulWidget

FlPageViewScope({                 // 非 const（带 assert）
  super.key,
  required int pageIndex,
  required Listenable controller, // 实际只接受 PageController 或 TabController
  required Widget child,
})
```

`build` 返回包着 `child` 的内部 InheritedWidget，不加布局节点。

### 静态方法（消费者可用的）

```dart
static int  depthOf(BuildContext context);                 // 不在作用域中 -1
static Listenable listenableOf(Listenable controller);      // TabController → animation ?? controller
static int? indexOf(Listenable controller);
static int  initialIndexOf(Listenable controller);

static NullableIndexedWidgetBuilder wrapItemBuilder({
  required Listenable controller,
  required NullableIndexedWidgetBuilder builder,
});

static List<Widget> wrapChildren({
  required Listenable controller,
  required List<Widget> children,
});
```

`maybeOf` / `read` 是 `@internal`，且 `FlPageViewScopeData`、`FlPageViewVisibility` 在库导出处被 `hide` 掉了——**包的使用者拿不到，别写**。

`indexOf` 返回 `null` 的情况：`TabController.length == 0`；`PageController.positions.length != 1`（布局前，或一个 controller 被多个 `PageView` 共用）；`PageController.page == null`。

### 嵌套语义

深度对齐 `ScrollNotification.depth`：最外层 0，每嵌一层 +1，作用域外 -1。每个作用域只订阅自己的 controller 和**直接父作用域**的可见性，`visible = (父?.visible ?? true) && index == pageIndex`。所以子页可见要求每一层祖先都在自己宿主的当前页；外层划走会让内层当前 tab 也 stop。可见性通过 `ValueNotifier` 下推，**翻页不会 rebuild 子树**。

未被包裹的 `PageView` 子页被当普通页面处理：首帧 start，之后翻页不改变可见性。

### 跨页顺序保证（README 未写）

内部有帧末两阶段队列：同一帧内**所有隐藏事件先于所有显示事件**，与监听注册顺序无关；同一批里翻过去又翻回来则什么都不发。因此 PageView 子页的 `start` 到达时机是**帧末**，不是同步。

---

## FlPageLifecycleView

```dart
typedef FlPageLifecycleCallback   = void Function(BuildContext context, FlLifecycleState state);
typedef FlPageRouteParamCallback  = void Function(BuildContext context, String? routeName, Object? arguments);
typedef FlPageViewChangedCallback = void Function(BuildContext context, int from, int to);

const FlPageLifecycleView({
  super.key,
  bool observePageView = false,
  bool observeAppLifecycle = false,
  FlPageLifecycleCallback? onStateChanged,
  FlPageRouteParamCallback? onRouteParam,      // ← 叫 onRouteParam，没有 onContextReady
  FlPageViewChangedCallback? onPageViewChanged,
  required Widget child,
});
```

内部 `State` 混入完整 `FlPageLifecycleMixin`，`build` 原样返回 `widget.child`。mixin 的那些 getter（`routeName` / `isPageAppeared` …）**不对外暴露**——需要它们就用 mixin。

每个实例都是一个完整的 mixin：1 条路由订阅 + 1 个首帧回调，开 `observeAppLifecycle` 再加 2 条全局流订阅。一个页面用几个是免费的；列表里放几百个要先算一下。

---

## FlPageControllerMixin

```dart
mixin FlPageControllerMixin      // 无 on 约束、无类型参数，任何类都能混入
```

**它不订阅任何东西，也没有 `dispose`。** 事件全靠页面转发进来。一个回调都不触发时，先查转发。

```dart
FlLifecycleState get lifecycleState;   // 初值 FlLifecycleState.onPageInit
bool get isPageResume;                 // 最后一个事件是否 onPageResume
bool get isPagePause;
bool get isForeground;
String? get routeName;
Object? get arguments;

void setupRouteInfo(String? name, Object? arguments);   // 注意首参名是 name

@mustCallSuper
void onLifecycleChanged(FlLifecycleState state, {BuildContext? context});   // 转发入口
```

模板回调（除最后一个外都 `@protected`，都不是 `mustCallSuper`）：

```dart
void onPageInit()
void onPageContextReady(BuildContext? context)   // ← ⚠️ 和页面 mixin 上同名回调签名不同！
void onPagePostFrame()
void onPageReassemble()
void onPageStart()
void onPageResume()
void onPageEnterAnimationStart()
void onPageEnterAnimationEnd()
void onPagePause()
void onPageStop()
void onPageLeaveAnimationStart()
void onPageLeaveAnimationEnd()
void onPageDispose()
void onAppResume()
void onAppInactive()
void onAppPause()
void onAppForeground()
void onAppBackground()

void onPageViewChanged(int from, int to)   // 非 @protected，且 onLifecycleChanged 不会分发它，需页面显式调
```

`onLifecycleChanged` 先缓存 state，再在 `FlLifecycleGuard.run` 里分发——controller 里抛异常不会回传到页面的链路上。

时序与幂等**完全由转发方决定**：绕过 `FlPageLifecycleMixin` 自己驱动 `onLifecycleChanged`，「start 后必有 resume」之类的保证就不成立了。它没有订阅所以没有 `dispose`，自己的资源在 `onPageDispose` 里放。

---

## FlPageRouteMixin

```dart
mixin FlPageRouteMixin<T extends StatefulWidget> on State<T>
    implements LifecycleRouteAware
```

```dart
ModalRoute? get modalRoute;   // 无路由或 dispose 后为 null
String?     get routeName;
Object?     get arguments;
bool        get isCurrent;
bool        get hasRoute;
```

回调全部 `@protected`、无 `mustCallSuper`：

```dart
void onPageContextReady(String? routeName, Object? arguments)
void onPageEnterAnimationStart()
void onPageEnterAnimationEnd()
void onPageLeaveAnimationStart()
void onPageLeaveAnimationEnd()
void onRouteStart()     // ⚠️ 是 onRoute*，不是 onPage*
void onRouteResume()
void onRoutePause()
void onRouteStop()
```

实际实现的语义（README 说它「不做幂等和补发」，**不准确**）：`_hasAppear` 让 start/stop 一次性；`routePageResume()` 在未曾出现过时会补发 start+resume；`routePageStop()` 先发 `onRoutePause` 再发 `onRouteStop`；`dispose` 会补发 pause/stop 对。真正没有守卫的是 `routePagePause()`——它无条件触发，哪怕页面从未出现或已经 pause。

---

## FlAppLifecycleMixin

```dart
mixin FlAppLifecycleMixin<T extends StatefulWidget> on State<T>

bool get isForeground;
bool get hasInit;      // dispose 后 false

@protected void onAppForeground()                            // 无 mustCallSuper
@protected void onAppBackground()                            // 无 mustCallSuper
@protected void appLifecycleChanged(AppLifecycleState state)  // 这里是空实现，无 mustCallSuper
```

`initState` **无条件**订阅（2 条流），没有开关；`dispose` 退订。

---

## FlAnimationLifecycleMixin

```dart
mixin FlAnimationLifecycleMixin<T extends StatefulWidget> on State<T>
```

无 getter。四个 `@protected`、无 `mustCallSuper` 的回调：

```dart
void onPageEnterAnimationStart()   // AnimationStatus.forward
void onPageEnterAnimationEnd()     // completed —— 可能在一个生命周期里触发两次（iOS 侧滑放弃）
void onPageLeaveAnimationStart()   // reverse —— 可能反复触发
void onPageLeaveAnimationEnd()     // dismissed
```

`didChangeDependencies` 里重试直到有 `ModalRoute`；没有 `ModalRoute` 时什么都不发也不抛。

---

## FlRouteObserver

```dart
class FlRouteObserver extends NavigatorObserver {
  static final FlRouteObserver instance = FlRouteObserver._();
  factory FlRouteObserver() => instance;   // 和 .instance 是同一个对象
}
```

公开面就是 `instance`、那个 factory，和四个 `NavigatorObserver` 重写（`didPush` / `didPop` / `didRemove` / `didReplace`）。`subscribe` / `unsubscribe` 是 `@internal`。

注册：`MaterialApp(navigatorObservers: [FlRouteObserver.instance])`。**嵌套 `Navigator` 各自注册一次，复用同一个 instance。** 转场动画回调不受注册影响（直接监听 `ModalRoute.animation`）。

行为：

- `didPush`：下层订阅者收 `pause`（新路由 `is PopupRoute`）或 `stop`（普通路由）。
- `didPop` / `didRemove`：离开的路由的订阅者集合被原子摘除并逐个 `stop`；然后**仅当 `previousRoute?.isCurrent == true`** 才唤醒下层（popup 走 `resume`，普通走 `start`）。这个 `isCurrent` 判断就是抑制 `pushAndRemoveUntil` / `popUntil` 期间误发 start 的地方。
- `didReplace`：旧路由 stop，**不唤醒下层**。
- 每个订阅者的调用各自包 guard，一个抛异常不影响其他订阅者和下层页面。

---

## 事件总线

### FlStateEventBusMixin

```dart
mixin FlStateEventBusMixin<S extends StatefulWidget> on State<S>

@protected void observeEvent<T>(void Function(T event) onData);
@protected void dispatchEvent<T>(T event);
@override @mustCallSuper void dispose();   // 自动取消全部订阅
```

内部维护订阅列表 + `(Type, Function)` 去重集合。重复的 `(T, onData)` 组合**本次订阅被忽略** + debug assert。只有方法引用能被去重，现场写的闭包字面量不能——所以 `observeEvent` 要在 `initState` 里调一次。

### FlGlobalEventBus（纯静态）

```dart
static void configure(FlIEventBus bus);   // 与旧实例不同则销毁旧的
static Future<void> destroy() async;      // ⚠️ 全局
static Stream<T> observeEvent<T>();
static void dispatchEvent<T>(T event);
```

`destroy()` 后下次使用会惰性重建一个 `FlEventBus`，但**旧订阅不会迁移**（它们收到了 `done` 已经死了）。`destroy()` / `configure()` 是进程级的，只该出现在测试的 `setUp` / `tearDown` 或 App 退出时。

### FlIEventBus / FlEventBus

```dart
abstract class FlIEventBus {
  Stream<T> on<T>();        // T == dynamic 时不过滤
  void fire(dynamic event);
  Future<void> destroy();
}

class FlEventBus implements FlIEventBus {
  FlEventBus({bool sync = false});
  FlEventBus.customController(StreamController<dynamic> controller);
  StreamController<dynamic> get streamController;
  // fire 在 controller 已关闭时是 no-op
}
```

传窄化的 controller（如 `StreamController<String>`）能通过 `customController`（Dart 泛型协变），但第一次 `fire` 不匹配类型时会抛 `TypeError`。

事件是**全局广播**：处于 stop 状态的页面照样收到。不想让后台页面反应就在处理函数里用 `isPageAppeared` 卡一下。

---

## FlLifecycleManager

```dart
class FlLifecycleManager extends WidgetsBindingObserver {
  static final FlLifecycleManager instance = FlLifecycleManager._();
  factory FlLifecycleManager() => instance;

  bool get isForeground;                    // lifecycleState == resumed
  Stream<bool> get stream;                  // 过滤后的前后台
  Stream<AppLifecycleState> get lifecycle;  // 原始、不过滤
  void listen();                            // 幂等
  void cancel();                            // 幂等；⚠️ 全局
  @override void didChangeAppLifecycleState(AppLifecycleState state);
}
```

两个广播 controller 是 `final` 且**永不关闭**。冷启动补发：首次 `listen()` 时若已 `resumed` 且从未发过前台事件，会用微任务发一次 `true`——**每进程只有一次，所以只有第一个订阅者能看到**。`paused` → 发 `false`；`resumed` → 只在来自 `paused` 时（或冷启动补发）发 `true`。`inactive` / `hidden` / `detached` 在 `stream` 上不发（这就是电话、通知栏下拉这类瞬时打断被过滤掉的机制），但都会流过 `lifecycle`。

`cancel()` 会让**所有活着的页面**都收不到 App 事件。绝不能在 `State.dispose()` 或 pop 回调里调。

---

## 全部 assert 与 debug 提示原文

1. `FlPageViewScope` 构造：

```
controller 只支持 PageController 或 TabController，收到的是 ${controller.runtimeType}
```

2. `FlPageLifecycleMixin` 开关稳定性（`initState` 和每次 `didChangeDependencies` 都检查）：

```
observePageView 在运行时被改成了 $observePageView（初始为 ...）。它必须在整个生命周期内保持不变，否则可见性状态机会停在对不齐的中间态。
```
```
observeAppLifecycle 在运行时被改成了 $observeAppLifecycle（初始为 ...）。它只在 initState 读取一次，改了也不会生效。
```

3. `observeEvent` 重复订阅（**本次订阅被跳过**，不只是警告）：

```
observeEvent<$T> 重复订阅了同一个回调。请把它移到 initState 中只调用一次——写在 build / onPageResume 里会让订阅数随重建次数线性增长。本次订阅已被忽略。
```

4. 未注册 observer 的提示（`debugPrint`，**每进程最多一次**）：

```
[page_lifecycle] 当前 Navigator 没有注册 FlRouteObserver，页面的 onPageStart / onPageResume / onPagePause / onPageStop 不会触发（转场动画回调不受影响，它直接监听 ModalRoute.animation）。请加上：
  MaterialApp(navigatorObservers: [FlRouteObserver.instance], ...)
嵌套 Navigator 需要各自注册一次。（本提示每次运行只输出一遍）
```

看到这条就是漏注册了。**注意它每进程只打一遍**——多个 Navigator 都漏注册时，只会提示一次。

---

## 导入

一个导入拿到全部公开面：

```dart
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
```

不要 import `package:fl_page_lifecycle/src/...` 下的任何文件。
