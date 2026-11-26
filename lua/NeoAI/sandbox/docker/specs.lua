--- 容器重建规格
--- @module 'NeoAI.sandbox.docker.specs'
---
--- 会话 userns 销毁时容器必然消失；需要跨会话存在的容器以**规格**（不是容器快照）重建：
---   * 安全规格（mount 全在 workspace、无危险参数、无敏感 env、有资源限制）
---     → 作为工作区审批条目，下次会话自动重建；记录 evidence，用户可撤销。
---   * 其它规格 → pending，必须用户在 `:NeoAI SandboxDocker` 手动批准后才重建。
---   * 原容器在会话退出时是关闭状态 → 不自动启动，只在终端打印重建命令与安全性。
---
--- 本模块只管理规格与展示；实际 create/start 由 broker/session 回调完成。

local fs = require("NeoAI.utils.fs")
local review = require("NeoAI.sandbox.docker.review")

local M = {}

local state = {
  root = nil,
  pending = {}, -- spec_id -> true（本会话发现、等待用户批准的非安全规格）
  auto = {},    -- spec_id -> true（本会话自动重建）
  suspended = {}, -- spec_id -> { count=..., until_ts=... }
}

-- ========== 私有函数 ==========

--- 取源/目标
local function _bind_parts(spec)
  local parts = {}
  for p in (tostring(spec) .. ":"):gmatch("(.-):") do parts[#parts + 1] = p end
  if #parts < 2 then return nil, nil end
  return parts[1], parts[2]
end

--- 路径是否在 workspace 根下
local function _under(p, roots)
  local path = tostring(p or ""):gsub("/+$", "")
  for _, root in ipairs(roots or {}) do
    local r = tostring(root or ""):gsub("/+$", "")
    if r ~= "" and (path == r or path:sub(1, #r + 1) == r .. "/") then return true end
  end
  return false
end

--- 稳定 spec id
local function _spec_id(spec)
  local parts = {
    tostring(spec.name or ""), tostring(spec.image or ""),
    tostring(spec.image_digest or ""), tostring(spec.workspace or ""),
  }
  local ok, sum = pcall(vim.fn.sha256, table.concat(parts, "\n"))
  if ok and type(sum) == "string" and sum ~= "" then return sum:sub(1, 32) end
  return tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
end

--- 规范化 mount 列表（只保留 bind；volume 交给 review 判 sensitive）。
local function _mounts(insp)
  local out = {}
  local hc = type(insp.HostConfig) == "table" and insp.HostConfig or {}
  if type(hc.Binds) == "table" then
    for _, spec in ipairs(hc.Binds) do
      local src, dst = _bind_parts(spec)
      if src and dst then
        out[#out + 1] = { type = "bind", source = src, destination = dst, read_only = spec:find(":ro", 1, true) ~= nil }
      end
    end
  end
  if type(hc.Mounts) == "table" then
    for _, m in ipairs(hc.Mounts) do
      if type(m) == "table" then
        out[#out + 1] = {
          type = tostring(m.Type or ""):lower(),
          source = m.Source and tostring(m.Source) or nil,
          destination = m.Target and tostring(m.Target) or nil,
          read_only = m.ReadOnly == true,
        }
      end
    end
  end
  return out
end

--- env 只保留 key；值不落盘（敏感容器不能自动重建）。
local function _env_keys(insp)
  local out = {}
  local cfg = type(insp.Config) == "table" and insp.Config or {}
  if type(cfg.Env) == "table" then
    for _, item in ipairs(cfg.Env) do
      local k = tostring(item):match("^([^=]+)=")
      if k then out[#out + 1] = k end
    end
  end
  table.sort(out)
  return out
end

--- 重建命令（**仅用于展示/用户手动执行**；内部重建走结构化 spec，不经过 shell）。
--- @param spec table
--- @return string
function M.rebuild_command(spec)
  local argv = { "docker", "run", "-d", "--name", vim.fn.shellescape(tostring(spec.name or "neoai")) }
  for _, m in ipairs(spec.mounts or {}) do
    if m.source and m.destination then
      local suffix = m.read_only and ":ro" or ""
      argv[#argv + 1] = "-v"
      argv[#argv + 1] = vim.fn.shellescape(tostring(m.source) .. ":" .. tostring(m.destination) .. suffix)
    end
  end
  if spec.memory and tonumber(spec.memory) > 0 then
    argv[#argv + 1] = "--memory"
    argv[#argv + 1] = tostring(spec.memory)
  end
  if spec.pids and tonumber(spec.pids) > 0 then
    argv[#argv + 1] = "--pids-limit"
    argv[#argv + 1] = tostring(spec.pids)
  end
  argv[#argv + 1] = tostring(spec.image or "?")
  for _, c in ipairs(spec.cmd or {}) do
    argv[#argv + 1] = vim.fn.shellescape(tostring(c))
  end
  return table.concat(argv, " ")
end

--- 安全性摘要（人类可读）。
--- @param spec table
--- @return string
function M.safety_text(spec)
  local lines = {
    "安全等级: " .. tostring(spec.review_level or "?"),
    "自动重建: " .. (spec.mode == "auto" and "是" or "否（需手动批准）"),
    "原状态: " .. (spec.was_running and "运行中" or "已关闭（仅打印命令，不自动启动）"),
  }
  if spec.review_reasons and #spec.review_reasons > 0 then
    lines[#lines + 1] = "原因: " .. table.concat(spec.review_reasons, ", ")
  end
  if spec.mounts and #spec.mounts > 0 then
    local ms = {}
    for _, m in ipairs(spec.mounts) do
      ms[#ms + 1] = tostring(m.source) .. " -> " .. tostring(m.destination) .. (m.read_only and " (ro)" or " (rw)")
    end
    lines[#lines + 1] = "挂载: " .. table.concat(ms, "; ")
  end
  return table.concat(lines, "\n")
end

--- 转换为 Docker create body（结构化；实际执行仍经 broker 策略）。
--- @param spec table
--- @return table
function M.to_create_body(spec)
  local hc = {
    Memory = spec.memory,
    PidsLimit = spec.pids,
    NanoCpus = spec.nano_cpus,
    NetworkMode = spec.network_mode,
    CapDrop = { "ALL" },
  }
  local binds = {}
  for _, m in ipairs(spec.mounts or {}) do
    if m.type == "bind" and m.source and m.destination then
      binds[#binds + 1] = tostring(m.source) .. ":" .. tostring(m.destination) .. (m.read_only and ":ro" or ":rw")
    end
  end
  if #binds > 0 then hc.Binds = binds end
  local body = {
    Image = spec.image_digest ~= "" and spec.image_digest or spec.image,
    Cmd = spec.cmd,
    Entrypoint = spec.entrypoint,
    WorkingDir = spec.workdir,
    User = spec.user,
    Env = spec.env,
    Labels = spec.labels,
    HostConfig = hc,
  }
  return body
end

-- ========== 公开 API ==========

--- 初始化规格根目录（由 sandbox.init 调用）。
--- @param root string
function M.init(root)
  state.root = root
  fs.ensure_dir(root)
end

--- 捕获一个容器的重建规格。
--- @param insp table 容器 inspect
--- @param ctx table { workspace_roots, session, agent, was_running?, auto_remove?, name? }
--- @return table|nil spec
function M.capture(insp, ctx)
  ctx = ctx or {}
  if type(insp) ~= "table" then return nil end
  local cfg = type(insp.Config) == "table" and insp.Config or {}
  local hc = type(insp.HostConfig) == "table" and insp.HostConfig or {}
  if hc.AutoRemove == true then return nil end

  local verdict = review.evaluate(insp, {
    workspace_roots = ctx.workspace_roots,
    session_netns = true,
  })

  local mounts = _mounts(insp)
  local mounts_safe = true
  for _, m in ipairs(mounts) do
    if m.type ~= "bind" or not m.source or not _under(m.source, ctx.workspace_roots or {}) then
      mounts_safe = false
    end
  end

  local has_limits = (tonumber(hc.Memory) or 0) > 0 and (tonumber(hc.PidsLimit) or 0) > 0
  local env_keys = _env_keys(insp)
  local secret_env = false
  for _, k in ipairs(env_keys) do
    local up = k:upper()
    if up:find("PASSWORD", 1, true) or up:find("SECRET", 1, true)
      or up:find("TOKEN", 1, true) or up:find("API_KEY", 1, true) then
      secret_env = true
      break
    end
  end
  -- 非敏感 env 可随规格保存（自动重建需要）；含敏感 key 时只保留 key，不落盘 value。
  local env_values = nil
  if not secret_env and type(cfg.Env) == "table" then
    env_values = {}
    for _, item in ipairs(cfg.Env) do env_values[#env_values + 1] = tostring(item) end
  end

  local mode = "manual"
  local reasons = {}
  for _, r in ipairs(verdict.reasons) do reasons[#reasons + 1] = r end
  if verdict.level == "safe" and mounts_safe and has_limits and not secret_env
    and type(insp.Image) == "string" and insp.Image ~= "" then
    mode = "auto"
  else
    if verdict.level ~= "safe" then reasons[#reasons + 1] = "REVIEW_" .. tostring(verdict.level):upper() end
    if not mounts_safe then reasons[#reasons + 1] = "MOUNT_OUTSIDE_WORKSPACE" end
    if not has_limits then reasons[#reasons + 1] = "NO_RESOURCE_LIMITS" end
    if secret_env then reasons[#reasons + 1] = "SECRET_ENV" end
  end

  local name = tostring(insp.Name or ""):gsub("^/", "")
  if name == "" then name = "neoai-" .. tostring(os.time()) end

  local spec = {
    version = 1,
    name = name,
    image = cfg.Image or "",
    image_digest = type(insp.Image) == "string" and insp.Image or "",
    cmd = type(cfg.Cmd) == "table" and cfg.Cmd or nil,
    entrypoint = type(cfg.Entrypoint) == "table" and cfg.Entrypoint or nil,
    workdir = cfg.WorkingDir,
    user = cfg.User,
    env_keys = env_keys,
    env = env_values,
    mounts = mounts,
    network_mode = hc.NetworkMode or "",
    memory = hc.Memory,
    pids = hc.PidsLimit,
    nano_cpus = hc.NanoCpus,
    labels = {
      ["neoai.sandbox.owner"] = tostring(ctx.owner or ""),
      ["neoai.sandbox.session"] = tostring(ctx.session or ""),
      ["neoai.sandbox.agent"] = tostring(ctx.agent or ""),
      ["neoai.sandbox.rebuild"] = mode,
    },
    workspace = ctx.workspace or (ctx.workspace_roots and ctx.workspace_roots[1]),
    review_level = verdict.level,
    review_reasons = reasons,
    mode = mode,
    was_running = ctx.was_running == true or (insp.State and insp.State.Running == true),
    auto_start = (ctx.was_running ~= false),
    created_at = os.time(),
  }
  spec.spec_id = _spec_id(spec)
  -- 用户要求“都重建”：关闭的容器也进入自动重建（只 create 不 start），并在终端打印
  -- 重建命令与安全性；只有非安全规格才进入 manual/pending。
  if spec.was_running == false then spec.auto_start = false end

  M.save(spec)
  if spec.mode == "auto" then state.auto[spec.spec_id] = true
  else state.pending[spec.spec_id] = true end
  return spec
end

--- 写入规格文件（0600）。
--- @param spec table
--- @return boolean
function M.save(spec)
  if not state.root or type(spec) ~= "table" or not spec.spec_id then return false end
  fs.ensure_dir(state.root)
  local path = state.root .. "/" .. tostring(spec.spec_id) .. ".json"
  local ok, encoded = pcall(vim.json.encode, spec)
  if not ok then return false end
  local wrote = fs.write_file_atomic(path, encoded)
  pcall(fs.chmod, path, 384) -- 0600
  return wrote ~= false
end

--- 读取全部规格。
--- @return table[]
function M.load_all()
  if not state.root then return {} end
  local out = {}
  for _, name in ipairs(fs.list_dir(state.root) or {}) do
    if name:match("%.json$") then
      local raw = fs.read_file(state.root .. "/" .. name)
      if raw then
        local ok, spec = pcall(vim.json.decode, raw)
        if ok and type(spec) == "table" and spec.spec_id then out[#out + 1] = spec end
      end
    end
  end
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  return out
end

--- 删除规格。
--- @param spec_id string
function M.remove(spec_id)
  if not state.root or type(spec_id) ~= "string" then return end
  pcall(fs.delete_file, state.root .. "/" .. spec_id .. ".json")
  state.pending[spec_id] = nil
  state.auto[spec_id] = nil
end

--- 标记 pending 已批准（持久化到规格；批准绑定 spec_id）。
--- @param spec_id string
--- @return boolean
function M.approve(spec_id)
  if type(spec_id) ~= "string" then return false end
  local found = nil
  for _, spec in ipairs(M.load_all()) do
    if spec.spec_id == spec_id then found = spec; break end
  end
  if not found then return false end
  found.approved = true
  found.mode = "auto"
  found.auto_start = found.was_running ~= false
  M.save(found)
  state.pending[spec_id] = nil
  state.auto[spec_id] = true
  return true
end

--- 是否 pending。
--- @param spec_id string
--- @return boolean
function M.is_pending(spec_id)
  return state.pending[spec_id] == true
end

--- 是否 auto。
--- @param spec_id string
--- @return boolean
function M.is_auto(spec_id)
  return state.auto[spec_id] == true
end

--- 失败计数/挂起自动重建（避免 crash loop）。
--- @param spec_id string
--- @param limit number|nil
--- @return boolean suspended
function M.note_failure(spec_id, limit)
  limit = tonumber(limit) or 3
  local s = state.suspended[spec_id] or { count = 0 }
  s.count = s.count + 1
  s.until_ts = os.time() + 3600
  state.suspended[spec_id] = s
  if s.count >= limit then
    state.auto[spec_id] = nil
    state.pending[spec_id] = true
    return true
  end
  return false
end

--- 是否挂起。
--- @param spec_id string
--- @return boolean
function M.is_suspended(spec_id)
  local s = state.suspended[spec_id]
  if not s then return false end
  if s.until_ts and s.until_ts < os.time() then
    state.suspended[spec_id] = nil
    return false
  end
  return true
end

--- 生成待重建列表（供 UI/命令）。
--- @return table[]
function M.list_pending()
  local out = {}
  for _, spec in ipairs(M.load_all()) do
    if M.is_pending(spec.spec_id) or spec.mode ~= "auto" then out[#out + 1] = spec end
  end
  return out
end

--- 终端打印重建命令 + 安全性（关闭的容器用）。
--- @param spec table
function M.print_hint(spec)
  if type(spec) ~= "table" then return end
  local text = string.format(
    "[NeoAI] 容器 %s 已随会话退出；重建命令：\n%s\n%s",
    tostring(spec.name or "?"), M.rebuild_command(spec), M.safety_text(spec))
  pcall(vim.notify, text, vim.log.levels.INFO)
end

--- 测试/热重载。
function M.reset()
  state.root = nil
  state.pending = {}
  state.auto = {}
  state.suspended = {}
end

return M
