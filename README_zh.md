# fl_page_lifecycle

给 Flutter 页面装上 Android 式的生命周期：任意 `State` 上的 `start` / `resume` / `pause` / `stop`，
外加首帧、路由转场动画、App 前后台与 `PageView` 切页。

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) | 中文

---

- [为什么需要它](#为什么需要它)
- [核心能力](#核心能力)
- [该用哪个入口](#该用哪个入口)
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

Flutter 只给了 `initState` 和 `dispose`，它不会告诉你页面什么时候**可见**、什么时候**可交互**——
而这两个时机才是视频播放、轮询定时器、埋点曝光和动画真正关心的。

想自己回答「我这个页面现在可见吗」，得把 `RouteAware`、`WidgetsBindingObserver`、
`ModalRoute.of(context).isCurrent`、`PageController` 的监听和首帧回调拼在一起，然后还要处理这些边界：

- 弹窗盖住页面时，页面其实还看得见，你要的是 `pause` 而不是 `stop`。`isCurrent` 这时返回 `false`，
  区分不出这两种情况。
- `pushAndRemoveUntil` 会为一个**仍然被别的路由盖着**的页面触发 `didPop`。照着 `RouteAware`
  直写的实现，会给一个谁也看不见的页面发出 `start`。
- iOS 侧滑返回拖到一半放弃，退场动画播了却永远不会结束。
- 页面在 pause 状态下被销毁，你等的那个 `resume` 再也不会来。

这个包把这些记账工作做了一遍，给你成对且幂等的回调：**start 之后必有 stop，pause 之后必有
resume 或 stop**，缺的那半边会在 `dispose` 时补发。混入一个 mixin，覆写你关心的回调即可，
没有任何需要手动初始化或释放的东西。

## 核心能力

- 完整的可见性状态机 —— `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop`，
  成对且幂等；弹窗只 pause 不 stop
- 路由转场动画回调，包含 iOS 侧滑返回中途放弃的折返
- App 前后台判定，过滤掉来电、下拉通知栏这类短暂中断
- `PageView` / `TabBarView` 子页由页码驱动，而不是路由变化
- 不动你的继承结构 —— [mixin](#1-在-state-上接页面生命周期)、
  [包一层 Widget](#3-不混入-state包一层-widget) 或[普通 Dart 对象](#4-在-controller--viewmodel-里接事件)三选一
- 页面内收发全局事件，订阅随 `dispose` 自动取消
- 只有一个第三方依赖（`meta`），无平台通道，无代码生成

## 该用哪个入口

| 你想要 | 用 |
|---|---|
| 在 `State` 上拿到全部能力 | [`FlPageLifecycleMixin`](#1-在-state-上接页面生命周期) |
| 同上，但页面在 `PageView` / `TabBarView` 里 | [`FlPageViewScope`](#2-pageview--tabbarview-里的子页) + `observePageView` |
| 不混入 `State` 也要拿到事件 | [`FlPageLifecycleView`](#3-不混入-state包一层-widget) |
| 在 Controller / ViewModel 里收事件 | [`FlPageControllerMixin`](#4-在-controller--viewmodel-里接事件) |
| 只要 App 前后台 | `FlAppLifecycleMixin` |
| 只要转场动画 | `FlAnimationLifecycleMixin` |
| 只要路由事件，不需要弹窗与 PageView 处理 | `FlPageRouteMixin` |

后三个是独立版。**不要叠加在 `FlPageLifecycleMixin` 之上**——它已经订阅了同样的事件源，
叠加会导致每个事件收到两次。

## 与 `visibility_detector` 的区别

[`visibility_detector`](https://pub.dev/packages/visibility_detector)（`google/flutter.widgets`）
回答的是一个**几何**问题：这个 Widget 的包围盒有多少落在视口内？本库回答的是一个**导航**问题：
用户现在正待在这个页面上吗？两者互不覆盖。下表依据 `visibility_detector` 0.4.0+2 得出。

| | `visibility_detector` | `fl_page_lifecycle` |
|---|---|---|
| 观察单位 | 任意 Widget，用唯一 `Key` 标识 | 一个路由页或 `PageView` 子页 |
| 给出什么 | `visibleFraction`、`visibleBounds`、`size`——连续值 | 离散事件：`start` / `resume` / `pause` / `stop` |
| 在 `ListView` 里滚出屏幕 | 能检测——这正是它的主场 | **检测不到** |
| 被同一路由内的不透明 Widget 遮住 | 不计入——[官方明示的限制](https://pub.dev/packages/visibility_detector#known-limitations) | **检测不到** |
| 被 dialog / bottomSheet 盖住 | 不计入——同上 | 发 `pause`，关闭后发 `resume` |
| 路由 push / pop | 不涉及 | 这正是它的主场 |
| App 前后台 | 不涉及 | 覆盖，且过滤掉短暂中断 |
| 路由转场动画 | 不涉及 | 四个回调，含 iOS 侧滑返回中途放弃 |
| 回调时机 | 合并触发：每个 `VisibilityDetectorController.updateInterval` 最多一次，默认 500 ms | 与路由事件或帧事件同步；`PageView` 子页合批到帧末 |
| 接入成本 | 无，包一层 Widget 即可 | 需要把 `FlRouteObserver` 注册到 `Navigator` |

**什么场景用哪个**

| 场景 | 选 |
|---|---|
| 页面被盖住或离开时暂停视频 / 轮询 / 动画 | `fl_page_lifecycle` |
| 统计页面停留时长，或上报页面曝光埋点 | `fl_page_lifecycle` |
| `TabBarView` 的某个 tab 滑进滑出时启停任务 | `fl_page_lifecycle`（`observePageView`） |
| 用户从别的 App 切回来时刷新过期数据 | `fl_page_lifecycle`（`observeAppLifecycle`） |
| 图片滚进视口后再懒加载 | `visibility_detector` |
| 信息流卡片露出 50% 才算一次「曝光」 | `visibility_detector` |
| 信息流里当前居中的那张视频卡自动播放 | **两个都要** |

最后一行是最值得说清的常见情况：用本库判断整个信息流页面确实处于 resume 状态——
否则用户早已跳走，你还在自动播放——再用 `visibility_detector` 判断当前是哪张卡片露出来。
两者观察的对象不同，不冲突。

## 环境要求

| 项 | 要求 |
|---|---|
| Dart SDK | `^3.11.5` |
| Flutter | `>=3.41.9` —— 首个随附 Dart 3.11.5 的 stable 版本 |
| 平台 | Flutter 支持的全部平台 —— 非插件包，无平台通道，未使用 `dart:io` |

## 安装

```yaml
dependencies:
  fl_page_lifecycle: ^0.0.1
```

尚未发布到 pub.dev，在那之前用 git 依赖：

```yaml
dependencies:
  fl_page_lifecycle:
    git:
      url: https://github.com/LqDeveloper/fl_page_lifecycle.git
```

```bash
flutter pub get
```

## 快速开始

`FlRouteObserver` **必须**注册到 `Navigator` 上，否则路由驱动的四个事件全部收不到，
而且不会有任何报错。这是接入时最高频的一个坑。

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [FlRouteObserver.instance], // ← 必须
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
  void onPageResume() => debugPrint('可交互了 —— 开始播放视频');

  @override
  void onPagePause() => debugPrint('被盖住或即将离开 —— 暂停视频');

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('Detail')));
}
```

在它上面 push 一个新页面，会看到 `pause` 然后 `stop`；弹一个 dialog，则只会看到 `pause`。

## 用法

### 1. 在 `State` 上接页面生命周期

**什么时候用**：路由页的默认选择——你需要知道页面何时可见、何时可交互，
好把不该在后台跑的活儿停掉。

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

  // 默认关闭；关着能让每个实例省下两条全局流订阅。
  @override
  bool get observeAppLifecycle => true;

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    debugPrint('路由 $routeName，参数 $arguments');
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

**两个开关**（覆写成 getter，必须返回常量，debug 下有断言把关）

| Getter | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `observePageView` | `bool` | `false` | 由 `FlPageViewScope` 下发的页码驱动可见性，而非路由变化 |
| `observeAppLifecycle` | `bool` | `false` | 是否派发五个 App 维度事件；打开后每个实例多两条全局流订阅 |

**状态 getter**（随时可读，不依赖任何订阅）

| Getter | 类型 | 说明 |
|---|---|---|
| `isPageAppeared` | `bool` | 是否可见：已发 `onPageStart` 且未发 `onPageStop` |
| `isPageResumed` | `bool` | 是否可交互：已发 `onPageResume` 且未发 `onPagePause` |
| `isForeground` | `bool` | App 是否在前台 |
| `isCurrent` | `bool` | 本页是否为所在 `Navigator` 的栈顶路由（实时查询，不缓存） |
| `routeName` / `arguments` | `String?` / `Object?` | 来自 `RouteSettings`，从 `onPageContextReady` 起可用 |
| `isInPageView` / `pageIndex` / `currentPageIndex` / `pageViewDepth` | `bool` / `int` | `PageView` 中的位置，见下一节 |

**注意**

- 判断「页面是否可见」用 `isPageAppeared`，**不要**用 `isCurrent`——弹窗盖在上面时
  `isCurrent` 为 false，但页面完全可见。
- `onPagePostFrame` 一定早于首帧的 `onPageStart`，所以可以在那里量好 `RenderObject` 尺寸，
  到 `onPageStart` 里直接用。
- 覆写 `onLifecycleStateChanged` 必须调用 `super`（已标注 `@mustCallSuper`）。
  覆写 `appLifecycleChanged` 同样必须调 `super`——它的方法体正是分发 `onAppResume` /
  `onAppInactive` / `onAppPause` 的地方，漏了这三个会静默失效。

### 2. `PageView` / `TabBarView` 里的子页

**什么时候用**：`PageView` 的子页会被一起构建并保活，路由事件说明不了当前哪一页在屏幕上。
用 `FlPageViewScope` 包一层，可见性就改由页码驱动。

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
        // 包一层 Scope，页码自动下发，子页无需再声明 pageIndex。
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
  bool get observePageView => true; // ← 不打开的话，子页会在首帧直接 start

  @override
  void onPageStart() => debugPrint('feed 页滑进来了');

  @override
  void onPageStop() => debugPrint('feed 页滑走了');

  @override
  void onPageViewChanged(int from, int to) => debugPrint('页码 $from -> $to');

  @override
  Widget build(BuildContext context) => const Center(child: Text('Feed'));
}
```

**`FlPageViewScope` 的静态方法**

| 方法 | 签名 | 用途 |
|---|---|---|
| `wrapChildren` | `({required Listenable controller, required List<Widget> children}) → List<Widget>` | 包装固定子列表，下标即页码 |
| `wrapItemBuilder` | `({required Listenable controller, required NullableIndexedWidgetBuilder builder}) → NullableIndexedWidgetBuilder` | 同上，用于 `PageView.builder` |
| `indexOf` | `(Listenable controller) → int?` | 当前下标，尚不可用时返回 `null` |

`initialIndexOf`、`listenableOf`、`depthOf` 覆盖更底层的场景。不用这些辅助方法时，
构造函数直接接收 `pageIndex`、`controller` 和 `child`；它带有断言，因此**不是** `const`
构造函数，写 `const FlPageViewScope(...)` 编译不过。`controller` 只支持 `PageController`
或 `TabController`，传别的会触发断言。Scope 可以嵌套，只有当每一层祖先 Scope
都停在其宿主所在页时，子页才算可见。

### 3. 不混入 `State`，包一层 Widget

**什么时候用**：页面是 `StatelessWidget`、`State` 上的 mixin 链不想再加、
或者只想给某一小块子树加埋点（比如给卡片做曝光统计）。

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FlPageLifecycleView(
      onStateChanged: (context, state) {
        if (state == FlLifecycleState.onPageResume) debugPrint('可见且可交互');
      },
      onRouteParam: (context, routeName, arguments) =>
          debugPrint('打开了 $routeName，参数 $arguments'),
      child: const Scaffold(body: Center(child: Text('Product'))),
    );
  }
}
```

**参数**

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `child` | `Widget` | required | 被观察的子树，由 `build` 原样返回，不引入额外布局节点 |
| `onStateChanged` | `FlPageLifecycleCallback?` | `null` | 每一个 `FlLifecycleState` 事件 |
| `onRouteParam` | `FlPageRouteParamCallback?` | `null` | 路由名与参数就绪时回调 |
| `onPageViewChanged` | `FlPageViewChangedCallback?` | `null` | 页码变化，参数为 `(旧, 新)` |
| `observePageView` | `bool` | `false` | 与 mixin 的同名开关一致 |
| `observeAppLifecycle` | `bool` | `false` | 与 mixin 的同名开关一致 |

每个实例内部都是一套完整的 `FlPageLifecycleMixin`：1 次路由订阅、1 个首帧回调，
打开 `observeAppLifecycle` 后再加两条全局流订阅。一个页面放几个完全无所谓，
但用在几百项的列表上要掂量一下。

### 4. 在 Controller / ViewModel 里接事件

**什么时候用**：响应生命周期的代码不在 Widget 树里——Controller、Presenter、ViewModel 或 Service。

`FlPageControllerMixin` **不订阅任何事件源**，它只提供一个入口加一组模板回调，
事件必须由页面侧转发进来。混入后如果一个回调都不触发，先查转发链路。

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

class DetailController with FlPageControllerMixin {
  @override
  void onPageResume() => debugPrint('开始轮询，route=$routeName');

  @override
  void onPagePause() => debugPrint('停止轮询');
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
    super.onLifecycleStateChanged(state); // 必须调用
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

用 `FlPageLifecycleView.onStateChanged` 转发，效果等价。

**注意**：回调的触发时机与幂等性**完全由转发源决定**。绕过 `FlPageLifecycleMixin`
自行调用 `onLifecycleChanged`，「start 后必跟 resume」这类保证就不再成立。
本 mixin 不持有任何订阅，因此没有 `dispose`；自身资源请在 `onPageDispose` 中释放。

### 5. 页面内收发全局事件

**什么时候用**：两个页面之间没有共同父节点却要通信——设置页改主题、下单后购物车角标要刷新。

```dart
import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// 事件用普通类表示，靠类型区分，不需要注册或枚举。
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
    // 不需要保存 StreamSubscription，dispose 时会自动 cancel。
    observeEvent<CartChanged>((event) => setState(() => _count = event.count));
  }

  void _add() => dispatchEvent(CartChanged(_count + 1));

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: _add, child: Text('购物车 $_count'));
}
```

`observeEvent` 要在 `initState` 里调一次。写进 `build` 或 `onPageResume` 会让订阅数
随重建次数线性增长，所以同一个 `(T, onData)` 组合重复注册时，本次订阅会被**忽略**
并触发一条 debug assert。只有方法引用能被去重——在调用处现场写的闭包字面量每次都是
新对象，识别不出是重复。

事件是全局广播的：已经 stop 的页面照样会收到。不想要这个行为，就在回调里用
`isPageAppeared` 做个判断。

`State` 之外用 `FlGlobalEventBus` 的静态方法——`observeEvent<T>()` 返回一条需要自己取消的
`Stream<T>`，`dispatchEvent<T>(T event)` 负责发布。想换掉底层实现，用
`FlGlobalEventBus.configure(FlEventBus())` 或传入你自己的 `FlIEventBus`。

## 事件时序

完整契约写在 `FlLifecycleState` 的 dartdoc 里——逐个事件说明了何时触发、何时不触发。
常见时序如下：

```
push 进入            onPageInit → onPageContextReady
                     → onPageEnterAnimationStart（不保证，见下）
                     → onPagePostFrame
                     → onPageStart → onPageResume → onPageEnterAnimationEnd

被普通路由盖住        onPagePause → onPageStop  ...  onPageStart → onPageResume
被弹窗盖住            onPagePause               ...  onPageResume

自身 pop 退出         onPageLeaveAnimationStart → onPagePause → onPageStop
                     → onPageLeaveAnimationEnd → onPageDispose

iOS 侧滑返回          onPageLeaveAnimationStart → onPageEnterAnimationStart
拖到一半放弃          → onPageEnterAnimationEnd        （没有 pause，也没有 stop）
```

应用的首个页面（`home`）没有转场动画，两个 EnterAnimation 事件都不会发出。
`onPageDispose` 一定是最后一个事件。

`onPageReassemble` 不在上面这些序列里：它只在热重载时触发（由 `kDebugMode` 把关），
当成调试期的钩子看待即可，不属于契约的一部分。

`PageView` 子页的 start / stop 到达时机是**帧末**，不是同步的。同一帧内所有隐藏
事件先于所有显示事件，与子页注册监听的先后无关；同一批里翻走又翻回来则什么都不发。
因此不会出现两个子页同时认为自己可见的中间态。

## API 速查

| 名称 | 类型 | 作用 | 详见 |
|---|---|---|---|
| `FlPageLifecycleMixin` | mixin on `State` | 完整页面生命周期，本库主入口 | [用法](#1-在-state-上接页面生命周期) |
| `FlPageViewScope` | widget | 向 `PageView` 子树下发页码与控制器 | [用法](#2-pageview--tabbarview-里的子页) |
| `FlPageLifecycleView` | widget | 与 mixin 同样的事件，改由回调抛出 | [用法](#3-不混入-state包一层-widget) |
| `FlPageControllerMixin` | mixin | 在非 Widget 类中接收转发来的事件 | [用法](#4-在-controller--viewmodel-里接事件) |
| `FlStateEventBusMixin` | mixin on `State` | `observeEvent` / `dispatchEvent`，订阅随 `dispose` 自动取消 | [用法](#5-页面内收发全局事件) |
| `FlRouteObserver` | `NavigatorObserver` | 把路由变化翻译成 start/resume/pause/stop，注册 `FlRouteObserver.instance` | [快速开始](#快速开始) |
| `FlLifecycleState` | enum | 18 个生命周期事件，以及 `isPageResume` / `isPagePause` / `isAppEvent` | [时序](#事件时序) |
| `FlAppLifecycleMixin` | mixin on `State` | 只要 App 前后台：`onAppForeground`、`onAppBackground`、`appLifecycleChanged`、`isForeground`、`hasInit` | — |
| `FlAnimationLifecycleMixin` | mixin on `State` | 只要转场动画：四个 `onPageEnter/LeaveAnimation*` 回调 | — |
| `FlPageRouteMixin` | mixin on `State` | 只收敛路由层面：start / stop 一次性、`dispose` 补发 pause / stop，但不区分弹窗、不管 PageView，且 `onRoutePause` 无守卫：`onRouteStart` / `onRouteResume` / `onRoutePause` / `onRouteStop`，另有 `modalRoute`、`hasRoute` | — |
| `FlLifecycleManager` | 单例 | App 前后台事件源：`instance`、`isForeground`、`stream`、`lifecycle`、`listen()`、`cancel()` | — |
| `FlGlobalEventBus` | 静态 API | 全局总线入口：`observeEvent<T>()`、`dispatchEvent<T>()`、`configure()`、`destroy()` | [用法](#5-页面内收发全局事件) |
| `FlIEventBus` | 抽象类 | 总线接口：`on<T>()`、`fire()`、`destroy()`——实现它可替换默认总线 | — |
| `FlEventBus` | class | 默认实现：单条广播流。`FlEventBus({sync})`、`FlEventBus.customController()` | — |
| `FlPageLifecycleCallback` | typedef | `void Function(BuildContext, FlLifecycleState)` | [用法](#3-不混入-state包一层-widget) |
| `FlPageRouteParamCallback` | typedef | `void Function(BuildContext, String?, Object?)` | [用法](#3-不混入-state包一层-widget) |
| `FlPageViewChangedCallback` | typedef | `void Function(BuildContext, int from, int to)` | [用法](#3-不混入-state包一层-widget) |

生命周期回调标了 `@protected`——在自己的类里覆写它们，不要直接调用。例外都在
`FlPageControllerMixin` 上：`onLifecycleChanged`、`setupRouteInfo` 和 `onPageViewChanged`
是公开的，因为需要由页面来调。另外注意它的 `onPageContextReady` 参数是 `BuildContext?`，
而不是 `State` 系 mixin 传的 `(String? routeName, Object? arguments)`；`onPageViewChanged`
也不会被 `onLifecycleChanged` 分发，需要页面显式转发。

## 第三方依赖

| 依赖 | 版本约束 | 作用 | 本包用在哪 |
|---|---|---|---|
| `meta` | `^1.17.0` | 提供 `@internal` / `@protected` / `@mustCallSuper` / `@nonVirtual` 注解，用来标注公开面 | `lib/src/lifecycle/fl_route_observer.dart:3`、`lib/src/mixin/fl_page_route_mixin.dart:3`、`lib/src/delegate/*.dart` |

这是唯一的第三方依赖——不绑定任何状态管理库，无代码生成，无平台通道。

## 注意事项

**不注册 `FlRouteObserver`，路由相关的一切都不工作。** 漏掉它不会抛异常，
`start` / `resume` / `pause` / `stop` 只是永远不来（debug 下会 `debugPrint` 提示一次）。
嵌套 `Navigator` 需要各自注册一次，同一个 `instance` 可以复用。

**`isCurrent` 不等于可见性。** 上层是 `PopupRoute`（dialog / bottomSheet / PopupMenu）时，
页面依然完全可见，因此只发 `pause`。判断可见性请用 `isPageAppeared`。

**`onPageContextReady` 可能永远不触发。** 它要求 `ModalRoute.of(context)` 非空。
一个不处于任何路由中的 Widget，静默失效的只有**由路由变化驱动的**那半边：被覆盖 /
被揭开时的 `start` / `resume` / `pause` / `stop`，以及两个转场动画事件。首帧的
`onPageStart` / `onPageResume` 和 `dispose` 时补发的 `onPagePause` / `onPageStop`
照常发出（首帧的可见性门禁只在已拿到 `ModalRoute` 时才生效），`onPageInit`、
`onPagePostFrame`、`onPageDispose` 也正常。所以把 mixin 混入一个不在路由中的
Widget 仍然有意义：能拿到这个 Widget 存活期间成对的启停。

**`onPageEnterAnimationStart` 首次进入通常不触发。** 动画监听器在 `onPageContextReady`
时才绑定，此刻入场动画早已开始。需要「页面开始进场」请用 `onPageContextReady`。
实际能收到的主要是动画折返——iOS 侧滑返回中途放弃。

**`onPageLeaveAnimationStart` 不代表页面一定会退出。** iOS 侧滑返回中途放弃时，
随后是 `onPageEnterAnimationStart` → `onPageEnterAnimationEnd`，而**不是**
`onPageLeaveAnimationEnd`。不可逆操作请放在 `onPageLeaveAnimationEnd` 或 `onPageDispose`。

**两个开关在同一实例上必须恒定。** `observePageView` 与 `observeAppLifecycle` 只在
`initState` 中读一次，中途翻转会让可见性状态机留下对不齐的中间态，debug 下有断言把关。

**不要叠加独立版 mixin。** `FlPageRouteMixin`、`FlAnimationLifecycleMixin` 和
`FlAppLifecycleMixin` 订阅的事件源与 `FlPageLifecycleMixin` 相同，三选一即可。

**事件总线不看可见性。** 已经 stop 的页面照样收到每一个事件。
后台页面不该响应时，用 `isPageAppeared` 加个判断。

**`FlLifecycleManager.cancel()` 同样是全局操作。** 它会移除 `WidgetsBinding` 观察者，
所有存活的页面都收不到 App 事件了。自己订阅 `FlLifecycleManager.instance.stream` 时，
取消自己那个 `StreamSubscription` 就够——不要去调 manager 的 `cancel()`。

**`FlGlobalEventBus.destroy()` 是全局操作。** 只能在测试的 `tearDown` 或 App 即将退出时调用，
**不要**在 `State.dispose()` 或路由 pop 回调里调用——它会关闭整条 broadcast stream，
所有其他存活页面的订阅都会收到 done 并静默失效。页面级的订阅释放，
`FlStateEventBusMixin` 已经替你做了。

## 示例

`example/` 是一个可运行的 App，覆盖全部 7 个入口，每个 demo 都带一块实时事件日志面板：

```bash
cd example
flutter run
```

## 配合 AI 编码助手使用

本库没有发到 pub.dev，AI 模型对它没有任何训练先验，会编造出不存在的 API 名字。
[`docs/ai/`](docs/ai/) 是一份现成的约定文件，复制到你自己的项目里就能避免这个问题：
主文件 `AGENTS.md` 覆盖入口选型、`resume/pause` 与 `start/stop` 的判断、事件时序和
提交前自检清单，另有三个参考文件分别是精确签名速查、场景配方代码和避坑详解。
放在哪里、以及 Cursor / Copilot / Windsurf / Cline / Claude Code 各自的对应位置，
见 [`docs/ai/README.md`](docs/ai/README.md)。

## 更新日志 · 许可证

见 [CHANGELOG.md](CHANGELOG.md)。本项目使用 [MIT](LICENSE) 许可证。
