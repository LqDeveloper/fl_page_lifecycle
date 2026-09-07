# 给 AI 编码助手的接入约定

这个目录里的文件不参与库的构建，也不会随 `pub publish` 发出去（`.pubignore` 已排除）。它是给**用到 `fl_page_lifecycle` 的业务项目**准备的一份 AI 助手约定：把它放进你的项目，AI 助手改页面生命周期相关代码时就会按正确的方式接入，而不是自己臆造 API 或者手写一套 `RouteAware` + `isCurrent`。

之所以需要这个：`fl_page_lifecycle` 不在公开 pub.dev 上，AI 模型对它没有任何训练先验。实测三个真实需求在没有这份约定时，助手会 100% 编造出 `PageLifecycleMixin`、`onPageShow` / `onPageHide`、`pauseOnOverlay:` 这类不存在的名字，代码一行都编译不过；有了这份约定则全部用对。

## 目录内容

```
AGENTS.md                 主文件：入口选型、resume/pause 判断、事件时序、避坑清单、提交前自检
references/
├── api.md                精确签名速查：18 个事件、每个 mixin 的完整回调签名、全部 assert 原文
├── recipes.md            10 个场景的完整代码：视频、埋点、轮询、TabBar 懒加载、事件总线、Controller 转发
└── pitfalls.md           15 条避坑详解，按「症状 → 原因 → 怎么做」组织
```

分层是有意的：`AGENTS.md` 会常驻在助手的上下文里，所以它只留决策所需的内容；三个参考文件按需读取，主文件里写明了什么情况下去读哪一个。

## 怎么放进你的项目

**推荐**：整个目录复制过去，然后在项目根的 `AGENTS.md` 里加一行指针。

```bash
# 在你的业务项目根目录
mkdir -p docs/ai
cp -r <fl_page_lifecycle>/docs/ai/AGENTS.md <fl_page_lifecycle>/docs/ai/references docs/ai/fl_page_lifecycle/
```

然后在项目根 `AGENTS.md` 里加：

```markdown
## Flutter 页面生命周期

本项目用 fl_page_lifecycle 处理页面可见性。改动涉及页面生命周期、可见性、
曝光埋点、视频/轮询启停、TabBarView 子页切换时，先读
`docs/ai/fl_page_lifecycle/AGENTS.md`。
```

保持目录结构完整很重要——主文件里指向 `references/` 的是相对路径。

**或者**直接把 `AGENTS.md` 的内容并进项目根 `AGENTS.md`（记得把 `references/` 的路径改成实际位置）。项目本来没有根 `AGENTS.md` 的话，把这份直接放到根目录也行。

## 哪些工具会读 `AGENTS.md`

`AGENTS.md` 是目前的跨工具事实标准，OpenAI Codex、Cursor、Zed、Jules、Aider、Devin 等会自动读取项目根目录的这个文件。各家对嵌套目录和文件引用的支持程度不同，所以上面推荐「根文件加指针」而不是只靠嵌套。

用别的约定的工具，内容不用改，换个文件名/位置即可：

| 工具 | 放这里 |
|---|---|
| Claude Code / Cowork | `CLAUDE.md`，或装成 skill（本仓库另有打包好的 `fl-page-lifecycle` skill） |
| Cursor | `.cursor/rules/fl-page-lifecycle.mdc`，加上 `description` / `globs: ["**/*.dart"]` 前言 |
| GitHub Copilot | `.github/copilot-instructions.md` |
| Windsurf | `.windsurf/rules/fl-page-lifecycle.md` |
| Cline | `.clinerules/fl-page-lifecycle.md` |
| Gemini CLI | `GEMINI.md` |

## 维护

内容都是照 `lib/` 源码核对过的，包括每个回调的精确签名和 assert 原文。**改了库的公开 API 就要同步改这里**，尤其 `references/api.md`——它的价值全部建立在「名字和签名一定对得上源码」之上，一处过时就会让助手写出编译不过的代码。
