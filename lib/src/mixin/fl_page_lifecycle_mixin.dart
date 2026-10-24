import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../delegate/fl_app_lifecycle_delegate.dart';
import '../delegate/fl_page_index_delegate.dart';
import '../delegate/fl_page_route_delegate.dart';
import '../lifecycle/fl_lifecycle_guard.dart';
import '../lifecycle/fl_lifecycle_state.dart';
import '../lifecycle/lifecycle_route_aware.dart';

/// 给 `State` 装上完整的页面生命周期：start / resume / pause / stop，
/// 加上首帧、转场动画、App 前后台与 `PageView` 切页。
///
/// 这是本库的主入口。混入即可用，**不需要**手动调任何初始化或释放方法：
///
/// ```dart
/// class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
///   @override
///   void onPageResume() => _startVideo();      // 页面可交互了
///
///   @override
///   void onPagePause() => _pauseVideo();       // 被弹窗盖住 / 即将离开
///
///   @override
///   Widget build(BuildContext context) => ...;
/// }
/// ```
///
/// 前提是 [FlRouteObserver] 已注册到 `Navigator` 上，否则路由驱动的四个事件
/// 收不到（debug 下会提示一次）。
///
/// ## 语义保证
///
/// - **成对**：start 之后必有 stop，pause 之后必有 resume 或 stop；
///   `dispose` 时会补发缺的那半边。
/// - **幂等**：重复触发被内部标志位挡掉，不会连发两次 start。
/// - **顺序**：`onPagePostFrame` 一定早于首帧的 start，因此可以在 postFrame
///   里量好尺寸、start 里直接用。
/// - **弹窗只 pause 不 stop**：被 `PopupRoute` 盖住时页面仍然可见，
///   判断可见性用 [isPageAppeared]，不要用 [isCurrent]。
///
/// 每个事件的确切触发时机、不会触发的情形与典型时序，都写在
/// [FlLifecycleState] 的文档里——**那里是本库的生命周期契约**，
/// 下面的回调只做一行摘要并指回去。
///
/// ## 两个默认关闭的开关
///
/// [observePageIndex] 与 [observeAppLifecycle] 默认都是 false，为的是摊薄实例
/// 成本（后者打开后每个实例多两条全局流订阅）。位于 `PageView` / `TabBarView`
/// 中要按页码驱动可见性时开前者，需要 App 前后台事件时开后者。
///
/// ## 相关类型
///
/// - 不想混入 `State`？用 `FlPageLifecycleView` 包一层，事件走回调抛出。
/// - 想在 Controller / ViewModel 里收事件？用 `FlPageControllerMixin`。
/// - 只要路由事件或只要动画事件？用 `FlPageRouteMixin` /
///   `FlAnimationLifecycleMixin`，**不要**与本 mixin 叠加使用。
mixin FlPageLifecycleMixin<T extends StatefulWidget> on State<T>
    implements LifecycleRouteAware {
  /// 路由相关处理（取路由、订阅路由事件、监听转场动画）全部委托给它。
  late final FlPageRouteDelegate _routeDelegate = FlPageRouteDelegate(
    host: this,
    onEnterAnimationStart: _handleEnterAnimationStart,
    onEnterAnimationEnd: _handleEnterAnimationEnd,
    onLeaveAnimationStart: _handleLeaveAnimationStart,
    onLeaveAnimationEnd: _handleLeaveAnimationEnd,
  );

  /// App 生命周期相关处理（前后台切换、AppLifecycleState）全部委托给它。
  late final FlAppLifecycleDelegate _appDelegate = FlAppLifecycleDelegate(
    onForeground: _handleAppForeground,
    onBackground: _handleAppBackground,
    onStateChanged: appLifecycleChanged,
  );

  /// 页码相关处理（判断是否位于按页码驱动的容器中、监听页码变化）全部委托给它。
  late final FlPageIndexDelegate _pageIndexDelegate = FlPageIndexDelegate(
    onPageShow: _notifyPageIndexShow,
    onPageHide: _notifyPageStop,
    onIndexChanged: onPageIndexChanged,
  );

  /// 本页所在路由的名字（`RouteSettings.name`）。
  ///
  /// [onPageContextReady] 之前、以及页面不处于任何路由中时为 null。
  String? get routeName => _routeDelegate.routeName;

  /// 本页所在路由的参数（`RouteSettings.arguments`，即 `Navigator.pushNamed`
  /// 的 `arguments`）。
  ///
  /// [onPageContextReady] 之前、以及页面不处于任何路由中时为 null。
  Object? get arguments => _routeDelegate.arguments;

  /// 本页是否位于按页码驱动的容器（`PageView` / `TabBarView` / `IndexedStack`）中，
  /// 即是否命中了 `FlPageIndexScope`。
  /// 首次 `didChangeDependencies` 之前恒为 false。
  bool get isInPageScope => _pageIndexDelegate.isInPageScope;

  /// 本页在所属容器中的页码，由 `FlPageIndexScope` 自动下发，**只读**。
  ///
  /// 不在任何 Scope 中（或首次 `didChangeDependencies` 之前）为 -1。
  int get pageIndex => _pageIndexDelegate.pageIndex;

  /// 本页所在层当前展示的页码，未能确定时为 -1。
  int get currentPageIndex => _pageIndexDelegate.currentIndex;

  /// `FlPageIndexScope` 的嵌套深度，取值与 `ScrollNotification.depth` 对齐：
  /// 最外层为 0，每往里嵌一层（如 `PageView` 里再套 `TabBarView`）加一；
  /// 不在任何 Scope 中为 -1。
  int get pageScopeDepth => _pageIndexDelegate.depth;

  /// 是否按页码驱动可见性，**默认 false**：不做判定，
  /// 页面首帧后直接按普通页面发出 start / resume。
  ///
  /// 页面位于 `PageView` / `TabBarView` / `IndexedStack` 中（外面包了
  /// `FlPageIndexScope`）、需要由页码而非路由驱动 start / stop 时，覆写它返回 true。
  ///
  /// 嵌套时**每一层容器都要包 `FlPageIndexScope`**：只包外层、漏掉内层不会报错，
  /// 本页会静默绑到外层的 Scope 上，切内层子页收不到 start / stop。打开本开关后
  /// debug 下会检查离本页最近的那个容器有没有包上，没包就提示一次。
  ///
  /// **必须在整个生命周期内保持不变**，debug 下有断言把关。可见性状态机是
  /// 有状态的：中途翻转会留下对不齐的中间态——由 false 变 true 时，本页可能
  /// 已经在首帧发过 start，此刻却不是当前页，于是停在「屏幕外却是 started」；
  /// 由 true 变 false 时则可能停在「本该可见却是 stopped」。要动态控制可见性，
  /// 请改用 `FlPageIndexScope` 的挂载与否，而不是翻这个开关。
  bool get observePageIndex => false;

  /// 是否订阅 App 前后台事件，**默认 false**：[onAppForeground] /
  /// [onAppBackground] / [appLifecycleChanged] 与对应的三个 App 枚举事件
  /// 都不发出，页面生命周期本身不受影响。需要这些事件时覆写它返回 true。
  ///
  /// 默认关掉是为了**摊薄实例成本**：打开后每个混入本 mixin 的 `State` 都会
  /// 订阅两条全局广播流，一次 App 前后台切换要在同一帧内同步 fan-out 给所有
  /// 存活实例。单个路由页可以忽略，但把 `FlPageLifecycleView` 用在列表项上时
  /// （几百个实例）就很可观——只在真正需要 App 事件的页面上打开。
  ///
  /// **必须在整个生命周期内保持不变**：只在 `initState` 中读取一次，
  /// 运行时改变无效，debug 下有断言把关。
  bool get observeAppLifecycle => false;

  /// App 当前是否位于前台。不依赖任何生命周期时机，随时可读，
  /// 也不依赖 [observeAppLifecycle]（它同步读 `WidgetsBinding.lifecycleState`）。
  bool get isForeground => _appDelegate.isForeground;

  /// 本页当前是否可见，即已发出 [onPageStart] 且尚未发出 [onPageStop]。
  ///
  /// 用于在异步回调返回时判断「页面还在不在前台」，避免对已 stop 的页面做
  /// 刷新、埋点这类动作。
  bool get isPageAppeared => _hasAppeared;

  /// 本页当前是否可交互，即已发出 [onPageResume] 且尚未发出 [onPagePause]。
  bool get isPageResumed => _hasResume;

  /// 本页是不是**所在 Navigator** 的栈顶路由。实时查询，不缓存。
  ///
  /// 三个容易踩的点：
  ///
  /// - 被弹窗（`PopupRoute`）盖住时为 false，但此刻页面**仍然可见**——弹窗只
  ///   触发 [onPagePause] 不触发 [onPageStop]，判断可见性请用 [isPageAppeared]；
  /// - 嵌套 Navigator 时只反映**本层**：内层栈顶页即使整个内层 Navigator 被
  ///   外层路由盖住，这里依然是 true；
  /// - 转场动画期间就已经翻转：被 pop 的路由在动画**开始**时就不再是栈顶，
  ///   要判断转场真的结束请用 [onPageEnterAnimationEnd] /
  ///   [onPageLeaveAnimationEnd]。
  ///
  /// 不在任何路由中（`ModalRoute.of` 为 null）时为 false，因此**不要**拿它去
  /// 过滤生命周期事件——那会把非路由页面永久挡死。
  bool get isCurrent => _routeDelegate.isCurrent;

  bool _hasAppeared = false;
  bool _hasResume = false;
  bool _hasDispose = false;
  bool _hasPostFrame = false;

  /// 是否真的调用过 `_appDelegate.attach()`。
  ///
  /// `dispose` 以它为准而**不是**重读 [observeAppLifecycle]：那两个开关本该恒定
  /// （[_debugCheckSwitchesStable] 会在 debug 下拦住翻转），但断言在 release 下
  /// 不执行，开关一旦被改成 false，重读就会跳过 detach，让委托持有的两条全局流
  /// 订阅永不释放。记录「实际做过什么」而不是「现在该做什么」，这条路径就不存在。
  bool _didAttachApp = false;

  /// 是否真的调用过 `_pageIndexDelegate.attach()`，理由同 [_didAttachApp]。
  bool _didAttachPageIndex = false;

  /// 两个开关的首次取值，仅用于 debug 断言，见 [_debugCheckSwitchesStable]。
  bool? _debugObservePageIndex;
  bool? _debugObserveAppLifecycle;

  /// 两个开关都必须在整个生命周期内保持不变，翻转会让可见性状态机对不齐。
  bool _debugCheckSwitchesStable() {
    assert(() {
      _debugObservePageIndex ??= observePageIndex;
      _debugObserveAppLifecycle ??= observeAppLifecycle;
      assert(
        observePageIndex == _debugObservePageIndex,
        'observePageIndex 在运行时被改成了 $observePageIndex（初始为 '
        '$_debugObservePageIndex）。它必须在整个生命周期内保持不变，'
        '否则可见性状态机会停在对不齐的中间态。',
      );
      assert(
        observeAppLifecycle == _debugObserveAppLifecycle,
        'observeAppLifecycle 在运行时被改成了 $observeAppLifecycle（初始为 '
        '$_debugObserveAppLifecycle）。它只在 initState 读取一次，改了也不会生效。',
      );
      return true;
    }());
    return true;
  }

  @override
  void initState() {
    super.initState();
    assert(_debugCheckSwitchesStable());
    if (observeAppLifecycle) {
      _didAttachApp = true;
      _appDelegate.attach();
    }

    _emit(onPageInit, FlLifecycleState.onPageInit);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (_hasDispose) {
        return;
      }
      _notifyPostFrame();
      _startIfNotInPageScope();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 判断本页是不是 PageView 的一页：`FlPageIndexScope` 是 InheritedWidget，
    // 这里才是注册依赖的合法时机，Scope 变化（页码调整、控制器被换掉）也能
    // 通过重新进入本方法被感知到。这里只做绑定，不发出任何事件。
    assert(_debugCheckSwitchesStable());
    if (observePageIndex) {
      _didAttachPageIndex = true;
      _pageIndexDelegate.attach(context);
    }

    // 「首次成功才发事件、失败留到下次重试」的语义由委托持有，
    // 见 [FlPageRouteDelegate.attachOnce]。
    if (!_routeDelegate.attachOnce(context)) {
      return;
    }
    _emit(
      () => onPageContextReady(
        _routeDelegate.routeName,
        _routeDelegate.arguments,
      ),
      FlLifecycleState.onPageContextReady,
    );
  }

  @override
  void reassemble() {
    super.reassemble();
    if (kDebugMode) {
      _emit(onPageReassemble, FlLifecycleState.onPageReassemble);
    }
  }

  @override
  void dispose() {
    _hasDispose = true;
    // 下面每一层 try/finally 的作用都一样：**宿主回调是外部代码，随时可能抛**，
    // 而资源释放与 `super.dispose()` 一次都不能少。回调与释放的先后顺序保持不变，
    // 因此 onPageStop 里 routeName 仍可读、onPageDispose 里仍为 null；
    // finally 也不吞异常，宿主的错误照常上抛。
    //
    // 委托关掉时从未被创建过，这里不去碰它——`late final` 一读就会实例化，
    // 只为了调一次空操作的 detach 不值得（列表里放几百个 FlPageLifecycleView 时尤其）。
    // 用 _didAttachApp / _didAttachPageIndex 而不是重读开关，理由见字段文档。
    try {
      if (_didAttachApp) {
        _appDelegate.detach();
      }
      // 这里用 _notifyPageStop 而非 _checkNotifyPageStop：页面已经在销毁，
      // 不该再用「是不是 PageView 当前页」去过滤。被滑走的子页在这一刻
      // isCurrentPage 已经是 false，走 check 会让它带着 _hasAppeared 直接销毁，
      // 收不到与 onPageStart 配对的 onPageStop。幂等由 _hasAppeared 保证。
      _notifyPageStop();
    } finally {
      try {
        _routeDelegate.detach();
        if (_didAttachPageIndex) {
          _pageIndexDelegate.detach();
        }
        _emit(onPageDispose, FlLifecycleState.onPageDispose);
      } finally {
        super.dispose();
      }
    }
  }

  /// App 切换到前台，由 [_appDelegate] 回调。
  void _handleAppForeground() {
    _emit(onAppForeground, FlLifecycleState.onAppForeground);
  }

  /// App 切换到后台，由 [_appDelegate] 回调。
  void _handleAppBackground() {
    _emit(onAppBackground, FlLifecycleState.onAppBackground);
  }

  /// 入场转场动画播放开始，由 [_routeDelegate] 回调。
  void _handleEnterAnimationStart() {
    _emit(
      onPageEnterAnimationStart,
      FlLifecycleState.onPageEnterAnimationStart,
    );
  }

  /// 入场转场动画播放完毕，由 [_routeDelegate] 回调。
  void _handleEnterAnimationEnd() {
    _emit(onPageEnterAnimationEnd, FlLifecycleState.onPageEnterAnimationEnd);
  }

  /// 退场转场动画播放开始，由 [_routeDelegate] 回调。
  void _handleLeaveAnimationStart() {
    _emit(
      onPageLeaveAnimationStart,
      FlLifecycleState.onPageLeaveAnimationStart,
    );
  }

  /// 退场转场动画播放完毕，由 [_routeDelegate] 回调。
  void _handleLeaveAnimationEnd() {
    _emit(onPageLeaveAnimationEnd, FlLifecycleState.onPageLeaveAnimationEnd);
  }

  /// 首帧渲染完成后，为**不在 PageView 中**的页面发出 start。
  ///
  /// 位于 PageView 中的页面不走这里——start 要等页码切到本页，由
  /// [_pageIndexDelegate] 回调 [_notifyPageStart]（首页在 `attach` 当场即可
  /// 确定，同样无需等待用户滑动）。
  ///
  /// 之所以留在首帧回调而不是跟着 `attach` 一起放进 `didChangeDependencies`：
  /// 这里是**同步**发出 start / resume 的，放进构建期会让宿主在回调里
  /// `setState` 直接报错。
  ///
  /// 已挂到路由上时还要过一道栈顶判断：页面向 [FlRouteObserver] 订阅是在
  /// `didChangeDependencies` 里，晚于 `Navigator` 同步发出的 `didPush`，因此
  /// 「本页被 push、同一帧内又被别的路由盖住」时收不到那次 stop（`initialRoute`
  /// 生成多级栈、连续两次 push 都会这样）。不加判断就会给一个从未露面的页面
  /// 发出 start，且没有配对的 stop 来纠正——之后上层被 pop 时发来的 start 会
  /// 被 `_hasAppeared` 挡掉。
  void _startIfNotInPageScope() {
    if (observePageIndex && _pageIndexDelegate.isInPageScope) {
      return;
    }
    // 只在确实挂到了路由上时才做这个判断：没有 `ModalRoute` 的页面
    // （作为普通子 Widget 嵌入）`isCurrent` 恒为 false，用它挡会永久挡死。
    // 被弹窗盖住而在这里被挡掉的页面，由 [_checkNotifyPageResume] 补发。
    if (_routeDelegate.isAttached && !_routeDelegate.isCurrent) {
      return;
    }
    _notifyPageStart();
  }

  /// PageView 切到本页时的 show，由 [_pageIndexDelegate] 回调。
  ///
  /// 与首帧的 [_startIfNotInPageScope] 共用同一道门禁：**已挂到路由上、但本页不是
  /// 所在 `Navigator` 的栈顶时不发 start**。两处是对称的——「本页所在的那一层
  /// 露出来了」不等于「本页露出来了」，还要它在自己那条路由栈里也在顶上。
  ///
  /// 没有这道门禁，「`PageView` 的一页里装了一条嵌套路由栈」会出错：栈里 push 了
  /// 第二层之后滑走再滑回，被盖住的第一层也会收到 start——它在划走时被 stop 过、
  /// `_hasAppeared` 已经是 false，幂等标志位挡不住。同理，宿主路由被别的路由盖住
  /// 期间用 `jumpToPage` 换页，换过去的那一页也不该当场 start。
  ///
  /// 被挡掉的页不会就此失联：上层 pop 时 [_checkNotifyPageStart] /
  /// [_checkNotifyPageResume] 会照常补发，它们那一侧的门禁是 [_isCurrentPage]。
  ///
  /// 没有 `ModalRoute` 的页面 `isCurrent` 恒为 false，所以先判 `isAttached`——
  /// 否则会把不在路由里的宿主永久挡死。
  void _notifyPageIndexShow() {
    if (_routeDelegate.isAttached && !_routeDelegate.isCurrent) {
      return;
    }
    _notifyPageStart();
  }

  /// 本页是不是「可以接收路由事件」的那一页。
  ///
  /// 关掉 [observePageIndex] 时恒为 true，且**短路掉**对委托的访问——
  /// 否则 `late final` 会在这里被实例化出来，白白抵消掉关开关省下的成本。
  bool get _isCurrentPage =>
      !observePageIndex || _pageIndexDelegate.isCurrentPage;

  void _checkNotifyPageStart() {
    if (!_isCurrentPage) {
      return;
    }
    _notifyPageStart();
  }

  /// 收到路由 resume（上层弹窗被 pop）。
  ///
  /// 尚未 appeared 时走 [_checkNotifyPageStart] 补发 start + resume，而不是
  /// 丢弃：页面可能在首帧就被同一帧 push 的弹窗盖住，被
  /// [_startIfNotInPageScope] 的栈顶判断挡掉了 start，此刻弹窗关闭正是它第一次
  /// 真正露面。`_didBecomeVisible` 已保证走到这里时本页确实是栈顶。
  void _checkNotifyPageResume() {
    if (_hasAppeared) {
      _notifyPageResume();
      return;
    }
    _checkNotifyPageStart();
  }

  void _checkNotifyPagePause() {
    if (_hasAppeared) {
      _notifyPagePause();
    }
  }

  void _checkNotifyPageStop() {
    if (!_isCurrentPage) {
      return;
    }
    _notifyPageStop();
  }

  /// 发一个生命周期事件：先调对应的模板回调，再把枚举值送到统一出口
  /// [onLifecycleStateChanged]。
  ///
  /// **两次调用各自独立 guard**，这是本 mixin 不漏发回调的关键：两者都是外部
  /// 代码，模板回调抛异常不该让统一出口收不到这个事件（`FlPageLifecycleView`
  /// 与 `FlPageControllerMixin` 只从统一出口拿事件，丢了就是彻底丢了），
  /// 反过来也一样。异常会照常上报，只是不再牵连调用链的其余部分，
  /// 见 [FlLifecycleGuard]。
  void _emit(VoidCallback callback, FlLifecycleState state) {
    FlLifecycleGuard.run(callback);
    FlLifecycleGuard.run(() => onLifecycleStateChanged(state));
  }

  /// 首帧回调，幂等。
  ///
  /// 抽出来是为了让 [_notifyPageStart] 能兜底补发：PageView 子页的 start 走
  /// 帧末队列，而队列的回调可能比本页自己的首帧回调注册得更早（同一帧里前一页
  /// 先排了队），不兜底的话 start 会跑到 [onPagePostFrame] 前面去。
  void _notifyPostFrame() {
    if (_hasPostFrame) {
      return;
    }
    _hasPostFrame = true;
    _emit(onPagePostFrame, FlLifecycleState.onPagePostFrame);
  }

  void _notifyPageStart() {
    if (_hasAppeared) {
      // 已可见却又收到 start：中间只经历过 pause（弹窗被 replace / remove 掉，
      // 下方页面没拿到配对的 resume），这里只补 resume，start 仍保持幂等。
      _notifyPageResume(); // 弹窗被 replace 后的 resume 补发
      return;
    }
    // 保证 onPagePostFrame 一定早于 start：此时布局与绘制已完成，宿主在
    // onPageStart 里可以直接用上量到的尺寸。
    _notifyPostFrame();
    _hasAppeared = true;
    _emit(onPageStart, FlLifecycleState.onPageStart);
    _notifyPageResume();
  }

  void _notifyPageResume() {
    if (_hasResume) {
      return;
    }
    _hasResume = true;
    _emit(onPageResume, FlLifecycleState.onPageResume);
  }

  void _notifyPagePause() {
    if (!_hasResume) {
      return;
    }
    _hasResume = false;
    _emit(onPagePause, FlLifecycleState.onPagePause);
  }

  void _notifyPageStop() {
    if (!_hasAppeared) {
      return;
    }
    _hasAppeared = false;
    _notifyPagePause();
    _emit(onPageStop, FlLifecycleState.onPageStop);
  }

  ///*********************************************

  /// 页面初始化（`State.initState`），详见 [FlLifecycleState.onPageInit]。
  ///
  /// 此时 `context` 还不能访问 `InheritedWidget`，也拿不到 `ModalRoute`。
  /// 适合创建 Controller、初始化不依赖 context 的成员。
  @protected
  void onPageInit() {}

  /// 依赖就绪、已拿到 `ModalRoute`，详见
  /// [FlLifecycleState.onPageContextReady]。
  ///
  /// 这是最早能读到 [routeName] / [arguments] 的时机，两者也直接作为参数传入。
  /// 页面不处于任何路由中时**永不触发**。
  @protected
  void onPageContextReady(String? routeName, Object? arguments) {}

  /// 首帧渲染完成，详见 [FlLifecycleState.onPagePostFrame]。
  ///
  /// 布局与绘制已完成，可安全读取 `RenderObject` 与尺寸。**一定早于**首帧的
  /// [onPageStart]，因此这里量好的尺寸在 start 里可以直接用。
  @protected
  void onPagePostFrame() {}

  /// 热重载（`State.reassemble`），**仅 Debug 模式**，
  /// 详见 [FlLifecycleState.onPageReassemble]。
  @protected
  void onPageReassemble() {}

  /// 入场转场动画开始播放（`AnimationStatus.forward`），
  /// 对应 [FlLifecycleState.onPageEnterAnimationStart]。
  ///
  /// **首次 push 入场时通常不会触发**：动画监听器在 [onPageContextReady]
  /// （首次 `didChangeDependencies`）中才由 [_routeDelegate] 绑定，
  /// 而 Navigator 在更早的 `didPush` 里就已把动画推进到 `forward`。
  /// 需要「页面开始进场」这个时机请用 [onPageContextReady]。
  ///
  /// 实际能收到的主要是动画折返：iOS 侧滑返回中途放弃，动画由 `reverse`
  /// 回到 `forward`，随后是 [onPageEnterAnimationEnd]。
  ///
  /// 与可见性状态机（[onPageStart] / [onPageResume]）无关，
  /// 不参与 `_hasAppeared` / `_hasResume` 判断，也没有幂等保证。
  @protected
  void onPageEnterAnimationStart() {}

  /// 页面变为可见，详见 [FlLifecycleState.onPageStart]。
  ///
  /// 幂等，发出后会**立即接着发出** [onPageResume]。被弹窗遮挡后再关闭
  /// **不会**重新触发本回调（页面从未 stop 过），那种情况只有 [onPageResume]。
  @protected
  void onPageStart() {}

  /// 页面变为可交互，详见 [FlLifecycleState.onPageResume]。
  ///
  /// 幂等。适合恢复动画 / 视频、恢复轮询、刷新数据、埋点页面曝光。
  @protected
  void onPageResume() {}

  /// 入场转场动画播放完毕，详见 [FlLifecycleState.onPageEnterAnimationEnd]。
  ///
  /// 适合把重量级操作（大图解码、复杂列表构建、自动弹出的引导层）推迟到转场
  /// 结束后执行，避免掉帧。
  ///
  /// **但本回调可能重复发出**：iOS 侧滑返回拖到一半放弃时，动画走
  /// `reverse → forward → completed`，`completed` 第二次到达，本回调再触发一次。
  /// 因此放在这里的网络请求、埋点上报**必须自己做幂等或去重**——否则一个常见的
  /// iOS 手势就会让它执行两遍。
  @protected
  void onPageEnterAnimationEnd() {}

  /// 退场转场动画开始播放（`AnimationStatus.reverse`），
  /// 对应 [FlLifecycleState.onPageLeaveAnimationStart]。
  ///
  /// 触发来源：自身被 pop 时动画开始反向；iOS 侧滑返回手势开始拖动。
  ///
  /// **不代表页面一定会退出**：侧滑手势中途放弃时也会触发，随后是
  /// [onPageEnterAnimationStart] → [onPageEnterAnimationEnd]，
  /// 而**不是** [onPageLeaveAnimationEnd]，页面也不会收到 pause / stop
  /// （从未真正 pop）。不可逆操作请放在 [onPageLeaveAnimationEnd] 或
  /// [onPageDispose]。
  ///
  /// 与 [onPageStop] 相互独立：普通 pop 时两者几乎同时，先后不作保证；
  /// 侧滑场景下本回调远早于 [onPageStop]（手势确认返回后才 pop）。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 页面失去交互焦点，但**可能仍然可见**，
  /// 详见 [FlLifecycleState.onPagePause]。
  ///
  /// 幂等。被 `PopupRoute` 盖住时只发本回调、不发 [onPageStop]——此刻页面还看得
  /// 见，要判断可见性用 [isPageAppeared]。适合暂停动画 / 视频、停止计时器。
  @protected
  void onPagePause() {}

  /// 页面完全不可见，详见 [FlLifecycleState.onPageStop]。
  ///
  /// 幂等，且发出前会先自动补发 [onPagePause]，因此 pause / stop 总是成对。
  @protected
  void onPageStop() {}

  /// 退场转场动画播放完毕，详见 [FlLifecycleState.onPageLeaveAnimationEnd]。
  ///
  /// 位于 [onPageStop] 之后、[onPageDispose] 之前。与
  /// [onPageLeaveAnimationStart] 不同，走到这里页面**确实**退出了，
  /// 适合放不可逆操作。
  @protected
  void onPageLeaveAnimationEnd() {}

  /// 页面销毁（`State.dispose`），详见 [FlLifecycleState.onPageDispose]。
  ///
  /// 这是**最后一个事件**，其后不会再发出任何生命周期事件。
  /// 适合释放自建的 Controller / Stream / 定时器。
  @protected
  void onPageDispose() {}

  /// App 进入 `AppLifecycleState.resumed`——**原始状态，不做过滤**，
  /// 详见 [FlLifecycleState.onAppResume]。
  ///
  /// 比 [onAppForeground] 更频繁：下拉通知栏后收起、来电挂断这类未真正离开
  /// App 的中断也会触发。需要"真的从后台回来才刷新"请用 [onAppForeground]。
  ///
  /// 需要 [observeAppLifecycle] 为 true 才会发出。
  @protected
  void onAppResume() {}

  /// App 进入 `AppLifecycleState.inactive`（可见但不可响应输入的临时中断），
  /// 详见 [FlLifecycleState.onAppInactive]。
  ///
  /// 收到时**无法判断**后续是回到前台还是进入后台。适合立即暂停视频、
  /// 遮挡敏感信息（App Switcher 截图前）。
  ///
  /// 需要 [observeAppLifecycle] 为 true 才会发出。
  @protected
  void onAppInactive() {}

  /// App 进入 `AppLifecycleState.paused`（已不可见），
  /// 详见 [FlLifecycleState.onAppPause]。
  ///
  /// 需要 [observeAppLifecycle] 为 true 才会发出。
  @protected
  void onAppPause() {}

  /// App 真正回到前台——**过滤后**的事件，
  /// 详见 [FlLifecycleState.onAppForeground]。
  ///
  /// 只有完整经历过 `paused` 再回来才发出，`inactive → resumed` 这类短暂中断
  /// 会被过滤掉。适合回到前台刷新列表、重新校验登录态、恢复轮询。
  ///
  /// 需要 [observeAppLifecycle] 为 true 才会发出。另外冷启动的那一次补发只有
  /// **首个**触发订阅的页面收得到，因此不要用它判断当前在不在前台——那请读
  /// [isForeground]。
  @protected
  void onAppForeground() {}

  /// App 进入后台——过滤后的事件，详见 [FlLifecycleState.onAppBackground]。
  ///
  /// 时机等同于 [onAppPause]。会广播给所有存活页面，包括当前不可见的页面。
  ///
  /// 需要 [observeAppLifecycle] 为 true 才会发出。
  @protected
  void onAppBackground() {}

  /// 所有生命周期事件的统一出口：上面每个回调执行完之后，都会再以对应的
  /// [FlLifecycleState] 调用一次本方法。
  ///
  /// 适合做统一埋点，或把事件转发给 Controller（配合
  /// `FlPageControllerMixin.onLifecycleChanged`）。覆写时**必须调 `super`**
  /// （已标注 `@mustCallSuper`）。
  ///
  /// 不含路由参数与 `PageView` 页码变化——它们不属于 [FlLifecycleState]，
  /// 分别走 [onPageContextReady] 与 [onPageIndexChanged]。
  @protected
  @mustCallSuper
  void onLifecycleStateChanged(FlLifecycleState state) {}

  /// PageView 页码发生变化，参数为 (旧页码, 新页码)。
  ///
  /// 仅在 [isInPageScope] 为 true 时触发，只反映**本页所在那一层**的翻页：嵌套时
  /// 外层换页不会从这里报出来，要听外层就把宿主挂在外层的 `FlPageIndexScope` 下。
  ///
  /// 三条约定：
  ///
  /// - **同一对参数**。本层每个已挂载的页收到的 `(from, to)` 完全一致，包括刚
  ///   切过去的那一页——旧页码记在层上而不是各自页上。已经被移出视口销毁的页自然
  ///   收不到，需要每页都收就配合 `keepAlive`。
  /// - **一次报到位**。`animateToPage(0 → 4)` 报的是 `(0, 4)`，不会把途中的
  ///   1 / 2 / 3 逐级报出来，见 `FlPageIndexScope` 的「提交时机」一节。
  /// - **不补发**。本层第一次确定页码时不发（没有「旧页码」）；在某次换页
  ///   **之后**才挂上来的宿主也不会补发那一次——`jumpToPage` 落地后才建出来的
  ///   新当前页、页面里后插进来的 `FlPageLifecycleView` 都属于这种。要的是
  ///   「本页成了当前页」这个信号，请用 [onPageStart]，它在这些情形下照常触发。
  @protected
  void onPageIndexChanged(int from, int to) {}

  ///*********************RouteAware 框架路由生命周期，**不允许子类重写***************************

  @internal
  @override
  @nonVirtual
  void routePageStart() {
    _checkNotifyPageStart();
  }

  @internal
  @override
  @nonVirtual
  void routePageResume() {
    _checkNotifyPageResume();
  }

  @internal
  @override
  @nonVirtual
  void routePagePause() {
    _checkNotifyPagePause();
  }

  @internal
  @override
  @nonVirtual
  void routePageStop() {
    _checkNotifyPageStop();
  }

  ///***********************************************************************************************
  @mustCallSuper
  @protected
  void appLifecycleChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _emit(onAppResume, FlLifecycleState.onAppResume);
        break;
      case AppLifecycleState.inactive:
        _emit(onAppInactive, FlLifecycleState.onAppInactive);
        break;
      case AppLifecycleState.paused:
        _emit(onAppPause, FlLifecycleState.onAppPause);
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // 有意不发事件，且**穷举列出**而不是用 `default:` 兜底：这样 Flutter
        // 以后新增 AppLifecycleState 值时这里会编译失败，强制作者做一次决策，
        // 而不是静默走掉。
        //
        // hidden 介于 inactive 与 paused 之间，前后台语义未定；
        // detached 时前后台语义已在 paused 那一步表达过，不重复发。
        break;
    }
  }
}
