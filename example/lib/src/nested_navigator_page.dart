import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
import 'package:flutter/material.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// 多 Navigator 场景：根 `Navigator` 挂 [FlRouteObserver]，
/// 每个嵌套 `Navigator` 各挂一个 [FlRouteObserverProxy]。
///
/// ## 为什么嵌套的那个不能也用 FlRouteObserver
///
/// [FlRouteObserver] 是单例，而 Flutter 的 `Navigator.initState` 里有
/// `assert(observer.navigator == null)`——一个 `NavigatorObserver` 实例同一时刻
/// 只能绑定一个 `NavigatorState`。把单例挂到第二个 `Navigator` 上，debug 下会
/// 直接断言失败。[FlRouteObserverProxy] 每次构造都是新实例，事件转发给同一个
/// `FlRouteObserver.instance`，因此订阅表仍然只有一份。
///
/// ## 本页的结构
///
/// 一个 `PageView` 装两条**各自独立的路由栈**——这是 go_router 的
/// `StatefulShellRoute`、以及大多数手写 tab 方案的形状：
///
/// ```
/// PageView
///   └ FlPageIndexScope（wrapChildren 自动包）
///       └ AutomaticKeepAliveClientMixin
///           └ FlPageLifecycleView(observePageIndex: true)   ← 监听翻页
///               └ Navigator(observers: [FlRouteObserverProxy()])  ← 监听本栈路由
///                   └ 栈内各页（FlPageLifecycleMixin）
/// ```
///
/// 两条栈同时存活，正是单例挂不住的那种场景。
///
/// ## 两层监听，合起来才是「本页可见吗」
///
/// 日志里能看到两类来源，这是本页最值得看的地方：
///
/// - **`栈 X 容器`**：由 [FlPageLifecycleView] 发出，粒度是**整条栈**。
///   左右滑动时一条栈整体 pause/stop、另一条 start/resume，适合挂 tab 级别的
///   轮询、预加载这类东西。
/// - **`栈 X#n`**：栈内页面自己发出。它们**同时**订阅了两个来源——本栈的路由
///   （靠 [FlRouteObserverProxy]）和外层的 `PageView` 页码（靠 `observePageIndex`）。
///
/// 于是栈内页的可见性是两个条件的合取：**本栈是当前页** 且 **本页是本栈的栈顶**。
/// 具体表现：
///
/// - 在栈 A 里 push 到第 1 层，再滑到栈 B —— A#1 收到 pause+stop；
/// - 滑回栈 A —— **只有 A#1 复活**，被它盖住的 A#0 保持 stopped；
/// - 在栈 A 不可见时 pop 掉 A#1 —— 谁都不发 start，等滑回来才轮到 A#0。
///
/// ## 两个容易写错的地方
///
/// **栈内页要开 `observePageIndex`。** 不开的话它只跟本栈的路由走，整条栈被划走时
/// 毫无反应——视频照播、轮询照跑。开了之后才有上面那个合取语义。
///
/// **子页用 `AutomaticKeepAliveClientMixin` 常驻。** `PageView` 默认不保留划走
/// 的子页，不加这一层的话滑到栈 B 再滑回来，栈 A 里 push 出来的层会连同整个
/// `Navigator` 一起被销毁、退回第 0 层——那不是生命周期的问题，而是没常驻。
class NestedNavigatorPage extends StatefulWidget {
  const NestedNavigatorPage({super.key});

  @override
  State<NestedNavigatorPage> createState() => _NestedNavigatorPageState();
}

class _NestedNavigatorPageState extends State<NestedNavigatorPage> {
  final _controller = PageController();

  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapTab(int index) {
    if (index == _index) {
      return;
    }
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'FlRouteObserverProxy',
          style: TextStyle(fontFamily: 'monospace', fontSize: 16),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTapTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.looks_one), label: '栈 A'),
          NavigationDestination(icon: Icon(Icons.looks_two), label: '栈 B'),
        ],
      ),
      body: PageView(
        controller: _controller,
        onPageChanged: (index) => setState(() => _index = index),
        // 包一层 Scope，页码自动下发。容器层的 FlPageLifecycleView 靠它拿到
        // 「本栈现在是不是当前页」。
        children: FlPageIndexScope.wrapChildren(
          controller: _controller,
          children: const [
            _TabStack(name: '栈 A'),
            _TabStack(name: '栈 B'),
          ],
        ),
      ),
    );
  }
}

/// 一条独立的路由栈：外面一层监听翻页，里面一层监听本栈路由。
///
/// **日志按栈隔离**：每条栈各持有一块面板，你在哪条栈就只看到哪条栈的事件。
/// 栈内的容器层与各层页面共用本栈这一块（与 `PageViewPage` 里 PageThree 和它
/// 内层 TabBarView 子页的关系一致），靠 tag 区分是「容器」还是第几层。
class _TabStack extends StatefulWidget {
  const _TabStack({required this.name});

  final String name;

  @override
  State<_TabStack> createState() => _TabStackState();
}

class _TabStackState extends State<_TabStack> {
  late final _log = LifecycleLogController(name: widget.name);

  @override
  void dispose() {
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _KeepAlive(
      // 容器层：跟着 PageView 页码走，滑动时整条栈一起 start / stop。
      // 挂在这里而不是挂在栈内页面上，理由见本文件顶部的类文档。
      child: FlPageLifecycleView(
        observePageIndex: true,
        // 与栈内页一致，只记四个可见性事件，见 [visibilityStates]。
        onStateChanged: (_, state) {
          if (!visibilityStates.contains(state)) {
            return;
          }
          _log.log(state.name, tag: '容器');
        },
        child: Navigator(
          // 每个嵌套 Navigator 各一个新实例。复用同一个 proxy 会触发和复用
          // FlRouteObserver 一样的断言——proxy 是无状态的，该 new 就 new。
          observers: [FlRouteObserverProxy()],
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => _StackPage(depth: 0, log: _log),
          ),
        ),
      ),
    );
  }
}

/// 让 `PageView` 划走的子页保持存活，否则整条栈会被销毁重建。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 栈里的一页，混入 [FlPageLifecycleMixin] 后事件走 [DemoLogMixin] 落到日志上。
class _StackPage extends StatefulWidget {
  const _StackPage({required this.depth, required this.log});

  final int depth;
  final LifecycleLogController log;

  @override
  State<_StackPage> createState() => _StackPageState();
}

class _StackPageState extends State<_StackPage>
    with FlPageLifecycleMixin, DemoLogMixin {
  /// 跟着容器所在的 `PageView` 页码走：整条栈被划走时本页也走不显示逻辑。
  ///
  /// 本页向上找到的最近一层 `FlPageIndexScope` 就是包住整条栈的那一层——嵌套
  /// `Navigator` 不打断 `InheritedWidget` 查找。可见性因此是两个条件的合取：
  /// **本栈是当前页** 且 **本页是本栈的栈顶**。后半个条件由 mixin 在
  /// PageView 的 show 路径上做栈顶判断保证，所以划回来时只有栈顶那页复活。
  @override
  bool get observePageIndex => true;

  @override
  LifecycleLogController get log => widget.log;

  /// 本页只看 start / resume / pause / stop 的配对与时序，
  /// 其余十几个事件会把这条主线淹掉。
  @override
  Set<FlLifecycleState>? get loggedStates => visibilityStates;

  /// 面板已按栈隔离，这里只需区分第几层。
  @override
  String get logTag => '#${widget.depth}';

  void _push() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _StackPage(depth: widget.depth + 1, log: widget.log),
      ),
    );
  }

  void _pushReplacement() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => _StackPage(depth: widget.depth + 1, log: widget.log),
      ),
    );
  }

  /// `useRootNavigator: false` 是关键：默认的 true 会把弹窗推到根 Navigator 上，
  /// 那样本页收不到 pause。
  void _showDialogInThisStack() {
    showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('内层弹窗'),
        content: const Text(
          '弹窗是 PopupRoute，下方页面仍可见，因此只发 onPagePause，不发 onPageStop；'
          '关闭后只补 onPageResume。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();

    return DemoScaffold(
      appBar: false,
      // 面板按栈隔离，控制器的 name 就是栈名。
      title: '${widget.log.name} 第 ${widget.depth} 层',
      log: widget.log,
      hint:
          '本页同时订阅了两个来源：本栈的路由（FlRouteObserverProxy 转发）'
          '和外层 PageView 的页码（observePageIndex）。所以「可见」= 本栈是当前页 '
          '且 本页是本栈栈顶。试试：push 到第 1 层 → 滑到栈 B（第 1 层 stop）'
          ' → 滑回来（只有第 1 层复活，第 0 层仍是 stopped）。',
      actions: [
        DemoAction(
          icon: Icons.add,
          label: 'push 下一层',
          effect: '本页 pause+stop\n新页 start+resume',
          onTap: _push,
        ),
        DemoAction(
          icon: Icons.swap_horiz,
          label: 'pushReplacement',
          effect: '本页 pause+stop\n（didReplace 转发）',
          onTap: _pushReplacement,
        ),
        DemoAction(
          icon: Icons.chat_bubble_outline,
          label: '内层弹窗',
          effect: '只 pause\n关闭补 resume',
          onTap: _showDialogInThisStack,
        ),
        if (canPop)
          DemoAction(
            icon: Icons.arrow_back,
            label: 'pop 回上层',
            effect: '本页 pause+stop\n下层 start+resume',
            onTap: () => Navigator.of(context).pop(),
          ),
      ],
      // 两条栈共用一个 controller，因此任意一页看到的都是全量事件。
      logTitle: '${widget.log.name} 的事件（容器层 + 本栈各层）',
    );
  }
}
