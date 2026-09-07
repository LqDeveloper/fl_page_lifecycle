import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
import 'package:flutter/material.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// PageView 场景：三个子页各自混入 `FlPageLifecycleMixin`，
/// 由 `FlPageViewScope` 下发页码与控制器来驱动可见性。
class PageViewPage extends StatefulWidget {
  const PageViewPage({super.key});

  @override
  State<PageViewPage> createState() => _PageViewPageState();
}

class _PageViewPageState extends State<PageViewPage> {
  final _controller = PageController();

  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 点击底部导航切页。
  ///
  /// `jumpToPage` / `animateToPage` 均可：子页的生命周期由 [FlPageViewScope]
  /// 下发的 `PageController` 驱动，两种切法都会通知到监听者。
  void _onTapItem(int index) {
    if (index == _index) return;
    _controller.jumpToPage(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _controller,
        physics: const NeverScrollableScrollPhysics(),
        onPageChanged: (index) => setState(() => _index = index),
        // 包一层 Scope，页码自动下发，子页无需再声明 pageIndex。
        children: FlPageViewScope.wrapChildren(
          controller: _controller,
          children: const [PageOne(), PageTwo(), PageThree()],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTapItem,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.looks_one), label: 'PageOne'),
          NavigationDestination(icon: Icon(Icons.looks_two), label: 'PageTwo'),
          NavigationDestination(icon: Icon(Icons.tab), label: 'TabBarView'),
        ],
      ),
    );
  }
}

/// 最朴素的一页：只看翻页时 start / stop 怎么走。
class PageOne extends StatefulWidget {
  const PageOne({super.key});

  @override
  State<PageOne> createState() => _PageOneState();
}

class _PageOneState extends State<PageOne>
    with FlPageLifecycleMixin, DemoLogMixin, AutomaticKeepAliveClientMixin {
  @override
  final log = LifecycleLogController(name: 'PageOne');

  /// 两个开关默认都是 false，PageView 子页要按页码驱动可见性、
  /// 并顺带演示 App 前后台，所以显式打开。
  @override
  bool get observePageView => true;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return DemoScaffold(
      title: 'PageOne',
      hint:
          '首页在 attach 当场就能确定页码，因此无需任何滑动即发出 start。'
          '左右滑动或点底部导航切页试试。',
      log: log,
    );
  }
}

/// 带弹窗与路由跳转的一页：验证「PageView 子页同样能收到路由事件」。
class PageTwo extends StatefulWidget {
  const PageTwo({super.key});

  @override
  State<PageTwo> createState() => _PageTwoState();
}

class _PageTwoState extends State<PageTwo>
    with FlPageLifecycleMixin, DemoLogMixin, AutomaticKeepAliveClientMixin {
  @override
  final log = LifecycleLogController(name: 'PageTwo');

  @override
  bool get observePageView => true;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return DemoScaffold(
      title: 'PageTwo',
      hint: 'PageView 子页同时受页码与路由驱动：翻页发 start / stop，弹窗与跳转照常生效。',
      log: log,
      actions: [
        DemoAction(
          icon: Icons.chat_bubble_outline,
          label: '弹窗',
          effect: 'pause → resume',
          onTap: () => DemoOverlays.showAlert(context),
        ),
        DemoAction(
          icon: Icons.vertical_align_bottom,
          label: 'BottomSheet',
          effect: 'pause → resume',
          onTap: () => DemoOverlays.showSheet(context),
        ),
        DemoAction(
          icon: Icons.arrow_forward,
          label: '跳转下一页',
          effect: 'pause → stop',
          onTap: () => Navigator.of(context).pushNamed('/FlPageRouteMixin_two'),
        ),
      ],
    );
  }
}

/// 第三页内部再嵌一个 `TabBarView`，演示 `FlPageViewScope` 对
/// `TabController` 的支持，以及嵌套时可见性按整条 Scope 链判定的行为。
class PageThree extends StatefulWidget {
  const PageThree({super.key});

  @override
  State<PageThree> createState() => _PageThreeState();
}

class _PageThreeState extends State<PageThree>
    with
        FlPageLifecycleMixin,
        DemoLogMixin,
        AutomaticKeepAliveClientMixin,
        SingleTickerProviderStateMixin {
  /// 外层 PageView 与内层 TabBarView 的事件汇总在同一块面板里，
  /// 用 tag 区分来源，方便观察两层可见性的联动。
  @override
  final log = LifecycleLogController(name: 'PageThree');

  @override
  String get logTag => 'PageThree';

  @override
  bool get observePageView => true;

  late final _tabController = TabController(length: 2, vsync: this);

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'PageThree · TabBarView',
          style: TextStyle(fontFamily: 'monospace', fontSize: 16),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Tab A'),
            Tab(text: 'Tab B'),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
              Text(
                '外层 PageView 与内层 TabBarView 各有一层 Scope。'
                'Tab 子页的页码来自 TabController，但可见性要求两层都在当前页——'
                '切走本页时，PageThree 与当前 Tab 会一起 stop。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 96,
                child: TabBarView(
                  controller: _tabController,
                  children: FlPageViewScope.wrapChildren(
                    controller: _tabController,
                    children: [
                      _TabChild(tag: 'Tab A', log: log),
                      _TabChild(tag: 'Tab B', log: log),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LifecycleLogPanel(
                  controller: log,
                  title: '事件日志（外层 PageView + 内层 TabBarView）',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// TabBarView 的一个子页，页码由内层 `FlPageViewScope` 下发的
/// `TabController` 决定。
class _TabChild extends StatefulWidget {
  const _TabChild({required this.tag, required this.log});

  final String tag;
  final LifecycleLogController log;

  @override
  State<_TabChild> createState() => _TabChildState();
}

class _TabChildState extends State<_TabChild>
    with FlPageLifecycleMixin, DemoLogMixin, AutomaticKeepAliveClientMixin {
  @override
  LifecycleLogController get log => widget.log;

  @override
  String get logTag => widget.tag;

  /// 内层 TabBarView 的子页同样要走页码判定。
  @override
  bool get observePageView => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '${widget.tag}（pageIndex = $pageIndex, depth = $pageViewDepth）',
        style: theme.textTheme.labelLarge?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
