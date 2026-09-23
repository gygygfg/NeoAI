# NeoAI 生命周期与关闭（v3.0）

> [English](en/shutdown_flow.md) | **中文**

> 生命周期管理由 `kernel/lifecycle.lua` 负责：`bootstrap` / `on_shutdown` / `shutdown`。
> 取消由 **AbortSignal** 级联传播（替代旧 `shutdown_flag`）。
> 对应源码：`lua/NeoAI/kernel/lifecycle.lua`、`lua/NeoAI/kernel/init.lua`、
> `lua/NeoAI/init.lua`（setup）。

## 1. 内核引导（kernel/init.lua）

`kernel.bootstrap()` 是内核层入口，依次：

1. 初始化日志（`logger.init(config_store.get("log"))`）。
2. 注册 `VimLeavePre` 自动命令（`NeoAILifecycle` 组）：退出时调用 `M.shutdown()`。

> 模型列表后台刷新已迁移为 `model_prefetch` 插件（阶段 2 启动，`vim.schedule` 非阻塞）。

## 2. 生命周期（kernel/lifecycle.lua）

### 2.1 bootstrap

`M.bootstrap()` 幂等。初始化日志、注册 `VimLeavePre` 清理自动命令、后台模型刷新。
`PLUGIN_INITIALIZED` 事件常量虽在 `kernel/events.lua` 中定义，但**当前代码未实际 emit**（属预留常量），故 bootstrap 不触发它。

### 2.2 on_shutdown

`M.on_shutdown(fn)` 注册清理函数（VimLeave 时执行），返回取消函数。多个清理函数按注册顺序执行，
关闭时**逆序**执行（后注册的先清理）。

### 2.3 shutdown

`M.shutdown()` 幂等：

1. 置 `shutting_down = true`（防止重复执行）。
2. 逆序执行所有清理函数（`pcall` 包裹，异常不中断）。
3. 发射 `PLUGIN_SHUTDOWN` 事件。
4. 日志 `"NeoAI shutdown complete"`。

## 3. setup 流程（NeoAI.init）

`NeoAI.setup(user_config)` 是插件入口，极薄且**不启动任何插件**（懒加载默认）：

```
config_store.load(user_config)      -- 纯函数：合并 + 校验
configure_threadpool()              -- 启动早期设置 libuv 线程池大小
kernel.bootstrap()                  -- 内核引导（日志、VimLeavePre）
work.require()                      -- 校验多线程可用 + worker 往返自检
catalog.register_builtins()        -- 仅登记内置插件规格（不启动）
lifecycle.on_shutdown(stop_all)     -- 关闭时逆序卸载所有已启动插件
lifecycle.on_shutdown(persist)      -- 关闭前先落盘活跃 Agent 进度
lazy.register(...)                  -- 注册命令/键位占位符
```

首次触发（`:NeoAI*` 命令、全局快捷键或主动 API）后才启动，且分**两阶段异步**：

```
ensure_phase1()  -- 阶段 1：session/agent/model/chat/status/ui/commands/keymaps（UI 就绪）
ensure_started() -- 阶段 2：tools/sandbox/tool_service/skills/mcp/herder + 全部 tool.*
```

- `plugins.start_list_async(ids, on_done)` 每帧启动一个插件并 `vim.defer_fn(...,0)` 让出事件循环；阶段 1 完成即打开界面。
- `ensure_started_sync(timeout)` 供测试 / `reload_all` 同步等待两阶段完成。
- 只读访问器（`get_*_service` / `get_statusline*`）不触发启动。

## 4. AbortSignal 级联取消

取消机制基于 `async.create_signal()` 的 AbortSignal：

- 每个 Agent 持有独立 `signal`。
- `runtime.abort(agent, reason)` → `agent.signal:abort(reason)` + 状态置 `aborted` + 发射 `AGENT_ABORTED`。
- 取消级联传播到 HTTP 请求（`utils.http` 监听 signal）、工具调用（`tools.executor` 检查 `signal:aborted()`）。
- **取消是正常停止而非错误**：`runtime._run_generation` 的错误回调区分 `aborted/cancelled`，
  状态复位 `idle`、reject `{kind="cancelled"}`，不弹「发送失败」提示。

## 5. 关闭路径

### 5.1 Vim 退出（VimLeavePre）

`lifecycle.shutdown()` 逆序执行清理函数，保存未持久化的会话、关闭异步任务。随后 `event_bus.emit(PLUGIN_SHUTDOWN)`。

### 5.2 窗口关闭

`chat_view.close()` → `chat_service.detach_window(win_id)`：

- 持久化 Agent 消息到会话（`_persist_agent`）。
- `runtime.dispose(agent)`（释放资源，`agent:signal:abort("disposed")`）。
- `todo_mod.cleanup(agent)`（清理待办状态与系统提示段）。
- 拒绝窗口关闭时仍在等待的暂存消息（`_flush_pending`），避免永久挂起。
- `tool_service.clear_approval()`：拒绝队列中所有待审批工具、释放串行审批槽位（否则 `approval_showing`
  残留 true 会让后续审批卡死）。

### 5.3 取消生成

`chat_service.cancel_generation()` → `runtime.abort(agent, "user_cancelled")` + `tool_service.clear_approval()`。

## 6. 相关文档

- [ai_engine.md](ai_engine.md)：Agent 状态机与 `runtime.run`。
- [EVENTS.md](EVENTS.md)：`PLUGIN_INITIALIZED` / `PLUGIN_SHUTDOWN` / `AGENT_*`。
- [configuration.md](configuration.md)：`log` / `herder` 配置。
