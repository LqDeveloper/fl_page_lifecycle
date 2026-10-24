import 'package:flutter/material.dart';

import '../lifecycle/fl_lifecycle_state.dart';
import '../mixin/fl_page_lifecycle_mixin.dart';
import 'fl_page_index_scope.dart';

/// 生命周期事件回调。[context] 是内部 `State` 的 context。
///
/// 两个时机不要拿它去查 `InheritedWidget`（`Theme.of` / `ModalRoute.of` 等）：
/// `onPageInit` 时还没挂上路由树，`onPageDispose` 时 `State` 正在 unmount，
/// 此刻访问会抛异常。需要在这两处用到的数据，请提前在别的回调里取好。
typedef FlPageLifecycleCallback =
    void Function(BuildContext context, FlLifecycleState state);

/// 路由参数就绪（`onPageContextReady`）回调。
typedef FlPageRouteParamCallback =
    void Function(BuildContext context, String? routeName, Object? arguments);

/// PageView 页码变化回调，参数为 (旧页码, 新页码)。
typedef FlPageIndexChangedCallback =
    void Function(BuildContext context, int from, int to);

/// 以「包一层 Widget」的方式获取页面生命周期，无需在 `State` 上混入
/// [FlPageLifecycleMixin]。
///
/// 内部维护一个混入了 [FlPageLifecycleMixin] 的 `State`，把事件通过回调抛出，
/// `build` 原样返回 [child]（不引入额外布局节点）。适用于：页面是
/// `StatelessWidget`、`State` 不便再混入、想把生命周期转发给 Controller
/// （配合 `FlPageControllerMixin`）、或临时给某个子树加埋点。
///
/// ```dart
/// FlPageLifecycleView(
///   onStateChanged: (context, state) =>
///       controller.onLifecycleChanged(state, context: context),
///   child: const DetailBody(),
/// )
/// ```
///
/// 触发时机与幂等保证均与 [FlPageLifecycleMixin] 一致，详见
/// [FlLifecycleState] 的文档。本 Widget 只暴露事件流，mixin 的 `routeName` /
/// `arguments` / `isInPageScope` 等 getter 不对外可见。
///
/// ## 实例成本
///
/// 每个 [FlPageLifecycleView] 内部都是一套完整的 [FlPageLifecycleMixin]：1 次
/// `FlRouteObserver` 订阅、1 个首帧回调，[observeAppLifecycle] 打开后再加
/// **2 条全局广播流订阅**（App 前后台 + `AppLifecycleState`）。一个路由页
/// 放几个完全无所谓，但用在列表项上要留意——几百个实例乘以每项的订阅数，
/// 且 App 每次前后台切换都要在同一帧内同步 fan-out 给全部实例。
///
/// 两个 observe 开关默认都是 `false`，正是为了让大量实例（例如给每个卡片
/// 单独埋曝光）的场景开箱即省掉占大头的两条流订阅。
class FlPageLifecycleView extends StatefulWidget {
  /// 是否启用 PageView 可见性判定，见 [FlPageLifecycleMixin.observePageIndex]。
  /// 默认 `false`，与 mixin 一致。
  ///
  /// 为 `true` 时在 `didChangeDependencies` 中查找 [FlPageIndexScope]，命中即由
  /// 页码变化（而非路由变化）驱动 start / stop。为 `false`、或位于 `PageView`
  /// 中却没包 [FlPageIndexScope] 时，首帧直接发出 `onPageStart` → `onPageResume`。
  ///
  /// **同一个 `FlPageLifecycleView` 上必须始终传同一个值**（debug 下有断言把关）：
  /// 可见性状态机是有状态的，中途翻转会留下对不齐的中间态。
  final bool observePageIndex;

  /// 是否订阅 App 前后台事件，见 [FlPageLifecycleMixin.observeAppLifecycle]。
  ///
  /// 默认 `false`，与 mixin 一致：`onAppForeground` / `onAppBackground` /
  /// `onAppResume` / `onAppInactive` / `onAppPause` 五个枚举事件不会通过
  /// [onStateChanged] 抛出，页面生命周期事件不受影响，每个实例省下两条全局
  /// 流订阅。需要 App 事件时传 `true`。
  ///
  /// 只在内部 `State` 的 `initState` 中读取一次，运行时改变无效，
  /// 因此**必须始终传同一个值**（debug 下有断言把关）。
  final bool observeAppLifecycle;

  /// 生命周期事件回调，在 [FlPageLifecycleMixin] 对应的 `protected` 回调
  /// 执行完之后抛出。`onPageDispose` 是最后一次回调。
  ///
  /// 不含路由参数与页码变化，它们不属于 [FlLifecycleState] 枚举，
  /// 分别走 [onRouteParam] 与 [onPageIndexChanged]。
  final FlPageLifecycleCallback? onStateChanged;

  /// 路由参数就绪。未注册 `FlRouteObserver` 或页面没有 `ModalRoute` 时不触发。
  final FlPageRouteParamCallback? onRouteParam;

  /// PageView 页码变化，见 [FlPageLifecycleMixin.onPageIndexChanged] 的三条约定。
  ///
  /// 仅在命中 [FlPageIndexScope] 时触发。注意本 Widget 很容易踩到其中的「不补发」：
  /// 把它条件渲染进一个已经翻好页的容器里时，它出生之前的那次换页不会补发。
  final FlPageIndexChangedCallback? onPageIndexChanged;

  /// 被观察的子树，由 `build` 原样返回。
  final Widget child;

  /// 包一层即可观察 [child] 所在页面的生命周期，事件通过回调抛出。
  ///
  /// 三个回调都是可选的，全不传时本 Widget 只是一层透明包装。
  const FlPageLifecycleView({
    super.key,
    this.observePageIndex = false,
    this.observeAppLifecycle = false,
    this.onStateChanged,
    this.onRouteParam,
    this.onPageIndexChanged,
    required this.child,
  });

  @override
  State<FlPageLifecycleView> createState() => _FlPageLifecycleViewState();
}

class _FlPageLifecycleViewState extends State<FlPageLifecycleView>
    with FlPageLifecycleMixin {
  @override
  bool get observePageIndex => widget.observePageIndex;

  @override
  bool get observeAppLifecycle => widget.observeAppLifecycle;

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);
    widget.onStateChanged?.call(context, state);
  }

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    widget.onRouteParam?.call(context, routeName, arguments);
  }

  @override
  void onPageIndexChanged(int from, int to) {
    widget.onPageIndexChanged?.call(context, from, to);
  }
}
