import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:fl_page_lifecycle/fl_page_lifecycle.dart';

/// 一条生命周期事件记录。
class LifecycleLogEntry {
  LifecycleLogEntry(this.event, {this.detail, this.tag})
    : time = DateTime.now();

  /// 事件名，如 `onPageStart`。
  final String event;

  /// 附加信息，如路由名、页码变化。
  final String? detail;

  /// 来源标记，嵌套场景用来区分是哪一层发出的。
  final String? tag;

  final DateTime time;

  String get formattedTime {
    String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    return '${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}'
        '.${pad(time.millisecond, 3)}';
  }
}

/// 事件日志的数据源。
///
/// [log] 同时做两件事：追加到列表供 [LifecycleLogPanel] 展示，
/// 以及 `debugPrint` 到终端——两种观察方式都保留。
class LifecycleLogController extends ChangeNotifier {
  LifecycleLogController({required this.name, this.maxEntries = 200});

  /// 页面名，用作终端输出的前缀。
  final String name;

  /// 最多保留多少条，超出后丢弃最旧的。
  final int maxEntries;

  final List<LifecycleLogEntry> entries = <LifecycleLogEntry>[];

  void log(String event, {String? detail, String? tag}) {
    final entry = LifecycleLogEntry(event, detail: detail, tag: tag);
    entries.add(entry);
    if (entries.length > maxEntries) {
      entries.removeAt(0);
    }
    debugPrint(
      '[${entry.formattedTime}][${tag == null ? name : '$name/$tag'}] '
      '$event${detail == null ? '' : ' — $detail'}',
    );
    _notify();
  }

  void clear() {
    entries.clear();
    _notify();
  }

  /// `onPageInit` / `onPageContextReady` 这些事件是在 build / layout 期间发出的，
  /// 此时直接 `notifyListeners` 会让面板撞上「构建期间 markNeedsBuild」，
  /// 推到帧末再刷新。
  void _notify() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 把 `FlPageLifecycleMixin` 的全部事件接到 [log] 上。
///
/// `onLifecycleStateChanged` 会收到 18 个枚举事件中的每一个，因此不必逐个覆写
/// `onPageStart` / `onPageResume`……
mixin DemoLogMixin<T extends StatefulWidget>
    on State<T>, FlPageLifecycleMixin<T> {
  LifecycleLogController get log;

  /// 嵌套场景（PageView 里再套 TabBarView）用它区分事件来源。
  String? get logTag => null;

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state);
    log.log(state.name, tag: logTag);
  }
}

/// 事件配色：一眼看出可见性变化的方向。
Color _colorOf(String event, ColorScheme scheme) {
  if (event.contains('Animation')) return const Color(0xFF1565C0);
  if (event.startsWith('onApp')) return const Color(0xFF6A1B9A);
  if (event.endsWith('Start') || event.endsWith('Resume')) {
    return const Color(0xFF2E7D32);
  }
  if (event.endsWith('Pause') || event.endsWith('Stop')) {
    return const Color(0xFFE65100);
  }
  return scheme.onSurfaceVariant;
}

/// 实时事件日志面板：新事件从底部追加，自动滚动到最新一条。
class LifecycleLogPanel extends StatefulWidget {
  const LifecycleLogPanel({super.key, required this.controller, this.title});

  final LifecycleLogController controller;

  /// 面板标题，默认「事件日志」。
  final String? title;

  @override
  State<LifecycleLogPanel> createState() => _LifecycleLogPanelState();
}

class _LifecycleLogPanelState extends State<LifecycleLogPanel> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrollToEnd);
    _scrollController.dispose();
    super.dispose();
  }

  /// 事件是在 build 之外发出的，等下一帧列表长出来了再滚。
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final entries = widget.controller.entries;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.terminal,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.title ?? '事件日志',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: entries.isEmpty
                          ? null
                          : widget.controller.clear,
                      icon: const Icon(Icons.clear_all, size: 16),
                      label: const Text('清空'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          '暂无事件',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: entries.length,
                        itemBuilder: (context, i) =>
                            _LogLine(entry: entries[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LifecycleLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _colorOf(entry.event, scheme);
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.5,
    );
    final dim = mono?.copyWith(color: scheme.onSurfaceVariant, fontSize: 11);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.formattedTime,
            style: mono?.copyWith(color: scheme.outline, fontSize: 11),
          ),
          const SizedBox(width: 10),
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (entry.tag != null)
                    TextSpan(text: '${entry.tag}  ', style: dim),
                  TextSpan(
                    text: entry.event,
                    style: mono?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (entry.detail != null)
                    TextSpan(text: '  ${entry.detail}', style: dim),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
