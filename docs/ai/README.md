# 给 AI 编码助手的接入约定

这个目录不参与构建，也不随 `pub publish` 发出去（`.pubignore` 已排除）。它是给**用到 `fl_page_lifecycle` 的业务项目**准备的一份 AI 助手约定：放进你的项目，助手改页面生命周期相关代码时就会按正确方式接入，而不是自己臆造 API 或手写一套 `RouteAware` + `isCurrent`。

**本目录对应 fl_page_lifecycle 0.0.4**，只写这一版的用法。库升级后要同步更新这里。

之所以需要：`fl_page_lifecycle` 是 2026 年 9 月才发布的新包，AI 模型对它没有任何训练先验。实测三个真实需求在没有这份约定时，助手 100% 会编造出 `PageLifecycleMixin`、`onPageShow` / `onPageHide`、`pauseOnOverlay:` 这类不存在的名字，代码一行都编译不过；有了则全部用对。

## 目录内容

```
AGENTS.md                 主文件：依赖与版本门禁、注册、入口选型、resume/pause 判断、时序、排错与自检
references/
├── sc-page.md            场景：视频音频 / 曝光与停留时长埋点 / 轮询 WebSocket / App 前后台
├── sc-index.md           场景：PageView·TabBarView 懒加载 / 嵌套容器 / onPageIndexChanged / IndexedStack
├── sc-route.md           场景：注册位置（go_router·auto_route·嵌套 Navigator）/ 路由栈批量操作 / 转场动画 / tab 内独立栈
├── sc-arch.md            场景：事件总线 / 局部子树观测 / Controller·ViewModel / 统一埋点 / 回调里 setState
├── api.md                签名速查（主用面）：18 个事件、主 mixin、FlPageIndexScope、FlPageLifecycleView
├── api-more.md           签名速查（其余）：Controller/Route/App/Animation mixin、Observer 与 Proxy、事件总线、Manager、assert 原文
└── pitfalls.md           症状速查表 + 18 条排错详解 + 选型
scripts/
└── verify_api_names.py   扫 dart 文件：① 不存在的标识符 ② 十几种高频接错方式
```

**分层是为了省上下文**：`AGENTS.md` 常驻助手上下文，所以只留决策所需的内容；`references/` 每个文件 7–9KB，主文件里写明了什么情况下读哪一个，助手一次只读一个，而不是把几万字一起拖进来。

`verify_api_names.py` 只依赖 Python，不需要能跑起来的 Flutter 环境：

```bash
python3 docs/ai/scripts/verify_api_names.py lib/pages/
```

一次传整个目录（只传单文件会误报项目自己的类）。除了校验名字是否存在，它还查十几种「编译得过、`analyze` 也不报、但回调静默不来」的接错方式（漏注册、observer 实例复用、Scope 只做一半、开关非常量、漏 `super`、`observeEvent` 位置、全局销毁、叠加入口 mixin、Controller 没转发或签名错、旧名残留…），每条给出原因、改法和文档位置；`--only-diagnose` 只跑这部分。参数顺序、类型仍要靠 `flutter analyze`。已用库自己的 `example/`（14 个文件的真实正确代码）对照测过：0 误报；16 类误用的故障样本 16/16 命中。

## 怎么放进你的项目

整个目录复制过去，然后在项目根 `AGENTS.md` 里加一行指针：

```markdown
## Flutter 页面生命周期
本项目用 fl_page_lifecycle 处理页面可见性与 App 前后台。改动涉及这些时，
先读 `docs/ai/fl_page_lifecycle/AGENTS.md`。
```

保持目录结构完整——主文件里指向 `references/` 的是相对路径。

## 哪些工具会读

`AGENTS.md` 是目前的跨工具事实标准，OpenAI Codex、Cursor、Zed、Jules、Aider 等会自动读取项目根目录的这个文件。用别的约定的工具，内容不用改，换文件名/位置即可：

| 工具 | 放这里 |
|---|---|
| Claude Code / Cowork | `CLAUDE.md`，或装成 skill（本仓库 `.claude/skills/fl-page-lifecycle/`） |
| Cursor | `.cursor/rules/fl-page-lifecycle.mdc`，加 `description` / `globs: ["**/*.dart"]` 前言 |
| GitHub Copilot | `.github/copilot-instructions.md` |
| Windsurf | `.windsurf/rules/fl-page-lifecycle.md` |
| Cline | `.clinerules/fl-page-lifecycle.md` |
| Gemini CLI | `GEMINI.md` |

## 维护

内容都照 `lib/` 源码核对过，包括每个回调的精确签名和 assert 原文。**改了库的公开 API 就要同步改这里**，尤其 `references/api.md` 与 `api-more.md`——它们的价值全部建立在名字和签名对得上源码之上。
