import 'package:flutter/material.dart';

import 'lifecycle_log.dart';

/// 各示例页共用的骨架：顶部说明 → 操作区 → 底部实时事件日志。
class DemoScaffold extends StatelessWidget {
  const DemoScaffold({
    super.key,
    required this.title,
    required this.log,
    this.hint,
    this.actions = const [],
    this.logTitle,
    this.appBar = true,
    this.bottomNavigationBar,
  });

  final String title;

  /// 顶部一句话说明本页在演示什么。
  final String? hint;

  /// 操作区的按钮 / 卡片。
  final List<Widget> actions;

  final LifecycleLogController log;

  final String? logTitle;

  /// PageView 的子页由外层统一提供 AppBar 时置 false。
  final bool appBar;

  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: appBar
          ? AppBar(
              title: Text(
                title,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
              ),
            )
          : null,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        top: !appBar,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hint != null) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lightbulb_outline,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hint!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (actions.isNotEmpty) ...[
                LayoutBuilder(
                  builder: (context, constraints) {
                    // 一行放三个：减去两道间距后三等分。
                    const spacing = 8.0;
                    final width = (constraints.maxWidth - spacing * 2) / 3;
                    return Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: [
                        for (final action in actions)
                          SizedBox(width: width, child: action),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
              ],
              Expanded(
                child: LifecycleLogPanel(controller: log, title: logTitle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 操作区按钮：一个图标 + 主标题 + 说明这一步会触发什么。
class DemoAction extends StatelessWidget {
  const DemoAction({
    super.key,
    required this.icon,
    required this.label,
    required this.effect,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// 点下去预期会看到哪些事件。
  final String effect;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, size: 13, color: scheme.primary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                effect,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.3,
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 演示用的弹窗与 BottomSheet，各页共用，避免每页重复一遍。
class DemoOverlays {
  const DemoOverlays._();

  static void showAlert(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Dialog'),
        content: const Text('弹窗是 PopupRoute，下方页面仍可见，因此只发 pause，不发 stop。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static void showSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const SizedBox(
        height: 160,
        child: Center(child: Text('BottomSheet 同样是 PopupRoute，关闭后只补 resume。')),
      ),
    );
  }
}
