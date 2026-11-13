--- 高权限模式的沙箱侧进程级状态
--- @module 'NeoAI.sandbox.privileged'
--- 高权限模式本身是 per-agent 状态（见 `tools/builtin/privileged_mode.lua`），但沙箱网络
--- 代理/遮蔽/容器门面等底层策略是**进程级**的：host_proxy 的连接回调、runtime 的挂载生成
--- 都没有 agent 上下文。因此这里维护：
---   * 已标记为高权限的 agent_id 集合 + 当前 agent_id（供无 agent 上下文的模块判断）；
---   * 高权限模式下的网络访问记录环形缓冲（"只记录不拦截"的可查证据）。
--- 本模块零业务依赖，避免沙箱底层反向依赖 tools/chat 服务。
---
--- 注意：当前 agent 处于高权限模式时，同进程内其它窗口/后台命令也会继承网络放行策略
--- （网络代理是共享单例）。这是已知边界，已在文档中标注。

local M = {}

-- ========== 私有状态 ==========

local state = {
  agents = {},     -- agent_id -> true
  current_id = nil,
  records = {},    -- 网络记录环形缓冲（新→旧）
  max_records = 1000,
  ssh_paths = nil, -- 高权限模式解除遮蔽的 SSH 密钥/agent 路径缓存
}

local function _limit()
  local n = tonumber(state.max_records) or 1000
  if n < 1 then n = 1 end
  return n
end

-- ========== 公开 API ==========

--- 标记/取消标记某个 agent 处于高权限模式
--- @param agent_id string|nil
--- @param active boolean
function M.mark(agent_id, active)
  if type(agent_id) ~= "string" or agent_id == "" then return end
  if active then
    state.agents[agent_id] = true
  else
    state.agents[agent_id] = nil
  end
end

--- 指定 agent 是否被标记为高权限
--- @param agent_id string|nil
--- @return boolean
function M.is_marked(agent_id)
  return type(agent_id) == "string" and state.agents[agent_id] == true
end

--- 设置当前 agent（无 agent 上下文的沙箱模块按此判断）
--- @param agent_id string|nil
function M.set_current(agent_id)
  state.current_id = (type(agent_id) == "string" and agent_id ~= "") and agent_id or nil
end

--- 当前 agent id
--- @return string|nil
function M.current()
  return state.current_id
end

--- 指定/当前 agent 是否处于高权限模式
--- @param agent_id string|nil 省略时使用当前 agent
--- @return boolean
function M.active(agent_id)
  if type(agent_id) == "string" and agent_id ~= "" then
    return state.agents[agent_id] == true
  end
  local cur = state.current_id
  if cur then return state.agents[cur] == true end
  return false
end

--- 是否有任意 agent 处于高权限模式（诊断/测试用）
--- @return boolean
function M.any_active()
  return next(state.agents) ~= nil
end

--- 网络放行判据（**进程级**）：进程内任一 Agent 处于高权限模式即放行。
--- 网络代理（`host_proxy`）是进程级共享单例，连接回调里没有 Agent 上下文，无法按连接
--- 归属判定；因此按「存在 PRIV 会话」整进程放行并记录。UI 焦点切换（多聊天窗口 / 子 Agent
--- 窗口 / 新建会话会把 current 指向别的 Agent）不再改变放行与记录结果。
--- 与文档「网络代理是共享单例，其它窗口/后台命令继承网络放行策略」的边界一致。
--- @return boolean
function M.network_active()
  return next(state.agents) ~= nil
end

--- 高权限模式是否解除 `offline=true` 的硬网络隔离（默认 true）。
--- @return boolean
function M.override_offline()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.privileged_mode") or {}
  end)
  return not (ok and cfg.override_offline == false)
end

--- 高权限模式解除遮蔽的 SSH 密钥 / agent 路径（按当前用户与 home 展开）。
--- 仅用于 unmask；是否启用由 `tools.privileged_mode.unmask_ssh_keys` 控制（默认开）。
--- @return string[]
function M.ssh_unmask_paths()
  if state.ssh_paths then return state.ssh_paths end
  local out, seen = {}, {}
  local function add(p)
    if type(p) ~= "string" or p == "" then return end
    if not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  add("/root/.ssh")
  local home_ssh = vim.fn.expand("~/.ssh")
  if type(home_ssh) == "string" and home_ssh ~= "" then add(home_ssh) end
  for _, p in ipairs(vim.fn.glob("/home/*/.ssh", false, true)) do add(p) end
  add("/root/.ssh-agent")
  add("/run/ssh-agent.socket")
  for _, p in ipairs(vim.fn.glob("/run/user/*/ssh*", false, true)) do add(p) end
  for _, p in ipairs(vim.fn.glob("/tmp/ssh-*", false, true)) do add(p) end
  state.ssh_paths = out
  return out
end

--- 指定路径是否属于 SSH 密钥/agent 路径（含子路径）。
--- @param path string|nil
--- @return boolean
function M.is_ssh_path(path)
  if type(path) ~= "string" or path == "" then return false end
  local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if abs ~= "/" then abs = abs:gsub("/+$", "") end
  for _, p in ipairs(M.ssh_unmask_paths()) do
    local base = vim.fn.fnamemodify(p, ":p")
    if base ~= "/" then base = base:gsub("/+$", "") end
    if abs == base or abs:sub(1, #base + 1) == base .. "/" then return true end
  end
  return false
end

--- 追加一条网络访问记录（新→旧，有界环形缓冲）
--- @param rec table { host?, port?, proto?, decision?, at? }
function M.record(rec)
  if type(rec) ~= "table" then return end
  local okc, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.privileged_mode") or {}
  end)
  if okc and tonumber(cfg.max_records) then
    state.max_records = tonumber(cfg.max_records)
  end
  table.insert(state.records, 1, {
    host = rec.host,
    port = rec.port,
    proto = rec.proto,
    decision = rec.decision,
    at = rec.at or os.time(),
  })
  local max = _limit()
  while #state.records > max do table.remove(state.records) end
end

--- 读取最近的网络访问记录（新→旧），不破坏原记录
--- @param limit number|nil 默认 50
--- @return table 数组
function M.records(limit)
  local n = tonumber(limit) or 50
  if n < 1 then n = 1 end
  local out = {}
  for i = 1, math.min(n, #state.records) do
    out[i] = state.records[i]
  end
  return out
end

--- 清空网络记录
function M.clear_records()
  state.records = {}
end

--- 重置（测试/热重载/沙箱 reset）
function M.reset()
  state.agents = {}
  state.current_id = nil
  state.records = {}
  state.max_records = 1000
  state.ssh_paths = nil
end

return M
