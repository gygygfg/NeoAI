--- 密钥数据流账本：记录每个假密钥的来源与所有流经点（工具参数、命令、环境变量、
--- 落盘路径、commit），并对「经命令/脚本加密后无法逐字还原」的派生文件打不透明标记。
--- @module NeoAI.sandbox.secret_flow
--- 边界：不存储明文密钥到磁盘（内存中仅保留假密钥与来源元数据）；账本经 evidence 落盘时
--- 只写假密钥/路径/工具名。通用加密变换不可逆，故派生文件以 `opaque=true` 标记，发布前强制人工确认。

local M = {}

local state = {
  ledger = {}, -- 数组 { event, fake, path, tool, command, transform, at }
  by_fake = {}, -- fake -> { origin = {...}, sinks = {...} }
  max_entries = 2000,
}

local function _now()
  return os.time()
end

local function _cfg()
  local c = require("NeoAI.kernel.config_store").get("tools.sandbox.secrets")
  return type(c) == "table" and c or {}
end

--- 是否启用数据流追踪
--- @return boolean
function M.enabled()
  return _cfg().flow_tracking ~= false
end

local function _push(entry)
  if not M.enabled() then return end
  state.ledger[#state.ledger + 1] = entry
  if #state.ledger > state.max_entries then
    table.remove(state.ledger, 1)
  end
  pcall(function()
    require("NeoAI.sandbox.evidence").add_async("secret_flow", {
      event = entry.event, fake = entry.fake, path = entry.path,
      tool = entry.tool, command = entry.command, transform = entry.transform,
    }, { tool = entry.tool, source = "observed", coverage = "full" })
  end)
end

--- 登记真实密钥 → 假密钥的来源。
--- @param secret string 真实密钥（仅用于内存来源元数据，不落盘）
--- @param fake string
--- @param rule string|nil
function M.on_register(secret, fake, rule)
  if not M.enabled() then return end
  local e = state.by_fake[fake] or { origin = {}, sinks = {} }
  e.origin = { kind = "value", rule = rule, at = _now() }
  e.real = secret
  state.by_fake[fake] = e
  _push({ event = "origin", fake = fake, rule = rule, at = _now() })
end

--- 登记二进制密钥来源。
--- @param real string
--- @param fake string
function M.on_register_binary(real, fake)
  if not M.enabled() then return end
  state.by_fake[fake] = state.by_fake[fake] or { origin = {}, sinks = {} }
  state.by_fake[fake].origin = { kind = "binary", at = _now() }
  state.by_fake[fake].real = real
  _push({ event = "origin_binary", fake = fake, at = _now() })
end

--- 记录一次数据流经点。
--- @param event string 如 "arg" | "command" | "env" | "file" | "commit" | "restore"
--- @param meta table { fake?, path?, tool?, command?, transform? }
function M.record(event, meta)
  if not M.enabled() then return end
  meta = meta or {}
  local entry = {
    event = event, fake = meta.fake, path = meta.path,
    tool = meta.tool, command = meta.command, transform = meta.transform, at = _now(),
  }
  if meta.fake then
    local e = state.by_fake[meta.fake] or { origin = {}, sinks = {} }
    e.sinks[#e.sinks + 1] = entry
    state.by_fake[meta.fake] = e
  end
  _push(entry)
end

--- 标记候选文件为「不透明派生」：命令/脚本可能加密/变换了密钥，输出无法逐字还原。
--- @param files table 候选文件数组
--- @param source table { tool?, command?, fakes? }
--- @return number 标记数
function M.mark_derived(files, source)
  if not M.enabled() then return 0 end
  source = source or {}
  local n = 0
  for _, f in ipairs(files or {}) do
    if type(f) == "table" and (f.action == "create" or f.action == "modify") then
      f.derived_opaque = true
      f.derived_source = {
        tool = source.tool, command = source.command,
        fakes = source.fakes, at = _now(),
      }
      n = n + 1
      _push({ event = "derived_opaque", path = f.path, tool = source.tool, command = source.command, at = _now() })
    end
  end
  return n
end

--- 是否存在不透明派生文件
--- @param files table
--- @return boolean
function M.has_derived(files)
  for _, f in ipairs(files or {}) do
    if type(f) == "table" and f.derived_opaque then return true end
  end
  return false
end

--- 某假密钥的来源与流经点
--- @param fake string
--- @return table|nil
function M.info(fake)
  return state.by_fake[fake]
end

--- 账本快照（测试/审计用）
--- @return table
function M.ledger()
  return vim.deepcopy(state.ledger)
end

--- 重置（测试用）
function M.reset()
  state.ledger = {}
  state.by_fake = {}
end

return M
