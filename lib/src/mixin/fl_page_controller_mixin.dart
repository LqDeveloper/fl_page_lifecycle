import 'package:flutter/material.dart';

import '../lifecycle/fl_lifecycle_guard.dart';
import '../lifecycle/fl_lifecycle_manager.dart';
import '../lifecycle/fl_lifecycle_state.dart';

/// 在**非 Widget 类**（Controller / Presenter / ViewModel / Service）中接收
/// 页面生命周期的 mixin。
///
/// 与库内其他 mixin 的本质区别：**它不订阅任何事件源**，只提供
/// 「一个入口 + 一组模板回调 + 状态缓存」，事件必须由页面侧调用
/// [onLifecycleChanged] 转发进来。混入后若一个回调都不触发，先查转发链路。
///
/// ```dart
/// class DetailController with FlPageControllerMixin {
///   @override
///   void onPageResume() => _timer = Timer.periodic(_d, _poll);
///
///   @override
///   void onPagePause() => _timer?.cancel();
/// }
///
/// class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
///   final _controller = DetailController();
///
///   @override
///   void onLifecycleStateChanged(FlLifecycleState state) {
///     super.onLifecycleStateChanged(state); // 必须调用
///     _controller.onLifecycleChanged(state, context: context);
///   }
/// }
/// ```
///
/// 用 `FlPageLifecycleView.onStateChanged` 转发，效果等价。
///
/// 两点注意：
///
/// - 回调的触发时机、幂等性、是否重复发出**完全由转发源决定**（详见
///   [FlLifecycleState]）。绕过 `FlPageLifecycleMixin` 自行调用
///   [onLifecycleChanged]，则「start 后必跟 resume」这类保证均不成立。
/// - 不持有任何订阅，因此没有 `dispose()`；自身资源请在 [onPageDispose] 中释放。
mixin FlPageControllerMixin {
  FlLifecycleState _lifecycleState = FlLifecycleState.onPageInit;

  /// 最近一次通过 [onLifecycleChanged] 收到的事件，初值为
  /// [FlLifecycleState.onPageInit]。
  ///
  /// 记录的是「最后一个事件」而非「页面当前状态」——App 事件也会覆盖它，
  /// 此时 [isPageResume] / [isPagePause] 都会变成 `false`。
  FlLifecycleState get lifecycleState => _lifecycleState;

  /// 最后一个事件是否为 [FlLifecycleState.onPageResume]。
  bool get isPageResume => _lifecycleState.isPageResume;

  /// 最后一个事件是否为 [FlLifecycleState.onPagePause]。
  bool get isPagePause => _lifecycleState.isPagePause;

  /// App 当前是否位于前台。直接转发 [FlLifecycleManager]，
  /// 与转发进来的事件无关，任何时机都可读。
  bool get isForeground => FlLifecycleManager.instance.isForeground;

  String? _routeName;
  Object? _arguments;

  /// 路由名，由页面侧调用 [setupRouteInfo] 传入，未传时为 null。
  String? get routeName => _routeName;

  /// 路由参数，由页面侧调用 [setupRouteInfo] 传入，未传时为 null。
  Object? get arguments => _arguments;

  /// 由页面侧写入路由信息，通常在 `onPageContextReady` 时调用一次。
  void setupRouteInfo(String? name, Object? arguments) {
    _routeName = name;
    _arguments = arguments;
  }

  /// 生命周期事件入口——由页面侧调用，把 [state] 分发到对应的模板回调，
  /// 并缓存到 [lifecycleState]。[context] 只透传给 [onPageContextReady]。
  ///
  /// **覆写时必须调用 `super`**（已标注 [mustCallSuper]），否则
  /// [lifecycleState] 不再更新、模板回调也不再分发。
  @mustCallSuper
  void onLifecycleChanged(FlLifecycleState state, {BuildContext? context}) {
    _lifecycleState = state;
    // Controller 是外部代码：它的回调抛异常不该顺着转发链打回页面侧，把页面自己
    // 后续的生命周期回调一起带走（转发通常写在 `onLifecycleStateChanged` 里，
    // 那正处在页面的调用链中间）。异常照常上报，见 [FlLifecycleGuard]。
    FlLifecycleGuard.run(() => _dispatch(state, context));
  }

  void _dispatch(FlLifecycleState state, BuildContext? context) {
    switch (state) {
      case FlLifecycleState.onPageInit:
        onPageInit();
        break;
      case FlLifecycleState.onPageContextReady:
        onPageContextReady(context);
        break;
      case FlLifecycleState.onPagePostFrame:
        onPagePostFrame();
        break;
      case FlLifecycleState.onPageReassemble:
        onPageReassemble();
        break;
      case FlLifecycleState.onPageStart:
        onPageStart();
        break;
      case FlLifecycleState.onPageResume:
        onPageResume();
        break;
      case FlLifecycleState.onPageEnterAnimationStart:
        onPageEnterAnimationStart();
        break;
      case FlLifecycleState.onPageEnterAnimationEnd:
        onPageEnterAnimationEnd();
        break;
      case FlLifecycleState.onPagePause:
        onPagePause();
        break;
      case FlLifecycleState.onPageStop:
        onPageStop();
        break;
      case FlLifecycleState.onPageLeaveAnimationStart:
        onPageLeaveAnimationStart();
        break;
      case FlLifecycleState.onPageLeaveAnimationEnd:
        onPageLeaveAnimationEnd();
        break;
      case FlLifecycleState.onPageDispose:
        onPageDispose();
        break;
      case FlLifecycleState.onAppResume:
        onAppResume();
        break;
      case FlLifecycleState.onAppInactive:
        onAppInactive();
        break;
      case FlLifecycleState.onAppPause:
        onAppPause();
        break;
      case FlLifecycleState.onAppForeground:
        onAppForeground();
        break;
      case FlLifecycleState.onAppBackground:
        onAppBackground();
        break;
    }
  }

  // ── 页面生命周期回调模板（子类覆写） ───────────────────────────────

  /// 页面初始化（`State.initState`）。此时拿不到 `ModalRoute`，
  /// `context` 也不能访问 `InheritedWidget`。
  @protected
  void onPageInit() {}

  /// 依赖就绪，可安全使用 [context]（页面首次 `didChangeDependencies`
  /// 且成功拿到 `ModalRoute`）。这是唯一带参数的回调。
  ///
  /// **可能永不触发**：页面不处于任何路由中时（`ModalRoute.of` 为 null），
  /// 本回调、start / resume / pause / stop 与两个转场动画回调全部失效。
  @protected
  void onPageContextReady(BuildContext? context) {}

  /// 首帧渲染完成，可安全读取 `RenderObject` 与尺寸。
  ///
  /// 由 `FlPageLifecycleMixin` 转发时**一定早于** [onPageStart] / [onPageResume]，
  /// PageView 子页也是如此（它的 start 走帧末队列，同样排在本回调之后）。
  /// 因此可以在这里量好尺寸，[onPageStart] 里直接用。
  @protected
  void onPagePostFrame() {}

  /// 热重载，**仅 Debug 模式**。
  @protected
  void onPageReassemble() {}

  /// 页面变为可见。转发源保证发出后紧跟一次 [onPageResume]。
  @protected
  void onPageStart() {}

  /// 页面变为可交互。适合：恢复动画、刷新数据、埋点曝光。
  @protected
  void onPageResume() {}

  /// 入场转场动画开始播放。
  ///
  /// **首次进入页面时通常不会触发**：动画监听器在 `onPageContextReady` 时才
  /// 绑定，此时入场动画早已开始；需要「页面开始进场」请用 [onPageContextReady]。
  /// 实际能收到的主要是动画折返（iOS 侧滑返回中途放弃）。
  @protected
  void onPageEnterAnimationStart() {}

  /// 入场转场动画播放完毕。适合把重量级操作推迟到转场结束避免掉帧。
  /// iOS 侧滑返回中途放弃时会重复发出。
  @protected
  void onPageEnterAnimationEnd() {}

  /// 页面失去交互焦点，**可能仍然可见**（如被弹窗遮挡）。
  @protected
  void onPagePause() {}

  /// 页面完全不可见。转发源保证发出前已补发 [onPagePause]。
  @protected
  void onPageStop() {}

  /// 退场转场动画开始播放：自身被 pop，或 iOS 侧滑返回手势开始拖动。
  ///
  /// **不代表页面一定会退出**：侧滑中途放弃时也会触发，随后是
  /// [onPageEnterAnimationStart] → [onPageEnterAnimationEnd]，而**不是**
  /// [onPageLeaveAnimationEnd]。不可逆操作请放在 [onPageLeaveAnimationEnd]
  /// 或 [onPageDispose]。与 [onPageStop] 相互独立，先后顺序不作保证。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 退场转场动画播放完毕，位于 [onPageStop] 之后、[onPageDispose] 之前。
  @protected
  void onPageLeaveAnimationEnd() {}

  /// 页面销毁（`State.dispose`），能收到的**最后一个页面事件**。
  ///
  /// 本 mixin 没有自动释放机制，自身的 Stream / Timer / 订阅请在这里释放。
  @protected
  void onPageDispose() {}

  // ── App 生命周期回调模板（子类覆写） ───────────────────────────────

  /// App 从后台返回前台（对应 [AppLifecycleState.resumed]）
  @protected
  void onAppResume() {}

  /// App 即将进入非活跃状态（对应 [AppLifecycleState.inactive]）
  @protected
  void onAppInactive() {}

  /// App 进入后台（对应 [AppLifecycleState.paused]）
  @protected
  void onAppPause() {}

  /// App 切换到前台（由 [FlLifecycleManager] 判定，过滤了 transient 中断）
  @protected
  void onAppForeground() {}

  /// App 切换到后台（由 [FlLifecycleManager] 判定）
  @protected
  void onAppBackground() {}

  /// 所在 `PageView` 的页码变化，参数为 (旧页码, 新页码)。
  ///
  /// **不经 [onLifecycleChanged] 分发**——页码变化不属于 [FlLifecycleState]，
  /// 需由页面侧在 `onPageViewChanged` 中直接调用本方法转发。
  void onPageViewChanged(int from, int to) {}
}
