import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
import 'package:flutter/material.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// `IndexedStack` 场景：三个子页共用一块日志面板，由 [FlPageIndexScope] 接一个
/// `ValueListenable<int>` 来驱动可见性。
///
/// ## 为什么 IndexedStack 也需要 Scope
///
/// `IndexedStack` 会把**所有**子页都 build 出来、`State` 全部存活，只绘制 `index`
/// 指定的那一个。于是被换下去的子页拿不到任何信号：`dispose` 不走、路由也没变，
/// 视频照播、轮询照跑。包一层 Scope，子页开 `observePageIndex` 就有了
/// start / resume / pause / stop。
///
/// ## 接法：让 Scope 和 IndexedStack 共用同一个真相来源
///
/// `IndexedStack` 没有控制器，页码就是个 `int`。把它放进 [ValueNotifier]，
/// 一份给 `IndexedStack.index`，一份给 [FlPageIndexScope.wrapChildren] 的
/// `controller`——两边读的是同一个值，不可能对不上：
///
/// ```dart
/// final _index = ValueNotifier<int>(0);
/// late final _pages = FlPageIndexScope.wrapChildren(
///   controller: _index,
///   children: const [...],
/// );
///
/// void _onTap(int i) => _index.value = i;   // 切页只改它
///
/// ValueListenableBuilder<int>(
///   valueListenable: _index,
///   builder: (context, index, _) =>
///       IndexedStack(index: index, children: _pages),
/// );
/// ```
///
/// `_pages` 只建一次：包装结果与当前页码无关，切页不需要重算。
///
/// ## 与 PageView 的唯一差别：提交时机
///
/// `PageView` 要等容器**停稳**才提交可见性，为的是让 `animateToPage(0 → 4)`
/// 掠过去的中间页不产生假曝光。`IndexedStack` 换页是一次 `build` 的事，没有中间
/// 态可言，所以**改了当场就提交**。其余完全一致——嵌套、深度、
/// `onPageIndexChanged`、宿主侧开关都按同一套规则走。
///
/// 也因此，本页的 `IndexedStack` 即使放在一个滚动容器里，换页也不会被那个容器的
/// 滚动状态拖住（Scope 对非滚动容器不绑 `Scrollable`）。
class IndexedStackPage extends StatefulWidget {
  const IndexedStackPage({super.key});

  @override
  State<IndexedStackPage> createState() => _IndexedStackPageState();
}

class _IndexedStackPageState extends State<IndexedStackPage> {
  /// 唯一的页码来源：既驱动 `IndexedStack.index`，也驱动 Scope。
  final _index = ValueNotifier<int>(0);

  /// 包装结果与页码无关，只建一次。
  ///
  /// 每个子页各自持有一块面板（与 `PageViewPage` 的 PageOne / PageTwo 一致），
  /// 因此这里不再下发共用的日志控制器——你在哪一页就只看到哪一页的事件。
  late final List<Widget> _pages = FlPageIndexScope.wrapChildren(
    controller: _index,
    children: const [
      _StackTab(name: 'Tab0'),
      _StackTab(name: 'Tab1'),
      _StackTab(name: 'Tab2'),
    ],
  );

  @override
  void dispose() {
    _index.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'IndexedStack',
          style: TextStyle(fontFamily: 'monospace', fontSize: 16),
        ),
      ),
      bottomNavigationBar: ValueListenableBuilder<int>(
        valueListenable: _index,
        builder: (context, index, _) => NavigationBar(
          selectedIndex: index,
          // 切页只改这一个值，Scope 会自己收到通知。
          onDestinationSelected: (i) => _index.value = i,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.looks_one), label: 'Tab0'),
            NavigationDestination(icon: Icon(Icons.looks_two), label: 'Tab1'),
            NavigationDestination(icon: Icon(Icons.looks_3), label: 'Tab2'),
          ],
        ),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _index,
        builder: (context, index, _) =>
            IndexedStack(index: index, children: _pages),
      ),
    );
  }
}

/// 一个子页。**不需要** `AutomaticKeepAliveClientMixin`——`IndexedStack` 本来就
/// 保留全部子页，这正是它与 `PageView` 的区别，也正是它需要 Scope 的原因。
class _StackTab extends StatefulWidget {
  const _StackTab({required this.name});

  final String name;

  @override
  State<_StackTab> createState() => _StackTabState();
}

class _StackTabState extends State<_StackTab>
    with FlPageLifecycleMixin, DemoLogMixin {
  /// 本页自己的日志，只记本页的事件——不再与其他子页混在一块面板里。
  @override
  late final LifecycleLogController log = LifecycleLogController(
    name: widget.name,
  );

  /// 本页只看 start / resume / pause / stop 的配对与时序，
  /// 其余十几个事件会把这条主线淹掉。
  @override
  Set<FlLifecycleState>? get loggedStates => visibilityStates;

  @override
  void dispose() {
    log.dispose();
    super.dispose();
  }

  /// 跟着 `IndexedStack` 的页码走。不开的话三个子页会在首帧一起 start，
  /// 之后再也不发 stop——那正是不包 Scope 时的表现。
  @override
  bool get observePageIndex => true;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      appBar: false,
      title: widget.name,
      log: log,
      logTitle: '${widget.name} 的事件',
      // 这里只读 pageIndex / pageScopeDepth 这类**不随切页变化**的值：切页时
      // IndexedStack 拿到的是同一批 widget 实例，子页并不会重建，写
      // currentPageIndex 会一直显示陈旧值。可见性本身不依赖重建——Scope 直接
      // 监听 ValueNotifier，这正是它不需要 setState 的原因。
      hint:
          '${widget.name}：pageIndex=$pageIndex，depth=$pageScopeDepth。'
          '点底部导航切页——被换下去的那页立刻 pause+stop，换上来的立刻 '
          'start+resume，没有 PageView 那道「等停稳」的延迟。'
          '注意本页没有 keepAlive：IndexedStack 本来就保留所有子页，'
          '这也正是它需要 Scope 的原因。',
      actions: [
        DemoAction(
          icon: Icons.chat_bubble_outline,
          label: '弹窗',
          effect: 'pause → resume',
          onTap: () => DemoOverlays.showAlert(context),
        ),
        DemoAction(
          icon: Icons.arrow_forward,
          label: '跳转新页面',
          effect: 'pause → stop',
          onTap: () => Navigator.of(context).pushNamed('/FlPageRouteMixin_two'),
        ),
      ],
    );
  }
}
