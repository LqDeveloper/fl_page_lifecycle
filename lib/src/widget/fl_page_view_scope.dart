import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 一层 [FlPageViewScope] 向下推送的可见性快照。
///
/// [visible] 为 true 表示「从最外层到本层，每一层都停在本页」，宿主据此发出
/// `onPageStart` / `onPageResume`；为 false 则发出 `onPagePause` /
/// `onPageStop`。嵌套场景下外层滑走会一路推到最内层，无需任何向上遍历。
///
/// 与 [FlPageViewScopeData] 一样是内部类型，导出时已 `hide`：包外唯一能拿到它的
/// 入口（`maybeOf` / `read`）本身就是 `@internal`，暴露一个取不到实例的类型只会
/// 让 API 文档变噪音。要在包外读可见性，用 `FlPageLifecycleMixin` 上的
/// `isPageAppeared` / `currentPageIndex` / `pageViewDepth`。
@internal
@immutable
class FlPageViewVisibility {
  /// 构造一份可见性快照。由 [FlPageViewScope] 内部创建并向下推送，
  /// 使用方一般只读不建。
  const FlPageViewVisibility({
    required this.visible,
    required this.currentIndex,
    required this.depth,
  });

  /// 本层及其所有祖先层是否都停在宿主所在页。
  final bool visible;

  /// 本层当前展示的下标，尚不可用时为 -1。
  final int currentIndex;

  /// 本层的嵌套深度，见 [FlPageViewScope.depthOf]。
  final int depth;
}

/// 由构建 `PageView` / `TabBarView` 的一方向下下发「页码 + 控制器」的作用域。
///
/// `FlPageLifecycleMixin` 判断「我是不是其中的一页」时只认本 Scope：命中则直接
/// 采用页码，并通过控制器感知切页——完全不依赖渲染树结构，因此：
///
/// - 页面内部怎么嵌套、包多少层、自己有没有滚动容器，都不影响判定；
/// - 页码由框架自动下发，宿主**无需**再声明 `pageIndex`。
///
/// ## 嵌套与深度
///
/// 每嵌套一层 Scope，[depthOf] 加一。取值与 `ScrollNotification.depth` 对齐：
/// 最外层为 0，每往里嵌一层加一；不在任何 Scope 中为 -1。
/// 每层只做两件事：订阅**自己**的控制器、订阅**父层**推送的
/// [FlPageViewVisibility]；两者任一变化就重算自己的可见性再往下推。因此：
///
/// - 单个页面只需监听最近一层，不做任何祖先遍历；
/// - 一次切页的通知量是 O(层数)，与页面数、树深度无关；
/// - 控制器每帧都在通知，但页码没变就地返回，不重算可见性；
/// - 可见性未翻转时不产生任何对象分配，滚动过程中零垃圾。
///
/// 外层 `PageView` 滑走时，内层 `TabBarView` 的当前子页同样会收到 stop；
/// 滑回来再一起收到 start。
///
/// ## 用法
///
/// [controller] 支持 `PageController`（`PageView`）与 `TabController`
/// （`TabBarView` / `TabBar`），用 [wrapItemBuilder] / [wrapChildren]
/// 包一层即可，不引入额外布局节点：
///
/// ```dart
/// // PageView
/// final pageController = PageController();
/// PageView.builder(
///   controller: pageController,
///   itemCount: pages.length,
///   itemBuilder: FlPageViewScope.wrapItemBuilder(
///     controller: pageController,
///     builder: (context, index) => pages[index],
///   ),
/// );
///
/// // TabBarView
/// TabBarView(
///   controller: tabController,
///   children: FlPageViewScope.wrapChildren(
///     controller: tabController,
///     children: pages,
///   ),
/// );
/// ```
///
/// 没包 Scope 的子页会被当成普通页面：首帧即判定为可见，可见性不随翻页变化。
class FlPageViewScope extends StatefulWidget {
  /// 为 [child] 注入所在页的页码与所属控制器。
  ///
  /// 一般不直接构造，用 [wrapItemBuilder] / [wrapChildren] 包一层即可。
  /// [controller] 的实际类型必须是 `PageController` 或 `TabController`，
  /// 构造时有断言把关。
  FlPageViewScope({
    super.key,
    required this.pageIndex,
    required this.controller,
    required this.child,
  }) : assert(
         controller is PageController || controller is TabController,
         'controller 只支持 PageController 或 TabController，'
         '收到的是 ${controller.runtimeType}',
       );

  /// [child] 所在页的下标。
  final int pageIndex;

  /// 所属 `PageView` / `TabBarView` 的控制器。
  ///
  /// 实际类型必须是 `PageController` 或 `TabController`，构造时有断言把关。
  /// 声明为 [Listenable] 是为了同时容纳两者。
  final Listenable controller;

  /// 被注入页码的子树，由 `build` 原样返回（只多一层 `InheritedWidget`，
  /// 不引入布局节点）。
  final Widget child;

  /// 查找最近一层 Scope 下发的数据，并注册依赖。
  ///
  /// 只能在 `build` / `didChangeDependencies` 中调用。返回的
  /// [FlPageViewScopeData] 在一页的生命周期内基本不变（只有页码或控制器被换掉
  /// 才会重建），可见性变化走 [FlPageViewScopeData.visibility] 通知，
  /// **不触发子树重建**。
  ///
  /// 包外请用 [depthOf]，或直接读 `FlPageLifecycleMixin` 上的
  /// `isInPageView` / `pageIndex` / `currentPageIndex` / `pageViewDepth`。
  @internal
  static FlPageViewScopeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FlPageViewScopeData>();

  /// 查找最近一层 Scope 下发的数据，**不**注册依赖。
  ///
  /// 供 `build` 之外的时机一次性读取使用。
  @internal
  static FlPageViewScopeData? read(BuildContext context) =>
      context
              .getElementForInheritedWidgetOfExactType<FlPageViewScopeData>()
              ?.widget
          as FlPageViewScopeData?;

  /// [context] 所处的 Scope 嵌套深度，取值与 `ScrollNotification.depth` 对齐：
  /// 最外层为 0，每往里嵌一层加一；不在任何 Scope 中为 -1。
  static int depthOf(BuildContext context) => maybeOf(context)?.depth ?? -1;

  /// 订阅哪个 [Listenable] 才能感知切页。
  ///
  /// `TabController` 本身**只在 index 提交时**发通知——它的 `offset` setter 只
  /// 改内部 `AnimationController` 的值，不调 `notifyListeners`，因此拖动过程中
  /// 完全静默。改订阅它的 `animation` 才能和 `PageView` 一样在拖过半页时就翻转
  /// 可见性，两者时机保持一致。
  static Listenable listenableOf(Listenable controller) =>
      controller is TabController
      ? (controller.animation ?? controller)
      : controller;

  /// 读取 [controller] 当前展示的下标；尚不可用时返回 null。
  ///
  /// 两种控制器都取「过半即算切过去」的语义：`PageController` 用
  /// `page.round()`，`TabController` 用 `animation.value.round()`。
  ///
  /// 返回 null 的三种情况：`PageController` 首次布局前拿不到 `page`；
  /// 或同一个 `PageController` 被多个 `PageView` 共用（此时 `page` 本身会断言
  /// 失败，这里提前挡住）；或 `TabController` 的 `length` 为 0（没有任何一页可
  /// 言，谈不上"当前是第几页"）。调用方应沿用上一次的下标，只在从未取到过时
  /// 才用 [initialIndexOf] 兜底。
  static int? indexOf(Listenable controller) {
    if (controller is TabController) {
      // length 为 0 时下面的 clamp 上界会是 -1，`num.clamp` 在
      // upperLimit < lowerLimit 时抛 ArgumentError。tabs 动态加载、初始为空的
      // 场景会走到这里，提前挡住。
      if (controller.length == 0) {
        return null;
      }
      final animation = controller.animation;
      if (animation == null) {
        return controller.index;
      }
      // 拖动时 animation.value 会越界（overscroll），夹回合法范围。
      return animation.value.round().clamp(0, controller.length - 1);
    }
    if (controller is PageController) {
      // PageController.page 在 position 不唯一时会断言失败，先自行把关。
      if (controller.positions.length != 1) {
        return null;
      }
      return controller.page?.round();
    }
    return null;
  }

  /// [controller] 的初始下标，供 [indexOf] 尚不可用时兜底。
  static int initialIndexOf(Listenable controller) {
    if (controller is TabController) {
      return controller.index;
    }
    if (controller is PageController) {
      return controller.initialPage;
    }
    return 0;
  }

  /// 把 `PageView.builder` 的 `itemBuilder` 包一层，为每一页注入 Scope。
  ///
  /// 返回 null 的 item 原样透传（`PageView.builder` 以此表示越界）。
  static NullableIndexedWidgetBuilder wrapItemBuilder({
    required Listenable controller,
    required NullableIndexedWidgetBuilder builder,
  }) {
    return (BuildContext context, int index) {
      final child = builder(context, index);
      if (child == null) {
        return null;
      }
      return FlPageViewScope(
        pageIndex: index,
        controller: controller,
        child: child,
      );
    };
  }

  /// 把 `PageView` / `TabBarView` 的子列表逐个包上 Scope，下标即页码。
  static List<Widget> wrapChildren({
    required Listenable controller,
    required List<Widget> children,
  }) {
    return List<Widget>.generate(
      children.length,
      (index) => FlPageViewScope(
        pageIndex: index,
        controller: controller,
        child: children[index],
      ),
      growable: false,
    );
  }

  @override
  State<FlPageViewScope> createState() => _FlPageViewScopeState();
}

class _FlPageViewScopeState extends State<FlPageViewScope> {
  /// 本层向下推送的可见性。用 [ValueNotifier] 而非 `setState`：切页只通知
  /// 监听者，不重建子树。
  final _visibility = ValueNotifier<FlPageViewVisibility>(
    const FlPageViewVisibility(visible: false, currentIndex: -1, depth: -1),
  );

  /// 父层推送过来的可见性，最外层为 null。
  ValueListenable<FlPageViewVisibility>? _parent;

  /// 实际订阅的通知源，见 [FlPageViewScope.listenableOf]。
  late Listenable _source = FlPageViewScope.listenableOf(widget.controller);

  /// 最近一次确定下来的页码，-1 表示还没取到过。
  ///
  /// 既是 [_handleSourceChanged] 的比较基准，也是 [_update] 读不到实时值时的
  /// 兜底来源。控制器被换掉时要重置为 -1。
  int _currentIndex = -1;

  int _depth = 0;

  @override
  void initState() {
    super.initState();
    _source.addListener(_handleSourceChanged);
  }

  /// 控制器的通知——滚动时**每一帧**都会来。
  ///
  /// 这里只做一次取值加一次比较：页码没变就到此为止，这是滚动过程中的绝大多数
  /// 帧（一次翻页几十帧，只有跨过半页的那一帧页码才变）。真正变了才往下走
  /// [_update]，去读父层可见性、重算本页可见性、必要时分配新的快照对象。
  ///
  /// 读不到页码（首次布局前、或多个 `PageView` 共用一个控制器）时同样到此为止，
  /// 沿用 [_currentIndex]，不把已经判定好的可见性冲掉。
  void _handleSourceChanged() {
    final index = FlPageViewScope.indexOf(widget.controller);
    if (index == null || index == _currentIndex) {
      return;
    }
    _currentIndex = index;
    _update();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // O(1) 的 InheritedWidget 查找，只取直接父层——不做任何祖先链遍历。
    final parentData = FlPageViewScope.maybeOf(context);
    final parent = parentData?.visibility;
    if (!identical(parent, _parent)) {
      _parent?.removeListener(_update);
      _parent = parent;
      _parent?.addListener(_update);
    }
    // 与 ScrollNotification.depth 对齐：最外层为 0，每往里嵌一层加一。
    _depth = parentData == null ? 0 : parentData.depth + 1;
    _update();
  }

  @override
  void didUpdateWidget(FlPageViewScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _source.removeListener(_handleSourceChanged);
      _source = FlPageViewScope.listenableOf(widget.controller);
      _source.addListener(_handleSourceChanged);
      // 换了控制器，旧页码不再有参考价值，重新从新控制器解析。
      _currentIndex = -1;
      _update();
    } else if (oldWidget.pageIndex != widget.pageIndex) {
      _update();
    }
  }

  @override
  void dispose() {
    _source.removeListener(_handleSourceChanged);
    _parent?.removeListener(_update);
    _visibility.dispose();
    super.dispose();
  }

  /// 重算本页可见性并往下推。
  ///
  /// 由页码变化（[_handleSourceChanged]）、父层可见性翻转、依赖或页码属性变化
  /// 触发，**不是**每帧都会走到这里。结果没变仍然直接返回，既不通知也不分配对象。
  void _update() {
    // 优先用实时值；读不到就沿用上一次的（多个 PageView 共用一个 controller、
    // 或首次布局前会走到这里），从未取到过才用初始值兜底，避免长期停在
    // initialPage。
    final live = FlPageViewScope.indexOf(widget.controller);
    if (live != null) {
      _currentIndex = live;
    } else if (_currentIndex == -1) {
      _currentIndex = FlPageViewScope.initialIndexOf(widget.controller);
    }
    final index = _currentIndex;

    final current = _visibility.value;
    final visible =
        (_parent?.value.visible ?? true) && index == widget.pageIndex;

    if (current.visible == visible &&
        current.currentIndex == index &&
        current.depth == _depth) {
      return;
    }
    _visibility.value = FlPageViewVisibility(
      visible: visible,
      currentIndex: index,
      depth: _depth,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlPageViewScopeData(
      pageIndex: widget.pageIndex,
      depth: _depth,
      visibility: _visibility,
      child: widget.child,
    );
  }
}

/// [FlPageViewScope] 实际下发给子树的 `InheritedWidget`。
///
/// 只承载「基本不变」的三样东西，因此 [updateShouldNotify] 极少为 true；
/// 频繁变化的可见性走 [visibility] 通知，不引起子树重建。
@internal
class FlPageViewScopeData extends InheritedWidget {
  const FlPageViewScopeData({
    super.key,
    required this.pageIndex,
    required this.depth,
    required this.visibility,
    required super.child,
  });

  /// 子树所在页在本层中的下标。
  final int pageIndex;

  /// 本层的嵌套深度，最外层为 0，见 [FlPageViewScope.depthOf]。
  final int depth;

  /// 本层向下推送的可见性，已合并所有祖先层的结果。
  final ValueListenable<FlPageViewVisibility> visibility;

  @override
  bool updateShouldNotify(FlPageViewScopeData oldWidget) =>
      pageIndex != oldWidget.pageIndex ||
      depth != oldWidget.depth ||
      !identical(visibility, oldWidget.visibility);
}
