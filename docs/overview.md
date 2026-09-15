# NeoAI 插件概览

> [English](en/overview.md) | **中文**

NeoAI 是一款面向 Neovim 的 AI 驱动聊天插件，可将 AI 助手直接集成到你的编辑器中。它采用双 UI 设计（树 + 聊天），支持多提供商 AI、完善的工具执行系统、子 Agent 分解，以及带分支的会话历史。

本插件基于 styleGuide.md 中描述的 v3.0 架构构建，遵循隔离（每次对话都使用全新的 Agent 实例）、单向依赖（utils → kernel → core → services → ui）以及默认异步（所有 I/O 均非阻塞）的设计原则。

## 核心特性

1. 双 UI 模式
   - 树 UI：带分支的会话树，支持展开/折叠、CRUD 操作
   - 聊天 UI：AI 对话，支持 streaming、推理内容展示、工具展示

2. 多提供商 AI
   - DeepSeek、OpenAI、Anthropic、Google、Groq、Together、OpenRouter
   - 中文提供商：SiliconFlow、Moonshot、Zhipu、Baidu、Aliyun、StepFun
   - 基于场景的模型选择（chat、code、reasoning、agent）

3. 模型感知策略（capabilities / profiles / prompt cache）
   - 协议族：OpenAI / Anthropic / Gemini 线路编码
   - 厂商方言：max_tokens / max_completion_tokens、reasoning_effort /
     thinking / enable_thinking、认证请求头、usage 字段
   - 能力表：上下文窗口、最大输出、缓存类型、每 token 字符数
     （优先使用实时 `/models` 元数据，其次内置表）
   - 显式缓存（Anthropic breakpoints / OpenAI explicit / Gemini
     cachedContents），失败时静默回退为隐式缓存；未知模型安全回退
   - 参见 docs/model_policy.md

4. 流式生成
   - 实时内容展示
   - 推理内容展示（例如 DeepSeek reasoning_content）
   - 工具调用参数流式传输（tool_args_panel 实时接收参数）
   - 通过 AbortSignal 取消生成

5. 工具系统
   - 内置工具：file ops、LSP、treesitter、shell、git、logging、todo、
     plan_mode、ask_user、read_image、web_fetch（默认不启用）、sub-agent、skills
   - 工具审批工作流（串行单槽队列、自动允许配置、
     按工具权限覆盖、AUTO 模式、审批超时）
   - Plan mode：仅允许只读/信息类工具 + ask_user；修改类工具受门控
   - Plan 蒸馏：审批通过时，将 plan 阶段的研究上下文蒸馏为一个
     checkpoint，以替代上下文压缩
   - Guard：重复工具调用提醒（observe-and-enrich）
   - 环境探测：依赖不可用 workspace/git 的工具将被禁用

6. 子 Agent 系统
   - 通过 `runtime.spawn()` 创建子 Agent（全新环境，零继承）
   - 边界约束（允许的工具、目录、命令、max_tool_calls）
   - 每个子 Agent 拥有独立的工具循环
   - `foreground` 模式：等待完整结果
   - 子 Agent 停靠区 UI 监控状态

7. 会话历史
   - 带分支的会话树（fork）
   - 追加式 JSONL 持久化，带 `.bak` 备份 + 断行修复
   - 后台异步上下文压缩：折叠第一轮至倒数第二轮、对前缀缓存友好的 checkpoint 写入压缩覆盖层；
     后续请求/再次压缩使用压缩替换，渲染与会话持久化仍是原始上下文（压缩不弹窗）
   - 推理内容不会回填到历史（保持前缀缓存稳定）

8. 优雅关闭
   - `kernel/lifecycle`：bootstrap / on_shutdown / shutdown
   - AbortSignal 级联取消（HTTP + 工具）
   - 在 `VimLeavePre` 时同步保存（在 lifecycle 中注册）

9. Herder 终端状态上报
   - 向 Herder 上报 Agent 生命周期状态（working/idle/blocked）
   - 在非 Herder 环境下严格为空操作（HERDR_ENV=1 守卫）
   - 将多会话/子 Agent 聚合为单一生命周期权威
   - --seq 严格递增，以实现并发/安全上报

10. lualine 状态栏集成
   - 在聊天窗口中实时显示 usage/cache/capacity
   - winbar 作为第二行（mode/model/state）
   - 可配置的部件 + 明亮的高亮组

11. 工具参数接收面板
   - 实时浮动窗口，展示流式工具调用参数
   - 在 `TOOL_ARG_CHUNK` 时打开，在 `TOOL_ARG_COMPLETED` 时关闭
   - 与推理面板的交互体验一致；当光标未跟随时抑制显示

12. MCP 支持（客户端）
   - 通过 stdio / Streamable HTTP 连接外部 MCP 服务器
   - 将远端 tools / resources / prompts 注册到工具系统
   - 启动时预缓存 + 失败驱动的动态刷新

13. Skills 支持
   - 扫描 SKILL.md 目录，将技能索引注入系统提示词
   - 模型通过 `load_skill` 按需加载技能正文

14. 待发消息队列
   - Agent 忙碌期间发送的消息会进入队列
   - 状态栏显示 `待发N` 徽标；实际发送后清除

## 架构概览

项目结构：

```text
lua/NeoAI/
  init.lua                   -- 主模块：setup、commands、keymaps
  default_config.lua         -- 默认配置（纯数据）
  kernel/                    -- 内核层（无业务依赖）
    init.lua
    events.lua
    event_bus.lua
    config_store.lua
    logger.lua
    lifecycle.lua
  core/                      -- 核心业务层
    session/                 -- Session（对象、JSONL 存储、上下文构建器、压缩器、
                             -- plan_distill、runtime_context）
    model/                   -- Model（registry、fetcher、adapter、profiles、capabilities、
                             -- prompt_cache、content、cache）
    attachment/              -- Attachment（图像内容寻址存储）
    agent/                   -- Agent 引擎（agent、runtime、request、stream、tool_loop、
                             -- prefix、guard、recovery）
  services/                  -- 服务层（chat、tool、model、status、herder、skills、mcp/*）
  ui/                        -- 表现层
    init.lua                 -- 注册 approval/ask_user/sub-agent dock UI
    window/                  -- 窗口管理器、聊天视图、树视图
    components/              -- input_box、message_list、reasoning_panel、tool_args_panel、
                             -- float_stream_window、model_picker、tool_approval、ask_user、
                             -- sub_agent_dock、fold、display_modes、markdown_view
    keymap.lua               -- 统一快捷键管理
  tools/                     -- 工具系统
    init.lua
    registry.lua
    executor.lua
    validator.lua
    packer.lua
    environment.lua          -- 工具环境探测（禁用不可用的工具）
    builtin/                 -- file_ops、shell、git_ops、lsp_ops、tree_ops、log_ops、
                             -- plan、todo、plan_mode、ask_user、read_image、skills、
                             -- web_fetch（网页抓取，默认不启用）、tool_helpers
  utils/                     -- 工具函数（async、json、http、fs、work、timer、image、stringx）
  tests/                     -- 测试套件（:NeoAITest）
```

关键架构原则：

- 环境隔离：每次对话 = 全新的 Agent 实例（私有消息队列 + 独立
  AbortSignal）。零状态泄漏。
- 单向依赖：utils → kernel → core → services → ui/tools
- 默认异步：所有 I/O 非阻塞；模型列表在后台获取；
  阻塞式文件 I/O 在线程池上运行（utils.work）
- 通过 AbortSignal 取消：取消操作级联传播至 HTTP + 工具
- 事件总线：基于 nvim User autocmds 的 `domain:verb` 事件命名（`NeoAI:` 前缀）
- 对前缀缓存友好：系统提示词由有序区块构建；工具定义
  按名称排序；推理内容不回填 → 字节级稳定

## 安装

使用 lazy.nvim：

```lua
{
  "gygygfg/NeoAI",
  config = function()
    require("NeoAI").setup()
  end
}
```

## 快速开始

基本用法：

```vim
:NeoAIOpen          " 打开默认 UI（由 ui.default_view 配置）
:NeoAIChat          " 打开聊天界面
:NeoAITree          " 打开树界面
:NeoAIClose         " 关闭所有 NeoAI 窗口
:NeoAIKeymaps       " 显示当前快捷键配置
:NeoAITest          " 运行测试（可选传入测试名称）
:NeoAIChatStatus    " 显示聊天窗口状态
:NeoAICycleDisplay  " 循环切换显示模式（chat / trajectory）
:NeoAIReloadDisplay " 热重载显示模式插件
:NeoAIPlan          " 切换 plan mode
:NeoAIAuto          " 切换 AUTO 模式（自动允许所有工具调用）
:NeoAIApprovePlan   " 批准 plan 并切换到 CHAT 模式
:NeoAIStatusline    " 预览 lualine 状态栏组件内容
```

## Herder 终端状态集成

NeoAI 会在 Herder 管理的窗格内，向 Herder 上报真实的 Agent 生命周期状态（`working` / `idle` / `blocked`），
使 Herder 的侧边栏能够实时反映 Agent 状态，而无需从屏幕输出中推断。此集成
**仅生成信号**——它将 NeoAI 的 Agent 生命周期转换为 Herder 语义并上报；
Herder 侧的识别/解析由 Herder 自身处理。

**前提条件**（须全部满足）：

1. 运行在 Herder 注入的窗格内（环境变量 `HERDR_ENV=1`、`HERDR_PANE_ID`、`HERDER_BIN_PATH`）；
2. `herder.enabled = true`（默认值）。

在非 Herder 环境下，该模块是严格的空操作：不订阅任何事件，
且无副作用。

**状态映射**：

| NeoAI Agent 状态 | Herder 上报状态 |
| ----------------- | --------------- |
| `generating` / `tool_running` | `working` |
| 工具审批待处理 / `ask_user` 等待回复 | `blocked` |
| `idle` / `aborted` / `error` | `idle` |

**多会话聚合**：单个 Neovim 窗格可能承载多个 AI 会话
（包括子 Agent）。NeoAI 将它们聚合为一个固定的 `source`（默认
`custom:neoai`），并上报单一的窗格状态，优先级为 `blocked > working > idle`。
每次上报都携带严格递增的 `--seq`，因此 Herder 会忽略同一 `source` 的过期数据包，
避免并发/异步回滚。

**上报流程示例**：

```
# 用户发送消息；Agent 开始生成
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 1
# 工具审批待处理 / 正在询问用户答案（blocked）
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state blocked --seq 2
# 审批通过；仍在生成
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 3
# 回合完成；等待输入
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state idle --seq 4
# 聊天窗口关闭；最后一个 Agent 被释放（释放生命周期权威）
herdr pane release-agent w1:p1 --source custom:neoai --agent neoai --seq 5
```

**配置**：

```lua
require('NeoAI').setup({
  herder = {
    enabled = true,           -- 启用上报（同时需要 HERDR_ENV=1）
    source = 'custom:neoai',  -- 稳定、全局唯一的生命周期权威标识符
    agent = 'neoai',          -- agent 名称（由 Herder 识别）
  },
})
```

> 诊断：在 Herder 窗格内，运行 `herdr agent explain <pane-id>` 可查看
> 当前 Agent 状态来源及最近的上报记录。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:NeoAIOpen` | 打开默认 UI（由 `ui.default_view` 配置：chat 或 tree） |
| `:NeoAIChat` | 直接打开聊天界面 |
| `:NeoAITree` | 直接打开树界面 |
| `:NeoAIClose` | 关闭所有 NeoAI 窗口 |
| `:NeoAIKeymaps` | 在浮动窗口中显示当前快捷键配置 |
| `:NeoAITest [names...]` | 运行测试（全部，或按名称指定） |
| `:NeoAIChatStatus` | 显示聊天窗口状态 |
| `:NeoAICycleDisplay` | 循环切换聊天显示模式（chat / trajectory） |
| `:NeoAIReloadDisplay [name]` | 热重载某个显示模式插件 |
| `:NeoAIPlan` | 切换 plan mode（只读/信息类工具 + ask_user） |
| `:NeoAIAuto` | 切换 AUTO 模式（自动允许所有工具调用） |
| `:NeoAIApprovePlan` | 批准 plan，切换到 CHAT，执行任务列表 |
| `:NeoAIStatusline` | 预览 lualine 状态栏组件内容 |
