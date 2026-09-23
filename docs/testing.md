# NeoAI 测试指南（v3.0）

> [English](en/testing.md) | **中文**

> NeoAI 采用**轻量自定义测试框架**（`lua/NeoAI/tests/init.lua`，无外部依赖）。
> 以 `suite` / `it` 组织用例，`t.<断言>` 断言，`:NeoAITest` 运行。
> 配合 Mock 对 HTTP、模型、文件系统等做隔离单元/集成测试。

## 1. 运行

```vim
:NeoAITest          " 运行全部套件
:NeoAITest flow_tools  " 运行指定套件（按名字）
```

headless 运行：

```bash
nvim --headless -u NONE --cmd 'set rtp+=.' \
  -c 'lua local r=require("NeoAI.tests").run_all(); vim.cmd(r.failed>0 and "cquit 1" or "qa!")'
```

## 2. 测试组织

```lua
local tests = require("NeoAI.tests")

tests.suite("flow_config", function(describe, it, before_each)
  before_each(function()
    require("NeoAI.kernel.config_store").reset()
  end)

  it("merge user overrides default", function(t)
    local cs = require("NeoAI.kernel.config_store")
    cs.load({ ai = { default_provider = "openai" } })
    t.eq(cs.get("ai.default_provider"), "openai")
  end)

  it("reads dotted path", function(t)
    local cs = require("NeoAI.kernel.config_store")
    cs.load({})
    t.eq(cs.get("ui.window.width"), 80)
  end)
end)
```

## 3. 断言辅助

用例回调收到 `t`（断言辅助表）：

| 断言 | 说明 |
| --- | --- |
| `t.eq(a, b)` | 相等 |
| `t.ne(a, b)` / `t.not_eq(a, b)` | 不等 |
| `t.true_(v)` / `t.false_(v)` | 真假 |
| `t.nil_(v)` / `t.not_nil(v)` | nil / 非 nil |
| `t.matches(pattern, v)` | 字符串匹配 |
| `t.ok(v)` | 真值 |
| `t.deep_eq(a, b)` | 深比较 |
| `t.sleep(ms)` | 异步等待（返回 Deferred） |
| `t.await(promise, timeout_ms?)` | 等待完成并传播拒绝，默认超时 10 秒 |
| `t.throws(fn)` | 捕获错误 |

异步用例必须 `return` 最终的 Deferred 链，或使用 `t.await()`；运行器会等待并统计异步断言失败。
仅启动异步回调而不返回/等待，无法可靠归属结果。测试模块加载失败、未知套件和运行器/清理异常都会计入 `failed` 与 `errors`。

## 4. Mock 策略

### 4.1 会话/文件隔离

测试运行器自动把会话默认路径重定向到每次运行独占的临时目录（`vim.fn.tempname()`），结束后清理并恢复
内存中的真实会话，防止测试污染真实历史。`kernel.*` 与 `core.session.*` 模块提供 `reset()` 方法
（config_store / event_bus / lifecycle / session_store / registry / tool_service 等），便于隔离。

### 4.2 HTTP / AI Mock

对 HTTP 请求做 Mock，模拟 LLM 的流式与非流式响应：

- 需要时覆写 `utils.http` 的请求层，或注入 mock server。
- `test_http.lua` 使用 `tests/http_server.lua` 的真实本地 TCP 服务和随机端口，覆盖分包、取消与进程退出、错误体上限；无需 Python 或外网。
- `test_integration.lua` 用 mock server 做集成；`test_fs_io.lua` 覆盖原子写入及磁盘满等故障，`test_session_store.lua` 覆盖删除重挂、日志合并和恢复。

### 4.3 工具 Mock

可直接调用工具定义，或覆写 `registry`（如 `registry.reset()` 后用 `register` 注入 mock 工具）。
`test_tools.lua`、`test_sub_agent_result.lua` 覆盖工具与子 Agent 结果。

### 4.4 事件 / 状态隔离

各模块 `reset()`（`event_bus.clear_all`、`herder.reset`、`chat_service.reset`、`status.reset` 等）
确保测试间无残留订阅/状态。

## 5. 测试覆盖主题

| 文件 | 覆盖 |
| --- | --- |
| `test_kernel` | 内核：配置合并、事件总线、生命周期 |
| `test_work_codec` | `vim.mpack` 结构化卸载、二进制往返与错误传播 |
| `test_stream_batching` | 流式分片累积（小内容即时可见、大内容与 8KB 边界 finalize 不丢数据） |
| `test_incremental` | 增量渲染（行差异、块缓存、块描述符复用、工具结果就地增长重建，增量与全量逐行一致） |
| `test_session` | 会话对象、JSONL 存储、上下文构建、压缩 |
| `test_tool_result_pruner` | 工具结果裁剪（码点计量、头/标记/尾、图像跳过） |
| `test_agent / test_guard / test_overflow` | Agent 状态机、护栏、溢出恢复、配对安全切分 |
| `test_runtime_context` | 运行时上下文注入 |
| `test_model_registry / test_model_capabilities / test_model_profiles / test_model_metadata` | 模型注册表、能力表、方言、实时元数据 |
| `test_protocol_adapter` | 协议编解码 |
| `test_prompt_cache / test_cache_strategy / test_cache_usage` | 显式缓存、前缀缓存策略、缓存命中用量 |
| `test_model_picker` | 模型选择器 |
| `test_modes` | 模式（CHAT/PLAN） |
| `test_multimodal` | 多模态图像 |
| `test_tools / test_tool_pending` | 工具执行、工具待发/暂存 |
| `test_max_tokens / test_truncation` | max_tokens 发送策略、输出截断续写 |
| `test_sub_agent_result` | 子 Agent 结果 |
| `test_pending_queue` | 待发消息队列 |
| `test_services / test_status` | 服务层（chat/tool/model/status）、状态栏 |
| `test_ask_user / test_herder` | 提问、Herder 上报 |
| `test_plan_mode / test_plan_distill / test_todo` | 计划模式、计划蒸馏、待办 |
| `test_skills` | Skills（frontmatter/发现/装载） |
| `test_mcp_client / test_mcp_transport / test_mcp_bridge` | MCP 客户端、传输层、桥接 |
| `test_chat_ui / test_tree_ui / test_chat_keys` | 聊天/树 UI、聊天键位 |
| `test_display_modes / test_fold / test_markdown` | 显示模式、折叠、Markdown |
| `test_timer / test_http / test_integration` | 可暂停计时器、HTTP 客户端、集成（mock server） |
| `test_sha256` | 纯 Lua SHA-256 与 `vim.fn.sha256` 交叉校验（含工作线程 `load(source)` 等价） |
| `test_secret_async` | 密钥异步假化：工作线程与同步结果一致、可 detokenize 还原、禁用时原样返回 |
| `test_secret_fake` | 格式保真假密钥：前缀/长度/字符类/熵 >= 原始、JWT/私钥块结构保真、往返与幂等、误还原边界、二进制同长随机字节 + 标记还原、出网白名单/供应商自动信任/headless 失败关闭/弹窗决策、数据流账本与不透明派生标记 |
| `test_lsp_guard` | NeoAI 界面 buffer 的 LSP 隔离：neoai* 自动关闭 LSP/Copilot、acwrite 保留、安装/卸载幂等 |
| `test_plugins` | 插件协议：依赖等待、替换、禁用、失败回滚、实际消息请求、重复启动、工具/提示段释放、热重载 |
| `test_sandbox` | 工具沙箱：加载器附加规格、fail-closed、状态机/幂等/fencing、策略聚合与受限规则、dry-run 不落盘、CAS 发布与冲突、buffer 写盘重定向、运行时能力探测与隔离进程、异步审批入队/应用/拒绝、选择性应用、保存/撤销保存（回滚原文件并回到待审、CAS 冲突拒绝）、run_command overlay 候选捕获、影响模型、证据脱敏分页、任务授权自动应用/范围、约束聚合、裁决信封、保留期与指标、受控网络网关、broker 幂等与对账、依赖图闭包、组合发布与路径冲突、策略回放、证据保留期、cgroup 资源域与 PID 上限、seccomp 基线施加与门禁、内容寻址缓存、故障注入（发布/后端/冻结）、性能基准、revision 派生、密钥原始值（工具参数/AI 上下文）停止并弹窗确认、假密钥操作警告提级不终止、环境变量名引用/环境变量密钥裸值不登记且不终止、暂存后端默认落盘/可切 shm、磁盘上限门禁 |
| `test_sandbox_instance` | 沙箱进程实例隔离：实例 store 根互不可见、热重载保留本实例待审、`init` 不阻塞探测运行时能力（懒加载）、过期实例目录回收 |
| `test_sandbox_service` | 长驻服务/镜像/诊断：service 启动/日志/状态/停止与注册表清理、停止时捕获服务改动回暂存、优雅停止（SIGTERM 优雅退出/超时 SIGKILL/`stop_all`）、`long_lived` 门禁分支、pip/npm/maven 镜像注入（含 settings.xml）、cgroup 事件快照与 OOM 判定 |
| `test_sandbox_background` | 后台进程/会话级常驻实例：`&`/nohup/setsid 识别（排除 `&&`/重定向/中段 `&`）、开启 `resident` 后 `run_command` 的后台进程跨工具调用存活（同一命名空间内 `ps` 可见）、非后台命令正常返回 |
| `test_sandbox_systemd_user` | 伪造 `systemd --user` 解析器：`systemctl --user` 由门面处理（start/stop/is-active），用户单元在沙箱内运行且单元文件/运行态不落宿主机；`--user` 解析为 facade+scope=user |
| `test_sandbox_symlink` | 符号链接候选：`stage_link` → finish → merge → publish 在真实盘创建软链；`systemctl --user enable` 与系统级门面 `systemctl enable` 的软链被捕获为候选且不落宿主机（返回真实 `Created symlink …` 文本） |
| `test_sandbox_systemd` | systemctl 门面（方案 A）：独立调用解析与路由、unit 解析与类型门禁、依赖闭包（Requires/Wants/After、缺失依赖）、start 静默成功、status/is-active/is-system-running/is-failed 真实风格输出与退出码、不支持动词返回真实错误（不暴露沙箱）、门禁拦截不调用宿主 systemctl；Service 属性解析与 `show --property`、pending enable 虚拟视图、`reset-failed` 清除 degraded、`kill`+`Restart=always` 自动重启与 NRestarts、`.timer` 调度与 `systemd-run --on-active` 瞬态定时器 |
| `test_sandbox_maintscript` | systemd 门面入口：`process_prefix` 把极薄入口覆盖绑定真实二进制路径（不再 PATH 前置 `/tmp/.dynbin`）、包安装注入 policy-rc.d、入口经文件 IPC 转发到 Lua 门面（stdout/stderr/退出码与真实 systemctl 一致） |
| `test_net_consent` | 沙箱网络访问同意：策略 ask/allow/deny、内部端口登记免权限、headless 失败关闭、弹窗 allow_once/deny/allow_session 记忆、外部目标按策略处理 |
| `test_sandbox_overlay_invalidate` | overlay 视图同步：发布/拒绝后 `resident.sync_real` 使命令读到真实盘新内容（不再读到旧物化，修复视图分裂）；权限位变化触发重新物化 |

### 5.1 沙箱逃逸/信息泄露审计（`scripts/sandbox_audit.lua`）

在真实沙箱内跑一组攻击探测（写入危险全局 sysctl、读宿主凭据/socket、magic sysrq、
`mount`/`unshare`/`nsenter`、`/proc/net` 与 `ip` 信息泄露、裸 TCP vs 代理拦截等），输出
结构化报告供人工确认：

```bash
nvim --headless --clean -u NONE --cmd "set rtp+=$PWD" -c "luafile scripts/sandbox_audit.lua"
```

判读：所有 `write_*` 应为 `READONLY`；`socket AF_VSOCK`/`AF_PACKET`/`AF_ALG` 应为 `EPERM`、
`clone_NEWUSER` 应 `EPERM`、`clone3` 应 `ENOSYS`、`sysctl(2)` 应 `ENOSYS`；
`raw_tcp_host=RAW_REACHED`、`proc_net_*`/`ip_*`/`host_info_leaks` 非零为**已知残余边界**
（共享 netns/全局 procfs 固有，见 [sandbox.md](sandbox.md) §6.1）。回归由 `test_sandbox` 的
「强制遮蔽危险全局 sysctl」「沙箱内无法写 core_pattern」「clone 命名空间过滤」「socket 地址族
白名单」「read_file /proc 脱敏」「遮蔽路径符号链接/`/proc/<pid>/root` 解析」用例守护。

### 5.2 插件测试约定

- 使用唯一插件 id 与服务名，测试结束 `unregister` / `revoke`，避免污染已启动的内置插件；
- 需要改配置的用例保存并恢复 `config_store.get_all()`；
- 涉及内置插件启停的用例，在断言前先恢复 `plugins.start_all()`，防止失败时影响后续套件；
- 实际消息请求用 `tests/http_server.lua` 本地 mock，离线可复现。

## 6. 相关文档

- [threaded_testing.md](threaded_testing.md)：测试框架结构与运行器。
- [utils.md](utils.md)：`utils.async`（Deferred/sleep 等用于测试）。
- [plugins.md](plugins.md)：插件系统与清理/替换测试要求。
