import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../lifecycle/fl_lifecycle_guard.dart';
import '../widget/fl_page_view_scope.dart';

/// `FlPageLifecycleMixin` 的 PageView 处理委托——把「页面是不是 `PageView` /
/// `TabBarView` 的某一页、当前有没有切到它」从生命周期状态机中独立出来。
///
/// 负责三件事，且**只**负责这三件事：
///
/// 1. [attach] 时判断宿主是否位于 `PageView` / `TabBarView` 中；
/// 2. 是则订阅最近一层 [FlPageViewScope] 推送的可见性；
/// 3. 可见性翻转时回调宿主：切到本页 [_onPageShow]、切离本页 [_onPageHide]，
///    以及页码变更本身 [_onIndexChanged]。
///
/// 判定**只有一条路径**：向上查一次 [FlPageViewScope]（`InheritedWidget` 的
/// O(1) 查找）。命中即说明构建方已显式下发页码与控制器（`PageController` 或
/// `TabController`），完全不依赖渲染树结构，也不需要宿主自行声明页码。
///
/// **嵌套由 Scope 自己解决**：每层 Scope 只订阅自己的控制器和父层的推送，把
/// 合并后的结果继续往下推。因此本委托无论嵌套多少层都只挂**一个**监听器，
/// 不做任何祖先遍历；外层 `PageView` 滑走时，内层 `TabBarView` 的当前子页
/// 同样会收到 hide。
///
/// 反过来说，**没包 [FlPageViewScope] 的子页会被当成普通页面**，首帧即发出
/// start，可见性不再随翻页变化。用 [FlPageViewScope.wrapItemBuilder] /
/// [FlPageViewScope.wrapChildren] 包一层即可。
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
class FlPageViewDelegate {
  FlPageViewDelegate({
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
  ValueListenable<FlPageViewVisibility>? _visibility;

  int _pageIndex = -1;
  int _currentIndex = -1;
  int _depth = -1;

  /// 当前判定出的可见性（Scope 推过来的最新值）。
  bool _visible = false;

  /// 已经**发出去**的可见性。与 [_visible] 不一致时才需要通知宿主。
  bool _notifiedVisible = false;

  /// 已经发出去的页码。
  int _notifiedIndex = -1;

  /// 宿主是否位于 `PageView` / `TabBarView` 中，[attach] 之前恒为 false。
  bool get isInPageView => _visibility != null;

  /// 宿主所在层当前展示的页码，未能确定时为 -1。
  int get currentIndex => _currentIndex;

  /// 宿主所在页的页码，由最近一层 [FlPageViewScope] 下发；
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
  bool get isCurrentPage => !isInPageView || _visible;

  /// 判断宿主是否位于 PageView 中，是则订阅可见性推送。
  ///
  /// 应在宿主的 `didChangeDependencies` 中调用——[FlPageViewScope] 是
  /// `InheritedWidget`，这里才是注册依赖的合法时机。
  ///
  /// **可重复调用**：Scope 未变化时直接返回，变化时（页码调整、控制器被换掉、
  /// 嵌套结构变化）会解绑旧的、重新订阅并重新判定可见性。
  ///
  /// 返回 false 表示不在 PageView 中，宿主应按普通页面处理。
  bool attach(BuildContext context) {
    final data = FlPageViewScope.maybeOf(context);
    if (data == null) {
      _unbind();
      _pageIndex = -1;
      _depth = -1;
      _visible = false;
      _currentIndex = -1;
      _notifiedVisible = false;
      _notifiedIndex = -1;
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

  /// 取消订阅。可重复调用；调用后不会再发出任何回调（终态）。
  void detach() {
    _detached = true;
    _FlPageViewFlushQueue.cancel(this);
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
    if (_visible != _notifiedVisible || _currentIndex != _notifiedIndex) {
      _FlPageViewFlushQueue.schedule(this);
    }
  }

  /// 第一阶段：只处理「切离本页」。
  ///
  /// 合并的意义不只是省一次调度：`PageController.page` 是连续值，同一轮里
  /// 翻过去又翻回来时，到这里一看状态没变，就不会发出一对根本没发生过的
  /// stop / start（对曝光埋点尤其重要）。
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
      // 已经没有下一次机会补发了（`_notifiedIndex` 还停在旧值，但只有页码再变
      // 才会重新排队）。这里之外的异常仍由队列逐个 guard 统一上报。
      FlLifecycleGuard.run(_onPageShow);
    }

    if (_currentIndex != _notifiedIndex) {
      final from = _notifiedIndex;
      _notifiedIndex = _currentIndex;
      if (from != -1) {
        _onIndexChanged(from, _currentIndex);
      }
    }
  }
}

/// 所有 [FlPageViewDelegate] 共用的两阶段通知队列。
///
/// 存在的理由是**跨页面的先后顺序**：一次切页会让两个页面同时变化，如果各自
/// 调度各自的回调，先后就取决于各页监听器的注册顺序——常驻页（`keepAlive`）
/// 的注册顺序是固定的，于是「切到下标更小的那一页」会先发 start 再发 stop。
///
/// 这里把一帧内的所有变化收进同一批，**先发完所有 hide，再发所有 show**，
/// 与注册顺序无关。顺带把整批合并成一次调度，页数再多也只排一次。
abstract final class _FlPageViewFlushQueue {
  static final Set<FlPageViewDelegate> _pending = <FlPageViewDelegate>{};
  static bool _scheduled = false;

  static void schedule(FlPageViewDelegate delegate) {
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

  static void cancel(FlPageViewDelegate delegate) => _pending.remove(delegate);

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
