/// 页面 / App 生命周期事件枚举
///
/// 由 `FlPageLifecycleMixin.onLifecycleStateChanged` 发出。
/// 每个枚举值与 Mixin 中同名的 `protected` 回调一一对应，
/// **回调方法先执行，随后才发出对应枚举值**。
///
/// ## 典型时序
///
/// 普通页面 push 进入（非 PageView）：
/// ```
/// onPageInit → onPageContextReady → onPageEnterAnimationStart(不保证)
///            → onPagePostFrame → onPageStart → onPageResume
///            → onPageEnterAnimationEnd
/// ```
/// 注意 `onPagePostFrame` **先于** `onPageStart` / `onPageResume` 发出——
/// 两者都在首帧回调里，`_notifyPageStart` 会先补发 postFrame，
/// 因此可以在 postFrame 里量好尺寸，start 里直接用。
///
/// 应用的首个页面（`home`）没有转场动画，两个 EnterAnimation 事件都不会发出。
///
/// 被新页面覆盖后再返回：
/// ```
/// onPagePause → onPageStop  ...  onPageStart → onPageResume
/// ```
///
/// 被弹窗（`PopupRoute`）覆盖后再关闭：
/// ```
/// onPagePause  ...  onPageResume
/// ```
///
/// 自身 pop 退出：
/// ```
/// onPageLeaveAnimationStart → onPagePause → onPageStop
///                           → （下层页面的 onPageStart → onPageResume）
///                           → onPageLeaveAnimationEnd → onPageDispose
/// ```
/// 下层页面的 start 发生在动画**开始**时，不等动画播完。
/// 其中 `onPageLeaveAnimationStart` 与 `onPagePause` / `onPageStop`
/// 都发生在动画开始的那一刻，三者的先后顺序不作保证。
///
/// iOS 侧滑返回拖到一半放弃（页面并未退出，只有动画事件）：
/// ```
/// onPageLeaveAnimationStart → onPageEnterAnimationStart
///                           → onPageEnterAnimationEnd
/// ```
/// 页面始终没有 pop，因此不会发出 pause / stop，
/// `onPageLeaveAnimationStart` 之后也不一定跟着 `onPageLeaveAnimationEnd`。
/// `onPageDispose` 是最后一个事件，其后 stream 立即关闭。
enum FlLifecycleState {
  /// 页面初始化 —— `State.initState` 中发出。
  ///
  /// 此时 App 前后台流已订阅完成，但 `context` 尚不能安全访问
  /// `InheritedWidget`（如 `Theme.of` / `MediaQuery.of`），
  /// 也拿不到 `ModalRoute`，`routeName` / `arguments` 仍为 null。
  ///
  /// 适合：创建 Controller、初始化不依赖 context 的成员。
  /// 整个生命周期中只发出一次，且一定是第一个事件。
  onPageInit,

  /// 依赖就绪 —— 首次 `didChangeDependencies` 且成功拿到 `ModalRoute` 时发出。
  ///
  /// 此刻已完成三件事：向 `FlRouteObserver` 注册订阅、缓存 `ModalRoute`、
  /// 绑定路由转场动画监听。因此这是最早能读取
  /// `routeName` / `arguments` 的时机。
  ///
  /// 只发出一次（由 `_didRunOnContextReady` 保证），后续因
  /// `InheritedWidget` 变更导致的 `didChangeDependencies` 不会重复发出。
  ///
  /// **不会发出的情况**：`ModalRoute.of(context) == null`，
  /// 即页面不处于任何路由中（例如作为普通子 Widget 嵌入）。
  /// 此时失效的只有**由路由变化驱动的**那部分：被覆盖 / 被揭开时的
  /// start / resume / pause / stop，以及两个转场动画事件。
  ///
  /// 首帧的 [onPageStart] / [onPageResume] 与 `dispose` 时补发的
  /// [onPagePause] / [onPageStop] **照常发出**——首帧的可见性门禁只在
  /// 已拿到 `ModalRoute` 时才生效。因此把 mixin 混入一个不在路由中的
  /// Widget 仍然有意义：能拿到「这个 Widget 活着的这段时间」的成对启停。
  onPageContextReady,

  /// 首帧渲染完成 —— `WidgetsBinding.addPostFrameCallback` 中发出。
  ///
  /// 此时布局与绘制已完成，可安全读取 `RenderObject`、控件尺寸与位置。
  ///
  /// **一定早于首帧的 [onPageStart] / [onPageResume]**，两种场景都如此：
  /// 非 PageView 场景在同一个首帧回调里先发本事件再发 start；PageView 子页的
  /// start 走帧末队列，同样排在其后。因此宿主可以在 [onPageStart] 里直接用上
  /// 本回调里量到的尺寸。
  ///
  /// 若页面在首帧到来前就被 dispose，本事件不会发出。
  onPagePostFrame,

  /// 热重载 —— `State.reassemble` 中发出，**仅 Debug 模式**。
  ///
  /// Release / Profile 模式下永远不会发出。
  /// 适合：调试期重建缓存、重置调试状态。
  onPageReassemble,

  /// 入场转场动画开始播放 —— 路由动画进入 `AnimationStatus.forward`。
  ///
  /// **首次 push 入场时不保证收到**：动画监听器在 [onPageContextReady]
  /// （首次 `didChangeDependencies`）中才绑定到 `ModalRoute.animation`，
  /// 而 Navigator 在更早的 `didPush` 里就可能已把动画推进到 `forward`——
  /// 状态变更若发生在绑定之前就收不到，是否触发取决于该帧的具体时序。
  /// **不要依赖它做首屏逻辑**，需要「入场开始」这个时机请用 [onPageInit]
  /// 或 [onPageContextReady]。
  ///
  /// 实际能收到的主要场景是**动画中途折返**：iOS 侧滑返回手势拖到一半放弃，
  /// 动画由 `reverse` 回到 `forward`，此时发出本事件，随后是
  /// [onPageEnterAnimationEnd]。
  ///
  /// 与 [onPageStart] 无关：本事件只反映路由转场动画的状态，
  /// 不参与可见性状态机，也没有任何幂等保证。
  onPageEnterAnimationStart,

  /// 页面变为可见。
  ///
  /// 内部由 `_hasAppeared` 标志位保证幂等：已处于可见状态时重复触发不会再发出
  /// 本事件；若此刻页面处于 pause，只补发一次 [onPageResume]（见该事件的
  /// 触发来源）。发出后会**立即接着发出** [onPageResume]。
  ///
  /// 触发来源：
  /// - 首帧渲染完成（非 PageView 场景，页面首次显示）
  /// - 上层普通页面 pop（`FlRouteObserver.didPop`，被 pop 的不是 `PopupRoute`）
  /// - 上层页面被 `removeRoute` 移除（`didRemove`）
  /// - PageView 场景：翻页**停**在 `pageIndex` 对应的页上。是停下来的那一刻
  ///   而不是滑过半页的那一刻，被 `animateToPage` 掠过去的中间页因此不会触发，
  ///   见 `FlPageIndexScope` 的「提交时机」一节
  ///
  /// **不触发**：上层被 push 的是 `PopupRoute`（弹窗）时，
  /// 下方页面从未 stop 过，因此关闭弹窗只会发 [onPageResume]。
  onPageStart,

  /// 页面变为可交互（获得焦点）。
  ///
  /// 内部由 `_hasResume` 标志位保证幂等。
  /// 适合：恢复动画、恢复计时器、刷新数据、埋点页面曝光。
  ///
  /// 触发来源：
  /// - 紧随 [onPageStart] 之后自动发出
  /// - 上层 `PopupRoute`（dialog / bottomSheet 等）被 pop，
  ///   且本页仍处于可见状态（`_hasAppeared == true`）
  /// - 弹窗开着时被 `pushReplacement` / `pushAndRemoveUntil` 换成普通路由，
  ///   该路由随后被 pop：本页从未 stop 过，此刻收到的路由事件是 start，
  ///   按 resume 补发，[onPageStart] 不会重复发出
  onPageResume,

  /// 入场转场动画播放完毕 —— 路由动画进入 `AnimationStatus.completed`。
  ///
  /// 监听器在 [onPageContextReady] 时绑定到 `ModalRoute.animation`，
  /// 因此 `ModalRoute` 为 null 或 `animation` 为 null 时不会发出。
  ///
  /// 适合：把重量级操作（大图解码、复杂列表构建、自动弹出的引导层）
  /// 推迟到转场动画结束后执行，避免掉帧。
  ///
  /// 可能重复发出：iOS 侧滑返回手势中途放弃时，动画会
  /// `reverse → forward → completed`，本事件会再次发出。因此放在这里的网络请求、
  /// 埋点上报**必须自己做幂等或去重**——否则一个常见的 iOS 手势就会让它执行两遍。
  onPageEnterAnimationEnd,

  /// 页面失去交互焦点，但**可能仍然可见**。
  ///
  /// 内部由 `_hasResume` 标志位保证幂等：未处于 resume 状态时不发出。
  /// 适合：暂停动画 / 视频、停止计时器、结束页面停留时长统计。
  ///
  /// 触发来源：
  /// - 上层 push 了 `PopupRoute`（弹窗、bottomSheet、PopupMenu）——
  ///   此时页面依然可见，**只**发出本事件，不会发出 [onPageStop]
  /// - 作为 [onPageStop] 的前置步骤自动发出（见下）
  /// - `State.dispose` 中，若页面仍处于 resume 状态则补发
  onPagePause,

  /// 页面完全不可见。
  ///
  /// 内部由 `_hasAppeared` 标志位保证幂等。
  /// **发出前会先自动补发 [onPagePause]**（若当前仍处于 resume 状态），
  /// 因此订阅者总能拿到成对的 pause / stop。
  ///
  /// 触发来源：
  /// - 上层 push 了普通页面（非 `PopupRoute`）
  /// - 自身被 pop（`didPop`）
  /// - 自身被 `removeRoute` 移除（`didRemove`）
  /// - 自身被 `pushReplacement` 替换（`didReplace` 的 oldRoute）
  /// - PageView 场景：翻页停在了别的页上（同上，是停下来的那一刻；半途放弃的
  ///   拖动不会触发）
  /// - `State.dispose` 中，若页面仍处于可见状态则补发
  onPageStop,

  /// 退场转场动画开始播放 —— 路由动画进入 `AnimationStatus.reverse`。
  ///
  /// 触发来源：
  /// - 自身被 pop / `maybePop`，退场动画开始反向播放；
  /// - iOS 侧滑返回手势开始拖动（此时尚未确定会不会真的返回）。
  ///
  /// 时机上与 [onPageStop] 基本同时（`didPop` 在动画**开始**时发出 stop），
  /// 但两者互相独立，先后顺序不作保证。
  ///
  /// **不代表页面一定会退出**：侧滑手势中途放弃时，动画会
  /// `reverse → forward → completed`，后续收到的是
  /// [onPageEnterAnimationStart] / [onPageEnterAnimationEnd]，
  /// 而**不是** [onPageLeaveAnimationEnd]。因此不要在本事件里做
  /// 释放资源、上报离开埋点这类不可逆操作——那些应放在
  /// [onPageLeaveAnimationEnd] 或 [onPageDispose]。
  ///
  /// 同样依赖 [onPageContextReady] 时绑定的动画监听器，
  /// 无 `ModalRoute` 或无 `animation` 时不发出。
  onPageLeaveAnimationStart,

  /// 退场转场动画播放完毕 —— 路由动画进入 `AnimationStatus.dismissed`。
  ///
  /// 时序上位于 [onPageStop] 之后、[onPageDispose] 之前：
  /// `didPop` 在动画**开始**时就发出 [onPageStop]，动画播完才发出本事件，
  /// 随后 Navigator 才拆除 Widget 树触发 dispose。
  ///
  /// 同样依赖 [onPageContextReady] 时绑定的动画监听器，
  /// 无 `ModalRoute` 或无 `animation` 时不发出。
  onPageLeaveAnimationEnd,

  /// 页面销毁 —— `State.dispose` 中发出。
  ///
  /// 发出顺序：先取消 App 前后台订阅，再补发 [onPagePause] / [onPageStop]
  /// （若仍可见），然后从 `FlRouteObserver` 注销并解绑转场动画监听、
  /// 取消 PageView 可见性订阅，最后发出本事件。
  ///
  /// 补发早于注销是有意的：因此 `routeName` / `arguments` 在 [onPageStop]
  /// 里仍然可读，到本事件时已经是 null。
  ///
  /// 这是**最后一个事件**，其后不会再发出任何生命周期事件。
  /// 适合：释放 Controller、关闭自建的 Stream / 定时器。
  onPageDispose,

  /// App 进入 `AppLifecycleState.resumed` —— **原始状态，不做任何过滤**。
  ///
  /// 每次系统回到 resumed 都会发出，包括下拉通知栏后收起、
  /// 来电挂断、控制中心关闭这类未真正离开 App 的短暂中断。
  ///
  /// 与 [onAppForeground] 的区别：本事件更频繁、更"生"。
  /// 需要精确响应中断恢复（如视频续播）用本事件；
  /// 需要"真的从后台回来才刷新数据"用 [onAppForeground]。
  ///
  /// 会广播给**所有存活的页面**，包括当前不可见的页面。
  onAppResume,

  /// App 进入 `AppLifecycleState.inactive` —— 原始状态，不做过滤。
  ///
  /// 表示 App 可见但不可响应输入的临时中断：
  /// iOS 来电 / 控制中心 / App Switcher，Android 多任务键 / 下拉通知栏。
  ///
  /// 典型序列 `resumed → inactive → resumed`（未真正离开 App）
  /// 或 `resumed → inactive → hidden → paused`（进入后台）。
  /// 收到本事件时**无法判断**后续走向，需要等待下一个状态。
  ///
  /// 适合：立即暂停视频播放、隐藏敏感信息（App Switcher 截图前）。
  onAppInactive,

  /// App 进入 `AppLifecycleState.paused` —— 原始状态，不做过滤。
  ///
  /// 表示 App 已不可见（进入后台）。
  /// iOS `applicationDidEnterBackground`，Android `Activity.onStop`。
  ///
  /// 适合：释放不可见资源、暂停动画、停止定时器、持久化草稿。
  ///
  /// 注意 `AppLifecycleState.hidden` 与 `detached` **不会**产生任何
  /// 枚举事件（内部 switch 走 default 分支忽略）。
  onAppPause,

  /// App 真正回到前台 —— **过滤后**的前后台事件。
  ///
  /// 由 `FlLifecycleManager.stream` 发出 `true` 时触发。
  /// 与 [onAppResume] 的关键区别：只有完整经历过
  /// `paused`（真正进入后台）再回来才发出，
  /// `inactive → resumed` 这类短暂中断会被过滤掉。
  ///
  /// 另有一次**冷启动补发**：`FlLifecycleManager` 首次被订阅时，
  /// 若 App 已处于 resumed 状态，会通过 microtask 补发一次 `true`，
  /// 保证订阅者不漏掉初始前台事件。由于补发标志位是全局的，
  /// 这次补发只有**首个触发订阅的页面**能收到。
  ///
  /// 适合：回到前台刷新列表、重新校验登录态、恢复轮询。
  onAppForeground,

  /// App 进入后台 —— 过滤后的前后台事件。
  ///
  /// 由 `FlLifecycleManager.stream` 发出 `false` 时触发，
  /// 时机等同于 [onAppPause]（`AppLifecycleState.paused`）。
  ///
  /// `detached` 时**不会**重复发出（进入 paused 时已发过一次）。
  ///
  /// 会广播给所有存活页面，包括当前不可见的页面。
  onAppBackground;

  /// 是否为页面可交互事件（[onPageResume]）
  bool get isPageResume => this == FlLifecycleState.onPageResume;

  /// 是否为页面失焦事件（[onPagePause]）
  bool get isPagePause => this == FlLifecycleState.onPagePause;

  /// 是否为 App 维度的事件
  bool get isAppEvent => const <FlLifecycleState>{
    FlLifecycleState.onAppForeground,
    FlLifecycleState.onAppBackground,
    FlLifecycleState.onAppResume,
    FlLifecycleState.onAppInactive,
    FlLifecycleState.onAppPause,
  }.contains(this);
}
