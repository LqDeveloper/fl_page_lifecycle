# fl_page_lifecycle

给 Flutter 页面装上 Android 风格的生命周期：任意 `State` 上的 `start` / `resume` / `pause` /
`stop`，外加首帧、路由转场动画、App 前后台，以及按页码驱动的容器
（`PageView`、`TabBarView`、`IndexedStack`）。

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) | 中文

---

- [为什么需要它](#为什么需要它)
- [核心能力](#核心能力)
- [我该用哪个入口](#我该用哪个入口)
- [与 `visibility_detector` 的区别](#与-visibility_detector-的区别)
- [环境要求](#环境要求)
- [安装](#安装)
- [快速开始](#快速开始)
- [用法](#用法)
- [事件时序](#事件时序)
- [API 速查](#api-速查)
- [第三方依赖](#第三方依赖)
- [注意事项](#注意事项)

## 为什么需要它

Flutter 只给了 `initState` 和 `dispose`，不会告诉你页面什么时候**变得可见**、什么时候
**可以交互**——而视频播放、轮询定时器、曝光埋点、动画，关心的恰恰是这两个时刻。

想自己回答「我这页现在可见吗」，得把 `RouteAware`、`WidgetsBindingObserver`、
`ModalRoute.of(context)!.isCurrent`、`PageController` 监听、首帧回调拼起来，然后把边界情况
一个个做对：

- 弹窗盖上来时页面**仍然可见**，你要的是 `pause` 而不是 `stop`；而 `isCurrent` 这时返回
  `false`，分不出这两种情况。
- `pushAndRemoveUntil` 会对一个**仍被别的路由盖着**的页面发出 `didRemove`。照着直觉写的
  `RouteAware` 会给一个没人看得见的页面发 `start`。
- iOS 侧滑返回拖到一半放弃，退场动画播了却没播完。
- 页面在 paused 状态下被销毁，你等的那个 `resume` 永远不会来。

这个包把这些账一次算清，给你成对且幂等的回调：**每个 `start` 后面一定有 `stop`，每个
`pause` 后面一定有 `resume` 或 `stop`**，缺的那半边在 `dispose` 时补发。混入一个 mixin，
覆写你关心的回调即可——没有要初始化的东西，也没有要释放的东西。

## 核心能力

- 完整的可见性状态机 —— `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop`，
  成对且幂等；弹窗只 pause 不 stop
- 路由转场动画回调，包含 iOS 侧滑返回中途放弃的情形
- App 前后台，且过滤掉来电、下拉通知栏这类瞬时中断
- `PageView`、`TabBarView`、`IndexedStack` 的子页按页码而非路由驱动
- 通过转发式 observer 支持嵌套 `Navigator`
- 不需要改动现有继承结构 —— [mixin](#1-在-state-上拿到页面生命周期)、
  [包一层 Widget](#4-不混入-mixin包一层-widget)、或[普通 Dart 对象](#5-在-controller--viewmodel-里收事件)
- 页面级全局事件总线，订阅随 `dispose` 自动取消
- 只有一个第三方依赖（`meta`），无平台通道，无代码生成

## 我该用哪个入口

| 你想要 | 用 |
|---|---|
| `State` 上的完整生命周期 | [`FlPageLifecycleMixin`](#1-在-state-上拿到页面生命周期) |
| 同上，但页面在 `PageView` / `TabBarView` / `IndexedStack` 里 | [`FlPageIndexScope`](#2-按页码驱动的容器子页) + `observePageIndex` |
| 页面在嵌套 `Navigator` 里 | [`FlRouteObserverProxy`](#3-嵌套-navigator) |
| 不混入 `State` 也要拿到事件 | [`FlPageLifecycleView`](#4-不混入-mixin包一层-widget) |
| 在 Controller / ViewModel 里收事件 | [`FlPageControllerMixin`](#5-在-controller--viewmodel-里收事件) |
| 只要 App 前后台 | `FlAppLifecycleMixin` |
| 只要路由转场动画 | `FlAnimationLifecycleMixin` |
| 只要路由事件，不需要弹窗区分与页码判定 | `FlPageRouteMixin` |

后三个是独立入口。**不要与 `FlPageLifecycleMixin` 叠加使用**——它们订阅同一批事件源，
叠加后每个事件会收到两遍。

## 与 `visibility_detector` 的区别

[`visibility_detector`](https://pub.dev/packages/visibility_detector) 回答的是**几何**问题：
这个 widget 的包围盒有多少落在视口里？本包回答的是**导航**问题：用户现在待的是不是这一页？
两者互不覆盖。

| | `visibility_detector` | `fl_page_lifecycle` |
|---|---|---|
| 观测单位 | 任意 widget，靠唯一 `Key` 标识 | 一个路由页，或按页码驱动的容器子页 |
| 报什么 | `visibleFraction`、`visibleBounds` —— 连续值 | 离散事件：`start` / `resume` / `pause` / `stop` |
| 滚出 `ListView` 视口 | 能检测 —— 这是它的主场 | **不**检测 |
| 被 dialog / bottomSheet 盖住 | 不做遮挡判定 | `pause`，关闭后 `resume` |
| 路由 push / pop | 不覆盖 | 它的主场 |
| App 前后台 | 不覆盖 | 覆盖，且过滤瞬时中断 |
| 接入成本 | 无，包一层 widget 即可 | 需要把 `FlRouteObserver` 注册到 `Navigator` |

**信息流自动播放视频需要两个一起用**：本包告诉你 Feed 页本身是不是 resumed 的——否则你会在
用户已经离开的页面上继续播；`visibility_detector` 告诉你哪张卡片在屏幕上。把两个信号存成两个
字段、在一处合并判断，不要在两个回调里各自调 `play()`。

## 环境要求

| 项 | 要求 |
|---|---|
| Dart SDK | `^3.11.5` |
| Flutter | `>=3.41.9` |
| 平台 | Flutter 支持的全部平台 —— 无插件、无平台通道、不使用 `dart:io` |

平台支持完全继承自你的 Flutter 版本：本包没有任何平台特定实现。

## 安装

```yaml
dependencies:
  fl_page_lifecycle: ^0.0.4
```

```bash
flutter pub get
```

## 快速开始

两步。**漏掉第一步是最高频的问题**——不注册 observer，四个可见性回调就永远不触发，
而且既不报错也没有日志。

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // 第 1 步 —— 注册 observer。嵌套 Navigator 各自还要一个，见下文。
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

// 第 2 步 —— 混入并覆写你需要的回调。不用初始化，也不用释放。
class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  @override
  void onPageResume() => debugPrint('visible and interactive');

  @override
  void onPagePause() => debugPrint('covered by a dialog, or leaving');

  @override
  Widget build(BuildContext context) => const Scaffold();
}
```

## 用法

### 1. 在 `State` 上拿到页面生命周期

**什么时候用**：一个路由页，在用户去别处时要停掉某些事情——视频、轮询定时器、动画——
回来时再恢复。

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class _FeedPageState extends State<FeedPage> with FlPageLifecycleMixin {
  Timer? _poll;
  bool _didLoadHeavy = false;

  // 两个开关默认都是 false，且必须在整个生命周期内保持不变。
  @override
  bool get observeAppLifecycle => true;

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    // 最早能读到 routeName / arguments 的时机。
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
    if (_didLoadHeavy) return; // 可能触发两次，见「注意」
    _didLoadHeavy = true;
    _decodeLargeImages();
  }

  @override
  void onAppForeground() => _refresh(); // 真的从后台回来，不是拉了下通知栏

  @override
  void onPageDispose() => _poll?.cancel();

  void _refresh() {}
  void _decodeLargeImages() {}

  @override
  Widget build(BuildContext context) => const Scaffold();
}
```

**两个开关**

| 名称 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `observePageIndex` | `bool` | `false` | 按页码而非路由驱动可见性，要求外层有 `FlPageIndexScope` |
| `observeAppLifecycle` | `bool` | `false` | 订阅 App 前后台。每个实例多两条全局流订阅 |

**随时可读的状态**

`isPageAppeared`、`isPageResumed`、`isForeground`、`routeName`、`arguments`、`isCurrent`、
`isInPageScope`、`pageIndex`、`currentPageIndex`、`pageScopeDepth`。

**注意**

- 判断「页面可见吗」用 `isPageAppeared`，**不要**用 `isCurrent`——弹窗盖上来时它是 `false`，
  而页面其实完整地显示着。
- 两个开关会被提前读取，必须是编译期常量。写成 `widget.something` 会在 debug 下触发断言。
- `onPageEnterAnimationEnd` 可能触发两次：iOS 侧滑返回中途放弃时，动画走
  `reverse → forward → completed`。放在那里的副作用操作必须自己做幂等。

### 2. 按页码驱动的容器子页

**什么时候用**：`PageView`、`TabBarView`、`IndexedStack` 的子页。它们划出视口后依然活着，
因此没有任何信号告诉它们「我被换下去了」——`dispose` 不走，路由也没变。

在容器一侧把子页包一层即可，页码会自动下发。

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
  // 不开这个开关，子页会被当成普通页面：首帧就 start，之后再也不 stop。
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

`IndexedStack` 没有控制器，把驱动它 `index` 的那个 `ValueListenable<int>` 传进来即可——
两边读的是同一个对象，不可能对不上：

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

**`FlPageIndexScope` 的静态方法**

| 名称 | 签名 | 说明 |
|---|---|---|
| `wrapChildren` | `({required Listenable controller, required List<Widget> children}) → List<Widget>` | 逐个包装子列表，下标即页码 |
| `wrapItemBuilder` | `({required Listenable controller, required NullableIndexedWidgetBuilder builder}) → NullableIndexedWidgetBuilder` | 包装 `PageView.builder` 的 `itemBuilder` |
| `depthOf` | `(BuildContext) → int` | Scope 嵌套深度，最外层 `0`，不在 Scope 中为 `-1` |
| `indexOf` | `(Listenable) → int?` | 控制器当前页码，尚不可用时为 `null` |
| `initialIndexOf` | `(Listenable) → int` | `indexOf` 尚不可用时的兜底页码 |
| `listenableOf` | `(Listenable) → Listenable` | 该订阅哪个对象才能感知切页 |

**注意**

- `controller` 接受 `PageController`、`TabController` 或 `ValueListenable<int>`，
  其他类型在 debug 下触发断言。
- **滚动型容器只在停稳时提交可见性。** `animateToPage(0 → 4)` 会从中间几页掠过去，
  但它们一个事件都不会发——否则曝光埋点会凭空多出三次页面浏览。`jumpToPage` 不产生滚动活动，
  当场提交；`IndexedStack` 没有中间态，同样当场提交。
- **嵌套时每一层都要包。** 只包外层不会报错：内层子页会静默绑到外层的 Scope 上，
  切内层子页时永远不 stop。debug 下会提示一次。

### 3. 嵌套 `Navigator`

**什么时候用**：go_router 的 `ShellRoute` / `StatefulShellRoute`、auto_route 的嵌套 router、
或手写的 tab 内独立栈——任何同时存在多个 `Navigator` 的结构。

`FlRouteObserver` 是单例，而 Flutter 的 `Navigator` 会断言一个 observer 实例最多只绑定一个
`NavigatorState`。所以根 `Navigator` 用单例，其余每个嵌套 `Navigator` 各用一个 proxy，
它们转发到同一张订阅表：

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class TabStack extends StatelessWidget {
  const TabStack({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      // 每个 Navigator 一个新 proxy。复用同一个会触发同样的断言。
      observers: [FlRouteObserverProxy()],
      onGenerateRoute: (settings) =>
          MaterialPageRoute<void>(settings: settings, builder: builder),
    );
  }
}
```

go_router 也是同一个形状——根用 `GoRouter(observers: [FlRouteObserver()])`，
每个 shell 用 `ShellRoute(observers: [FlRouteObserverProxy()])`。

**注意**

- 页面只跟踪**自己所在**的那个 `Navigator`。外层路由把整个嵌套 `Navigator` 盖住时，
  内层页面不会收到通知。需要这种联动的话，在嵌套 `Navigator` 外面包一层
  `FlPageLifecycleView` 往下转发。
- `showDialog` 默认 `useRootNavigator: true`。想让嵌套栈里的页面收到 `onPagePause`，
  要显式传 `false`。

### 4. 不混入 mixin，包一层 Widget

**什么时候用**：页面是 `StatelessWidget`、`State` 上已经不方便再加 mixin、
或者你只想观测某一块子树。

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

**参数**

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `observePageIndex` | `bool` | `false` | 与 mixin 上同名开关含义一致 |
| `observeAppLifecycle` | `bool` | `false` | 与 mixin 上同名开关含义一致 |
| `onStateChanged` | `FlPageLifecycleCallback?` | `null` | 每一个 `FlLifecycleState` 事件 |
| `onRouteParam` | `FlPageRouteParamCallback?` | `null` | 路由名与参数就绪时回调 |
| `onPageIndexChanged` | `FlPageIndexChangedCallback?` | `null` | 页码变化，`(from, to)` |
| `child` | `Widget` | 必填 | 原样返回，不引入布局节点 |

**注意**

- 不要在 `onPageInit` / `onPageDispose` 时机用回调里的 `context` 查 `InheritedWidget`：
  此时 `State` 还没挂上，或正在 unmount。
- 每个实例都是一套完整的状态机。一个页面放几个是免费的，列表里放几百个就不是——
  尤其是同时打开 `observeAppLifecycle: true`（每个实例两条全局订阅）。

### 5. 在 Controller / ViewModel 里收事件

**什么时候用**：启停逻辑写在 widget 树之外。

`FlPageControllerMixin` **不订阅任何东西**——事件必须由页面转发进来。

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class DetailController with FlPageControllerMixin {
  @override
  void onPageResume() => debugPrint('start polling');

  @override
  void onPagePause() => debugPrint('stop polling');

  // 注意签名是 BuildContext?，不是 (String?, Object?)。
  @override
  void onPageContextReady(BuildContext? context) => debugPrint('$routeName');
}

class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  final _controller = DetailController();

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state); // 必须调用
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

**注意**

- 必须转发两处（`onLifecycleChanged` 与 `setupRouteInfo`）；页码变化还要第三处，
  因为它不属于 `FlLifecycleState`。
- 这个 mixin 不持有任何订阅，因此没有 `dispose`——自己的资源在 `onPageDispose` 里释放。

### 6. 页面级全局事件

**什么时候用**：一个页面要对另一个页面发生的事情做出反应——登录成功、购物车更新——
又不想把 stream 一层层传下去。

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
    // 传方法引用，不要写闭包字面量，理由见「注意」。
    observeEvent<LoginSuccess>(_onLogin);
  }

  void _onLogin(LoginSuccess event) => setState(() {});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// 在别处：
void publish() => FlGlobalEventBus.dispatchEvent(const LoginSuccess('u1'));
```

**注意**

- `observeEvent` 只在 `initState` 里调**一次**。写进 `build` 会让订阅数随每次重建增长。
  mixin 会挡掉重复的 `(类型, 回调)` 组合并在 debug 下断言，但只有**方法引用**认得出来，
  每次现写的闭包字面量识别不了。
- `FlGlobalEventBus.destroy()` 是进程级操作，绝不要在 `State.dispose` 里调用——
  其他所有存活订阅会跟着静默失效。mixin 已经在 `dispose` 里取消了自己那几条。

## 事件时序

`FlLifecycleState` 共 18 个值，它的 dartdoc 是权威的时序契约。常见序列：

```
push 进入页面    onPageInit → onPageContextReady → onPagePostFrame
                 → onPageStart → onPageResume → onPageEnterAnimationEnd

被页面覆盖       onPagePause → onPageStop   ...返回...   onPageStart → onPageResume
被弹窗覆盖       onPagePause               ...关闭...    onPageResume
自身 pop         onPageLeaveAnimationStart → onPagePause → onPageStop
                 → onPageLeaveAnimationEnd → onPageDispose
```

状态机替你保证的四件事：

- **成对** —— `start` 之后一定有 `stop`；缺的那半边在 `dispose` 时补发。
- **幂等** —— 重复触发被挡掉，不会连着来两个 `start`。
- **有序** —— `onPagePostFrame` 一定早于首帧的 `onPageStart`，所以那里量到的尺寸在
  `start` 里可以直接用。
- **弹窗只 pause 不 stop** —— 此刻页面还在屏幕上。

App 事件分两档：`onAppResume` / `onAppInactive` / `onAppPause` 是原始的 `AppLifecycleState`；
`onAppForeground` / `onAppBackground` 是过滤后的——下拉通知栏、来电这类中断不会触发它们。

## API 速查

| 名称 | 类型 | 作用 | 详见 |
|---|---|---|---|
| `FlPageLifecycleMixin` | mixin | 完整的页面生命周期状态机 | [1](#1-在-state-上拿到页面生命周期) |
| `FlRouteObserver` | class | 把 `Navigator` 变化翻译成页面事件，**必须注册** | [快速开始](#快速开始) |
| `FlRouteObserverProxy` | class | 嵌套 `Navigator` 用的转发 observer | [3](#3-嵌套-navigator) |
| `FlLifecycleState` | enum | 18 个生命周期事件；含 `isPageResume` / `isPagePause` / `isAppEvent` | [事件时序](#事件时序) |
| `FlPageIndexScope` | widget | 向容器子页下发页码 | [2](#2-按页码驱动的容器子页) |
| `FlPageLifecycleView` | widget | 同样的事件走回调，不需要 mixin | [4](#4-不混入-mixin包一层-widget) |
| `FlPageLifecycleCallback` | typedef | `(BuildContext, FlLifecycleState) → void` | [4](#4-不混入-mixin包一层-widget) |
| `FlPageRouteParamCallback` | typedef | `(BuildContext, String?, Object?) → void` | [4](#4-不混入-mixin包一层-widget) |
| `FlPageIndexChangedCallback` | typedef | `(BuildContext, int, int) → void` | [4](#4-不混入-mixin包一层-widget) |
| `FlPageControllerMixin` | mixin | 在普通 Dart 对象里接收转发来的事件 | [5](#5-在-controller--viewmodel-里收事件) |
| `FlPageRouteMixin` | mixin | 只要路由事件与转场动画 | — |
| `FlAppLifecycleMixin` | mixin | 只要 App 前后台 | — |
| `FlAnimationLifecycleMixin` | mixin | 只要路由转场动画 | — |
| `FlLifecycleManager` | class | App 前后台单例：`isForeground`、`stream`、`lifecycle`、`listen()`、`cancel()` | [注意事项](#注意事项) |
| `FlStateEventBusMixin` | mixin | 在 `State` 里 `observeEvent` / `dispatchEvent`，自动取消 | [6](#6-页面级全局事件) |
| `FlGlobalEventBus` | class | 静态访问点：`observeEvent`、`dispatchEvent`、`configure`、`destroy` | [6](#6-页面级全局事件) |
| `FlEventBus` | class | `FlIEventBus` 的默认实现；`FlEventBus(sync: true)` 同步派发 | [6](#6-页面级全局事件) |
| `FlIEventBus` | class | 总线接口 —— 实现它即可在测试里注入 mock | [6](#6-页面级全局事件) |

## 第三方依赖

| 依赖 | 版本约束 | 作用 | 本包用在哪 |
|---|---|---|---|
| `meta` | `^1.17.0` | `@internal` / `@nonVirtual` 等注解，把内部成员挡在公开契约之外 | `lib/src/lifecycle/fl_route_observer.dart`、`lib/src/mixin/fl_page_route_mixin.dart` 等 6 处 |

这是唯一的第三方依赖。没有平台通道，没有代码生成，不会传递引入任何 UI 包。

## 注意事项

**不注册 `FlRouteObserver`，路由相关的一切都不工作。** 漏掉它不会抛异常——四个可见性回调
只是永远不触发，而转场动画回调照常工作（它们直接监听 `ModalRoute.animation`）。
「动画有、可见性没有」就是确诊症状。debug 下每进程会提示一次。

**不要叠加多个入口 mixin。** `FlPageLifecycleMixin`、`FlPageRouteMixin`、
`FlAppLifecycleMixin`、`FlAnimationLifecycleMixin` 订阅同一批源，成员名也会撞。叠加的结果是
一部分事件收到两遍，另一套状态机根本不跑。`FlStateEventBusMixin` 是例外，可与任意一个同用。

**`onPageEnterAnimationEnd` 可能触发两次。** iOS 侧滑返回中途放弃时，动画走
`reverse → forward → completed`。放在那里的网络请求或埋点必须自己做幂等。同理，
`onPageLeaveAnimationStart` **不代表**页面一定会退出——不可逆操作请放到
`onPageLeaveAnimationEnd` 或 `onPageDispose`。

**到 `onPageDispose` 时路由信息已经是 null。** mixin 先补发 `onPagePause` / `onPageStop`
再注销，所以 `routeName` / `arguments` 在那两个回调里仍可读，到 `onPageDispose` 就没了。
请提前读，或在 `onPageContextReady` 时缓存下来。

**你的回调里抛出的异常不会向外传播。** 它们会以库名 `fl_page_lifecycle` 上报给
`FlutterError.onError`，这样一个页面的失败不会中断另一个页面的事件，也不会泄漏订阅。
可能失败的操作（埋点上报、网络请求）请自己包一层 `try`/`catch`。

**两个进程级的开关要当心。** `FlGlobalEventBus.destroy()` 与 `FlLifecycleManager.cancel()`
影响所有存活页面。它们是给测试 tearDown 和 App 退出用的；页面级清理是自动的，两个都不需要。

**不要用 `onAppForeground` 判断当前在不在前台。** 那是事件，而且冷启动的补发只有进程内
第一个订阅者收得到。判断状态请读 `isForeground`——它是同步读取，任何时机都有效。

**什么时候不该用这个包。** 它回答的是导航层面的问题。它不检测 widget 滚出 `ListView` 视口，
也不检测同一路由内被不透明兄弟节点盖住——前者请用 `visibility_detector`，
后者两个包都不处理。

## 示例

`example/` 是一个可运行的 App，覆盖了每一个入口，每页都带实时事件日志面板：

```bash
cd example
flutter run
```

## 配合 AI 编码助手使用

这个包很新，AI 助手没有关于它的训练数据，会编造出不存在的 API 名。
[`docs/ai/`](docs/ai/) 是一份现成的接入约定，可以直接复制到你自己的项目里防止这件事——
一个 `AGENTS.md` 讲清入口选择、`resume/pause` 与 `start/stop` 的取舍、事件顺序和提交前检查清单，
外加三份参考文件（精确签名、成套食谱、避坑指南）。
[`docs/ai/README.md`](docs/ai/README.md) 说明该放到哪里，包含 Cursor、Copilot、Windsurf、
Cline、Claude Code 各自的对应位置。

## Changelog · License

见 [CHANGELOG.md](CHANGELOG.md)。以 [MIT](LICENSE) 协议发布。
