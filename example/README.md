# fl_page_lifecycle example

`fl_page_lifecycle` 的可运行示例，覆盖库里全部 7 个入口。首页是一个列表，
每一项进去是对应 mixin 的独立 demo：

| 入口 | 演示内容 |
| --- | --- |
| `FlPageLifecycleMixin` | 完整页面生命周期：可见性状态机 + App 前后台 + 路由转场动画 |
| `FlPageLifecycleMixin` - PageView | 叠加 `PageView` / `TabBarView` 的页码驱动可见性 |
| `FlPageLifecycleMixin` - 路由栈批量操作 | `popUntil` / `pushAndRemoveUntil` 下中间层的 start / stop 判定 |
| `FlPageRouteMixin` | 只转发路由事件与转场动画，不做幂等与补发 |
| `FlAppLifecycleMixin` | 只关心 App 前后台，过滤通知栏、来电这类短暂中断 |
| `FlStateEventBusMixin` | 页面内订阅 / 发布全局事件，订阅随 `dispose` 自动取消 |
| `FlAnimationLifecycleMixin` | 只关心转场动画，把重活推迟到入场动画结束后执行 |

每个 demo 页底部都挂着一块实时日志面板，事件同时 `debugPrint` 到终端
（见 `lib/src/widgets/lifecycle_log.dart`），两种观察方式都保留。

## 运行

```bash
cd example
flutter run
```

`android/` 与 `ios/` 已经在仓库里，无需再跑 `flutter create .`。

`main.dart` 里给 `MaterialApp` 注册了 `FlRouteObserver()` —— 这是页面生命周期
能收到路由事件的前提，接入自己的工程时别漏掉这一步。
