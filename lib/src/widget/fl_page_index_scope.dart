import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 一层 [FlPageIndexScope] 向下推送的可见性快照。
///
/// [visible] 为 true 表示「从最外层到本层，每一层都停在本页」，宿主据此发出
/// `onPageStart` / `onPageResume`；为 false 则发出 `onPagePause` /
/// `onPageStop`。嵌套场景下外层滑走会一路推到最内层，无需任何向上遍历。
///
/// 与 [FlPageIndexScopeData] 一样是内部类型，导出时已 `hide`：包外唯一能拿到它的
/// 入口（`maybeOf`）本身就是 `@internal`，暴露一个取不到实例的类型只会
/// 让 API 文档变噪音。要在包外读可见性，用 `FlPageLifecycleMixin` 上的
/// `isPageAppeared` / `currentPageIndex` / `pageScopeDepth`。
@internal
@immutable
class FlPageIndexVisibility {
  /// 构造一份可见性快照。由 [FlPageIndexScope] 内部创建并向下推送，
  /// 使用方一般只读不建。
  const FlPageIndexVisibility({
    required this.visible,
    required this.currentIndex,
    required this.previousIndex,
    required this.generation,
    required this.depth,
  });

  /// 本层及其所有祖先层是否都停在宿主所在页。
  final bool visible;

  /// 本层当前展示的下标，尚不可用时为 -1。
  final int currentIndex;

  /// 本层上一次停在的下标，从未换过页时为 -1。
  ///
  /// 取自**层**而不是某一页：一次翻页里所有页读到的是同一对
  /// (previousIndex, currentIndex)，包括在这趟翻页途中才挂载、
  /// 自己从未见过旧页码的那些页，见 [_FlPageIndexLayer]。
  final int previousIndex;

  /// 本层换页的次数，每次 [currentIndex] 真的变化时加一。
  ///
  /// 用来区分「本层刚换了页」与「本页刚挂上来、第一次读到页码」——后者不该
  /// 补发一次早于它存在的变化。宿主侧的判据见
  /// `FlPageIndexDelegate._notifiedGeneration`。
  final int generation;

  /// 本层的嵌套深度，见 [FlPageIndexScope.depthOf]。
  final int depth;
}

/// 一层 `PageView` / `TabBarView` 共享的换页状态，按控制器区分。
///
/// 这一层的每一页各有各的 [FlPageIndexScope]，但「当前停在第几页」是**层**的
/// 属性而不是页的属性。放在页上会有个绕不过去的洞：翻页途中才挂载的页没有旧
/// 页码可言，于是 `onPageIndexChanged` 的 `from` 恒为 -1 被整条挡掉——而那通常
/// 正是**刚切过去的那一页**，最该收到事件的一页反而收不到。
///
/// 收到这里之后，一次翻页里所有页读到的是同一对 (previousIndex, currentIndex)。
///
/// 用 [Expando] 而不是 `Map`：控制器被回收时本条目跟着消失，不需要任何注销，
/// 也不会让一个早已销毁的 `PageView` 的控制器留在全局表里。
final Expando<_FlPageIndexLayer> _layers = Expando<_FlPageIndexLayer>(
  'fl_page_index_layer',
);

_FlPageIndexLayer _layerOf(Listenable controller) =>
    _layers[controller] ??= _FlPageIndexLayer();

/// 只承载「已经提交出去的页码」这一件事。
///
/// 采样（订阅控制器、读 `indexOf`）**有意留在每个 Scope 上**，没有收到这里来：
/// 收敛掉的重复劳动只有每帧 N 次几个浮点运算，量级是微秒，而把实时采样值也做成
/// 层级共享会引入一个很难看出来的失效模式——整层的 Scope 全部销毁又重建时
/// （控制器被外部持有、`PageView` 被条件渲染掉再建回来），共享值会跨过那段空窗，
/// 让重建出来的页沿用早已过时的页码。收益微乎其微，不值得换这个风险。
class _FlPageIndexLayer {
  int index = -1;
  int previousIndex = -1;
  int generation = 0;

  /// 提交一个新页码，返回值无意义——同一次翻页里本层的多个 Scope 都会调到这里，
  /// 页码没变的那些是空操作，因此它们读到的是同一对下标与同一个 generation。
  void commit(int newIndex) {
    if (index == newIndex) {
      return;
    }
    previousIndex = index;
    index = newIndex;
    generation++;
  }
}

/// 由构建 `PageView` / `TabBarView` / `IndexedStack` 的一方向下下发
/// 「页码 + 控制器」的作用域。
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
/// [FlPageIndexVisibility]；两者任一变化就重算可见性再往下推。因此：
///
/// - 单个页面只需监听最近一层，不做任何祖先遍历；
/// - 一次切页的通知量是 O(层数)，与页面数、树深度无关；
/// - 控制器每帧都在通知，但页码没变就地返回，不重算可见性；
/// - 可见性未翻转时不产生任何对象分配，滚动过程中零垃圾。
///
/// 外层 `PageView` 滑走时，内层 `TabBarView` 的当前子页同样会收到 stop；
/// 滑回来再一起收到 start。
///
/// ## IndexedStack 等非滚动容器
///
/// [controller] 除了两种滚动控制器，还接受 **`ValueListenable<int>`**——用来支持
/// `IndexedStack` 这类「所有子页都 build 出来、只显示其中一个」的容器。它们的子页
/// 同样拿不到任何「我被换下去了」的信号（`dispose` 不走，路由也没变），因此同样
/// 需要本 Scope。
///
/// 把驱动 `IndexedStack.index` 的那个 `ValueNotifier` 原样交给 Scope 即可，
/// 两者共用同一个真相来源：
///
/// ```dart
/// final _index = ValueNotifier<int>(0);
/// late final _pages = FlPageIndexScope.wrapChildren(
///   controller: _index,
///   children: const [HomeTab(), FeedTab(), MineTab()],
/// );
///
/// // 切页就改它，Scope 会自己收到通知
/// void _onTap(int i) => _index.value = i;
///
/// @override
/// Widget build(BuildContext context) => ValueListenableBuilder<int>(
///   valueListenable: _index,
///   builder: (context, index, _) =>
///       IndexedStack(index: index, children: _pages),
/// );
/// ```
///
/// 与滚动容器的唯一差别是**提交时机**：`IndexedStack` 换页是一次 `build` 的事，
/// 不存在被掠过的中间页，所以没有下面那道「停稳才提交」的门禁，改了当场就提交。
/// 其余一切相同——嵌套、深度、`onPageIndexChanged`、宿主侧的
/// [FlPageLifecycleMixin.observePageIndex] 全部照常，**两种容器也可以互相嵌套**。
///
/// 一个要留意的地方：`FlPageIndexDelegate` 那条「最近的容器没包 Scope」的 debug
/// 提示只识别 `PageView` / `TabBarView`，漏包 `IndexedStack` 时**不会提示**
/// ——`IndexedStack` 更多时候只是个布局原语，按容器报会大量误报。
///
/// ## 提交时机：停下来才算翻过去
///
/// 下面这一节**只针对滚动容器**（`PageView` / `TabBarView`），
/// `ValueListenable<int>` 驱动的容器不受这套规则约束。
///
/// 可见性**只在容器停在某一页上时提交**：手指还在拖、惯性还在跑、
/// `animateToPage` / `TabController.animateTo` 的动画还没结束，本层就先攒着不推
/// （判据是最近一层 `Scrollable` 的 `ScrollPosition.isScrollingNotifier`，
/// `TabBarView` 内部也是 `PageView`，两种控制器走的是同一条路径）。
///
/// 这条规则解决的是**假曝光**：`animateToPage(0 → 4)` 会让视口从中间三页上真的
/// 掠过去，每一页都短暂成为「当前页」。按滑过半页就提交的话，它们各自会收到一对
/// 只隔几帧的 `onPageStart` / `onPageStop`，曝光埋点凭空多出三次页面浏览，视频 /
/// 轮询也会被启停一轮。攒到停下来再看，它们从可见变回不可见全发生在冻结期内，
/// 于是一个事件都不会发出，只剩 `S0` 的 stop 与 `S4` 的 start。
///
/// 同理，半途放弃的拖动（拖过半页又拖回来松手）也不再发出任何事件，
/// [FlPageLifecycleMixin.onPageIndexChanged] 的页码则直接从 0 跳到 4，
/// 不再逐级报中间值。
///
/// 「上一次停在第几页」记在**层**上（见 [_FlPageIndexLayer]）而不是各自页上，
/// 因此这趟途中才挂载的页读到的也是同一对 `(0, 4)`。
///
/// 代价是翻一页时 start / stop 比「滑过半页」晚到约一次回弹动画的时间
/// （`jumpToPage` 不产生滚动活动，仍然当场提交）。需要在离开的瞬间就暂停视频，
/// 请配合路由事件或自行监听控制器。
///
/// 这条规则以「翻页总会停下来」为前提。容器若长期停不下来（例如一个 `duration`
/// 很长的 `animateToPage`），可见性就一直攒着不提交，start / stop 在它停下之前
/// 不会发出。要在持续滚动的容器上做可见性，请改用路由事件或自行监听控制器。
///
/// ## Scope 必须是每一页的最外层
///
/// 「本层容器停下来没有」读的是**离 Scope 最近的那个 `Scrollable`**。
/// [wrapItemBuilder] / [wrapChildren] 天然满足；自行构造时**不要**把它放进页面
/// 内部的滚动容器里（`ListView`、内层 `PageView` 等），否则门禁会绑到那个内层
/// 容器上：翻页时它恒为静止，门禁失效、假曝光回归；滚动它时外层真正的翻页反而
/// 提交不出去。debug 下会就此提示一次（`PageController` 能判定，`TabController`
/// 因为拿不到 `TabBarView` 内部的 `PageController` 判不了）。
///
/// 页面内部某个局部要跟着页码走，在那里放 `FlPageLifecycleView`
/// （`observePageIndex: true`），它会找到外层这个 Scope，不要再构造一个。
///
/// ## 用法
///
/// [controller] 支持三种：`PageController`（`PageView`）、`TabController`
/// （`TabBarView` / `TabBar`）、`ValueListenable<int>`（`IndexedStack` 等非滚动
/// 容器，见上一节）。用 [wrapItemBuilder] / [wrapChildren] 包一层即可，
/// 不引入额外布局节点：
///
/// ```dart
/// // PageView
/// final pageController = PageController();
/// PageView.builder(
///   controller: pageController,
///   itemCount: pages.length,
///   itemBuilder: FlPageIndexScope.wrapItemBuilder(
///     controller: pageController,
///     builder: (context, index) => pages[index],
///   ),
/// );
///
/// // TabBarView
/// TabBarView(
///   controller: tabController,
///   children: FlPageIndexScope.wrapChildren(
///     controller: tabController,
///     children: pages,
///   ),
/// );
/// ```
///
/// 没包 Scope 的子页会被当成普通页面：首帧即判定为可见，可见性不随翻页变化。
///
/// **嵌套时每一层都要包**。只包外层、漏掉内层不会报错：内层子页找到的最近一层
/// 是外层的 Scope，于是可见性跟着外层页码走，切内层子页不发 start / stop
/// （子页 keepAlive 时旧页会永远停在 appeared），`pageIndex` / `pageScopeDepth`
/// 读到的也是外层的值。debug 下 `FlPageIndexDelegate` 会就此提示一次。
class FlPageIndexScope extends StatefulWidget {
  /// 为 [child] 注入所在页的页码与所属控制器。
  ///
  /// 一般不直接构造，用 [wrapItemBuilder] / [wrapChildren] 包一层即可。
  /// [controller] 的实际类型必须是 `PageController`、`TabController`，
  /// 或 `IndexedStack` 这类非滚动容器用的 `ValueListenable<int>`，
  /// 构造时有断言把关。
  ///
  /// 自行构造时唯一的硬性约束：**本 Scope 必须是每一页的最外层**，不能放进页面
  /// 内部的滚动容器里——可见性的提交时机绑在离它最近的那个 `Scrollable` 上，
  /// 放错了会让「停下来才提交」的门禁失效。详见类文档的「Scope 必须是每一页的
  /// 最外层」一节，debug 下也会就此提示一次。
  FlPageIndexScope({
    super.key,
    required this.pageIndex,
    required this.controller,
    required this.child,
  }) : assert(
         controller is PageController ||
             controller is TabController ||
             controller is ValueListenable<int>,
         'controller 只支持 PageController、TabController，'
         '或 IndexedStack 这类非滚动容器用的 ValueListenable<int>，'
         '收到的是 ${controller.runtimeType}',
       );

  /// [child] 所在页的下标。
  final int pageIndex;

  /// 本层的页码来源。
  ///
  /// 实际类型必须是下面三者之一，构造时有断言把关；声明为 [Listenable]
  /// 是为了同时容纳它们：
  ///
  /// - `PageController`——`PageView`；
  /// - `TabController`——`TabBarView` / `TabBar`；
  /// - `ValueListenable<int>`——`IndexedStack` 这类非滚动容器，见类文档。
  final Listenable controller;

  /// 被注入页码的子树，由 `build` 原样返回（只多一层 `InheritedWidget`，
  /// 不引入布局节点）。
  final Widget child;

  /// 查找最近一层 Scope 下发的数据，并注册依赖。
  ///
  /// 只能在 `build` / `didChangeDependencies` 中调用。返回的
  /// [FlPageIndexScopeData] 在一页的生命周期内基本不变（只有页码或控制器被换掉
  /// 才会重建），可见性变化走 [FlPageIndexScopeData.visibility] 通知，
  /// **不触发子树重建**。
  ///
  /// 包外请用 [depthOf]，或直接读 `FlPageLifecycleMixin` 上的
  /// `isInPageScope` / `pageIndex` / `currentPageIndex` / `pageScopeDepth`。
  @internal
  static FlPageIndexScopeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FlPageIndexScopeData>();

  /// [context] 所处的 Scope 嵌套深度，取值与 `ScrollNotification.depth` 对齐：
  /// 最外层为 0，每往里嵌一层加一；不在任何 Scope 中为 -1。
  static int depthOf(BuildContext context) => maybeOf(context)?.depth ?? -1;

  /// 复位「Scope 放错位置」诊断的「已提示过」标志。**仅供测试隔离使用。**
  ///
  /// 这类诊断为了不刷屏都是进程级只提示一次，于是会跨测试用例残留：先跑的用例
  /// 触发过之后，后跑的用例就再也看不到提示，断言「应当提示」的那些会静默变成
  /// 永远通过的空壳。在 `setUp` 里调一次即可让每个用例互不影响。
  ///
  /// 生产代码不需要调用：标志只在 debug 下、且只在 `assert` 内被访问。
  @internal
  static void debugResetWarnings() =>
      _FlPageIndexScopeState._debugDidWarnForeignScrollPosition = false;

  /// 订阅哪个 [Listenable] 才能感知切页。
  ///
  /// `TabController` 本身**只在 index 提交时**发通知——它的 `offset` setter 只
  /// 改内部 `AnimationController` 的值，不调 `notifyListeners`，因此拖动过程中
  /// 完全静默。改订阅它的 `animation` 才能和 `PageController` 一样在拖动过程中
  /// 持续采到页码，两种控制器的采样时机保持一致。
  ///
  /// `PageController` 与 `ValueListenable<int>` 直接订阅自身即可。
  ///
  /// 采到的中间值什么时候才提交出去是另一回事，见类文档的「提交时机」一节。
  static Listenable listenableOf(Listenable controller) =>
      controller is TabController
      ? (controller.animation ?? controller)
      : controller;

  /// 读取 [controller] 当前展示的下标；尚不可用时返回 null。
  ///
  /// 两种控制器都取「过半即算切过去」的语义：`PageController` 用
  /// `page.round()`，`TabController` 用 `animation.value.round()`。
  ///
  /// 注意这只是**采样**：翻页过程中读到的中间值不会被提交出去，
  /// 见类文档的「提交时机」一节。
  ///
  /// `ValueListenable<int>`（`IndexedStack` 等非滚动容器）直接返回它的值，
  /// 没有采样一说——那个值就是结论。
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
    if (controller is ValueListenable<int>) {
      return controller.value;
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
    if (controller is ValueListenable<int>) {
      return controller.value;
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
      return FlPageIndexScope(
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
      (index) => FlPageIndexScope(
        pageIndex: index,
        controller: controller,
        child: children[index],
      ),
      growable: false,
    );
  }

  @override
  State<FlPageIndexScope> createState() => _FlPageIndexScopeState();
}

class _FlPageIndexScopeState extends State<FlPageIndexScope> {
  /// 本层向下推送的可见性。用 [ValueNotifier] 而非 `setState`：切页只通知
  /// 监听者，不重建子树。
  final _visibility = ValueNotifier<FlPageIndexVisibility>(
    const FlPageIndexVisibility(
      visible: false,
      currentIndex: -1,
      previousIndex: -1,
      generation: 0,
      depth: -1,
    ),
  );

  /// 父层推送过来的可见性，最外层为 null。
  ValueListenable<FlPageIndexVisibility>? _parent;

  /// 本层容器的滚动位置，用来判断「翻页停下来了没有」，见 [_isAtRest]。
  ///
  /// 取的是**最近一层 `Scrollable`** 的 position：`wrapChildren` /
  /// `wrapItemBuilder` 保证本 Scope 就是每一页的最外层，因此它必然是容器自己的
  /// `PageView`——`TabBarView` 内部也是一个 `PageView`，于是两种控制器在这里
  /// 走的是同一条路径，不需要各自发明一套「停下来了」的判定。
  ///
  /// 不在任何 `Scrollable` 中（Scope 被单独使用）时为 null，此时恒为静止，
  /// 行为与加这层门禁之前一致。
  ScrollPosition? _scrollPosition;

  /// 实际订阅的通知源，见 [FlPageIndexScope.listenableOf]。
  late Listenable _source = FlPageIndexScope.listenableOf(widget.controller);

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
  ///
  /// 同一层的每个 Scope 都会各自跑一遍这段，算出来的必然是同一个值。这份重复
  /// 是**有意留下的**，理由见 [_FlPageIndexLayer]。
  void _handleSourceChanged() {
    final index = FlPageIndexScope.indexOf(widget.controller);
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
    final parentData = FlPageIndexScope.maybeOf(context);
    final parent = parentData?.visibility;
    if (!identical(parent, _parent)) {
      _parent?.removeListener(_update);
      _parent = parent;
      _parent?.addListener(_update);
    }
    // 与 ScrollNotification.depth 对齐：最外层为 0，每往里嵌一层加一。
    _depth = parentData == null ? 0 : parentData.depth + 1;
    // `Scrollable.maybeOf` 注册的是对 position 的依赖，position 被换掉
    // （控制器换了、physics 变了）时会重新走到这里，因此这里重新绑定就够了。
    // 旧 position 的 dispose 被 `ScrollableState` 推迟到微任务，晚于本次解绑。
    //
    // 非滚动容器（`ValueListenable<int>`）**一律不绑**：它没有自己的
    // `Scrollable`，`maybeOf` 找到的必然是外面某个不相干的滚动容器
    // （`IndexedStack` 放在页面的 `ListView` 里就会这样）。绑上去会让换页的提交
    // 被那个列表的滚动状态牵着走——滚列表时换页提交不出去，停下来才补发。
    // 见 [_needsSettleGate]。
    final position = _needsSettleGate
        ? Scrollable.maybeOf(context)?.position
        : null;
    assert(_debugCheckScrollPositionBelongsToController(position));
    _bindScrollPosition(position);
    _update();
  }

  /// 本层是不是滚动型容器，需要「停稳才提交」的门禁。
  ///
  /// `PageView` / `TabBarView` 的页码来自连续采样，翻页途中会真的从中间几页上
  /// 掠过去，因此必须等停稳再提交（见类文档的「提交时机」一节）。
  /// `IndexedStack` 这类由 `ValueListenable<int>` 驱动的容器换页是瞬时的，
  /// 没有中间态可言，当场提交即可。
  bool get _needsSettleGate =>
      widget.controller is PageController || widget.controller is TabController;

  /// 整个进程只提示一次，避免每一页刷一行——放错位置的 Scope 会随每页重复实例化。
  ///
  /// 代价是它会**跨测试用例残留**，见 [FlPageIndexScope.debugResetWarnings]。
  static bool _debugDidWarnForeignScrollPosition = false;

  /// debug 下检查「[_isAtRest] 读的那个 `ScrollPosition` 是不是本层容器自己的」。
  ///
  /// 静止门禁的正确性全押在这条假设上：最近一层 `Scrollable` 就是本页所属的那个
  /// `PageView` / `TabBarView`。[wrapItemBuilder] / [wrapChildren] 把 Scope 放在
  /// 每一页的最外层，这条假设必然成立；但本类的构造函数是公开的，手写时很容易
  /// 放到页面**内部**——比如页面里套了 `ListView`，Scope 被放在列表项上。此时
  /// `Scrollable.maybeOf` 拿到的是那个 `ListView` 的 position，门禁就绑错了对象：
  ///
  /// - 翻页时内层列表恒为静止，门禁形同虚设，被 `animateToPage` 掠过去的中间页
  ///   会退回到假曝光；
  /// - 反过来，用户滚动内层列表时 `isScrolling` 为 true，外层真正的翻页反而
  ///   提交不出去，start / stop 被拖到列表停下才发。
  ///
  /// 两种表现都不报错、不打日志，所以在这里主动喊一声。
  ///
  /// 判定方法：`PageController` 是 `ScrollController`，它的 [positions] 就是
  /// 「归它管的所有滚动位置」，拿到的 position 不在其中就说明绑错了。
  ///
  /// **`TabController` 判不了**：`TabBarView` 的滚动由它内部私有的
  /// `PageController` 驱动，外部拿不到，没有可比对的 positions。这一支直接放行，
  /// 宁可漏报也不误报。
  ///
  /// 用 `debugPrint` 而不是 `assert(false)`，与本库另外两处「位置写错了」的诊断
  /// 保持一致：把 Scope 手动放在页面内部、只为让某个局部跟着页码走，是一种能
  /// 说得通的用法（尽管更该用 `FlPageLifecycleView`），不该直接崩掉 debug 构建。
  bool _debugCheckScrollPositionBelongsToController(ScrollPosition? position) {
    final controller = widget.controller;
    // position 为 null 表示 Scope 根本不在任何 Scrollable 里（单独使用），
    // 此时 [_isAtRest] 恒为 true，行为与加门禁之前一致，不是错误。
    if (position == null || controller is! ScrollController) {
      return true;
    }
    // positions 为空说明容器还没完成首次布局、或控制器刚被换掉，此刻下不了结论，
    // 留到下一次 didChangeDependencies 再看。
    if (controller.positions.isEmpty ||
        controller.positions.contains(position)) {
      return true;
    }
    if (_debugDidWarnForeignScrollPosition) {
      return true;
    }
    _debugDidWarnForeignScrollPosition = true;
    debugPrint(
      '[page_lifecycle] FlPageIndexScope(pageIndex: ${widget.pageIndex}) 离它最近的 '
      'Scrollable 不属于传进来的 ${controller.runtimeType}，说明这个 Scope 没有直接'
      '放在它所属容器的视口里（最常见的是手写时放进了页面内部的 ListView / '
      'PageView）。\n'
      '可见性的提交时机会跟着那个内层滚动容器走：翻页时它恒为静止，'
      '「停下来才提交」的门禁失效，被 animateToPage 掠过去的中间页会发出假的 '
      'onPageStart / onPageStop；而滚动内层容器时它在动，外层真正的翻页反而要等'
      '它停下才提交。\n'
      '请改用 FlPageIndexScope.wrapItemBuilder / wrapChildren，让 Scope 成为每一页'
      '的最外层；页面内部某个局部要跟着页码走，请在那里放 FlPageLifecycleView，'
      '而不是再构造一个 Scope。（本提示每次运行只输出一遍）',
    );
    return true;
  }

  @override
  void didUpdateWidget(FlPageIndexScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _source.removeListener(_handleSourceChanged);
      _source = FlPageIndexScope.listenableOf(widget.controller);
      _source.addListener(_handleSourceChanged);
      // 门禁的绑定是从 controller 派生的（见 [_needsSettleGate]），换了 controller
      // 就必须跟着重算：滚动型换成 ValueListenable<int> 后若不解绑，本层的提交会
      // 继续被那个已不相干的 Scrollable 的滚动状态卡住——它一滚，换页事件就发不
      // 出去。同类别互换时 `_ScrollableScope` 变化会触发 didChangeDependencies
      // 自愈，但跨类别互换没有那条路径，只能在这里补上。
      _bindScrollPosition(
        _needsSettleGate ? Scrollable.maybeOf(context)?.position : null,
      );
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
    _bindScrollPosition(null);
    _visibility.dispose();
    super.dispose();
  }

  void _bindScrollPosition(ScrollPosition? position) {
    if (identical(position, _scrollPosition)) {
      return;
    }
    _scrollPosition?.isScrollingNotifier.removeListener(_handleScrollSettled);
    _scrollPosition = position;
    position?.isScrollingNotifier.addListener(_handleScrollSettled);
  }

  /// 本层容器当前是不是停在某一页上：没有手指在拖，也没有惯性 / 程序化动画在跑。
  ///
  /// `isScrollingNotifier` 直接反映 `ScrollActivity.isScrolling`：`Idle` 与
  /// `Hold` 为 false，`Drag` / `Ballistic` / `Driven` 为 true，并且在活动切换时
  /// 主动通知——这正是 [_handleScrollSettled] 需要的那个边沿。翻页停下来时
  /// 不会再有新的像素通知，所以只靠订阅控制器是等不到这个时刻的。
  bool get _isAtRest => !(_scrollPosition?.isScrollingNotifier.value ?? false);

  /// 翻页停下来了，把冻结期间攒下的最终状态提交出去。
  void _handleScrollSettled() {
    if (!_isAtRest) {
      return;
    }
    _update();
  }

  /// 重算本页可见性并往下推。
  ///
  /// 由页码变化（[_handleSourceChanged]）、父层可见性翻转、依赖或页码属性变化
  /// 触发，**不是**每帧都会走到这里。结果没变仍然直接返回，既不通知也不分配对象。
  void _update() {
    // 优先用实时值；读不到就沿用上一次的（多个 PageView 共用一个 controller、
    // 或首次布局前会走到这里），从未取到过才用初始值兜底，避免长期停在
    // initialPage。
    final live = FlPageIndexScope.indexOf(widget.controller);
    if (live != null) {
      _currentIndex = live;
    } else if (_currentIndex == -1) {
      _currentIndex = FlPageIndexScope.initialIndexOf(widget.controller);
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
    // 翻页还没停下来就先攒着，等 [_handleScrollSettled] 再提交。
    // 掠过去的中间页就是在这里被吃掉的：它们从可见变回不可见都发生在冻结期内，
    // 停下来时一看与上次提交的状态一致，一个事件都不会发出。
    if (!_isAtRest) {
      return;
    }
    // 先把页码提交到层上：同一次翻页里本层每个 Scope 都会走到这里，页码没变的
    // 是空操作，于是它们向下推的 previousIndex / generation 完全一致。
    final layer = _layerOf(widget.controller);
    layer.commit(index);
    _visibility.value = FlPageIndexVisibility(
      visible: visible,
      currentIndex: index,
      previousIndex: layer.previousIndex,
      generation: layer.generation,
      depth: _depth,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlPageIndexScopeData(
      pageIndex: widget.pageIndex,
      depth: _depth,
      visibility: _visibility,
      child: widget.child,
    );
  }
}

/// [FlPageIndexScope] 实际下发给子树的 `InheritedWidget`。
///
/// 只承载「基本不变」的三样东西，因此 [updateShouldNotify] 极少为 true；
/// 频繁变化的可见性走 [visibility] 通知，不引起子树重建。
@internal
class FlPageIndexScopeData extends InheritedWidget {
  const FlPageIndexScopeData({
    super.key,
    required this.pageIndex,
    required this.depth,
    required this.visibility,
    required super.child,
  });

  /// 子树所在页在本层中的下标。
  final int pageIndex;

  /// 本层的嵌套深度，最外层为 0，见 [FlPageIndexScope.depthOf]。
  final int depth;

  /// 本层向下推送的可见性，已合并所有祖先层的结果。
  final ValueListenable<FlPageIndexVisibility> visibility;

  @override
  bool updateShouldNotify(FlPageIndexScopeData oldWidget) =>
      pageIndex != oldWidget.pageIndex ||
      depth != oldWidget.depth ||
      !identical(visibility, oldWidget.visibility);
}
