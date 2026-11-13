# 场景：页面级资源起停（节号全局唯一，勿改）

## 1. 视频 / 音频

用 `onPageResume` / `onPagePause`：弹窗盖上来就该停。

```dart
class _VideoPageState extends State<VideoPage> with FlPageLifecycleMixin {
  late final VideoPlayerController _player;
  bool _wantsToPlay = true;   // 用户手动暂停过就不强行续播

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        if (isPageResumed && _wantsToPlay) _player.play();   // 初始化可能晚于 resume
      });
  }

  @override
  void onPageResume() { if (_wantsToPlay) _player.play(); }

  @override
  void onPagePause() {
    if (_player.value.isInitialized) _wantsToPlay = _player.value.isPlaying;
    _player.pause();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }
}
```

- 本库的 pause 只看路由，不看 App 前后台。切后台也要停就开 `observeAppLifecycle`，在 `onAppBackground` 里停。
- 信息流多卡片自动播：本库判「Feed 页是否 resumed」，`visibility_detector` 判「哪张卡在屏上」，两个一起用。

## 2. 曝光与停留时长

用 `onPageStart` / `onPageStop`：弹窗不算离开。成对且 dispose 补发，不会漏埋。

```dart
class _ArticlePageState extends State<ArticlePage> with FlPageLifecycleMixin {
  DateTime? _enterAt;
  String _pageId = 'unknown';

  @override
  void onPageContextReady(String? routeName, Object? arguments) => _pageId = routeName ?? 'unknown';

  @override
  void onPageStart() {
    _enterAt = DateTime.now();
    Analytics.pageView(_pageId, args: arguments);
  }

  @override
  void onPageStop() {
    final at = _enterAt;
    if (at == null) return;
    _enterAt = null;
    Analytics.pageDuration(_pageId, DateTime.now().difference(at));   // routeName 此时仍可读
  }
}
```

- 刨掉后台时间：开 `observeAppLifecycle`，`onAppBackground` 结算一段、`onAppForeground` 重新计时。
- `popUntil` 会让中间层各闪一对 start/stop，用时长阈值过滤。
- 全项目统一埋点见 `sc-arch.md` §13。

## 3. 轮询 / WebSocket

用 `onPageStart` / `onPageStop`（弹筛选面板时刷新不该断），再开 `observeAppLifecycle` 挡住后台。

```dart
class _DashboardPageState extends State<DashboardPage> with FlPageLifecycleMixin {
  Timer? _timer;

  @override
  bool get observeAppLifecycle => true;

  void _start() {
    _timer?.cancel();                       // 先取消再建，避免重复定时器
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _fetch());
    _fetch();
  }

  void _stop() { _timer?.cancel(); _timer = null; }

  @override
  void onPageStart() => _start();
  @override
  void onPageStop() => _stop();
  @override
  void onAppBackground() => _stop();
  @override
  void onAppForeground() { if (isPageAppeared) _start(); }

  Future<void> _fetch() async {
    final data = await api.load();
    if (!mounted) return;
    setState(() => _data = data);
  }
}
```

WebSocket 重连代价高时分两级：`onPagePause` 只停 UI 消费，`onPageStop` 才断连。

## 7. App 前后台

- 只要前后台：`FlAppLifecycleMixin`，覆写 `onAppForeground()` / `onAppBackground()`，无开关。
- 页面里顺带要：别叠它，改开 `observeAppLifecycle => true`：

```dart
@override
void onAppForeground() {
  if (!isPageAppeared) return;   // 只刷新用户看得见的页面
  _load();
}
```

- `onAppForeground` / `onAppBackground` 已过滤来电、通知栏、控制中心这类瞬时打断；原始状态用 `onAppResume` / `onAppInactive` / `onAppPause`。
- 页面创建时 App 已在前台的**不会**收到初始 `onAppForeground`，判断状态读 `isForeground`。
- 非页面代码直接订流并自己 cancel：`FlLifecycleManager.instance.stream.listen((fg) { ... })`。别调 `FlLifecycleManager.cancel()`。
