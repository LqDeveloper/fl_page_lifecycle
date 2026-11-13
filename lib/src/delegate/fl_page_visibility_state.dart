import 'package:flutter/foundation.dart';

/// 页面可见性状态机——`FlPageLifecycleMixin` 与 `FlPageRouteMixin` 共用的
/// start / resume / pause / stop 配对逻辑。
///
/// 两个 mixin 曾各写一份，同一个缺陷要在两处各修一遍（弹窗被 replace 后不补发
/// resume、start 回调里同步改路由栈后多发 resume 都是如此）。现在规则只在这里
/// 写一次，mixin 只负责决定**什么时候**调用，以及事件发给谁。
///
/// 规则：
///
/// - [start] 幂等。已 appeared 时再收到 start 只补 [resume]——那是弹窗被
///   replace / remove 掉、下方页面没拿到配对 resume 的情形；
/// - start 回调之后重新看一眼状态再发 resume：宿主可能在回调里同步 push 了
///   页面（本页已被 [stop]），或同步弹了窗（[_isCovered] 为 true，resume 留给
///   弹窗关闭时补发）；
/// - [stop] 幂等，且先补 [pause] 再发 stop。标志位先翻转再回调，回调里再次
///   触发时能被挡住。
///
/// 不持有任何订阅，也不做异常隔离——回调怎么发、要不要包 guard 由宿主决定。
@internal
class FlPageVisibilityState {
  FlPageVisibilityState({
    required VoidCallback onStart,
    required VoidCallback onResume,
    required VoidCallback onPause,
    required VoidCallback onStop,
    required bool Function() isCovered,
    VoidCallback? beforeStart,
    bool guardResume = true,
  }) : _onStart = onStart,
       _onResume = onResume,
       _onPause = onPause,
       _onStop = onStop,
       _isCovered = isCovered,
       _beforeStart = beforeStart,
       _guardResume = guardResume;

  final VoidCallback _onStart;
  final VoidCallback _onResume;
  final VoidCallback _onPause;
  final VoidCallback _onStop;

  /// 本页当前是否被别的路由盖着（已挂到路由上且不是栈顶）。
  final bool Function() _isCovered;

  /// 真正发出 start 之前调用一次，`FlPageLifecycleMixin` 用它保证
  /// `onPagePostFrame` 一定早于 start。
  final VoidCallback? _beforeStart;

  /// resume / pause 是否幂等。
  ///
  /// `FlPageLifecycleMixin` 为 true。`FlPageRouteMixin` 为 false：它的
  /// resume / pause 历来无条件转发（见该 mixin 的类文档），这里原样保留。
  final bool _guardResume;

  bool _appeared = false;
  bool _resumed = false;

  /// 已发出 start 且尚未发出 stop。
  bool get isAppeared => _appeared;

  /// 已发出 resume 且尚未发出 pause。
  bool get isResumed => _resumed;

  /// 本页是否被别的路由盖着，见构造参数 `isCovered`。
  bool get isCovered => _isCovered();

  /// 页面变为可见。
  void start() {
    if (_appeared) {
      resume(); // 弹窗被 replace 后的 resume 补发
      return;
    }
    _beforeStart?.call();
    _appeared = true;
    _onStart();
    if (!_appeared) {
      return; // start 回调里同步 push 了页面，本页已被 stop
    }
    if (_isCovered()) {
      return; // start 回调里同步弹了窗，resume 留给弹窗关闭时补发
    }
    resume();
  }

  /// 页面变为可交互。
  void resume() {
    if (_guardResume && _resumed) {
      return;
    }
    _resumed = true;
    _onResume();
  }

  /// 页面失去交互焦点。
  void pause() {
    if (_guardResume && !_resumed) {
      return;
    }
    _resumed = false;
    _onPause();
  }

  /// 页面完全不可见。
  void stop() {
    if (!_appeared) {
      return;
    }
    _appeared = false;
    pause();
    _onStop();
  }
}
