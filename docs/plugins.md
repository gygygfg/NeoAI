# NeoAI 插件系统（v1.0）

NeoAI 采用「服务定位器 + 插件宿主」架构：业务代码不直接 `require` 具体服务，而是通过
`kernel.services.use()` 获取**当前配置下生效**的实现；所有副作用（命令、键位、工具、事件订阅、
MCP 连接、状态栏监听、UI 注入）都登记为可启动/可卸载的**插件**。

- 宿主：`lua/NeoAI/kernel/plugins.lua`
- 服务定位器：`lua/NeoAI/kernel/services.lua`
- 默认组合：`lua/NeoAI/plugins/catalog.lua`

## 1. 服务定位器（kernel/services.lua）

| API | 说明 |
| --- | --- |
| `provide(name, impl)` | 登记服务实现（同名覆盖，用于替换/热重载） |
| `use(name)` | 返回当前实现；未提供/被禁用返回 `nil`（**绝不回退默认模块**） |
| `has(name)` | 服务是否已提供 |
| `revoke(name, expected?)` | 注销服务（可选校验实现一致） |
| `wait(name, cb)` | 服务就绪时回调；返回取消函数（依赖等待） |
| `list()` / `reset()` | 列出服务名 / 清空（测试用） |

业务调用示例：

```lua
local services = require("NeoAI.kernel.services")
local chat = services.use("services.chat_service")
if chat then
  chat.send_message("hi")
end
```

服务被禁用时 `use()` 返回 `nil`，调用方必须显式降级（如 `if not chat then ... end`），
不得 `require("NeoAI.services.chat_service")` 兜底。

## 2. 插件宿主（kernel/plugins.lua）

### 2.1 插件规格（spec）

```lua
{
  id = "services.model_service",          -- 全局唯一标识
  deps = { "services.session" },          -- 依赖的插件 id（启动前先启动）
  service = "services.model_service",     -- 可选：对外提供的服务名
  module = "NeoAI.services.model_service",-- 可选：服务实现模块（config 可替换）
  start = function(ctx) ... end,          -- 可选：副作用启动，返回清理函数
  stop = function(ctx) ... end,           -- 可选：额外清理
}
```

- `ctx` 提供 `{ id, plugins, services, on_cleanup }`；`ctx.on_cleanup(fn)` 可登记多个清理函数。
- `start` 也可直接返回清理函数，或返回清理函数数组。

### 2.2 API

| API | 说明 |
| --- | --- |
| `register(spec)` / `register_many(specs)` | 注册（不启动） |
| `start(id)` | 启动本体及其依赖；失败回滚本次新启动的插件 |
| `stop(id)` | 逆序清理并注销服务（幂等） |
| `start_all()` | 按注册顺序启动全部；任一失败则整批回滚 |
| `stop_all()` | 逆序停止全部 |
| `status(id)` / `is_started(id)` / `spec(id)` / `list()` | 查询 |
| `unregister(id)` / `reset()` | 注销 / 清空（测试用） |

### 2.3 生命周期与失败回滚

```
register → start（先依赖 → 再提供服务 → 再执行 start）→ started
                              ↘ 失败：回滚本次新启动的插件，标记 failed
stop：逆序执行清理 → 注销服务 → stopped
```

- 依赖优先：`deps` 中的插件先启动；循环依赖会被检测并报错。
- 失败回滚：`start(id)` 失败只回滚**本次新启动**的插件；`start_all()` 失败整批回滚。
- 幂等：重复 `start`/`stop` 不重复执行副作用。

## 3. 默认组合（plugins/catalog.lua）

内置能力分为三类：

### 3.1 服务提供方

| 插件 id | 提供 | 生命周期 |
| --- | --- | --- |
| `services.session` | `NeoAI.core.session.session_store` | — |
| `services.agent` | `NeoAI.core.agent.agent` | — |
| `services.tools` | `NeoAI.tools` | 应用审批配置 |
| `services.sandbox` | `NeoAI.sandbox` | 探测运行时能力、准备暂存/候选存储 |
| `services.model_service` | `NeoAI.services.model_service` | — |
| `services.chat_service` | `NeoAI.services.chat_service` | — |
| `services.tool_service` | `NeoAI.services.tool_service` | — |
| `services.skills` | `NeoAI.services.skills` | — |
| `services.mcp` | `NeoAI.services.mcp` | — |
| `services.status` | `NeoAI.services.status` | — |
| `services.herder` | `NeoAI.services.herder` | — |

### 3.2 副作用插件

| 插件 id | 作用 | 清理 |
| --- | --- | --- |
| `ui` | 注册审批/提问/子 Agent 监控 UI | 关闭窗口 + 解除 UI 注入 |
| `commands` | 注册全部 `:NeoAI*` 命令 | 删除命令 |
| `keymaps` | 注册全局快捷键 | 删除键位 |
| `model_prefetch` | 启动后台拉取模型列表 | 调度取消 |
| `mcp.connect` | 连接 MCP 服务器 | `mcp.shutdown()` |
| `skills.scan` | 扫描技能目录 | `skills.reset()` |
| `statusline` | 状态栏事件订阅 + lualine 注入 | `status.unwatch()` |
| `herder` | Herder 状态上报 | `herder.reset()` |
| `sandbox.session` | agent 生命周期订阅：循环内共用沙箱、agentEnd 轮换并迁移暂存 | `sandbox.unwatch_sessions()` |

### 3.3 工具插件

每个内置工具是独立插件 `tool.<name>`（如 `tool.shell`、`tool.file_ops`、`tool.skills`），
`start` 注册工具定义（技能工具同时注册提示段），清理时移除工具并释放提示段。
依赖 `services.tools` 与 `services.sandbox`。

加载器是沙箱强制点：`catalog._tool_spec` 把 `services.sandbox` 传入
`tools.load_module`，后者对每个工具 `sandbox.attach`；`registry.register/update`
统一附加规格（覆盖 MCP 动态注册）。执行时 `tools.executor` 统一过
`services.sandbox.gate`，服务缺失且 `fail_closed=true` 时拒绝执行。详见
[sandbox.md](sandbox.md)。

## 4. 配置（plugins）

```lua
require("NeoAI").setup({
  plugins = {
    builtin = true,                 -- false = 不登记内置插件（完全自管）
    disabled = { "ui", "services.mcp" }, -- 禁用的插件/服务 id
    entries = {
      ["tool.shell"] = false,        -- 禁用某插件
      ["services.model_service"] = { module = "my_model_provider" }, -- 替换实现
    },
  },
})
```

- `disabled` 中的插件及其下游依赖（依赖闭包）会被一并移除。
- `entries[id] = false` 等价于禁用；`entries[id] = { module = "..." }` 替换服务/工具实现模块
  （模块需可 `require`，接口与默认实现一致）。
- `plugins.builtin = false` 时不登记任何内置插件，适合宿主自行组合。

## 5. 清理生命周期

所有副作用必须可卸载，由插件宿主在 `stop` 时调用：

- 命令：`nvim_del_user_command`
- 全局键位：`vim.keymap.del`
- 事件订阅：`event_bus.on` 返回的取消函数
- 提示段：`prefix.register_section` 返回的取消函数
- MCP：`mcp.shutdown()`；工具：`registry.remove`
- 状态栏：`status.unwatch()`；UI：`ui.reset()` 解除 `tool_service` / `ask_user` 注入
- Herder：`herder.reset()`

`lifecycle.shutdown()` 会执行 `setup()` 登记的清理函数（内部调用 `plugins.stop_all()`）；
`NeoAIReloadAll` / `reload_all` 也先 `plugins.stop_all()` 再清缓存重载。

## 6. 热重载

`reload_all` 的受控重载流程：

1. 快照 `NeoAI.*` 模块缓存（失败回滚用）；
2. 读取当前配置、会话 id、AUTO 状态；
3. `plugins.stop_all()` → `event_bus.clear_all()` → 清空 `NeoAI.*` 缓存 → 重新 `setup()`；
4. 重建界面并恢复会话；失败则恢复模块缓存快照。

## 7. 测试要求

插件专项测试见 `lua/NeoAI/tests/test_plugins.lua`，覆盖：

- 依赖等待与循环依赖、重复启动幂等；
- 服务替换、禁用与依赖闭包；
- 启动失败回滚（单插件 / 整批）；
- 工具插件卸载与提示段释放；
- 实际消息请求（本地 `tests/http_server.lua` mock，离线可复现）；
- `stop_all` 后 `start_all` 的热重载恢复。

新增插件必须补充对应测试，并在完整回归中保持 `failed=0`。

## 8. 相关文档

- [styleGuide.md](../styleGuide.md) — 目录结构、模块模板、异步与事件约定
- [configuration.md](configuration.md) — 配置项参考
- [testing.md](testing.md) — 测试指南
- [EVENTS.md](EVENTS.md) — 事件常量
