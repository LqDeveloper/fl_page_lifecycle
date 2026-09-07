# fl_page_lifecycle 接入约定

给在本项目里写代码的 AI 编码助手看的说明。适用于任何涉及 **Flutter 页面可见性 / 页面生命周期**的改动：页面被覆盖或离开时暂停视频与轮询、页面曝光与停留时长埋点、`TabBarView` / `PageView` 子页切换时启停任务、App 前后台回来刷新数据、页面间事件总线。

本项目用 [`fl_page_lifecycle`](https://github.com/LqDeveloper/fl_page_lifecycle) 处理这类需求，**不要手写 `RouteAware` + `ModalRoute.isCurrent` 的方案**——原因见下一节。

## 什么时候去读参考文件

这份文件够应付大部分改动。遇到下面三种情况再去读对应的参考文件，**不要凭印象拼 API 名字**：

| 情况 | 读 |
|---|---|
| 需要某个类 / 回调 / getter 的**精确签名**，或不确定某个名字是否存在 | `references/api.md` |
| 要写具体场景的代码（视频、埋点、轮询、TabBar 懒加载、事件总线、Controller 转发） | `references/recipes.md` |
| 行为和预期不符，要查原因；或想确认某个语义的边界 | `references/pitfalls.md` |

这个库**不在公开 pub.dev 上**，所以你对它没有任何训练先验。`PageLifecycleMixin`、`onPageShow`、`onPageHide`、`pauseOnOverlay:` 这类名字都是不存在的——真实的名字全部以 `Fl` 开头，回调是 `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop`。拿不准就查 `references/api.md`。

## 为什么用这个库而不是手写

手写 `RouteAware` + `isCurrent` 在这几个场景上必然出错：

- **dialog 盖住页面时，页面仍然可见**，只该 `pause` 不该 `stop`。而 `ModalRoute.isCurrent` 此时返回 `false`，分不出这两种情况。所以**永远别用 `isCurrent` 判断可见性**。
- `pushAndRemoveUntil` 会给一个「仍被别的路由盖着」的路由发 `didPop`，朴素的 `RouteAware` 会给没人看得见的页面发 `start`。
- iOS 侧滑返回中途松手，离场动画播了但没走完，页面并没有离开。
- 页面在 `pause` 状态下被 `dispose`，你等的那个 `resume` 永远不会来——资源就泄漏在那儿。

库把这些账算过一遍，给出**配对且幂等**的回调：每个 `start` 必有 `stop`，每个 `pause` 必有 `resume` 或 `stop`，缺的那一半在 `dispose` 时补发。所以**成对写代码就是安全的**：`onPageResume` 里起的东西在 `onPagePause` 里停掉，不用再操心页面是怎么走的。

## 前置：必须注册 `FlRouteObserver`

```dart
MaterialApp(
  navigatorObservers: [FlRouteObserver.instance], // ← 少了这行，四个可见性事件全不触发
  home: const HomePage(),
)
```

不注册**不会抛异常**，只是 `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop` 静默失效（debug 下 `debugPrint` 提示一次，且每进程只打一遍）。改完涉及生命周期的代码，先确认这行在。

- **嵌套 `Navigator` 要各自注册一次**，复用同一个 `FlRouteObserver.instance`。用 `Navigator` 做 tab 内独立栈、或用 go_router / auto_route 的 shell route 时特别容易漏掉里层。
- go_router / auto_route 的写法各不相同，**先读本项目的路由配置文件再决定加在哪里**，不要默认只加在 `MaterialApp` 上。具体写法见 `references/recipes.md` 第 9 节。
- 转场动画那四个回调**不依赖注册**（直接监听 `ModalRoute.animation`）。所以「动画回调有、可见性回调没有」这个症状 = 没注册。

## 选哪个入口

先看页面长什么样，再选入口。不要默认全都用 `FlPageLifecycleMixin`。

| 页面形态 | 用 |
|---|---|
| 普通路由页（`StatefulWidget`） | `FlPageLifecycleMixin` |
| `PageView` / `TabBarView` 的子页 | `FlPageViewScope` 包裹 + 子页 `observePageView => true` |
| `StatelessWidget`，或不想再加 mixin，或只观测某个子树 | `FlPageLifecycleView` |
| 逻辑在 Controller / ViewModel 里 | `FlPageControllerMixin` + 页面转发 |
| 只要 App 前后台 | `FlAppLifecycleMixin` |
| 只要转场动画 | `FlAnimationLifecycleMixin` |
| 只要路由事件（回调名是 `onRouteStart/Resume/Pause/Stop`） | `FlPageRouteMixin` |

**这些入口不能叠加。** 后四个和 `FlPageLifecycleMixin` 订阅同一批源，成员名也会撞（`isCurrent`、`routeName`、`appLifecycleChanged`、`routePageStart` 等）。叠加的后果不只是收到两遍事件——最后混入的那个 mixin 的实现被调两次，另一个状态机根本不跑。**选一个。**

唯一正确的叠加形式是叠项目自己写的 mixin：

```dart
mixin MyTrackMixin<T extends StatefulWidget> on State<T>, FlPageLifecycleMixin<T> { }

class _S extends State<P> with FlPageLifecycleMixin, MyTrackMixin { }
```

（`FlStateEventBusMixin` 是例外，它和生命周期无关，可以放心一起混入。）

## resume/pause 还是 start/stop

这是接入时唯一真正需要动脑的地方，也是最容易埋 bug 的地方。两对回调的区别只有一处：**dialog / bottomSheet / popupMenu 盖上来时，只发 `pause`，不发 `stop`。**

判断标准就一句话：**弹窗盖住页面时，这件事该不该继续？**

| 弹窗期间…… | 用 | 典型场景 |
|---|---|---|
| **该停** | `onPageResume` / `onPagePause` | 视频/音频播放、动画、相机预览、地图定位、耗电的传感器 |
| **该继续** | `onPageStart` / `onPageStop` | 列表轮询、WebSocket、页面曝光埋点与停留时长、倒计时 |

理由：弹窗弹出来时用户**还在这个页面上**。视频该停（不然弹窗上盖着声音在响），但订单列表的轮询不该停（用户开了个筛选面板，回来当然希望数据是新的），停留时长也不该在这时候结算（他没离开）。

**别不假思索地一律用 `resume/pause`**——轮询用 `resume/pause` 的直接后果就是「一弹筛选面板刷新就断了」这类线上问题。需求描述里往往已经写明了期望（「弹 bottomSheet 出来轮询就停了，其实用户还在这个页面上」= 要 `start/stop`），**照描述选**。

拿不准就问：这件事的成本是「用户听得见/看得见」的，还是「后台默默花点流量」的？前者用 `resume/pause`，后者用 `start/stop`。两对都用也可以（埋点走 `start/stop`、播放器走 `resume/pause`），它们是独立的两层。

## 最常用的写法

```dart
class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
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
  Widget build(BuildContext context) => const Scaffold(body: Text('Detail'));
}
```

两个开关（重写成 getter，**必须整个生命周期恒定**，debug 有 assert 拦）：

| Getter | 默认 | 什么时候开 |
|---|---|---|
| `observePageView` | `false` | 这个页面是 `PageView` / `TabBarView` 的子页 |
| `observeAppLifecycle` | `false` | 需要 `onAppForeground` / `onAppBackground` 等五个 App 级事件。每个实例多两条全局流订阅，按需开 |

判断状态用这几个 getter，随时可读、不需要订阅：

| 想知道 | 读 | 别读 |
|---|---|---|
| 页面可见吗 | `isPageAppeared` | ~~`isCurrent`~~（dialog 一盖就 false） |
| 页面可交互吗 | `isPageResumed` | — |
| App 在前台吗 | `isForeground` | — |
| 是不是栈顶（真的想知道栈顶时才用） | `isCurrent` | — |

## 事件时序

```
push 进来        onPageInit → onPageContextReady → onPagePostFrame
                 → onPageStart → onPageResume → onPageEnterAnimationEnd

被路由覆盖        onPagePause → onPageStop   ...   onPageStart → onPageResume
被 dialog 覆盖    onPagePause                ...   onPageResume        （不 stop）

自己被 pop       onPageLeaveAnimationStart → onPagePause → onPageStop
                 → onPageLeaveAnimationEnd → onPageDispose

iOS 侧滑中途放弃  onPageLeaveAnimationStart → onPageEnterAnimationStart
                 → onPageEnterAnimationEnd            （不 pause，不 stop）
```

- `onPagePostFrame` 一定在第一个 `onPageStart` 之前，可以在它里面量 `RenderObject` 尺寸，`onPageStart` 里直接用。
- 首页（`home`）没有转场，两个入场动画事件都不发。
- `onPageEnterAnimationStart` **首次进入通常不发**（监听器在 `onPageContextReady` 时才绑上）。想表达「页面正在出现」用 `onPageContextReady`。
- `onPageLeaveAnimationStart` **不代表页面会离开**（iOS 侧滑放弃就会反转）。不可逆的收尾放 `onPageLeaveAnimationEnd` 或 `onPageDispose`。
- `onPageDispose` 永远是最后一个。此时 `routeName` 已是 `null`，要用路由信息就在 `onPageStop` 里读。
- 重写 `onLifecycleStateChanged` 必须调 `super`；重写 `appLifecycleChanged` **也必须调 `super`**（它是三个原始 App 事件的分发器，漏了会静默失效）。
- `PageView` 子页的 `start` / `stop` 到达时机是**帧末**，不是同步。同一帧内所有隐藏先于所有显示。

## PageView / TabBarView 子页：两步都要做

`PageView` 的子页全都被 build 且保活，路由事件说明不了哪个在屏上，所以要换成按页码驱动：

```dart
PageView(
  controller: _controller,
  children: FlPageViewScope.wrapChildren(   // 第 1 步：注入页码
    controller: _controller,
    children: const [FeedTab(), ProfileTab()],
  ),
)
```

```dart
class _FeedTabState extends State<FeedTab> with FlPageLifecycleMixin {
  @override
  bool get observePageView => true;   // 第 2 步：否则这个 tab 在首帧就 start 了
}
```

- 只包不开开关 → 子页首帧全部 `start`，等于没做懒加载。
- 只开开关不包 → 拿不到页码，可见性永远不变。
- `controller` 只接受 `PageController` 或 `TabController`；构造函数**不是 `const`**（带 assert），写 `const FlPageViewScope(...)` 编译不过。
- `PageView.builder` 用 `FlPageViewScope.wrapItemBuilder`。
- 一个 `PageController` 不要给多个 `PageView` 共用（页码解析不出来）。
- 作用域可嵌套：子页可见要求**每一层祖先也都在自己宿主的当前页**。外层划走，内层当前 tab 也会 stop。

## 提交前照着过一遍

- [ ] `FlRouteObserver.instance` 注册了，**每个嵌套 `Navigator` 也注册了**
- [ ] 判可见性用 `isPageAppeared`，没有用 `isCurrent`
- [ ] `onPageResume` 里起的资源，在 `onPagePause` 里成对停掉了（或 `start`/`stop` 成对）
- [ ] `resume/pause` 与 `start/stop` 是按「弹窗期间该不该继续」选的，不是随手选的
- [ ] 没有叠加 `FlPageRouteMixin` / `FlAnimationLifecycleMixin` / `FlAppLifecycleMixin` 到 `FlPageLifecycleMixin` 上
- [ ] `observePageView` / `observeAppLifecycle` 返回字面常量，没有跟着 state 变
- [ ] 重写 `onLifecycleStateChanged` 或 `appLifecycleChanged` 的地方都调了 `super`
- [ ] `observeEvent<T>` 只在 `initState` 里调一次（写进 `build` 会随重建线性增长；重复注册被静默忽略 + debug assert）
- [ ] 没有在页面级清理里调 `FlGlobalEventBus.destroy()` 或 `FlLifecycleManager.cancel()`——这两个是**全局**的，会连坐所有活着的页面
- [ ] 用 `FlPageControllerMixin` 时，页面确实转发了事件（它自己不订阅任何东西），且 `onPageContextReady` 的签名是 `(BuildContext? context)`——**和页面 mixin 上的同名回调签名不同**
- [ ] `await` 之后访问 `context` / `setState` 前查了 `mounted`
- [ ] 跑过 `flutter analyze`（期望 0 error 0 warning）

交代改动时说清三件事：**改了哪些文件**、**每个生命周期回调里放了什么**、**上面清单里哪几条是这次特意处理的**（尤其 `FlRouteObserver` 注册位置和 dialog 覆盖的行为）。

## 不适用的场景

这个库回答**导航层面**的问题：「用户此刻在不在这个页面上」。它**不检测**：

- widget 滚出 `ListView` 视口 → 用 [`visibility_detector`](https://pub.dev/packages/visibility_detector)
- 同一路由内被不透明 widget 盖住 → 两个库都不检测
- 「卡片露出了百分之多少」→ 用 `visibility_detector`

信息流里自动播视频这类场景**两个一起用**：这个库确认 Feed 页面本身是 resumed 的（否则会在用户已经跳走的页面上继续播），`visibility_detector` 确认哪张卡在屏上。

反过来，纯 App 前后台且不需要过滤瞬时打断（来电、通知栏下拉）的话，Flutter 自带的 `WidgetsBindingObserver` 就够。
