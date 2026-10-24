import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';
import 'package:flutter/material.dart';

import 'widgets/demo_scaffold.dart';
import 'widgets/lifecycle_log.dart';

/// 整个示例**共用一份日志**。
///
/// 这是路由栈那组操作能说明问题的前提：`pushAndRemoveUntil` 的重点在于「留在栈里、
/// 被新页盖住的那一层有没有被错误唤醒」——如果每层各记各的，你站在新页上根本看不到
/// 底层页发生了什么。共用一份就能在同一个面板里看到所有层的事件按时间交错排列。
///
/// 示例专用，进程内常驻，不随页面销毁；正式代码里不要这么写。
final _log = LifecycleLogController(name: 'PageLifecycle');

/// `FlPageLifecycleMixin` 的完整示例，同时也是路由栈中的**第 0 层**。
///
/// 一个页面演示两组事情：
///
/// - **遮挡方式的差异**：弹窗 / BottomSheet 是 `PopupRoute`，页面仍可见，只发
///   `onPagePause`；push 普通页面才发 `onPagePause` + `onPageStop`。
/// - **路由栈批量操作**：`popUntil` 与 `pushAndRemoveUntil` 对「中间层」「被盖住的
///   底层」的影响完全不同，见下面两个方法的注释。
class PageLifecyclePage extends StatelessWidget {
  const PageLifecyclePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const _LifecycleDemoPage(label: 'L0', level: 0);
}

/// 栈中的一层。除了标题与可用操作，各层完全一致。
class _LifecycleDemoPage extends StatefulWidget {
  const _LifecycleDemoPage({required this.label, required this.level});

  /// 面板里的来源标记，如 `L0` / `L1` / `NEW`。
  final String label;

  /// 当前深度，用来给下一层命名。
  final int level;

  @override
  State<_LifecycleDemoPage> createState() => _LifecycleDemoPageState();
}

class _LifecycleDemoPageState extends State<_LifecycleDemoPage>
    with FlPageLifecycleMixin, DemoLogMixin {
  /// 本页在 `main.dart` 的路由表里的名字，`popUntil` / `pushAndRemoveUntil`
  /// 要靠它定位第 0 层。更深的层都是匿名 `MaterialPageRoute`，不会被误匹配。
  static const _rootRouteName = '/FlPageLifecycleMixin';

  @override
  LifecycleLogController get log => _log;

  @override
  String? get logTag => widget.label;

  bool get _isRoot => widget.level == 0;

  void _push() {
    final next = widget.level + 1;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LifecycleDemoPage(label: 'L$next', level: next),
      ),
    );
  }

  /// 逐个 pop 回到第 0 层。
  ///
  /// `Navigator.popUntil` 是一个 `while` 循环，**每次 `pop()` 都独立走一遍**
  /// 历史整理与观察者派发。所以被跨过的中间层确实会短暂成为栈顶，各自收到一对
  /// `start → resume → pause → stop`。这不是 bug：它是配对的、会自我纠正的瞬态。
  void _popUntilRoot() {
    Navigator.of(context).popUntil(ModalRoute.withName(_rootRouteName));
  }

  /// 清掉第 0 层之上的所有层，换成一个新页面。
  ///
  /// 与 `popUntil` 的关键差别：新路由**先**被 push 到栈顶，然后才逐个 remove
  /// 下面的旧路由。因此每次 `didRemove` 的 `previousRoute` 都还被新页盖着，
  /// 一层都没有真的露出来——L0 全程不该出现 `onPageStart`。
  void _pushAndRemoveToRoot() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) =>
            _LifecycleDemoPage(label: 'NEW', level: widget.level + 1),
      ),
      ModalRoute.withName(_rootRouteName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FlPageLifecycleMixin · ${widget.label}',
      logTitle: '事件日志（所有层共用，tag 是层名）',
      hint: _isRoot
          ? '两组对照：① 弹窗只发 pause，跳转才发 pause + stop；'
                '② 先压几层，再分别试 popUntil 与 pushAndRemoveUntil，'
                '注意看本层（L0）在两种操作下的表现差异。'
          : '继续压更深，或直接回 L0。所有层的事件都汇总在下方同一个面板里，'
                '这样站在上层也能看到底层发生了什么。',
      log: _log,
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
          icon: Icons.layers_outlined,
          label: '再压一层',
          effect: '本层 stop，新层 start',
          onTap: _push,
        ),
        if (!_isRoot)
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
        DemoAction(
          icon: Icons.arrow_forward,
          label: '跳到别的示例页',
          effect: 'pause → stop',
          onTap: () => Navigator.of(context).pushNamed('/FlPageRouteMixin_two'),
        ),
      ],
    );
  }
}
