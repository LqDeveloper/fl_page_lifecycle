import 'package:flutter/material.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// 整个示例**共用一份日志**。
///
/// 这是本页能说明问题的前提：`pushAndRemoveUntil` 的重点在于「留在栈里、被新页
/// 盖住的那一层有没有被错误唤醒」——如果每层各记各的，你站在新页上根本看不到
/// 底层页发生了什么。共用一份就能在同一个面板里看到所有层的事件按时间交错排列。
///
/// 示例专用，进程内常驻，不随页面销毁；正式代码里不要这么写。
final _stackLog = LifecycleLogController(name: 'RouteStack');

/// 路由栈批量操作示例的入口页，也是栈中的第 0 层。
class RouteStackPage extends StatelessWidget {
  const RouteStackPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const StackDemoPage(label: 'L0', level: 0);
}

/// 栈中的一层。除了标题不同，各层完全一致。
class StackDemoPage extends StatefulWidget {
  const StackDemoPage({super.key, required this.label, required this.level});

  /// 面板里的来源标记，如 `L0` / `L1` / `NEW`。
  final String label;

  /// 当前深度，用来给下一层命名。
  final int level;

  @override
  State<StackDemoPage> createState() => _StackDemoPageState();
}

class _StackDemoPageState extends State<StackDemoPage>
    with FlPageLifecycleMixin, DemoLogMixin {
  @override
  LifecycleLogController get log => _stackLog;

  @override
  String? get logTag => widget.label;

  void _push() {
    final next = widget.level + 1;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StackDemoPage(label: 'L$next', level: next),
      ),
    );
  }

  /// 逐个 pop 回到第 0 层。
  ///
  /// `Navigator.popUntil` 是一个 `while` 循环，**每次 `pop()` 都独立走一遍**
  /// 历史整理与观察者派发。所以被跨过的中间层确实会短暂成为栈顶，各自收到一对
  /// `start → resume → pause → stop`。这不是 bug：它是配对的、会自我纠正的瞬态。
  void _popUntilRoot() {
    Navigator.of(context).popUntil(ModalRoute.withName("/RouteStackPage"));
  }

  /// 清掉第 0 层之上的所有层，换成一个新页面。
  ///
  /// 与 `popUntil` 的关键差别：新路由**先**被 push 到栈顶，然后才逐个 remove
  /// 下面的旧路由。因此每次 `didRemove` 的 `previousRoute` 都还被新页盖着，
  /// 一层都没有真的露出来——L0 全程不该出现 `onPageStart`。
  void _pushAndRemoveToRoot() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => StackDemoPage(label: 'NEW', level: widget.level + 1),
      ),
      ModalRoute.withName("/RouteStackPage"),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRoot = widget.level == 0;
    return DemoScaffold(
      title: '路由栈批量操作 · ${widget.label}',
      logTitle: '事件日志（所有层共用，tag 是层名）',
      hint: isRoot
          ? '先压几层，再分别试 popUntil 与 pushAndRemoveUntil，'
                '注意看本层（L0）在两种操作下的表现差异。'
          : '压到更深处，或者直接回到 L0。所有层的事件都汇总在下方同一个面板里。',
      log: _stackLog,
      actions: [
        DemoAction(
          icon: Icons.layers_outlined,
          label: '再压一层',
          effect: '本层 stop，新层 start',
          onTap: _push,
        ),
        if (!isRoot)
          DemoAction(
            icon: Icons.arrow_back,
            label: '返回上一层',
            effect: '本层 stop，下层 start',
            onTap: () => Navigator.of(context).pop(),
          ),
        DemoAction(
          icon: Icons.keyboard_double_arrow_down,
          label: 'popUntil 回 L0',
          effect: '中间层各一对 start/stop',
          onTap: _popUntilRoot,
        ),
        DemoAction(
          icon: Icons.playlist_remove,
          label: 'pushAndRemoveUntil',
          effect: 'L0 不该出现 start',
          onTap: _pushAndRemoveToRoot,
        ),
      ],
    );
  }
}
