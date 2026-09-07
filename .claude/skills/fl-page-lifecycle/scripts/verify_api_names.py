#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 dart 文件里用到的 fl_page_lifecycle 标识符是否真实存在。

为什么需要它：fl_page_lifecycle 没有发到 pub.dev，模型对它没有训练先验，
最常见的失败是编造出 `PageLifecycleMixin`、`onPageShow` / `onPageHide`、
`pauseOnOverlay:` 这类根本不存在的名字——代码一行都编译不过，但读起来很像真的。
`flutter analyze` 当然能发现，可它需要能跑起来的 Flutter 环境；这个脚本只要 Python，
适合在交代改动之前先自查一遍。

用法：
    python3 verify_api_names.py <文件或目录> [更多路径...]
    python3 verify_api_names.py lib/pages/            # 查一个目录
    python3 verify_api_names.py --print-api           # 打印已知公开面
    python3 verify_api_names.py --lib <package>/lib <路径>   # 用真实源码重新推导公开面

退出码：0 = 没发现问题；1 = 发现可疑标识符；2 = 用法错误。

维护提示：下面的 PUBLIC 是照 lib/fl_page_lifecycle.dart 的导出面逐个核对来的。
库的公开 API 变了就要同步改——这个脚本的价值完全建立在这份清单准确之上。
带 --lib 指向库的 lib/ 目录可以重新推导一份做对照。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------- 公开面

PUBLIC_TYPES = {
    "FlPageLifecycleMixin", "FlPageRouteMixin", "FlAppLifecycleMixin",
    "FlAnimationLifecycleMixin", "FlPageControllerMixin", "FlStateEventBusMixin",
    "FlPageLifecycleView", "FlPageViewScope", "FlRouteObserver", "FlLifecycleState",
    "FlLifecycleManager", "FlGlobalEventBus", "FlIEventBus", "FlEventBus",
    "FlPageLifecycleCallback", "FlPageRouteParamCallback", "FlPageViewChangedCallback",
}

PUBLIC_MEMBERS = {
    # 生命周期回调
    "onPageInit", "onPageContextReady", "onPagePostFrame", "onPageReassemble",
    "onPageEnterAnimationStart", "onPageStart", "onPageResume",
    "onPageEnterAnimationEnd", "onPagePause", "onPageStop",
    "onPageLeaveAnimationStart", "onPageLeaveAnimationEnd", "onPageDispose",
    "onAppResume", "onAppInactive", "onAppPause", "onAppForeground",
    "onAppBackground", "onPageViewChanged", "onLifecycleStateChanged",
    "appLifecycleChanged",
    # FlPageRouteMixin 的回调是 onRoute*，不是 onPage*
    "onRouteStart", "onRouteResume", "onRoutePause", "onRouteStop",
    # FlPageControllerMixin 的公开入口
    "onLifecycleChanged", "setupRouteInfo",
    # 开关与状态 getter
    "observePageView", "observeAppLifecycle", "isPageAppeared", "isPageResumed",
    "isInPageView", "pageIndex", "currentPageIndex", "pageViewDepth",
    "isForeground", "isCurrent", "routeName", "arguments", "hasInit", "hasRoute",
    "modalRoute", "lifecycleState", "isPageResume", "isPagePause", "isAppEvent",
    # FlPageViewScope 静态方法
    "wrapChildren", "wrapItemBuilder", "indexOf", "initialIndexOf",
    "listenableOf", "depthOf",
    # FlPageLifecycleView 参数
    "onStateChanged", "onRouteParam",
    # 事件总线与 manager
    "observeEvent", "dispatchEvent", "configure", "destroy", "instance",
    "streamController", "customController", "fire",
}

PUBLIC = PUBLIC_TYPES | PUBLIC_MEMBERS

# 本库类型名里的标志性词根。带这些词根、却不是公开名字、又不是项目自己声明的类型，
# 基本就是把真名记错了（FlPageLifecycleObserver、PageLifecycleScope 这一类）。
#
# 不用「Fl 开头」当判据：Flutter 自己有 Flexible / Flow / FloatingActionButton，
# 项目里也可能有别的 Fl 前缀类，那样误报会多到没人愿意跑这个脚本。
LIB_TOKENS = (
    "PageLifecycle", "PageViewScope", "RouteObserver", "LifecycleState",
    "LifecycleManager", "StateEventBus", "GlobalEventBus", "IEventBus",
    "PageControllerMixin", "AppLifecycleMixin", "AnimationLifecycleMixin",
    "PageRouteMixin", "LifecycleScope", "LifecycleView", "LifecycleMixin",
)

TYPE_SHAPES = re.compile(
    r"\b([A-Za-z0-9_]*(?:" + "|".join(LIB_TOKENS) + r")[A-Za-z0-9_]*)\b"
)

# 成员名形状。这几类的真名是**封闭集合**（回调就那 26 个、开关就 2 个、状态 getter 就那几个），
# 所以这里的判据比类型名可靠得多。
MEMBER_SHAPES = re.compile(
    r"\b("
    r"on(?:Page|App|Route|Lifecycle)[A-Za-z0-9_]*"
    r"|observe[A-Z][A-Za-z0-9_]*"
    r"|isPage[A-Z][A-Za-z0-9_]*"
    r"|pauseOn[A-Za-z0-9_]*"          # 常见编造：pauseOnOverlay / pauseOnAppBackground
    r")\b"
)

# 本地声明：项目自己的类 / mixin / 方法 / getter / 字段，不该被算成编造的库 API。
LOCAL_DECL = re.compile(
    r"\b(?:mixin|class|typedef|enum|extension)\s+([A-Za-z0-9_]+)"
    r"|(?:void|Future<[^>]*>|[A-Za-z0-9_<>?,\s]+?)\s+([A-Za-z0-9_]+)\s*\([^)]*\)\s*(?:async\s*)?\{"
    r"|\bget\s+([A-Za-z0-9_]+)"
    r"|\bfinal\s+[A-Za-z0-9_<>?,\s]+?\s+([A-Za-z0-9_]+)\s*[;=]"
    r"|\b(?:this|super)\.([A-Za-z0-9_]+)"
)

# 带 @override 的声明不是本地声明，而是在**声称**覆写库里的某个成员。
# 覆写一个不存在的回调（`@override void onPageShow()`）正是最典型的编造，
# 所以这些名字必须照常参与校验，不能被上面的 LOCAL_DECL 豁免掉。
OVERRIDE_DECL = re.compile(
    r"@override\s*"
    r"(?:[A-Za-z0-9_<>?,\[\]\s]*?\s)?"
    r"(?:get\s+)?([A-Za-z0-9_]+)\s*[({=>;]"
)

# 库内部实现细节：出现在说明文字里不算错，但出现在代码里说明用了非公开 API。
INTERNAL = {
    "FlLifecycleGuard", "FlPageRouteDelegate", "FlPageViewDelegate",
    "FlAppLifecycleDelegate", "FlRouteAnimationBinding", "FlPageViewScopeData",
    "FlPageViewVisibility",
}

# Flutter / 常见三方包里恰好命中形状的真实名字。漏了会误报，所以宁可写全。
FRAMEWORK_OK = {
    # PageView / TabBar
    "onPageChanged",
    # webview_flutter —— 和 onPageStart 只差一个字母，最容易被误判
    "onPageStarted", "onPageFinished", "onPageProgress",
    # AppLifecycleListener（Flutter 3.13+）
    "onAppLifecycleStateChange",
    # Flutter 自带的生命周期与路由类型：它们是真实存在的，只是本库不用它们。
    # 报成「不存在」是错的——真要劝人迁移，那是 pitfalls.md 的事，不是这个脚本的事。
    "AppLifecycleState", "AppLifecycleListener", "RouteObserver", "RouteAware",
    "NavigatorObserver", "RouteSettings", "RouteInformation",
    # 观察者模式的通用命名
    "observer", "observers",
    # Flutter 里 Fl 开头的东西（这里只是保险，判据已不靠 Fl 前缀）
    "Flutter", "FlutterError", "FlutterErrorDetails", "FlutterLogo",
    "FlutterView", "FlexFit", "Flexible", "Flex", "FloatingActionButton",
    "Flow", "FlowDelegate",
}

DART_EXT = {".dart"}


def strip_comments_and_strings(src: str) -> str:
    """去掉注释与字符串字面量，避免把说明文字里的名字当成代码里的调用。"""
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    src = re.sub(r"'''.*?'''|\"\"\".*?\"\"\"", " ", src, flags=re.S)
    src = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", src)
    src = re.sub(r"\"(?:\\.|[^\"\\\n])*\"", '""', src)
    return src


def collect_files(paths: list[str]) -> list[Path]:
    out: list[Path] = []
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            out.extend(sorted(f for f in p.rglob("*") if f.suffix in DART_EXT))
        elif p.suffix in DART_EXT:
            out.append(p)
        elif p.exists():
            print(f"跳过（不是 dart 文件）：{p}", file=sys.stderr)
        else:
            print(f"路径不存在：{p}", file=sys.stderr)
    return out


def derive_public_from_lib(lib_dir: Path) -> set[str]:
    """从库源码重新推导一份公开面，用于核对上面那份清单是否过时。

    只看 lib/ 顶层导出的文件，并跳过标了 @internal 的声明。
    """
    entry = lib_dir / "fl_page_lifecycle.dart"
    if not entry.exists():
        print(f"找不到 {entry}", file=sys.stderr)
        return set()
    exported = []
    for m in re.finditer(r"export\s+'([^']+)'", entry.read_text(encoding="utf-8")):
        f = lib_dir / m.group(1)
        if f.exists():
            exported.append(f)
    names: set[str] = set()
    for f in exported:
        src = f.read_text(encoding="utf-8")
        for m in re.finditer(
            r"@internal[\s\S]{0,80}?\b(?:mixin|class|typedef|enum)\s+([A-Za-z0-9_]+)", src
        ):
            names.discard(m.group(1))
        for m in re.finditer(r"\b(?:mixin|class|typedef|enum)\s+([A-Za-z0-9_]+)", src):
            if not m.group(1).startswith("_"):
                names.add(m.group(1))
        for m in re.finditer(r"\bvoid\s+([A-Za-z0-9_]+)\s*\(", src):
            if not m.group(1).startswith("_"):
                names.add(m.group(1))
        for m in re.finditer(r"\bget\s+([A-Za-z0-9_]+)", src):
            if not m.group(1).startswith("_"):
                names.add(m.group(1))
    return names


def scan(files: list[Path], public: set[str]) -> tuple[dict, dict, set[str]]:
    """返回 (可疑名字 -> [出现位置], 内部 API -> [出现位置], 本地声明集合)。

    本地声明是**跨全部被扫文件汇总**的：项目里 `PageLifecyclePage` 在 A 文件声明、
    B 文件使用是常态，逐文件判断会把 B 里的用法误报成编造。所以这个脚本要一次扫
    整个目录（或一次把全部改动文件都传进来），只扫单个文件会多报。
    """
    parsed: list[tuple[Path, str]] = []
    local: set[str] = set()
    for f in files:
        code = strip_comments_and_strings(
            f.read_text(encoding="utf-8", errors="replace")
        )
        parsed.append((f, code))
        local |= {g for m in LOCAL_DECL.finditer(code) for g in m.groups() if g}
        # 覆写声明要回到被校验的集合里：它声称的是库的成员，不是本地新增的。
        local -= set(OVERRIDE_DECL.findall(code))

    suspects: dict[str, list[str]] = {}
    internals: dict[str, list[str]] = {}
    for f, code in parsed:
        for i, line in enumerate(code.splitlines(), 1):
            names = set(TYPE_SHAPES.findall(line)) | set(MEMBER_SHAPES.findall(line))
            for name in names:
                if name in FRAMEWORK_OK or name in local:
                    continue
                where = f"{f}:{i}"
                if name in INTERNAL:
                    internals.setdefault(name, []).append(where)
                elif name not in public:
                    suspects.setdefault(name, []).append(where)
    return suspects, internals, local


def main() -> int:
    ap = argparse.ArgumentParser(
        description="校验 dart 代码里的 fl_page_lifecycle 标识符是否真实存在"
    )
    ap.add_argument("paths", nargs="*", help="要检查的 dart 文件或目录")
    ap.add_argument("--print-api", action="store_true", help="打印已知公开面后退出")
    ap.add_argument("--lib", metavar="DIR", help="库的 lib/ 目录，用它重新推导公开面做对照")
    args = ap.parse_args()

    if args.print_api:
        for n in sorted(PUBLIC):
            print(n)
        return 0

    if not args.paths:
        ap.print_usage()
        return 2

    public = set(PUBLIC)
    if args.lib:
        derived = derive_public_from_lib(Path(args.lib))
        if derived:
            only_derived = sorted(derived - public - INTERNAL)
            only_baked = sorted(public - derived)
            if only_derived:
                print("提示：源码里有、清单里没有的名字（清单可能过时）：")
                print("  " + ", ".join(only_derived))
            if only_baked:
                print("提示：清单里有、这次没从源码扫到的名字（多为枚举值或参数名，通常正常）：")
                print("  " + ", ".join(only_baked[:20])
                      + (" …" if len(only_baked) > 20 else ""))
            public |= derived
            print()

    files = collect_files(args.paths)
    if not files:
        print("没有找到 dart 文件")
        return 2

    suspects, internals, _local = scan(files, public)

    print(f"检查了 {len(files)} 个 dart 文件")
    if len(files) == 1:
        print("   （只扫了一个文件：项目自己的类如果声明在别处，可能被误报。"
              "建议一次传入整个目录或全部改动文件。）")

    if internals:
        print("\n⚠️  用到了库的内部实现（标了 @internal 或未导出，不该在业务代码里出现）：")
        for name, spots in sorted(internals.items()):
            print(f"  {name}")
            for s in spots[:5]:
                print(f"      {s}")

    if not suspects:
        print("\n✅ 没有发现编造的标识符。")
        print("   注意这个脚本只查名字是否存在，不查用法是否正确——"
              "参数顺序、类型、是否漏了 super 仍要靠 flutter analyze。")
        return 1 if internals else 0

    print("\n❌ 下面这些标识符在 fl_page_lifecycle 的公开 API 里不存在：")
    for name, spots in sorted(suspects.items()):
        print(f"\n  {name}")
        for s in spots[:5]:
            print(f"      {s}")
        if len(spots) > 5:
            print(f"      …… 共 {len(spots)} 处")
    print("\n真实的名字请查 references/api.md。常见对应关系：")
    print("  PageLifecycleMixin / FlPageLifecycleObserver → FlPageLifecycleMixin + FlRouteObserver.instance")
    print("  onPageShow / onPageHide                      → onPageStart / onPageStop（或 onPageResume / onPagePause）")
    print("  pauseOnOverlay: / pauseOnAppBackground:      → 没有这种构造参数，用回调 + observeAppLifecycle")
    return 1


if __name__ == "__main__":
    sys.exit(main())
