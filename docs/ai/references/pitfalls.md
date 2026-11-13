# 排错（按症状查，编号被脚本输出引用，勿改）

| # | 症状 | 原因 | 改法 |
|---|---|---|---|
| 1 | 四个可见性回调全不来，动画回调正常；或只有某些页面不来 | 漏注册观察者，不抛异常；debug 提示每进程只打一遍 | 根挂 `FlRouteObserver()`，每个嵌套 `Navigator` 各挂新 `FlRouteObserverProxy()`，见 `sc-route.md` §9 |
| 2 | 弹 dialog/bottomSheet 时资源被误释放 | 用了 `isCurrent`，任何路由压上来它都是 false | 可见用 `isPageAppeared`，可交互用 `isPageResumed` |
| 3 | 事件收到两遍，或某个状态机完全不跑 | 叠加了库里多个入口 mixin | 只留 `FlPageLifecycleMixin`；App 事件开 `observeAppLifecycle`，动画回调它本来就有 |
| 4 | 子页首帧全部 start / 子页可见性永远不变 | 包了 Scope 没开 `observePageIndex` / 开了没包 | 两处都做；`controller` 只收三种类型；一个 `PageController` 别给多个 `PageView` 共用 |
| 5 | debug 断言「开关被改」 | 开关取值跟着 widget/state 变了 | 返回字面常量；条件行为放回调里判断 |
| 6 | `onAppResume` 等不来 / 自己叠的埋点 mixin 不生效 | 重写 `onLifecycleStateChanged` 或 `appLifecycleChanged` 漏了 `super` | 补 `super`；通常重写具体回调即可，不必重写这两个 |
| 7 | 订阅数随重建增长，或第二次订阅无效 | `observeEvent` 写在 `build`/`onPageResume` 里；闭包字面量无法去重 | 只在 `initState` 调一次，传方法引用 |
| 8 | 某页 pop 后所有页面的事件/订阅失活 | 调了进程级的 `FlGlobalEventBus.destroy()` 或 `FlLifecycleManager.cancel()` | 页面里别调，mixin 已自动清理；它们只用于测试 tearDown |
| 9 | `FlPageControllerMixin` 一个回调都不来 | 它不订阅任何东西；或 `onPageContextReady` 签名写成了 `(String?, Object?)` | 页面转发 `onLifecycleChanged` + `setupRouteInfo`；Controller 上签名是 `(BuildContext? context)`，见 `sc-arch.md` §12 |
| 10 | `try/catch` 抓不到回调里的异常 | 每次分发都有守卫，异常走 `FlutterError.reportError`（library `fl_page_lifecycle`；四个动画回调由 Flutter 自己兜，library 是 Flutter 的） | 可能失败的操作在回调里自己包 `try/catch` |
| 11 | `onPageDispose` 里 `routeName` 是 null | dispose 顺序：补发 pause/stop → 注销路由 → 发 dispose | 在 `onPageStop` 读，或 `onPageContextReady` 时存字段 |
| 12 | 切内层 tab 收不到 start/stop，外层正常 | 嵌套时漏包内层容器，本页静默绑到外层 Scope（debug 提示一次，允许误报） | 每层容器都 `wrapChildren`；页内轮播本该跟外层走的可忽略提示 |
| 13 | `animateToPage` 掠过的页没埋点 / 翻页事件晚一拍 | 设计如此：滚动容器停稳才提交 | 要划走瞬间响应就配合路由事件或自己听控制器 |
| 14 | `onPageIndexChanged` 没收到 / 不是相邻页码 | 首次确定页码不发；换页后才挂载的宿主不补发；只报本层；`0→4` 一次报 `(0, 4)` | 要「本页成了当前页」用 `onPageStart` |
| 15 | debug 断言 `observer.navigator == null` | 同一 observer 实例挂了两个 `Navigator` | 嵌套的每个各 new 一个 `FlRouteObserverProxy()` |
| 16 | `IndexedStack` 子页可见性不对且无任何提示 | 漏包 Scope；漏包诊断只认 `PageView`/`TabBarView` | `FlPageIndexScope.wrapChildren`，见 `sc-index.md` §16 |
| 17 | 划回 tab 只有栈顶页复活 | 设计如此：页码驱动的页面不是本栈栈顶时不发 start，盖住它的路由 pop 后补上 | 无需处理，见 `sc-route.md` §17 |

其他症状：`setState() called during build` → `sc-arch.md` §14；`popUntil` 后中间层闪一对 start/stop → `sc-route.md` §6。

## 易想反的三点

- **没有 `ModalRoute` 的 widget 混入 mixin 仍有事件**：首帧 start + resume 照发，pause + stop 在 dispose 补发。失效的只有路由驱动的转场、转场动画回调和 `onPageContextReady`。
- **`FlPageRouteMixin` 有幂等和补发**：start/stop 一次性，dispose 补发。只有 `onRouteResume` / `onRoutePause` 不判重。它不管页码、没有统一出口。
- **已知缺口**：弹窗被 `pushReplacement` 换成页面，或弹窗不关直接在上面 push 页面，下层页面收不到 stop，`isPageAppeared` 仍为 true，直到上层 pop。要精确时长就先 `pop` 弹窗再 `push`。

## 选型与原生替代

本库不检测：widget 滚出视口、露出百分比（用 `visibility_detector`）；同一路由内被不透明 widget 盖住（都不检测）。信息流自动播视频两个一起用。

用户不装本库时如实说明原生方案的局限：

| 需求 | 原生替代 | 局限 |
|---|---|---|
| 页面可见性 | `RouteAware` + `RouteObserver` | 分不出弹窗覆盖；`pushAndRemoveUntil`/`popUntil` 给被盖住的页面误发事件；配对要自己保证 |
| App 前后台 | `didChangeAppLifecycleState` / `AppLifecycleListener` | 来电、下拉通知栏被当成回到前台 |
| 页码容器子页 | 自己听 `PageController`/`TabController` | 嵌套判定、停稳时机、配对都要自己写 |
