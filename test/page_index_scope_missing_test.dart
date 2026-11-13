import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
import 'package:fl_page_lifecycle/src/delegate/fl_page_index_delegate.dart';

// 漏包 `FlPageIndexScope` 的 debug 诊断。
//
// 诊断只提示一次，去重键是「宿主类型 + 容器类型」的组合，且这张表是进程级的。
// 每个用例跑前调一次 `FlPageIndexDelegate.debugResetWarnings` 把它清掉，
// 用例之间才互不影响。下面各用例仍用各自的宿主类型，是为了让断言里的类型名
// 一眼对得上，不再是为了绕开残留。

/// 跑 [body] 并收集它打出的本诊断提示。
///
/// `debugPrint` 必须在测试体**内**还原：`flutter_test` 在每个测试体结束时
/// （早于 `addTearDown` 的回调）校验 foundation 的 debug 变量有没有被改过。
///
/// 同一进程里还有「没注册 FlRouteObserver」那条提示，按关键字挑出本诊断。
Future<List<String>> captureWarnings(Future<void> Function() body) async {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) {
      logs.add(message);
    }
  };
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return logs.where((m) => m.contains('没有用 FlPageIndexScope 包子页')).toList();
}

void main() {
  // 隔离进程级的「已提示过」组合表，让用例之间互不影响、顺序无关。
  setUp(FlPageIndexDelegate.debugResetWarnings);

  testWidgets('包对了就不提示', (tester) async {
    final tab = TabController(length: 2, vsync: const TestVSync());
    addTearDown(tab.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: TabBarView(
            controller: tab,
            children: FlPageIndexScope.wrapChildren(
              controller: tab,
              children: const <Widget>[_WrappedHost(), _WrappedHost()],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(warnings, isEmpty);
  });

  testWidgets('内层 TabBarView 漏包：提示，且报 TabBarView 而不是它内部的 PageView', (
    tester,
  ) async {
    final page = PageController();
    addTearDown(page.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: PageView.builder(
            controller: page,
            itemCount: 2,
            itemBuilder: FlPageIndexScope.wrapItemBuilder(
              controller: page,
              builder: (_, _) => const _BareTabs(host: _InnerHost()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(warnings, hasLength(1));
    final message = warnings.single;
    expect(message, contains('_InnerHost'));
    // TabBarView 内部就是 PageView，报的必须是用户写下的那个 Widget。
    expect(message, contains('最近的 TabBarView 没有用 FlPageIndexScope 包子页'));
    // 绑到了外层 Scope，文案要说清楚绑到了哪一层。
    expect(message, contains('绑到了更外层的 Scope（depth=0'));
  });

  testWidgets('一个 Scope 都没有：提示，且文案是「找不到任何 FlPageIndexScope」', (tester) async {
    final page = PageController();
    addTearDown(page.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: PageView(
            controller: page,
            children: const <Widget>[_LooseHost(), _LooseHost()],
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(warnings, hasLength(1));
    expect(warnings.single, contains('_LooseHost'));
    expect(warnings.single, contains('最近的 PageView 没有用 FlPageIndexScope 包子页'));
    expect(warnings.single, contains('找不到任何 FlPageIndexScope'));
  });

  testWidgets('页面内部的轮播 PageView：报 PageView，不会误升级成外层的 TabBarView', (
    tester,
  ) async {
    final tab = TabController(length: 2, vsync: const TestVSync());
    addTearDown(tab.dispose);
    final banner = PageController();
    addTearDown(banner.dispose);

    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: TabBarView(
            controller: tab,
            children: FlPageIndexScope.wrapChildren(
              controller: tab,
              children: <Widget>[
                // 页面内部自己的轮播，与生命周期无关——这是允许的误报场景，
                // 但报出来的必须是这个 PageView，而不是外面的 TabBarView。
                PageView(
                  controller: banner,
                  children: const <Widget>[_BannerHost(), _BannerHost()],
                ),
                const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(warnings, hasLength(1));
    expect(warnings.single, contains('_BannerHost'));
    expect(warnings.single, contains('最近的 PageView 没有用 FlPageIndexScope 包子页'));
  });

  testWidgets('同一组合只提示一遍', (tester) async {
    final page = PageController();
    addTearDown(page.dispose);

    // 同一个用例内挂三个实例，验证「同一组合只输出一次」的去重确实生效。
    // （用例之间的隔离由 setUp 的 debugResetWarnings 负责。）
    final warnings = await captureWarnings(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlRouteObserver.instance],
          home: PageView(
            controller: page,
            children: const <Widget>[
              Column(
                children: <Widget>[_RepeatHost(), _RepeatHost(), _RepeatHost()],
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(warnings, hasLength(1));
    expect(warnings.single, contains('_RepeatHost'));
  });
}

/// 内层 `TabBarView` 故意不包 Scope。
class _BareTabs extends StatefulWidget {
  const _BareTabs({required this.host});
  final Widget host;
  @override
  State<_BareTabs> createState() => _BareTabsState();
}

class _BareTabsState extends State<_BareTabs>
    with SingleTickerProviderStateMixin {
  late final TabController tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TabBarView(controller: tab, children: <Widget>[widget.host, widget.host]);
}

/// 每个用例一个宿主类型，见文件头注释。
class _WrappedHost extends StatefulWidget {
  const _WrappedHost();
  @override
  State<_WrappedHost> createState() => _WrappedHostState();
}

class _WrappedHostState extends State<_WrappedHost>
    with FlPageLifecycleMixin<_WrappedHost> {
  @override
  bool get observePageIndex => true;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _InnerHost extends StatefulWidget {
  const _InnerHost();
  @override
  State<_InnerHost> createState() => _InnerHostState();
}

class _InnerHostState extends State<_InnerHost>
    with FlPageLifecycleMixin<_InnerHost> {
  @override
  bool get observePageIndex => true;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _LooseHost extends StatefulWidget {
  const _LooseHost();
  @override
  State<_LooseHost> createState() => _LooseHostState();
}

class _LooseHostState extends State<_LooseHost>
    with FlPageLifecycleMixin<_LooseHost> {
  @override
  bool get observePageIndex => true;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _BannerHost extends StatefulWidget {
  const _BannerHost();
  @override
  State<_BannerHost> createState() => _BannerHostState();
}

class _BannerHostState extends State<_BannerHost>
    with FlPageLifecycleMixin<_BannerHost> {
  @override
  bool get observePageIndex => true;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _RepeatHost extends StatefulWidget {
  const _RepeatHost();
  @override
  State<_RepeatHost> createState() => _RepeatHostState();
}

class _RepeatHostState extends State<_RepeatHost>
    with FlPageLifecycleMixin<_RepeatHost> {
  @override
  bool get observePageIndex => true;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
