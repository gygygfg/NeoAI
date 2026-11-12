--- AGENTS.md 自动加载
--- @module 'NeoAI.core.session.agents_md'
--- 仓库级开发约定文件（默认 `AGENTS.md`）的自动发现与注入。
---
--- 为什么注入「一轮 read_file 工具调用」而不是写进系统提示段：
---   系统提示要求逐字节稳定（provider 前缀缓存），一旦把文件内容塞进系统提示，文件任何
---   变动都会让整段前缀缓存失效。这里改为在会话首个回合把 AGENTS.md 作为一次已完成工具
---   调用放进历史：assistant(tool_calls=read_file) + tool(内容)，模型每轮都能看到，
---   且不动系统提示。
---
--- 注入时机：首个用户消息之后（由 `core/agent/runtime.run` 调用 `ensure`）。放首位会让个别
--- provider（Anthropic/Gemini 要求首条为 user）拒绝请求，因此统一排在用户消息之后。
--- 每次会话只注入一次（`agent._agents_md_injected` 幂等），重开会话不会重复注入。
---
--- 边界：注入只读文件、不写；AI 若要更新 AGENTS.md 仍走既有沙箱审批，不因本模块放行。

local M = {}

--- 默认配置兜底（default_config 缺省时仍可用）
local DEFAULTS = {
  enabled = true,
  file = "AGENTS.md",
  max_bytes = 64 * 1024,
  auto_allow_read = true,
}

--- 虚构工具调用轮的 assistant reasoning。
--- DeepSeek thinking 模式要求「请求携带 tools 时所有历史 assistant 必须回传
--- reasoning_content」；这一轮是我们构造的，没有被真实模型生成，因此必须补一个占位
--- reasoning，否则首轮请求会直接 400。
local SYNTHETIC_REASONING = "先读取本工作区的开发约定（AGENTS.md），后续实现需遵守其中的规则。"

-- ========== 私有函数 ==========

--- 取配置
--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("session.agents_md")
  end)
  if not ok or type(cfg) ~= "table" then return vim.deepcopy(DEFAULTS) end
  local out = vim.deepcopy(DEFAULTS)
  for k, v in pairs(cfg) do out[k] = v end
  return out
end

--- 规范化绝对目录（展开 ~，去尾斜杠）
--- @param dir string
--- @return string
local function _norm(dir)
  local abs = vim.fn.fnamemodify(vim.fn.expand(dir), ":p")
  if abs ~= "/" then abs = abs:gsub("/+$", "") end
  return abs
end

--- 拼接目录与文件名（避免根目录出现 `//name`）
--- @param dir string
--- @param name string
--- @return string
local function _join(dir, name)
  if dir == "/" then return "/" .. name end
  return dir .. "/" .. name
end

-- ========== 公开 API ==========

--- 从 start 目录向上查找约定文件
--- 逐级向上直到根目录；命中返回绝对路径（规范化），未命中返回 nil。
--- @param start string|nil 起始目录（默认 cwd）
--- @param name string|nil 文件名（默认 session.agents_md.file）
--- @return string|nil
function M.find(start, name)
  name = name or _cfg().file or DEFAULTS.file
  local dir = _norm(start or vim.fn.getcwd())
  if dir == "" then return nil end
  while true do
    local candidate = _join(dir, name)
    local stat = vim.uv.fs_stat(candidate)
    if stat and stat.type == "file" then return candidate end
    if dir == "/" then return nil end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == "" then return nil end
    parent = parent:gsub("/+$", "")
    if parent == "" then parent = "/" end
    if parent == dir then return nil end
    dir = parent
  end
end

--- 读取约定文件（UTF-8 安全，超 max_bytes 截断并标注）
--- @param path string 绝对路径
--- @return table|nil { path, text, lines, bytes, truncated }
function M.load(path)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return nil end
  local cfg = _cfg()
  local max_bytes = tonumber(cfg.max_bytes) or DEFAULTS.max_bytes
  local text = table.concat(lines, "\n")
  local truncated = false
  if max_bytes > 0 and #text > max_bytes then
    local stringx = require("NeoAI.utils.stringx")
    text = stringx.safe_truncate(text, max_bytes, "\n…（AGENTS.md 已截断）") or text
    truncated = true
  end
  return {
    path = path,
    text = text,
    lines = #lines,
    bytes = #text,
    truncated = truncated,
  }
end

--- 指定路径是否是当前工作区的约定文件（读取该文件免沙箱审批）。
--- 仅用于只读工具（read_file）；写入/编辑仍走既有审批。
--- @param path string|nil
--- @param start string|nil 起始目录（默认 cwd）
--- @return boolean
function M.is_target(path, start)
  if type(path) ~= "string" or path == "" then return false end
  local base = start or vim.fn.getcwd()
  local target = M.find(base, _cfg().file)
  if not target then return false end
  local expanded = vim.fn.expand(path)
  if expanded:sub(1, 1) ~= "/" then expanded = _join(_norm(base), expanded) end
  local abs = vim.fn.fnamemodify(expanded, ":p")
  if abs ~= "/" then abs = abs:gsub("/+$", "") end
  local okr, real = pcall(vim.fn.resolve, abs)
  if okr and type(real) == "string" and real ~= "" then abs = real end
  local okt, real_target = pcall(vim.fn.resolve, target)
  if okt and type(real_target) == "string" and real_target ~= "" then target = real_target end
  return abs == target
end

--- 注入说明（追加在工具结果末尾，明确「须遵守」与「写入需审批」）
--- @return string
local function _directive()
  return "\n\n---\n"
    .. "以上是本工作区的开发约定（AGENTS.md），请在后续所有实现中遵守。\n"
    .. "如果开发约定发生变化（新增/调整规则、目录结构变更等），可主动更新 AGENTS.md；"
    .. "写入会经过沙箱审批，不会自动放行。"
end

--- 为历史会话中「旧版注入的虚构工具轮」补齐占位 reasoning。
--- 旧版本注入的 assistant(tool_calls=read_file) 没有 reasoning；DeepSeek thinking + tools
--- 会在恢复该会话后的首个请求直接 400。这里按 agents_md 标记就地补齐（幂等）。
--- @param agent table|nil
--- @return boolean changed
function M.backfill(agent)
  if type(agent) ~= "table" or type(agent.messages) ~= "table" then return false end
  if agent._agents_md_reasoning_backfilled then return false end
  agent._agents_md_reasoning_backfilled = true
  local changed = false
  for _, m in ipairs(agent.messages) do
    if m.role == "assistant" and (type(m.reasoning) ~= "string" or m.reasoning == "") then
      local synthetic = m.meta and m.meta.agents_md == true
      if not synthetic then
        -- meta 不随会话持久化；旧会话靠调用 id 前缀识别（见 inject 的 call_id）。
        for _, tc in ipairs(m.tool_calls or {}) do
          if type(tc.id) == "string" and tc.id:find("neoai_agents_md_", 1, true) == 1 then
            synthetic = true
            break
          end
        end
      end
      if synthetic then
        m.reasoning = SYNTHETIC_REASONING
        changed = true
      end
    end
  end
  return changed
end

--- 判断 agent 是否应注入（顶层 agent + 未注入过 + 配置开启）
--- @param agent table|nil
--- @return boolean
function M.should_inject(agent)
  if type(agent) ~= "table" or type(agent.messages) ~= "table" then return false end
  if agent.parent then return false end
  if agent._agents_md_injected then return false end
  if _cfg().enabled == false then return false end
  return true
end

--- 向 agent 注入一轮 read_file 工具调用（assistant tool_calls + tool 结果）
--- 幂等：成功后置 `agent._agents_md_injected=true`；未找到文件/读取失败时返回 false 且不置位
--- （下一次仍可重试，例如用户稍后补上 AGENTS.md）。
--- @param agent table
--- @param opts table|nil { cwd? = string }
--- @return boolean injected
function M.inject(agent, opts)
  if not M.should_inject(agent) then return false end
  opts = opts or {}
  local cfg = _cfg()
  local path = M.find(opts.cwd or agent.cwd or vim.fn.getcwd(), cfg.file)
  if not path then return false end
  local doc = M.load(path)
  if not doc then return false end

  agent._agents_md_injected = true
  agent._agents_md_path = path

  local ok_json, json = pcall(require, "NeoAI.utils.json")
  local encoded = nil
  if ok_json and json and type(json.encode) == "function" then
    local ok_enc, value = pcall(json.encode, {
      file_path = path,
      start_line = 1,
      end_line = math.max(1, doc.lines),
    })
    if ok_enc and type(value) == "string" then encoded = value end
  end
  encoded = encoded or ("{}")

  local agent_mod = require("NeoAI.core.agent.agent")
  local call_id = "neoai_agents_md_" .. tostring(agent.id or "agent")
  local meta = { agents_md = true }

  agent_mod.add_message(agent, "assistant", "", {
    -- 虚构轮必须带 reasoning：DeepSeek thinking + tools 会校验历史 assistant 的
    -- reasoning_content（无则 400）。占位文本仅用于满足协议，不伪装成真实思考内容。
    reasoning = SYNTHETIC_REASONING,
    tool_calls = {
      {
        id = call_id,
        type = "function",
        ["function"] = { name = "read_file", arguments = encoded },
      },
    },
    meta = meta,
  })
  agent_mod.add_tool_result(agent, call_id, "read_file", doc.text .. _directive(), {
    meta = meta,
    duration_ms = 0,
  })
  return true
end

--- 若满足条件则尝试注入（供 runtime 调用；失败静默）
--- @param agent table
--- @return boolean injected
function M.ensure(agent)
  -- 先补齐旧会话的占位 reasoning（幂等），再尝试首次注入。
  pcall(M.backfill, agent)
  local ok, injected = pcall(M.inject, agent)
  if ok then return injected == true end
  return false
end

--- 重置注入状态（测试/热重载用）
--- @param agent table|nil
function M.reset(agent)
  if type(agent) == "table" then
    agent._agents_md_injected = nil
    agent._agents_md_path = nil
    agent._agents_md_reasoning_backfilled = nil
  end
end

return M
