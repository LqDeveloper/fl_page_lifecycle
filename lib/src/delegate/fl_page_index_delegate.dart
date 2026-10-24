import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../lifecycle/fl_lifecycle_guard.dart';
import '../widget/fl_page_index_scope.dart';

/// `FlPageLifecycleMixin` 的 PageView 处理委托——把「页面是不是 `PageView` /
/// `TabBarView` 的某一页、当前有没有切到它」从生命周期状态机中独立出来。
///
/// 负责三件事，且**只**负责这三件事：
///
/// 1. [attach] 时判断宿主是否位于 `PageView` / `TabBarView` 中；
/// 2. 是则订阅最近一层 [FlPageIndexScope] 推送的可见性；
/// 3. 可见性翻转时回调宿主：切到本页 [_onPageShow]、切离本页 [_onPageHide]，
///    以及页码变更本身 [_onIndexChanged]。
///
/// 判定**只有一条路径**：向上查一次 [FlPageIndexScope]（`InheritedWidget` 的
/// O(1) 查找）。命中即说明构建方已显式下发页码与控制器（`PageController` 或
/// `TabController`），完全不依赖渲染树结构，也不需要宿主自行声明页码。
///
/// **嵌套由 Scope 自己解决**：每层 Scope 只订阅自己的控制器和父层的推送，把
/// 合并后的结果继续往下推。因此本委托无论嵌套多少层都只挂**一个**监听器，
/// 不做任何祖先遍历；外层 `PageView` 滑走时，内层 `TabBarView` 的当前子页
/// 同样会收到 hide。
///
/// 反过来说，**没包 [FlPageIndexScope] 的子页会被当成普通页面**，首帧即发出
/// start，可见性不再随翻页变化。用 [FlPageIndexScope.wrapItemBuilder] /
/// [FlPageIndexScope.wrapChildren] 包一层即可。嵌套时漏包内层容器更隐蔽——宿主会
/// 静默绑到外层 Scope 上，debug 下由 [_debugCheckNearestContainerWrapped] 提示。
///
/// [attach] 会当场读一次可见性，因此首页无需等待任何滑动即可被判定为当前页。
///
/// 不持有任何可见性状态（`_hasAppeared` / `_hasResume` 等），也不保证幂等，
/// 是否真的要发出 start / stop 由宿主自行判断——宿主可以用 [isCurrentPage]
/// 过滤掉「不在当前页却收到路由事件」的情况。
///
/// 生命周期：宿主在**每次** `didChangeDependencies` 中调用 [attach]
/// （Scope 未变化时是空操作），在 `dispose` 中调用一次 [detach]。
/// [attach] 返回 false 表示不在 PageView 中，此后本委托完全静默，
/// [isCurrentPage] 恒为 true。
@internal
class FlPageIndexDelegate {
  FlPageIndexDelegate({
    required VoidCallback onPageShow,
    required VoidCallback onPageHide,
    required void Function(int from, int to) onIndexChanged,
  }) : _onPageShow = onPageShow,
       _onPageHide = onPageHide,
       _onIndexChanged = onIndexChanged;

  /// 切换到宿主所在页时的回调。
  final VoidCallback _onPageShow;

  /// 从宿主所在页切走时的回调。
  final VoidCallback _onPageHide;

  /// 所在层的页码发生变化时的回调，参数为 (旧页码, 新页码)。
  /// 首次确定页码时不发出（此时没有「旧页码」）。
  final void Function(int from, int to) _onIndexChanged;

  bool _detached = false;

  /// 最近一层 Scope 推送的可见性，未命中 Scope 时为 null。
  ValueListenable<FlPageIndexVisibility>? _visibility;

  int _pageIndex = -1;
  int _currentIndex = -1;
  int _depth = -1;

  /// 当前判定出的可见性（Scope 推过来的最新值）。
  bool _visible = false;

  /// 已经**发出去**的可见性。与 [_visible] 不一致时才需要通知宿主。
  bool _notifiedVisible = false;

  /// 本层上一次停在的页码，由 Scope 随可见性一起推下来。
  int _previousIndex = -1;

  /// 本层的换页次数，见 [FlPageIndexVisibility.generation]。
  int _generation = 0;

  /// 已经就此发过 [_onIndexChanged] 的那次换页。
  ///
  /// 比的是**层**的换页次数而不是宿主自己见过的页码：后者在宿主刚挂载时恒为
  /// -1，会把「翻页途中才挂上来的页」的第一次变化整条挡掉——而那通常正是刚切
  /// 过去的那一页。改用 generation 之后，判据变成「本层在我挂上来之后有没有
  /// 换过页」，[_seed] 负责把挂载当时的值记下来当基准。
  int _notifiedGeneration = 0;

  /// 是否已经取过基准，见 [_seed]。
  bool _didSeed = false;

  /// 宿主是否位于 `PageView` / `TabBarView` 中，[attach] 之前恒为 false。
  bool get isInPageScope => _visibility != null;

  /// 宿主所在层当前展示的页码，未能确定时为 -1。
  int get currentIndex => _currentIndex;

  /// 宿主所在页的页码，由最近一层 [FlPageIndexScope] 下发；
  /// 不在 PageView 中时为 -1。
  int get pageIndex => _pageIndex;

  /// Scope 嵌套深度，取值与 `ScrollNotification.depth` 对齐：最外层为 0，
  /// 每往里嵌一层加一；不在任何 Scope 中为 -1。
  int get depth => _depth;

  /// 宿主当前是不是正在展示的那一页。
  ///
  /// 嵌套时要求**每一层**都停在本页——这一点由 Scope 逐层合并后推送过来，
  /// 这里直接读结果即可。不在 PageView 中时恒为 true，宿主据此可以无分支地写
  /// `if (isCurrentPage) notifyStart()`。
  bool get isCurrentPage => !isInPageScope || _visible;

  /// 判断宿主是否位于 PageView 中，是则订阅可见性推送。
  ///
  /// 应在宿主的 `didChangeDependencies` 中调用——[FlPageIndexScope] 是
  /// `InheritedWidget`，这里才是注册依赖的合法时机。
  ///
  /// **可重复调用**：Scope 未变化时直接返回，变化时（页码调整、控制器被换掉、
  /// 嵌套结构变化）会解绑旧的、重新订阅并重新判定可见性。
  ///
  /// 返回 false 表示不在 PageView 中，宿主应按普通页面处理。
  bool attach(BuildContext context) {
    final data = FlPageIndexScope.maybeOf(context);
    assert(_debugCheckNearestContainerWrapped(context, data));
    if (data == null) {
      _unbind();
      _pageIndex = -1;
      _depth = -1;
      _visible = false;
      _currentIndex = -1;
      _previousIndex = -1;
      _generation = 0;
      _notifiedVisible = false;
      _notifiedGeneration = 0;
      _didSeed = false;
      return false;
    }

    _pageIndex = data.pageIndex;
    _depth = data.depth;
    if (!identical(data.visibility, _visibility)) {
      _unbind();
      _visibility = data.visibility;
      data.visibility.addListener(_handleVisibilityChanged);
    }
    _sync();
    return true;
  }

  /// 每个「宿主类型 + 容器类型」的组合只提示一次，避免每页刷一行。
  ///
  /// 不像 `FlPageRouteDelegate` 那样整个进程只提示一次：这个判定**允许误报**
  /// （见下），一次误报不该把后面真正的漏包吞掉。组合数受代码里的类型数量约束，
  /// 且只在 debug 下累积。
  ///
  /// 「只提示一次」是进程级的，因此它会**跨测试用例残留**：先跑的用例把某个组合
  /// 登记掉之后，后跑的用例就再也看不到那条提示，断言「应当提示」的用例会静默
  /// 变成永远通过的空壳。测试请在 `setUp` 里调 [debugResetWarnings] 隔离。
  static final Set<String> _debugWarnedCombos = <String>{};

  /// 清掉「已提示过」的记录，让下一次检查重新提示。**仅供测试隔离使用。**
  ///
  /// 生产代码不需要调用：这张表只在 debug 下、且只在 `assert` 内被访问，
  /// release 构建里它连初始化都不会发生。
  @internal
  static void debugResetWarnings() => _debugWarnedCombos.clear();

  /// 本委托是否已经做过一次 [_debugCheckNearestContainerWrapped]。
  ///
  /// `didChangeDependencies` 会因为主题、MediaQuery 等任何依赖变化反复触发，
  /// 而这个判定要向上走祖先链（没命中 Scope 时一路走到根），不该每次都走一遍。
  /// 结构在首次挂载后才长出新的 Scope 属于极端情况，诊断做一次足够。
  bool _debugDidCheckContainer = false;

  /// debug 下检查「离宿主最近的 `PageView` / `TabBarView` 是不是真的被它绑定到的
  /// [FlPageIndexScope] 覆盖」，没覆盖就 `debugPrint` 提示一次。
  ///
  /// 宿主只认**最近一层** Scope（[attach] 里那次 O(1) 查找）。内层容器忘了包
  /// Scope 时不会报任何错，宿主会静默绑到**外层**的 Scope 上，于是：
  ///
  /// - 可见性只跟着外层页码走，切内层子页不发 start / stop——子页 keepAlive 时
  ///   旧页会永远停在 appeared，视频 / 轮询停不掉，曝光埋点重复计；
  /// - 不 keepAlive 时靠 `dispose` 兜底补发 stop，顺序还会颠倒成 start → stop，
  ///   破坏「先 hide 后 show」的保证；
  /// - [pageIndex] / [depth] 报的是外层的值，排查时极具误导性。
  ///
  /// 而**外层看上去完全正常**，所以这个坑没有任何自查手段，只能主动喊一声。
  ///
  /// 判定方法：从宿主向上走，走到绑定的那层 `FlPageIndexScopeData` 为止
  /// （没绑上就走到根）。中途撞见 `PageView` / `TabBarView` 就说明它没被 Scope
  /// 覆盖。`TabBarView` 内部就是一个 `PageView`（`NotificationListener` 包着），
  /// 因此先撞见 `PageView`、紧接着又撞见 `TabBarView` 时报后者——那是用户写下的
  /// 那个 Widget。页面内部自己套了轮播 `PageView` 的情况下，紧接着撞见的是
  /// `TabBarView` 内部的 `PageView` 而不是 `TabBarView`，不会被误升级。
  ///
  /// 用 `debugPrint` 而不是 `assert(false)`，因为**允许误报**：页面内部放一个与
  /// 生命周期无关的轮播 `PageView`，本页确实应该跟着外层页码走，此时这里也会
  /// 提示。提示文案里写明了这种情况该怎么处理。
  bool _debugCheckNearestContainerWrapped(
    BuildContext context,
    FlPageIndexScopeData? data,
  ) {
    if (_debugDidCheckContainer) {
      return true;
    }
    _debugDidCheckContainer = true;

    Widget? nearest;
    Widget? nextUp;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      // 走到绑定的那层 Scope 就收工：它到宿主之间没有别的容器，说明包对了。
      if (data != null && identical(widget, data)) {
        return false;
      }
      if (widget is! PageView && widget is! TabBarView) {
        return true;
      }
      if (nearest == null) {
        // 再往上看一层，好分辨「TabBarView 内部的 PageView」与用户自己写的
        // PageView，见方法文档。
        nearest = widget;
        return true;
      }
      nextUp = widget;
      return false;
    });

    final container = nearest;
    if (container == null) {
      return true;
    }
    final reported = container is PageView && nextUp is TabBarView
        ? nextUp!
        : container;

    final hostType = context.widget.runtimeType;
    final containerType = reported.runtimeType;
    if (!_debugWarnedCombos.add('$hostType>$containerType')) {
      return true;
    }

    final cause = data == null
        ? '向上也找不到任何 FlPageIndexScope，本页会被当成普通页面：'
              '首帧就发出 onPageStart / onPageResume，之后再也不会随切页发出 '
              'onPageStop。'
        : '于是本页绑到了更外层的 Scope（depth=${data.depth}、'
              'pageIndex=${data.pageIndex}）：可见性只跟着那一层的页码走，'
              '切换 $containerType 的子页不会发出 onPageStart / onPageStop'
              '（子页 keepAlive 时旧页会永远停在 appeared），'
              'pageIndex / pageScopeDepth 读到的也是外层的值。';

    debugPrint(
      '[page_lifecycle] $hostType 打开了 observePageIndex，但离它最近的 '
      '$containerType 没有用 FlPageIndexScope 包子页，$cause\n'
      '请给这个 $containerType 也包一层：\n'
      '  TabBarView(\n'
      '    controller: tabController,\n'
      '    children: FlPageIndexScope.wrapChildren(\n'
      '      controller: tabController, children: pages),\n'
      '  )\n'
      '  // PageView.builder 用 FlPageIndexScope.wrapItemBuilder\n'
      '如果这个 $containerType 只是页面内部的轮播、本页本来就该跟着外层页码走，'
      '忽略本提示即可；本页完全不需要按页码驱动生命周期时，'
      '把 observePageIndex 改回 false。（每个「宿主+容器」组合只输出一遍）',
    );
    return true;
  }

  /// 取消订阅。可重复调用；调用后不会再发出任何回调（终态）。
  void detach() {
    _detached = true;
    _FlPageIndexFlushQueue.cancel(this);
    _unbind();
  }

  void _unbind() {
    _visibility?.removeListener(_handleVisibilityChanged);
    _visibility = null;
  }

  void _handleVisibilityChanged() => _sync();

  /// 读取最新推送，有变化就排一次通知。
  ///
  /// 只记录状态、不直接回调：推送可能发生在 build / layout 期间（Scope 在
  /// `didChangeDependencies` 里重算），当场回调会让宿主在 `onPageStop` 里
  /// `setState` 撞上「构建期间 markNeedsBuild」。
  void _sync() {
    final value = _visibility?.value;
    if (value == null) {
      return;
    }
    _visible = value.visible;
    _currentIndex = value.currentIndex;
    _previousIndex = value.previousIndex;
    _generation = value.generation;
    _seed();
    if (_visible != _notifiedVisible || _generation != _notifiedGeneration) {
      _FlPageIndexFlushQueue.schedule(this);
    }
  }

  /// 把「本宿主挂上来时本层已经换过几次页」记为基准，只做一次。
  ///
  /// 少了它，一个挂进已经翻好页的容器里的宿主（例如 `PageView` 开了
  /// `allowImplicitScrolling` 预建相邻页、或页面里后来才插进一个
  /// `FlPageLifecycleView`）会把它出生之前的那次换页当成新事件补发一遍。
  ///
  /// 取的是**第一次收到推送时**的值而不是 `attach` 当场的值：翻页途中挂载的页，
  /// 它的 Scope 正处在冻结期（见 `FlPageIndexScope` 的「提交时机」），此刻推的还是
  /// 初始快照，generation 仍是 0，于是停下来那次换页照样算数。
  void _seed() {
    if (_didSeed) {
      return;
    }
    _didSeed = true;
    _notifiedGeneration = _generation;
  }

  /// 第一阶段：只处理「切离本页」。
  ///
  /// 合并的意义不只是省一次调度：`PageController.page` 是连续值，同一轮里
  /// 翻过去又翻回来时，到这里一看状态没变，就不会发出一对根本没发生过的
  /// stop / start（对曝光埋点尤其重要）。
  ///
  /// 跨帧的那一半由上游兜住：`FlPageIndexScope` 在容器停下来之前根本不推送，
  /// 因此被 `animateToPage` 掠过去的中间页连一次可见性变化都收不到，
  /// 见 `FlPageIndexScope` 的「提交时机」一节。这里只负责同一帧内的合并。
  void _flushHide() {
    if (_detached || _visible || !_notifiedVisible) {
      return;
    }
    _notifiedVisible = false;
    _onPageHide();
  }

  /// 第二阶段：处理「切到本页」与页码变更。
  void _flushShow() {
    if (_detached) {
      return;
    }

    if (_visible && !_notifiedVisible) {
      _notifiedVisible = true;
      // 单独兜一层：show 回调抛异常不该把下面的页码变更一起带走——那次变更
      // 已经没有下一次机会补发了（`_notifiedGeneration` 还停在旧值，但只有再
      // 换一次页才会重新排队）。这里之外的异常仍由队列逐个 guard 统一上报。
      FlLifecycleGuard.run(_onPageShow);
    }

    if (_generation != _notifiedGeneration) {
      _notifiedGeneration = _generation;
      // 本层从未换过页（刚起步那一次）时没有旧页码可言，不发。
      if (_previousIndex != -1) {
        _onIndexChanged(_previousIndex, _currentIndex);
      }
    }
  }
}

/// 所有 [FlPageIndexDelegate] 共用的两阶段通知队列。
///
/// 存在的理由是**跨页面的先后顺序**：一次切页会让两个页面同时变化，如果各自
/// 调度各自的回调，先后就取决于各页监听器的注册顺序——常驻页（`keepAlive`）
/// 的注册顺序是固定的，于是「切到下标更小的那一页」会先发 start 再发 stop。
///
/// 这里把一帧内的所有变化收进同一批，**先发完所有 hide，再发所有 show**，
/// 与注册顺序无关。顺带把整批合并成一次调度，页数再多也只排一次。
abstract final class _FlPageIndexFlushQueue {
  static final Set<FlPageIndexDelegate> _pending = <FlPageIndexDelegate>{};
  static bool _scheduled = false;

  static void schedule(FlPageIndexDelegate delegate) {
    _pending.add(delegate);
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    // 用帧末回调而不是 Timer，两点原因：
    // 1. 它在 build / layout 之后执行，宿主可以放心在 onPageStop 里 setState；
    // 2. 它不是 Timer，不会让使用方的 widget 测试报「A Timer is still pending
    //    even after the widget tree was disposed」——首帧 attach 就会排一次
    //    通知，用 Timer 的话每个测试末尾都得补 pump(Duration.zero)。
    SchedulerBinding.instance.addPostFrameCallback((_) => _flush());
    // 触发变化的操作（切页、布局）本身都会安排新帧，这里只是兜底：
    // 已排帧时是空操作。
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  static void cancel(FlPageIndexDelegate delegate) => _pending.remove(delegate);

  static void _flush() {
    _scheduled = false;
    if (_pending.isEmpty) {
      return;
    }
    final batch = _pending.toList(growable: false);
    _pending.clear();
    for (final delegate in batch) {
      FlLifecycleGuard.run(delegate._flushHide);
    }
    for (final delegate in batch) {
      FlLifecycleGuard.run(delegate._flushShow);
    }
  }
}
