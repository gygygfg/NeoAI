--- 免审批预授权绑定
--- @module 'NeoAI.sandbox.protected.preauthorize'
--- 让**特定密钥**对**特定消费者**（工具 / 服务商）在**特定目标**上免审批使用，命中即静默放行。
--- 这是「保留特定密钥无审批即可被信任链工具/服务商调用」的落地：把过去按**主机**或按**整个
--- 目录**的粗放放行，收敛为「密钥指纹 × 消费者 × 目标」的显式绑定。
---
--- 约束（刻意如此）：
---   * **指纹必填**：绑定的是「这把钥匙」，不是「这个路径」。`cp` 改名或换一把钥匙后绑定立即
---     失效，避免「批准一次，换成另一把」。
---   * **只减审批，不加能力**：命中绑定只跳过弹窗，不会让资源多出能力
---     （如 SSH 私钥仍无 `read`，见 `sandbox/protected/registry.lua`）。
---   * **不免审计**：每次命中写 `observe/audit`（含指纹前缀、消费者、目标、第几次），
---     否则「信任链」会退化成无痕后门。
---   * **不可永久**：没有「永久允许」。绑定来自配置或在会话内建立，`expires_at` / `max_uses`
---     任一触发即重新走审批。
---
--- 配置：`tools.sandbox.protected.preauthorized`（数组）
---   { fingerprint = "sha256:…",            -- 必填（sha256:<hex>）
---     resource    = "~/.ssh/id_deploy",     -- 可选，仅用于审计标注（不参与匹配）
---     consumers   = { "egress", "tool:git_fetch" }, -- 空 = 任意消费者
---     targets     = { "github.com" },       -- 空 = 任意目标；支持 `*.example.com`
---     expires_at  = 1730000000,             -- 可选，epoch 秒
---     max_uses    = 100 }                   -- 可选，0/缺省 = 不限

local M = {}

-- ========== 私有状态 ==========

local state = {
  used = {}, -- key(fingerprint|consumer|target|idx) -> n
  by_index = {}, -- idx -> n（同一绑定的累计使用次数，供审计界面显示）
  seq = 0,
}

-- ========== 私有函数 ==========

--- 读取绑定列表
--- @return table
local function _bindings()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.protected")
  end)
  if not ok or type(cfg) ~= "table" then return {} end
  local list = cfg.preauthorized
  return type(list) == "table" and list or {}
end

--- 目标是否匹配绑定（精确主机 / `*.suffix`）
--- @param target string|nil
--- @param patterns table|nil
--- @return boolean
local function _target_matches(target, patterns)
  if type(patterns) ~= "table" or #patterns == 0 then return true end
  if type(target) ~= "string" or target == "" then return false end
  local t = target:lower()
  for _, pat in ipairs(patterns) do
    if type(pat) == "string" and pat ~= "" then
      local p = pat:lower()
      if p == t then return true end
      if p:sub(1, 2) == "*." then
        local suffix = p:sub(2)
        if #t > #suffix and t:sub(-#suffix) == suffix then return true end
      end
    end
  end
  return false
end

--- 消费者是否匹配（空 = 任意；支持 `*` 通配项）
--- @param consumers table|string[]|nil 请求方消费者集合
--- @param allowed table|string[]|nil 绑定允许的消费者
--- @return boolean
local function _consumer_matches(consumers, allowed)
  if type(allowed) ~= "table" or #allowed == 0 then return true end
  local req = consumers
  if type(req) == "string" then req = { req } end
  for _, a in ipairs(allowed) do
    if a == "*" then return true end
    for _, c in ipairs(req or {}) do
      if a == c then return true end
    end
  end
  return false
end

--- 绑定是否已过期/超次
--- @param b table
--- @param idx integer
--- @param fingerprint string
--- @param consumer string
--- @param target string|nil
--- @return boolean
local function _exhausted(b, idx, fingerprint, consumer, target)
  if type(b.expires_at) == "number" and os.time() > b.expires_at then return true end
  local max_uses = tonumber(b.max_uses) or 0
  if max_uses <= 0 then return false end
  local key = table.concat({ fingerprint, tostring(consumer), tostring(target), tostring(idx) }, "|")
  return (state.used[key] or 0) >= max_uses
end

--- 记录一次使用
--- @param b table
--- @param idx integer
--- @param fingerprint string
--- @param consumer string
--- @param target string|nil
--- @return integer 本次是第几次使用
local function _consume(b, idx, fingerprint, consumer, target)
  local key = table.concat({ fingerprint, tostring(consumer), tostring(target), tostring(idx) }, "|")
  state.used[key] = (state.used[key] or 0) + 1
  state.by_index[idx] = (state.by_index[idx] or 0) + 1
  return state.used[key]
end

-- ========== 公开 API ==========

--- 计算密钥指纹（`sha256:<hex>`）。同一密钥在任何路径下指纹相同。
--- 结尾空白会被去掉：PEM 块在文件内容里的匹配不含结尾换行，而用户用 `sha256sum` 计算时
--- 文件通常带结尾换行——统一口径后，`preauthorize.fingerprint_file` 与运行时检测才能对上。
--- @param value string|nil
--- @return string|nil
function M.fingerprint(value)
  if type(value) ~= "string" or value == "" then return nil end
  local v = value:gsub("%s+$", "")
  if v == "" then return nil end
  local ok, hex = pcall(vim.fn.sha256, v)
  if not ok or type(hex) ~= "string" or hex == "" then return nil end
  return "sha256:" .. hex
end

--- 计算密钥文件的指纹（与运行时检测同口径）
--- @param path string|nil
--- @return string|nil fingerprint
--- @return string|nil err
function M.fingerprint_file(path)
  if type(path) ~= "string" or path == "" then return nil, "路径为空" end
  local p = vim.fn.expand(path)
  if vim.fn.filereadable(p) ~= 1 then return nil, "文件不可读" end
  local ok, lines = pcall(vim.fn.readfile, p, "b")
  if not ok or type(lines) ~= "table" then return nil, "读取失败" end
  local fp = M.fingerprint(table.concat(lines, "\n"))
  if not fp then return nil, "内容为空" end
  return fp
end

--- 是否配置了任何绑定（用于判断是否需要走匹配）
--- @return boolean
function M.has_any()
  return #_bindings() > 0
end

--- 判断一次使用是否被预授权
--- @param opts table {
---   secret?: string, fingerprint?: string, consumers?: string|table,
---   target?: string, op?: string }
--- @return boolean allowed
--- @return table|nil binding 命中的绑定
function M.allow(opts)
  opts = opts or {}
  local fp = opts.fingerprint or M.fingerprint(opts.secret)
  if type(fp) ~= "string" or fp == "" then return false, nil end
  local list = _bindings()
  if #list == 0 then return false, nil end
  local consumer_label = type(opts.consumers) == "table" and opts.consumers[1] or opts.consumers
  for idx, b in ipairs(list) do
    if type(b) == "table" and b.fingerprint == fp
      and _consumer_matches(opts.consumers, b.consumers)
      and _target_matches(opts.target, b.targets)
      and not _exhausted(b, idx, fp, tostring(consumer_label or ""), opts.target) then
      local uses = _consume(b, idx, fp, tostring(consumer_label or ""), opts.target)
      state.seq = state.seq + 1
      -- 免审批 ≠ 免审计：每次命中都留痕（含指纹前缀，不写完整指纹与明文）。
      pcall(function()
        require("NeoAI.sandbox.observe.audit").record({
          kind = "protected",
          tool = consumer_label,
          level = 1,
          reasons = { "PREAUTHORIZED_USE" },
          meta = {
            seq = state.seq,
            fingerprint = fp:sub(1, 18) .. "…",
            resource = b.resource,
            target = opts.target,
            op = opts.op,
            uses = uses,
            max_uses = b.max_uses,
          },
        })
      end)
      return true, b
    end
  end
  return false, nil
end

--- 列出与请求匹配的绑定（**不消费**配额、不写审计）
--- 供「需要先看匹配结果再决定用哪几个」的调用方（如 git 只读放开指定私钥）。
--- @param opts table { consumers?: string|table, target?: string }
--- @return table[] { index, fingerprint, resource, consumers, targets, max_uses }
function M.match_all(opts)
  opts = opts or {}
  local out = {}
  for idx, b in ipairs(_bindings()) do
    if type(b) == "table" and type(b.fingerprint) == "string" and b.fingerprint ~= ""
      and _consumer_matches(opts.consumers, b.consumers)
      and _target_matches(opts.target, b.targets)
      and not (type(b.expires_at) == "number" and os.time() > b.expires_at) then
      out[#out + 1] = {
        index = idx,
        fingerprint = b.fingerprint,
        resource = b.resource,
        consumers = b.consumers,
        targets = b.targets,
        max_uses = b.max_uses,
      }
    end
  end
  return out
end

--- 列出绑定（供 `:NeoAI SandboxReview` 与测试；不含计数器）
--- @return table[]
function M.list()
  local out = {}
  for i, b in ipairs(_bindings()) do
    if type(b) == "table" then
      out[#out + 1] = {
        index = i,
        fingerprint = b.fingerprint,
        resource = b.resource,
        consumers = b.consumers,
        targets = b.targets,
        expires_at = b.expires_at,
        max_uses = b.max_uses,
      }
    end
  end
  return out
end

--- 各绑定的累计使用次数（按配置下标）
--- @return table<integer, integer>
function M.usage()
  local out = {}
  for k, v in pairs(state.by_index) do out[k] = v end
  return out
end

--- 撤销一条绑定（按配置下标，从**运行时**配置移除）。
--- 免审批之所以可接受，前提是「用一次看得到、随时能撤回」；撤销是会话内生效（`config_store.set`
--- 只改内存热配置，不写用户配置文件——重启后恢复原配置，与「加入白名单」同一语义），并留审计。
--- @param index integer
--- @return boolean ok
--- @return string|nil err
function M.revoke(index)
  index = tonumber(index)
  local list = _bindings()
  if not index or index < 1 or index > #list then
    return false, "PREAUTH_INDEX_INVALID: 没有第 " .. tostring(index) .. " 条绑定"
  end
  local removed = list[index]
  local out = {}
  for i, b in ipairs(list) do
    if i ~= index then out[#out + 1] = b end
  end
  local ok, err = pcall(function()
    require("NeoAI.kernel.config_store").set("tools.sandbox.protected.preauthorized", out)
  end)
  if not ok then return false, "PREAUTH_REVOKE_FAILED: " .. tostring(err) end
  state.by_index = {}
  pcall(function()
    require("NeoAI.sandbox.observe.audit").record({
      kind = "protected",
      tool = "preauthorize",
      level = 1,
      reasons = { "PREAUTHORIZED_REVOKED" },
      meta = {
        index = index,
        fingerprint = type(removed) == "table" and removed.fingerprint and
          tostring(removed.fingerprint):sub(1, 18) .. "…" or nil,
        resource = type(removed) == "table" and removed.resource or nil,
      },
    })
  end)
  return true
end

--- 重置使用计数（测试用）
function M.reset()
  state.used = {}
  state.by_index = {}
  state.seq = 0
end

return M
