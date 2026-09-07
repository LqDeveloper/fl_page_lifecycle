---
name: fl-page-lifecycle
description: >-
  用 fl_page_lifecycle 这个 Flutter 库给页面接上 Android 式生命周期（onPageStart / onPageResume /
  onPagePause / onPageStop），并按业务场景落地：页面被覆盖或离开时暂停视频与轮询、埋点曝光与页面停留时长、
  TabBarView / PageView 子页切换时启停任务、App 前后台回来刷新数据、页面间事件总线。包含入口选型决策
  （FlPageLifecycleMixin / FlPageViewScope / FlPageLifecycleView / FlPageControllerMixin）、
  必须注册 FlRouteObserver 的前置条件、事件时序与配对不变式，以及一份源码级避坑清单。
  Use this skill whenever the user is working on Flutter page visibility or page lifecycle and mentions any of:
  fl_page_lifecycle、FlPageLifecycleMixin、FlRouteObserver、onPageResume / onPagePause、页面生命周期、
  页面可见性、页面曝光、页面停留时长、埋点、"离开页面时暂停视频"、"回到页面继续播放"、"页面被 dialog 挡住"、
  "切到后台停止轮询"、"TabBarView 切换时才加载"、"PageView 子页什么时候可见"、RouteAware、
  ModalRoute.isCurrent、WidgetsBindingObserver、visibility_detector 选型对比。
  即使用户没说库名、只描述了"我想在页面不可见时停掉定时器/视频/动画/播放器"这类需求，也要用这个 skill——
  手写 RouteAware + isCurrent 的方案在 dialog 覆盖和 pushAndRemoveUntil 场景下必然出错，这个库正是为此存在。
  不适用于：判断 widget 是否滚动进视口（那是 visibility_detector）、纯 App 前后台监听（Flutter 自带
  WidgetsBindingObserver 就够）、以及给这个库本身做代码审计或发版（另有 skill）。
---

# fl_page_lifecycle 接入指导

这个库回答的是**导航层面**的问题：「用户此刻是不是在这个页面上」。它不回答几何问题（widget 有没有滚进视口，那是 `visibility_detector`）。

手写这套判断为什么会错——这决定了你该怎么用它：

- **dialog 盖住页面时，页面仍然可见**，只该 `pause` 不该 `stop`。而 `ModalRoute.isCurrent` 此时返回 `false`，分不出这两种情况。所以**永远别用 `isCurrent` 判断可见性**。
- `pushAndRemoveUntil` 会给一个「仍被别的路由盖着」的路由发 `didPop`，朴素的 `RouteAware` 会给没人看得见的页面发 `start`。
- iOS 侧滑返回中途松手，离场动画播了但没走完，页面并没有离开。
- 页面在 `pause` 状态下被 `dispose`，你等的那个 `resume` 永远不会来——资源就泄漏在那儿。

库把这些账算过一遍，给出**配对且幂等**的回调：每个 `start` 必有 `stop`，每个 `pause` 必有 `resume` 或 `stop`，缺的那一半在 `dispose` 时补发。所以**成对写代码就是安全的**：`onPageResume` 里起的东西，在 `onPagePause` 里停掉，不用再操心页面是怎么走的。

## 接入前必做两件事

### 1. 加依赖

```yaml
dependencies:
  fl_page_lifecycle: ^0.0.1
```

环境要求：Dart SDK `^3.11.5`、Flutter `>=3.41.9`。纯 Dart 实现，无平台通道，全平台可用。

### 2. 注册 `FlRouteObserver`（最常见的接入失败原因）

```dart
MaterialApp(
  navigatorObservers: [FlRouteObserver.instance], // ← 少了这行，四个可见性事件全不触发
  home: const HomePage(),
)
```

不注册**不会抛异常**，只是 `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop` 静默失效（debug 下会 `debugPrint` 一次提示）。所以每次接入完，先确认这行在。

关键细节：

- **嵌套 `Navigator` 要各自注册一次**，复用同一个 `FlRouteObserver.instance` 即可。用了 `Navigator` 做 tab 内独立栈、或用 go_router / auto_route 的 shell route 时，特别容易漏掉里层。
- 用 `go_router` / `auto_route` 时注册在路由配置的 `observers` 上，写法各不相同——不确定就先读用户的路由配置文件，再决定加在哪里。
- 转场动画那四个回调**不依赖注册**，它们直接监听 `ModalRoute.animation`。所以「动画回调有、可见性回调没有」这个症状 = 没注册。

## 选哪个入口

先看页面长什么样，再选入口。不要默认全都用 `FlPageLifecycleMixin`。

| 页面形态 | 用 | 关键点 |
|---|---|---|
| 普通路由页（`StatefulWidget`） | `FlPageLifecycleMixin` | 默认选择，什么都不用初始化 |
| `PageView` / `TabBarView` 的子页 | `FlPageViewScope` 包裹 + 子页 `observePageView => true` | 两者缺一不可，见下 |
| `StatelessWidget`，或不想再加 mixin，或只想观测某个子树 | `FlPageLifecycleView` | 回调式，`child` 原样返回，不加布局节点 |
| 逻辑在 Controller / ViewModel 里 | `FlPageControllerMixin` + 页面转发 | **它自己不订阅任何东西**，见下 |
| 只要 App 前后台 | `FlAppLifecycleMixin` | 无开关，`initState` 就订阅 |
| 只要转场动画 | `FlAnimationLifecycleMixin` | — |
| 只要裸路由事件 | `FlPageRouteMixin` | 回调叫 `onRouteStart/Resume/Pause/Stop`，不是 `onPage*` |

**这些入口不能叠加。** 后四个和 `FlPageLifecycleMixin` 订阅的是同一批源，而且成员名会撞（`isCurrent`、`routeName`、`appLifecycleChanged`、`routePageStart` 等）。叠加的后果不只是收到两遍事件——最后混入的那个 mixin 的实现被调用两次，另一个状态机根本不跑。**选一个**。

## 最常用的写法

```dart
class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  Timer? _poll;

  @override
  void onPageResume() {
    // 页面可见且可交互：起播、起轮询、起动画
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void onPagePause() {
    // 被覆盖 / 正在离开 / 切后台：一定要在这里成对停掉
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
| `observeAppLifecycle` | `false` | 需要 `onAppForeground` / `onAppBackground` 等五个 App 级事件。每个实例多两条全局流订阅，所以按需开 |

判断状态用这几个 getter，随时可读、不需要订阅：

| 想知道 | 读 | 别读 |
|---|---|---|
| 页面可见吗 | `isPageAppeared` | ~~`isCurrent`~~（dialog 一盖就 false） |
| 页面可交互吗 | `isPageResumed` | — |
| App 在前台吗 | `isForeground` | — |
| 是不是栈顶（真的想知道栈顶时才用） | `isCurrent` | — |

## 最关键的一个判断：`resume/pause` 还是 `start/stop`

这是接入时唯一真正需要动脑的地方，也是最容易埋 bug 的地方。两对回调的区别只有一处：**dialog / bottomSheet / popupMenu 盖上来时，只发 `pause`，不发 `stop`。**

于是判断标准就一句话：**弹窗盖住页面时，这件事该不该继续？**

| 弹窗期间…… | 用 | 典型场景 |
|---|---|---|
| **该停** | `onPageResume` / `onPagePause` | 视频/音频播放、动画、相机预览、地图定位、耗电的传感器 |
| **该继续** | `onPageStart` / `onPageStop` | 列表轮询、WebSocket、页面曝光埋点与停留时长、倒计时 |

理由：弹窗弹出来时用户**还在这个页面上**。视频该停（不然弹窗上盖着声音在响），但订单列表的轮询不该停（用户开了个筛选面板，回来当然希望数据是新的），停留时长也不该在这时候结算（他没离开）。

**别不假思索地一律用 `resume/pause`**——轮询用 `resume/pause` 的直接后果就是「一弹筛选面板刷新就断了」这类线上问题。用户的描述里往往已经写明了期望（「弹 bottomSheet 出来轮询就停了，其实用户还在这个页面上」= 要 `start/stop`），**照他说的选**。

拿不准就问自己：这件事的成本是「用户听得见/看得见」的，还是「后台默默花点流量」的？前者用 `resume/pause`，后者用 `start/stop`。

两对都要也可以（比如埋点用 `start/stop`、播放器用 `resume/pause`），它们是独立的两层，互不影响。

## 事件时序

写代码前先对一遍时序，选错回调比选错入口更难查。

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

几条落地时会用到的：

- `onPagePostFrame` 一定在第一个 `onPageStart` 之前，所以可以在它里面量 `RenderObject` 尺寸，`onPageStart` 里直接用。
- 首页（`home`）没有转场，两个入场动画事件都不发。
- `onPageEnterAnimationStart` **首次进入通常不发**（监听器在 `onPageContextReady` 时才绑上，那时入场动画已经开始了）。想表达「页面正在出现」用 `onPageContextReady`。
- `onPageLeaveAnimationStart` **不代表页面会离开**（iOS 侧滑放弃就会反转）。不可逆的收尾放 `onPageLeaveAnimationEnd` 或 `onPageDispose`。
- `onPageDispose` 永远是最后一个事件。此时 `routeName` 已经是 `null`了，要用路由信息就在 `onPageStop` 里读。
- 重写 `onLifecycleStateChanged` 必须调 `super`；重写 `appLifecycleChanged` **也必须调 `super`**（它是三个原始 App 事件的分发器，漏了 `super` 会静默失效）。

## 按场景落地

**先读 `references/recipes.md`**，里面是可直接改造的完整代码：视频播放器启停、页面曝光与停留时长埋点、轮询/WebSocket、TabBarView 懒加载、切后台回来刷新数据、页面间事件总线、Controller/ViewModel 转发。

场景到入口的对应关系：

| 需求 | 落点 |
|---|---|
| 离开/被盖住时暂停视频、回来继续 | `onPageResume` / `onPagePause` |
| 页面曝光埋点（PV） | `onPageStart`；用 `onPageStop` 配对算停留时长 |
| 轮询、WebSocket | `onPageStart` / `onPageStop`（弹窗期间要继续）；另开 `observeAppLifecycle` 挡住切后台 |
| 动画、相机预览、地图定位 | `onPageResume` / `onPagePause` |
| Tab 划到才加载 | `FlPageViewScope.wrapChildren` + 子页 `observePageView => true` + `onPageStart` |
| 从别的 App 回来刷新过期数据 | `observeAppLifecycle => true` + `onAppForeground` |
| 两个没有共同父级的页面通信 | `FlStateEventBusMixin` 的 `observeEvent<T>` / `dispatchEvent<T>` |

## PageView / TabBarView 子页：两步都要做

`PageView` 的子页全都被 build 且保活，路由事件说明不了哪个在屏上。所以要换成按页码驱动：

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

- 只包不开开关 → 子页在首帧全部 `start`，等于没做懒加载。
- 只开开关不包 → 拿不到页码，可见性永远不变。
- `controller` 只接受 `PageController` 或 `TabController`，别的类型 debug 下 assert。构造函数**不是 `const`**（带 assert），写 `const FlPageViewScope(...)` 编译不过。
- `PageView.builder` 用 `FlPageViewScope.wrapItemBuilder`。
- 作用域可嵌套：子页可见的条件是**每一层祖先作用域也都在自己宿主的当前页**。外层划走，内层当前 tab 也会 stop。

## 避坑清单

接入完照着过一遍，这些都是源码级的事实。完整版和原因见 `references/pitfalls.md`。

- [ ] `FlRouteObserver.instance` 注册了，**每个嵌套 `Navigator` 也注册了**
- [ ] 判可见性用 `isPageAppeared`，没有用 `isCurrent`
- [ ] `onPageResume` 里起的资源，在 `onPagePause` 里成对停掉了
- [ ] 没有叠加 `FlPageRouteMixin` / `FlAnimationLifecycleMixin` / `FlAppLifecycleMixin` 到 `FlPageLifecycleMixin` 上
- [ ] `observePageView` / `observeAppLifecycle` 返回的是常量，没有跟着 state 变
- [ ] 重写了 `onLifecycleStateChanged` 或 `appLifecycleChanged` 的地方都调了 `super`
- [ ] `observeEvent<T>` 只在 `initState` 里调一次（写进 `build` 或 `onPageResume` 会随重建线性增长；重复注册会被静默忽略 + debug assert）
- [ ] 没有在 `dispose` / 页面级清理里调 `FlGlobalEventBus.destroy()` 或 `FlLifecycleManager.cancel()`——这两个是**全局**的，会连坐所有活着的页面
- [ ] 用 `FlPageControllerMixin` 时，页面确实把事件转发进去了（它自己不订阅任何东西），且 `onPageContextReady` 的签名是 `(BuildContext? context)`——**和页面 mixin 上的同名回调签名不同**
- [ ] 事件总线是全局广播，`stop` 状态的页面照样收得到；后台页面不该反应就用 `isPageAppeared` 卡一下
- [ ] `scripts/verify_api_names.py` 跑过且没有编造的标识符

## 需要精确签名时

`references/api.md` 是完整 API 速查：18 个 `FlLifecycleState` 枚举值及顺序、每个 mixin 的 `mixin ... on ...` 声明与全部回调签名、`FlPageViewScope` 全部静态方法、三个 typedef、事件总线与 `FlLifecycleManager` 的公开面、以及所有 assert 的原文。**写代码前如果对某个名字或参数不确定，去查它，不要凭印象拼**。

这条要特别当心：这个库**不在公开 pub.dev 上**，所以你对它没有任何训练先验，「凭印象」写出来的名字大概率是编造的。实测最常见的四类编造是 `PageLifecycleMixin`（漏了 `Fl` 前缀）、`onPageShow` / `onPageHide`、`onPageVisible` / `onPageInvisible`、以及 `pauseOnOverlay:` / `pauseOnAppBackground:` 这种并不存在的构造参数。真名全部以 `Fl` 开头，回调是 `onPageStart` / `onPageResume` / `onPagePause` / `onPageStop`。库里还有几处同名不同参的回调（比如上面那条 `onPageContextReady`），拼错了编译不过或者静默不触发。

## 交付前自检

改完代码跑一遍，别只交代码。

**先跑脚本查编造的 API 名**——它只要 Python，不需要能跑起来的 Flutter 环境，所以在任何情况下都跑得动：

```bash
python3 scripts/verify_api_names.py <改动涉及的目录，如 lib/pages/>
```

一次把整个目录（或全部改动文件）传进去，别只传单个文件——项目自己的类常常声明在别处，只扫一个文件会误报。脚本只校验**名字是否存在**，不校验用法对不对；参数顺序、类型、有没有漏 `super` 仍然要靠 `flutter analyze`。

```bash
flutter analyze          # 期望 0 error 0 warning
flutter test             # 如果项目有测试
```

跑不了 Flutter 环境时（没装、或在纯分析场景里），至少要把脚本跑过，并明确告诉用户 `flutter analyze` 没跑，需要他本地补一次——不要让人以为已经验证过了。

然后向用户交代三件事：**改了哪些文件**、**每个生命周期回调里放了什么**、以及**上面避坑清单里哪几条是这次特意处理过的**（尤其是 `FlRouteObserver` 注册位置和 dialog 覆盖的行为）。如果用户的路由方案是 go_router / auto_route 这类，明确说明 observer 加在了哪里、嵌套栈有没有覆盖到。
