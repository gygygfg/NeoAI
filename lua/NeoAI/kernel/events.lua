--- NeoAI 事件常量注册表
--- @module NeoAI.kernel.events
--- 事件名规范：domain:verb（如 "agent:spawn"、"stream:chunk"）。
--- 所有模块通过引用常量触发/监听事件，禁止硬编码事件字符串。

local M = {}

-- ========== Agent 生命周期 ==========
M.AGENT_CREATED = "agent:created"
M.AGENT_SPAWNED = "agent:spawned"
M.AGENT_DISPOSED = "agent:disposed"
M.AGENT_ABORTED = "agent:aborted"
M.AGENT_STATE_CHANGED = "agent:state_changed"

-- ========== 生成 / 流式 ==========
M.GENERATION_STARTED = "generation:started"
M.GENERATION_COMPLETED = "generation:completed"
M.GENERATION_ERROR = "generation:error"
M.GENERATION_CANCELLED = "generation:cancelled"
M.STREAM_STARTED = "stream:started"
M.STREAM_CHUNK = "stream:chunk"
M.STREAM_COMPLETED = "stream:completed"
M.STREAM_ERROR = "stream:error"

-- ========== 推理 ==========
M.REASONING_STARTED = "reasoning:started"
M.REASONING_CHUNK = "reasoning:chunk"
M.REASONING_COMPLETED = "reasoning:completed"

-- ========== 消息 ==========
M.MESSAGE_ADDED = "message:added"
M.MESSAGE_UPDATED = "message:updated"
M.MESSAGE_EDITED = "message:edited"
M.MESSAGE_DELETED = "message:deleted"
M.MESSAGE_SENT = "message:sent"
M.MESSAGE_QUEUED = "message:queued"
M.MESSAGES_CLEARED = "messages:cleared"

-- ========== 会话 ==========
M.SESSION_CREATED = "session:created"
M.SESSION_LOADED = "session:loaded"
M.SESSION_SAVED = "session:saved"
M.SESSION_DELETED = "session:deleted"
M.SESSION_SWITCHED = "session:switched"
M.SESSION_RENAMED = "session:renamed"
M.SESSION_FORKED = "session:forked"

-- ========== 分支 / 树 ==========
M.BRANCH_CREATED = "branch:created"
M.BRANCH_DELETED = "branch:deleted"
M.TREE_REFRESHED = "tree:refreshed"

-- ========== 工具 ==========
M.TOOL_LOOP_STARTED = "tool_loop:started"
M.TOOL_LOOP_FINISHED = "tool_loop:finished"
M.TOOL_LOOP_LIMIT_REACHED = "tool_loop:limit_reached"
M.TOOL_EXECUTION_STARTED = "tool:execution_started"
M.TOOL_EXECUTION_COMPLETED = "tool:execution_completed"
M.TOOL_EXECUTION_ERROR = "tool:execution_error"
M.TOOL_CALL_DETECTED = "tool:call_detected"
M.TOOL_APPROVAL_REQUESTED = "tool:approval_requested"
M.TOOL_APPROVED = "tool:approved"
M.TOOL_APPROVAL_CANCELLED = "tool:approval_cancelled"
M.TOOL_RESULT_RECEIVED = "tool:result_received"
M.TOOL_LOOP_GUARD_REMINDER = "tool_loop:guard_reminder"

-- ========== 用户提问（ask_user） ==========
-- 开始等待用户回答时触发（agent 处于 blocked 候选），回答/取消后触发 answered。
M.ASK_USER_WAITING = "ask_user:waiting"
M.ASK_USER_ANSWERED = "ask_user:answered"

-- ========== 工具参数接收（流式） ==========
-- 模型流式生成工具调用参数时逐片触发（携带当前累积的 tool_calls 快照），
-- 参数流结束触发 completed。UI 用它像推理悬浮窗一样实时展示"接收参数"悬浮窗。
M.TOOL_ARG_CHUNK = "tool:arg_chunk"
M.TOOL_ARG_COMPLETED = "tool:arg_completed"

-- ========== 待办 / 计划模式 ==========
M.TODO_UPDATED = "todo:updated"
M.PLAN_MODE_CHANGED = "plan_mode:changed"

-- ========== 模型 ==========
M.MODELS_UPDATED = "models:updated"
M.MODEL_SWITCHED = "model:switched"
M.MODEL_REFRESH_STARTED = "models:refresh_started"
M.MODEL_REFRESH_FAILED = "models:refresh_failed"

-- ========== UI / 窗口 ==========
M.WINDOW_OPENED = "window:opened"
M.WINDOW_CLOSED = "window:closed"
M.UI_REFRESHED = "ui:refreshed"
M.UI_MODE_CHANGED = "ui:mode_changed"
M.DISPLAY_MODE_CHANGED = "display:mode_changed"

-- ========== 子 Agent ==========
M.SUB_AGENT_CREATED = "sub_agent:created"
M.SUB_AGENT_UPDATED = "sub_agent:updated"
M.SUB_AGENT_COMPLETED = "sub_agent:completed"
M.SUB_AGENT_ERROR = "sub_agent:error"
M.SUB_AGENT_RESULT_READY = "sub_agent:result_ready"

-- ========== 配置 / 生命周期 ==========
M.CONFIG_LOADED = "config:loaded"
M.CONFIG_CHANGED = "config:changed"
M.PLUGIN_INITIALIZED = "plugin:initialized"
M.PLUGIN_SHUTDOWN = "plugin:shutdown"
M.PLUGIN_LOADED = "plugin:loaded"
M.PLUGIN_UNLOADED = "plugin:unloaded"
M.PLUGIN_FAILED = "plugin:failed"

-- ========== MCP ==========
M.MCP_CONNECTING = "mcp:connecting"
M.MCP_READY = "mcp:ready"
M.MCP_ERROR = "mcp:error"
M.MCP_DISCONNECTED = "mcp:disconnected"
M.MCP_TOOLS_UPDATED = "mcp:tools_updated"

-- ========== Skills ==========
M.SKILLS_UPDATED = "skills:updated"

-- ========== 日志 ==========
M.LOG_MESSAGE = "log:message"

-- ========== 上下文压缩 ==========
M.COMPACTION_STARTED = "compaction:started"
M.COMPACTION_CHUNK = "compaction:chunk"
M.COMPACTION_COMPLETED = "compaction:completed"
M.TOOL_RESULT_PRUNED = "tool:result_pruned"

-- ========== 沙箱 ==========
M.SANDBOX_PREFLIGHT_STARTED = "sandbox:preflight_started"
M.SANDBOX_STAGED = "sandbox:staged"
M.SANDBOX_CANDIDATE_READY = "sandbox:candidate_ready"
M.SANDBOX_PUBLISH_STARTED = "sandbox:publish_started"
M.SANDBOX_COMMITTED = "sandbox:committed"
M.SANDBOX_DISCARDED = "sandbox:discarded"
M.SANDBOX_CONFLICT = "sandbox:conflict"
M.SANDBOX_RECOVERY_REQUIRED = "sandbox:recovery_required"
M.SANDBOX_OUTCOME_UNKNOWN = "sandbox:outcome_unknown"
M.SANDBOX_REVIEW_ENQUEUED = "sandbox:review_enqueued"
M.SANDBOX_REVIEW_APPROVED = "sandbox:review_approved"
M.SANDBOX_REVIEW_REJECTED = "sandbox:review_rejected"
M.SANDBOX_REVIEW_SUPERSEDED = "sandbox:review_superseded"
M.SANDBOX_APPLIED = "sandbox:applied"
-- 撤销保存：把真实文件回滚到应用前内容，并把变更单元移回待审（payload.requeued=true）。
-- 历史遗留的「已撤销」记录 `u` 重做保存时也会发此事件（apply_state APPLIED ↔ REVERTED）。
M.SANDBOX_REVERTED = "sandbox:reverted"
M.SANDBOX_GRANT_CREATED = "sandbox:grant_created"
M.SANDBOX_GRANT_REVOKED = "sandbox:grant_revoked"

-- ========== 沙箱权限档位 / 自动提权 ==========
M.SANDBOX_PRIVILEGE_CLASSIFIED = "sandbox:privilege_classified"
M.SANDBOX_PRIVILEGE_ESCALATION_REQUESTED = "sandbox:privilege_escalation_requested"
M.SANDBOX_PRIVILEGE_ESCALATION_GRANTED = "sandbox:privilege_escalation_granted"
M.SANDBOX_PRIVILEGE_ESCALATION_DENIED = "sandbox:privilege_escalation_denied"
M.SANDBOX_PRIVILEGE_RECORDED = "sandbox:privilege_recorded"
M.SANDBOX_HOST_OP_ENQUEUED = "sandbox:host_op_enqueued"
M.SANDBOX_HOST_OP_APPLIED = "sandbox:host_op_applied"
M.SANDBOX_HOST_OP_REJECTED = "sandbox:host_op_rejected"

-- ========== 沙箱密钥防护 ==========
M.SANDBOX_SECRET_DETECTED = "sandbox:secret_detected"
M.SANDBOX_SECRET_TRACED = "sandbox:secret_traced"
M.SANDBOX_SECRET_BLOCKED = "sandbox:secret_blocked"
M.SANDBOX_SECRET_ALERT = "sandbox:secret_alert"
M.SANDBOX_SECRET_EGRESS = "sandbox:secret_egress"
M.SANDBOX_SENSITIVE_REDACTED = "sandbox:sensitive_redacted"

-- 沙箱网络访问同意：沙箱外部命令访问沙箱外目标（宿主本机其他端口/外部主机）时请求用户同意
M.SANDBOX_NET_CONSENT_REQUESTED = "sandbox:net_consent_requested"

-- 越界访问留痕：读取/操作当前工作区（cwd）之外的用户目录（home/root 等）
M.SANDBOX_OUTSIDE_ACCESS = "sandbox:outside_access"

-- ========== 沙箱安全分级 / 行为审计 / 容器受控 ==========
M.SANDBOX_RISK_ASSESSED = "sandbox:risk_assessed"
M.SANDBOX_RISK_BLOCKED = "sandbox:risk_blocked"
M.SANDBOX_AUDIT_OBSERVED = "sandbox:audit_observed"
M.SANDBOX_AUDIT_ANOMALY = "sandbox:audit_anomaly"
M.SANDBOX_CONTAINER_PLANNED = "sandbox:container_planned"
M.SANDBOX_CONTAINER_UNSUPPORTED = "sandbox:container_unsupported"
-- systemctl 门面：命令在沙箱内被路由到长驻服务 / 命中不支持语义
M.SANDBOX_SYSTEMD_ROUTED = "sandbox:systemd_routed"
M.SANDBOX_SYSTEMD_UNSUPPORTED = "sandbox:systemd_unsupported"
-- 后台命令门面：run_command 的 &/nohup/setsid 被路由到长驻服务（跨调用存活）
M.SANDBOX_BACKGROUND_ROUTED = "sandbox:background_routed"

-- ========== 交互式终端（run_command PTY） ==========
-- run_command 以 PTY 运行命令时，轮询 /proc 检测到“阻塞读终端 = 等待输入”触发 waiting_input；
-- 判官子 agent / 用户手动注入时触发 input_sent；命令退出触发 exited。
M.PTY_STARTED = "pty:started"
M.PTY_WAITING_INPUT = "pty:waiting_input"
M.PTY_INPUT_SENT = "pty:input_sent"
M.PTY_EXITED = "pty:exited"

-- ========== 计划蒸馏 ==========
M.PLAN_DISTILL_STARTED = "plan_distill:started"
M.PLAN_DISTILL_CHUNK = "plan_distill:chunk"
M.PLAN_DISTILLED = "plan_distilled"

return M
