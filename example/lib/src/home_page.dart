import 'package:flutter/material.dart';

/// 首页：列出库内提供的各个 Mixin，点进去是对应的示例页。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('fl_page_lifecycle 示例')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _MixinCard(entry: _entries[index]),
      ),
    );
  }
}

/// 单个 Mixin 的入口卡片。
class _MixinCard extends StatelessWidget {
  const _MixinCard({required this.entry});

  final _MixinEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => Navigator.of(context).pushNamed(entry.path),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  entry.icon,
                  size: 22,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      entry.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页列表项的数据模型。
class _MixinEntry {
  const _MixinEntry({
    required this.title,
    required this.description,
    required this.icon,
    required this.path,
  });

  final String title;
  final String description;
  final IconData icon;
  final String path;
}

const _entries = <_MixinEntry>[
  _MixinEntry(
    title: 'FlPageLifecycleMixin',
    description:
        '完整页面生命周期：可见性状态机 + App 前后台 + 路由转场动画，'
        '并保证 start 后必跟 resume、stop 前必补 pause。'
        '页内同时演示路由栈批量操作——popUntil 的中间层会收到一对配对的 '
        'start/stop 瞬态，而 pushAndRemoveUntil 下被新页盖住的底层不该收到 start。',
    icon: Icons.auto_awesome_motion_outlined,
    path: "/FlPageLifecycleMixin",
  ),
  _MixinEntry(
    title: 'FlPageLifecycleMixin-PageViewPage',
    description:
        '完整页面生命周期：可见性状态机 + App 前后台 + 路由转场动画 + PageView/TabBarView，'
        '并保证 start 后必跟 resume、stop 前必补 pause。',
    icon: Icons.auto_awesome_motion_outlined,
    path: "/PageViewPage",
  ),
  _MixinEntry(
    title: 'FlPageIndexScope-IndexedStack',
    description:
        'IndexedStack 把所有子页都 build 出来、只显示一个，被换下去的页收不到任何信号。'
        '给 Scope 传一个 ValueListenable<int> 即可按页码驱动可见性，'
        '且换页当场提交，没有 PageView 那道「等停稳」的门禁。',
    icon: Icons.layers_clear_outlined,
    path: "/IndexedStackPage",
  ),
  _MixinEntry(
    title: 'FlRouteObserverProxy-多 Navigator',
    description:
        '两条同时存活的嵌套路由栈：根 Navigator 挂 FlRouteObserver，'
        '每个嵌套 Navigator 各挂一个 FlRouteObserverProxy。'
        '单例挂第二个 Navigator 会触发 Flutter 的断言，proxy 正是为此而生。',
    icon: Icons.account_tree_outlined,
    path: "/NestedNavigatorPage",
  ),
  _MixinEntry(
    title: 'FlPageRouteMixin',
    description:
        '只关心路由：转发 push / pop / remove / replace 事件与转场动画，'
        '不区分弹窗、不管 PageView，onRoutePause 也不做守卫。',
    icon: Icons.alt_route_outlined,
    path: "/FlPageRouteMixin_one",
  ),

  _MixinEntry(
    title: 'FlAppLifecycleMixin',
    description: '只关心 App 前后台，过滤掉通知栏、来电这类短暂中断。',
    icon: Icons.phone_iphone_outlined,
    path: "/FlAppLifecycleMixin",
  ),

  _MixinEntry(
    title: 'FlAnimationLifecycleMixin',
    description: '只关心路由转场动画，把重活推迟到入场动画结束后执行，避免掉帧。',
    icon: Icons.animation_outlined,
    path: "/FlAnimationLifecycleMixin",
  ),
  _MixinEntry(
    title: 'FlPageLifecycleView',
    description:
        '不混入 mixin，事件通过回调拿到：适合 StatelessWidget、'
        '不想再加 mixin 的页面，或只观测页面里的一小块子树做曝光统计。',
    icon: Icons.crop_free_outlined,
    path: "/FlPageLifecycleView",
  ),
  _MixinEntry(
    title: 'FlPageControllerMixin',
    description:
        '把生命周期送进 Controller / ViewModel。它自己不订阅任何东西，'
        '页面必须转发 onLifecycleChanged 与 setupRouteInfo 两处。',
    icon: Icons.settings_input_component_outlined,
    path: "/FlPageControllerMixin",
  ),
  _MixinEntry(
    title: 'FlStateEventBusMixin',
    description: '页面内订阅 / 发布全局事件，订阅随 dispose 自动取消；事件全局广播，不可见的页面同样会收到。',
    icon: Icons.campaign_outlined,
    path: "/FlStateEventBusMixin",
  ),
];
