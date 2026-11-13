# 场景：页码容器（节号全局唯一，勿改）

两步缺一不可：容器 `FlPageIndexScope.wrapChildren`，子页 `observePageIndex => true`。只包不开 → 首帧全 start；只开不包 → 可见性不变。

## 4. PageView / TabBarView 懒加载

```dart
PageView(
  controller: _controller,
  children: FlPageIndexScope.wrapChildren(controller: _controller, children: const [A(), B(), C()]),
)

class _FeedTabState extends State<FeedTab> with FlPageLifecycleMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get observePageIndex => true;
  @override
  bool get wantKeepAlive => true;      // 不保活的话划回来是新 State，_loaded 丢失

  bool _loaded = false;

  @override
  void onPageStart() {
    if (_loaded) return;
    _loaded = true;
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return const SizedBox();
  }
}
```

- `TabBarView` 传 `TabController`；`PageView.builder` 用 `wrapItemBuilder`。
- 一个 `PageController` 别给多个 `PageView` 共用。

**提交时机（滚动容器停稳才提交）**

| 操作 | 结果 |
|---|---|
| `animateToPage(0 → 4)` / `TabController.animateTo` | 只有 0 stop + 4 start，掠过的页不发事件 |
| 拖过半页又拖回来 | 什么都不发 |
| `jumpToPage` | 当场提交 |
| 正常翻一页 | 停稳时成对发出 |

代价是 start/stop 比滑过半页晚约一次回弹动画。同一帧内所有 stop 先于所有 start。

子页同时受路由驱动：在子页上弹 dialog 照样 pause/resume，push 新路由照样 stop。

## 5. 嵌套容器

外层 `PageView`、内层 `TabBarView` **各包一层**，内层传自己的 `TabController`，每个子页都开 `observePageIndex`。

- 漏包内层不报错：本页绑到外层 Scope，切内层子页收不到 start/stop，`pageIndex` / `pageScopeDepth` 读到外层的值。debug 提示一次（允许误报：页内轮播本该跟外层走）。
- 可见性按整条链判定：外层切走时，内层当前子页一起 stop。
- `pageScopeDepth`：最外层 0，每嵌一层 +1。

## 15. onPageIndexChanged(int from, int to)

仅在 Scope 内触发，只报本页所在那一层。

- 本层每个已挂载的页收到同一对 `(from, to)`，包括刚切过去的那页。
- `animateToPage(0 → 4)` 报 `(0, 4)`，不逐级报。
- 本层首次确定页码不发；换页之后才挂载的宿主不补发那一次。

要「本页成了当前页」用 `onPageStart`。

## 16. IndexedStack

一个 `ValueNotifier<int>` 同时驱动 `IndexedStack.index` 和 Scope：

```dart
final _index = ValueNotifier<int>(0);
late final List<Widget> _pages = FlPageIndexScope.wrapChildren(   // 建一次，别放进 builder
  controller: _index,
  children: const [FeedTab(), MessageTab(), MineTab()],
);

// build 里
ValueListenableBuilder<int>(
  valueListenable: _index,
  builder: (context, index, _) => IndexedStack(index: index, children: _pages),
)
// 切页：_index.value = i；dispose 里 _index.dispose()
```

与 `PageView` 的差别：

- 不需要 `AutomaticKeepAliveClientMixin`。
- 当场提交，不受外面任何滚动容器影响。
- **漏包没有任何提示**。
- 切页时子页不重建，`build` 里别读 `currentPageIndex`。
