# NeoAI 生命周期与关闭（v3.0）

> 生命周期管理由 `kernel/lifecycle.lua` 负责：`bootstrap` / `on_shutdown` / `shutdown`。
> 取消由 **AbortSignal** 级联传播（替代旧 `shutdown_flag`）。
> 对应源码：`lua/NeoAI/kernel/lifecycle.lua`、`lua/NeoAI/kernel/init.lua`、
> `lua/NeoAI/init.lua`（setup）。

## 1. 内核引导（kernel/init.lua）

`kernel.bootstrap()` 是内核层入口，依次：

1. 初始化日志（`logger.init(config_store.get("log"))`）。
2. 注册 `VimLeavePre` 自动命令（`NeoAILifecycle` 组）：退出时调用 `M.shutdown()`。
3. `schedule` 延迟 100ms 后台刷新模型列表（`model_service.prefetch`，启动不阻塞）。

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

`NeoAI.setup(user_config)` 是插件入口，极薄：

```
config_store.load(user_config)      -- 纯函数：合并 + 校验
kernel.bootstrap()                  -- 内核引导（日志、VimLeavePre、模型后台刷新）
herder.init()                       -- Herder 终端状态信号（懒检测环境，no-op）
tools.init()                        -- 初始化工具系统（同步注册内置工具）
skills.init()                       -- 扫描技能目录，填充索引
mcp.init()                          -- 预缓存注册 + 异步连接 MCP 服务器
lifecycle.on_shutdown(mcp.shutdown) -- 关闭时关 MCP 子进程/会话
_register_commands()                -- 注册用户命令（懒加载业务模块）
_register_global_keymaps()          -- 注册全局快捷键
status.ensure_lualine_extension()   -- 注入 lualine 扩展（若已加载）
```

命令注册均懒加载对应的业务模块（`require(...)` 在命令调用时才执行）。

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
