---
name: fl-page-lifecycle
description: >-
  Flutter 页面可见性与 App 前后台生命周期（fl_page_lifecycle 0.0.4）。需求是「页面可见/不可见时做某事」或
  「App 切前后台时做某事」就用，即使没提库名：离开暂停/回来恢复视频、轮询、动画，返回刷新列表，曝光与停留时长埋点，
  PageView/TabBarView/IndexedStack 子页懒加载，过滤来电与通知栏下拉。手写 RouteAware / isCurrent /
  didChangeAppLifecycleState 必错。此包不在训练数据里，API 名必须查表。不用于 widget 滚入视口（visibility_detector）。
---

# fl_page_lifecycle 0.0.4 接入

新包，不在训练数据里。`PageLifecycleMixin`、`onPageShow`/`onPageHide`、`pauseOnOverlay:` 都是编造的，真名一律 `Fl` 开头，签名以第 7 节为准。

## 0. 先查依赖

`grep -n -A1 fl_page_lifecycle pubspec.yaml`

- **是 0.0.4** → 继续。
- **不是 0.0.4，或没装** → 停下问用户，别自己装依赖，也别按本文写代码。给出 `flutter pub add fl_page_lifecycle`（约束 `^0.0.4`）。
- **用户不装** → 用原生方案并说明局限，见 `pitfalls.md` 末尾。

本库答的是「用户此刻在不在这个页面上」。回调**成对且幂等**：start↔stop、pause↔resume/stop，缺的那半在 `dispose` 补发。

## 1. 注册观察者

```dart
MaterialApp(navigatorObservers: [FlRouteObserver()])            // 根：单例
ShellRoute(observers: [FlRouteObserverProxy()])                  // 每个嵌套 Navigator 各 new 一个
```

同一实例挂两个 `Navigator` 会断言失败。不注册不报错，只是可见性回调不来（动画回调照常）。先读项目路由配置再决定加在哪。其他框架写法见 `sc-route.md` §9。

## 2. 选入口

| 页面形态 | 用 |
|---|---|
| 普通路由页 | `FlPageLifecycleMixin`（默认） |
| `PageView`/`TabBarView`/`IndexedStack` 子页 | 容器 `FlPageIndexScope.wrapChildren` + 子页 `observePageIndex => true`，缺一不可 |
| `StatelessWidget` / 只观测子树 | `FlPageLifecycleView` |
| 逻辑在 Controller/ViewModel | `FlPageControllerMixin` + 页面手动转发 |
| 只要前后台 / 转场动画 / 路由事件 | `FlAppLifecycleMixin` / `FlAnimationLifecycleMixin` / `FlPageRouteMixin`（回调叫 `onRoute*`） |

库里的入口 mixin **不能叠加**（`FlStateEventBusMixin` 除外）。复用逻辑叠自己的：`mixin M<T extends StatefulWidget> on State<T>, FlPageLifecycleMixin<T>`。

## 3. resume/pause 还是 start/stop

唯一差别：弹窗（`PopupRoute` 或 `opaque: false` 路由）盖上来**只发 pause，不发 stop**。问一句「弹窗期间这件事该不该继续」：

| 弹窗期间 | 用 | 场景 |
|---|---|---|
| 该停 | `onPageResume` / `onPagePause` | 视频音频、动画、相机、传感器 |
| 该继续 | `onPageStart` / `onPageStop` | 轮询、WebSocket、曝光与停留时长、倒计时 |

两对可同时用。

## 4. 写法

```dart
class _S extends State<Page> with FlPageLifecycleMixin {
  @override
  void onPageResume() => _player.play();
  @override
  void onPagePause() => _player.pause();
}
```

- 开关（getter，**取值必须恒定**）：`observePageIndex`（页码容器子页）、`observeAppLifecycle`（要 App 事件），默认都 `false`。
- 状态：可见 `isPageAppeared`（别用 `isCurrent`）、可交互 `isPageResumed`、前台 `isForeground`。
- 重写 `onLifecycleStateChanged` / `appLifecycleChanged` 必须调 `super`。
- `onPageInit` / `onPageContextReady` 在构建期，别 `setState`。
- `onPageDispose` 里 `routeName` 已为 null，要用在 `onPageStop` 读。

## 5. 时序

```
push 进来      Init → ContextReady → PostFrame → Start → Resume → EnterAnimationEnd
被路由覆盖     Pause → Stop  …  Start → Resume
被弹窗覆盖     Pause         …  Resume
自己 pop       LeaveAnimationStart → Pause → Stop → LeaveAnimationEnd → Dispose
iOS 侧滑放弃   LeaveAnimationStart → EnterAnimationStart → EnterAnimationEnd（无 pause/stop）
```

`EnterAnimationEnd` 可能触发两次，须幂等；`LeaveAnimationStart` 不代表会离开，不可逆操作放 `LeaveAnimationEnd` / `Dispose`。

## 6. 页码容器

```dart
PageView(controller: c, children: FlPageIndexScope.wrapChildren(controller: c, children: pages))
// 子页
@override
bool get observePageIndex => true;
```

- `controller`：`PageController` / `TabController` / `ValueListenable<int>`（`IndexedStack` 用同一个 `ValueNotifier<int>` 驱动 index 和 Scope）。构造函数非 const。
- **嵌套时每层都要包**，漏包不报错（`IndexedStack` 连提示都没有）。
- 滚动容器**停稳才提交**：`animateToPage` 掠过的页不发事件，`jumpToPage` 与 `ValueListenable` 当场提交。

## 7. 接口（全部公开 API，签名照源码）

```dart
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';   // 唯一入口，别 import src/
```

**`enum FlLifecycleState`**（18 个，按声明顺序）：`onPageInit` `onPageContextReady` `onPagePostFrame` `onPageReassemble` `onPageEnterAnimationStart` `onPageStart` `onPageResume` `onPageEnterAnimationEnd` `onPagePause` `onPageStop` `onPageLeaveAnimationStart` `onPageLeaveAnimationEnd` `onPageDispose` `onAppResume` `onAppInactive` `onAppPause` `onAppForeground` `onAppBackground`。getter：`isPageResume` `isPagePause` `isAppEvent`。

**`mixin FlPageLifecycleMixin<T extends StatefulWidget> on State<T>`**

```dart
// 可覆写开关（默认 false，取值恒定）
bool get observePageIndex;   bool get observeAppLifecycle;
// 只读
String? routeName;  Object? arguments;        // ContextReady 之前、Dispose 时为 null
bool isPageAppeared, isPageResumed, isForeground, isCurrent, isInPageScope;
int pageIndex, currentPageIndex, pageScopeDepth;   // 不在 Scope 中为 -1
// 可覆写回调，全部 void、@protected、默认空实现
onPageInit()  onPageContextReady(String? routeName, Object? arguments)  onPagePostFrame()
onPageReassemble()                        // 仅 debug 热重载
onPageStart()  onPageResume()  onPagePause()  onPageStop()  onPageDispose()
onPageEnterAnimationStart()  onPageEnterAnimationEnd()
onPageLeaveAnimationStart()  onPageLeaveAnimationEnd()
onAppResume()  onAppInactive()  onAppPause()  onAppForeground()  onAppBackground()  // 需 observeAppLifecycle
onPageIndexChanged(int from, int to)      // 需在 Scope 内，只报本层
// @mustCallSuper
onLifecycleStateChanged(FlLifecycleState state)   // 18 个事件的统一出口
appLifecycleChanged(AppLifecycleState state)      // 原始 App 状态分发器
```

**`FlPageIndexScope`**（StatefulWidget，构造非 const）

```dart
FlPageIndexScope({Key? key, required int pageIndex, required Listenable controller, required Widget child})
static List<Widget> wrapChildren({required Listenable controller, required List<Widget> children})
static NullableIndexedWidgetBuilder wrapItemBuilder({required Listenable controller, required NullableIndexedWidgetBuilder builder})
static int depthOf(BuildContext context)              // 不在 Scope 中 -1
static int? indexOf(Listenable controller)            // 尚不可用时 null
static int initialIndexOf(Listenable controller)
static Listenable listenableOf(Listenable controller)
```

**`FlPageLifecycleView`**（包一层 Widget，不混 mixin；mixin 的 getter 不对外暴露）

```dart
const FlPageLifecycleView({Key? key, bool observePageIndex = false, bool observeAppLifecycle = false,
  void Function(BuildContext context, FlLifecycleState state)? onStateChanged,
  void Function(BuildContext context, String? routeName, Object? arguments)? onRouteParam,
  void Function(BuildContext context, int from, int to)? onPageIndexChanged,
  required Widget child})
// typedef: FlPageLifecycleCallback / FlPageRouteParamCallback / FlPageIndexChangedCallback
```

**`mixin FlPageControllerMixin`**（无 `on` 约束；不订阅任何东西，没有 dispose）

```dart
@mustCallSuper void onLifecycleChanged(FlLifecycleState state, {BuildContext? context})  // 页面转发入口
void setupRouteInfo(String? name, Object? arguments)
FlLifecycleState lifecycleState;  bool isPageResume, isPagePause, isForeground;  String? routeName;  Object? arguments;
// 回调与主 mixin 同名的 18 个，仅两处不同：
void onPageContextReady(BuildContext? context)    // ⚠️ 签名不同
void onPageIndexChanged(int from, int to)         // 不经 onLifecycleChanged 分发，页面要单独转发
```

**独立 mixin**（均 `on State<T>`，不与主 mixin 叠加）

```dart
FlPageRouteMixin:  ModalRoute? modalRoute; String? routeName; Object? arguments; bool isCurrent, hasRoute;
                   onPageContextReady(String?, Object?)  onRouteStart()  onRouteResume()  onRoutePause()  onRouteStop()
                   + 四个 on Page Enter/Leave Animation Start/End 回调
FlAppLifecycleMixin:        bool isForeground, hasInit;  onAppForeground()  onAppBackground()  appLifecycleChanged(AppLifecycleState)
FlAnimationLifecycleMixin:  onPageEnterAnimationStart/End()  onPageLeaveAnimationStart/End()
```

**观察者与单例**

```dart
FlRouteObserver()               // factory，恒返回 FlRouteObserver.instance
FlRouteObserverProxy()          // 无参，每个嵌套 Navigator 各 new 一个
FlLifecycleManager.instance     // bool isForeground; Stream<bool> stream（已过滤）; Stream<AppLifecycleState> lifecycle;
                                // void listen(); void cancel()  ← 进程级，页面里别调
```

**事件总线**

```dart
mixin FlStateEventBusMixin on State:  observeEvent<T>(void Function(T event) onData)   dispatchEvent<T>(T event)   // dispose 自动取消
FlGlobalEventBus（静态）:  Stream<T> observeEvent<T>()   void dispatchEvent<T>(T event)
                          void configure(FlIEventBus bus)   Future<void> destroy()   ← 进程级，页面里别调
FlEventBus({bool sync = false}) / FlEventBus.customController(StreamController<dynamic>)  implements FlIEventBus
FlIEventBus:  Stream<T> on<T>()   void fire(dynamic event)   Future<void> destroy()
```

## 8. 按需读（一次只读一个）

| 要做的事 | `references/` |
|---|---|
| 视频、埋点、轮询/WebSocket、App 前后台 | `sc-page.md` |
| 懒加载、嵌套容器、`onPageIndexChanged`、`IndexedStack` | `sc-index.md` |
| 各路由框架注册、`popUntil`/`pushAndRemoveUntil`、转场动画、tab 内独立栈 | `sc-route.md` |
| 事件总线、子树观测、Controller、统一埋点、`setState` 报错 | `sc-arch.md` |
| 行为异常排查 | `pitfalls.md` |

## 9. 交付前

```bash
python3 scripts/verify_api_names.py <改动目录>   # 编造的名字 + 高频接错方式；传目录，别传单文件
flutter analyze
```

回调不来先跑脚本，再查 `pitfalls.md`。`❌` 是确定错误，`⚠️` 取决于扫描范围。

自检：版本已确认 · 根 `FlRouteObserver()`、每个嵌套栈一个新 proxy · 用 `isPageAppeared` 判可见 · 起停成对且按第 3 节选对 · 没叠加入口 mixin、开关恒定、该调的 `super` 调了 · `observeEvent` 只在 `initState` 调一次，没调 `FlGlobalEventBus.destroy()` / `FlLifecycleManager.cancel()` · `await` 后查 `mounted` · 页码容器每层都包了。

交代改动时说明：改了哪些文件、观察者注册在哪、两对回调按什么选的。
