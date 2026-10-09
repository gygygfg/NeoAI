--- Herder 侧集成配置安装器
--- @module NeoAI.services.herder_install
---
--- 背景（已实测）：
--- - Herdr 的 agent 身份是编译期固定集合，本地检测清单（`~/.config/herdr/agent-detection/<id>.toml`）
---   只能**覆盖已有** agent、**无法新增**；`[ui.sidebar.agents.rows_by_agent]` 也只接受**已知 canonical id**
---   （`neoai` 会被判为 `unknown canonical agent id`）。因此识别靠 NeoAI 主动上报
---   （`pane report-agent` + `pane report-metadata`，见 `NeoAI.services.herder`），本模块不写检测清单。
--- - 本模块只写入一条**合法、低冲突**的展示增强：在 `[ui]` 表下开启
---   `show_agent_labels_on_pane_borders`（分屏边框显示上报的 agent 标签，如 NeoAI）。
---   若文件已有 `[ui]` 段，则把受管块**插入该段内**，避免重复定义 `[ui]` 导致的 TOML 冲突。
---
--- 特性：marker 幂等（已装/键已存在则跳过）、写入前备份、写入后 `herdr config check` 校验失败自动回滚。
--- - 默认由 `services.herder` 在**启动时**异步、静默、幂等地触发（见 `install_async`），无需用户操作；
--- - 也提供 `:NeoAIHerderConfig [show|install|uninstall]` 手动控制（会给出提示）。

local M = {}

local MARKER_BEGIN = "# >>> NeoAI herder integration (managed by NeoAI; do not edit) >>>"
local MARKER_END = "# <<< NeoAI herder integration <<<"
local KEY = "show_agent_labels_on_pane_borders"
local KEY_LINE = "show_agent_labels_on_pane_borders = true"

-- ========== 私有函数 ==========

--- Herdr 可执行文件路径（环境变量优先，否则 PATH 上的 herdr）
--- @return string
local function _bin()
  return os.getenv("HERDER_BIN_PATH") or os.getenv("HERDR_BIN_PATH") or "herdr"
end

--- Herdr 配置目录（HERDR_CONFIG_PATH 覆盖优先，否则 ~/.config/herdr）
--- @return string
local function _config_dir()
  local override = os.getenv("HERDR_CONFIG_PATH")
  if override and override ~= "" then
    return vim.fn.fnamemodify(override, ":p:h")
  end
  return vim.fn.expand("~/.config/herdr")
end

--- 读取文件全部内容（不存在返回 nil）
--- @param path string
--- @return string|nil
local function _read(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then return nil end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and stat.size > 0 and vim.uv.fs_read(fd, stat.size, 0) or ""
  vim.uv.fs_close(fd)
  return data or ""
end

--- 原子写入：先写临时文件再 rename（按字节原样写入，不追加换行）
--- @param path string
--- @param content string
--- @return boolean ok, string|nil err
local function _atomic_write(path, content)
  local dir = vim.fn.fnamemodify(path, ":p:h")
  vim.fn.mkdir(dir, "p")
  local tmp = path .. ".neoai.tmp"
  local fd, oerr = vim.uv.fs_open(tmp, "w", 420)
  if not fd then return false, tostring(oerr) end
  local wok, werr = vim.uv.fs_write(fd, content, 0)
  vim.uv.fs_close(fd)
  if not wok then
    vim.uv.fs_unlink(tmp)
    return false, tostring(werr)
  end
  local rok, rerr = vim.uv.fs_rename(tmp, path)
  if not rok then return false, tostring(rerr) end
  return true
end

--- 用 `herdr config check` 校验当前配置文件（同步一次性调用）
--- @return boolean ok, string detail
local function _validate_sync()
  local ok, out = pcall(vim.fn.system, { _bin(), "config", "check" })
  if not ok then return false, tostring(out) end
  if vim.v.shell_error == 0 then return true, out end
  return false, out
end

--- 异步校验配置（`vim.system`，不阻塞事件循环）。返回 false 表示 vim.system 不可用。
--- @param on_result fun(ok: boolean, detail: string)
--- @return boolean started
local function _validate_async(on_result)
  local started = pcall(vim.system, { _bin(), "config", "check" }, { text = true }, function(obj)
    vim.schedule(function()
      local detail = (obj.stderr or "") ~= "" and obj.stderr or (obj.stdout or "")
      on_result(obj.code == 0, detail)
    end)
  end)
  return started
end

--- 异步触发 herdr 配置重载（尽力而为，失败忽略）
local function _reload_async()
  pcall(vim.system, { _bin(), "server", "reload-config" }, { text = true }, function() end)
end

--- 受管块（不含 `[ui]` 表头；插入已有 `[ui]` 段时使用）
--- @return string[]
local function _block_lines()
  return {
    MARKER_BEGIN,
    "# 展示增强：NeoAI 生命周期由 report-agent/report-metadata 主动上报驱动。",
    "# 在分屏边框显示上报的 agent 标签（如 NeoAI，来自 display_agent）。",
    KEY_LINE,
    MARKER_END,
  }
end

--- 是否已安装受管块
--- @param content string|nil
--- @return boolean
local function _is_installed(content)
  return content ~= nil and content:find(MARKER_BEGIN, 1, true) ~= nil
end

--- 配置中是否已存在目标键（用户自有设置），避免重复定义同键
--- @param content string|nil
--- @return boolean
local function _has_key(content)
  if content == nil then return false end
  for line in content:gmatch("[^\n]*") do
    if line:match("^%s*" .. KEY .. "%s*=") then return true end
  end
  return false
end

--- 生成新内容：优先插入已有 `[ui]` 段内，否则追加带 `[ui]` 头的块
--- @param existing string|nil
--- @return string
local function _compose(existing)
  local block = _block_lines()
  if existing == nil or existing == "" then
    local out = { "[ui]" }
    for _, l in ipairs(block) do out[#out + 1] = l end
    return table.concat(out, "\n") .. "\n"
  end

  local lines = vim.split(existing, "\n", { plain = true })
  local ui_idx = nil
  for i, l in ipairs(lines) do
    if l:match("^%s*%[ui%]%s*$") then
      ui_idx = i
      break
    end
  end

  if ui_idx then
    -- 已有 [ui] 段：把受管块插入该段内，避免重复定义 [ui]
    local out = {}
    for i, l in ipairs(lines) do
      out[#out + 1] = l
      if i == ui_idx then
        for _, b in ipairs(block) do out[#out + 1] = b end
      end
    end
    return table.concat(out, "\n")
  end

  -- 无 [ui] 段：追加一个带 [ui] 头的块
  local base = existing
  if base:sub(-1) ~= "\n" then base = base .. "\n" end
  local extra = { "", "[ui]" }
  for _, l in ipairs(block) do extra[#extra + 1] = l end
  return base .. table.concat(extra, "\n") .. "\n"
end

--- 移除受管块（按行）
--- @param content string
--- @return string|nil 新内容（未找到块返回 nil）
local function _remove_block(content)
  local lines = vim.split(content, "\n", { plain = true })
  local b, e
  for i, l in ipairs(lines) do
    if l:find(MARKER_BEGIN, 1, true) then b = i end
    if l:find(MARKER_END, 1, true) then e = i end
  end
  if not b or not e or e < b then return nil end
  local out = {}
  for i, l in ipairs(lines) do
    if i < b or i > e then out[#out + 1] = l end
  end
  return table.concat(out, "\n")
end

-- ========== 公开 API ==========

--- 当前 Herdr 配置文件路径
--- @return string
function M.config_path()
  return _config_dir() .. "/config.toml"
end

--- 是否已安装展示增强片段
--- @return boolean
function M.is_installed()
  return _is_installed(_read(M.config_path()))
end

--- 推荐的 Herdr 展示增强片段（独立可粘贴，含 `[ui]` 头）
--- @return string
function M.snippet()
  local out = { "[ui]" }
  for _, l in ipairs(_block_lines()) do out[#out + 1] = l end
  return table.concat(out, "\n") .. "\n"
end

--- 集成状态（只读，不产生副作用）
--- @return table
function M.status()
  local path = M.config_path()
  local content = _read(path)
  local herder = require("NeoAI.services.herder")
  return {
    herdr_env = os.getenv("HERDR_ENV") == "1",
    pane_id = os.getenv("HERDR_PANE_ID"),
    source = herder.get_source(),
    agent = herder.get_agent(),
    display_agent = herder.get_display_agent(),
    reporting = herder.is_available(),
    config_path = path,
    config_exists = content ~= nil,
    installed = _is_installed(content),
  }
end

--- 安装片段：写入 config.toml（marker 幂等；写入前备份；写入后校验，失败回滚）。
--- 校验通过后异步触发 herdr 配置重载。
--- @return table { ok, changed, path, reason?, error? }
function M.install()
  local path = M.config_path()
  local existing = _read(path)

  if _is_installed(existing) then
    return { ok = true, changed = false, path = path, reason = "already-installed" }
  end
  if _has_key(existing) then
    return { ok = true, changed = false, path = path, reason = "key-present" }
  end

  local backup = nil
  if existing ~= nil then
    backup = path .. ".neoai-backup-" .. tostring(os.time())
    local bok, berr = _atomic_write(backup, existing)
    if not bok then return { ok = false, path = path, error = "backup-failed: " .. tostring(berr) } end
  end

  local wok, werr = _atomic_write(path, _compose(existing))
  if not wok then return { ok = false, path = path, error = "write-failed: " .. tostring(werr) } end

  local vok, detail = _validate_sync()
  if not vok then
    if backup then
      local orig = _read(backup)
      if orig ~= nil then _atomic_write(path, orig) end
    else
      vim.uv.fs_unlink(path)
    end
    return { ok = false, path = path, error = "config-check-failed: " .. tostring(detail) }
  end

  _reload_async()
  return { ok = true, changed = true, path = path, backup = backup }
end

--- 异步安装（非阻塞、幂等、静默）：文件读写同步（本地、极快），
--- `herdr config check` 走 `vim.system` 异步。已安装/键已存在则立即 no-op。
--- @param opts table|nil { on_done?: fun(res: table) }
--- @return boolean started 是否发起了写入/校验（false = 未做任何改动）
function M.install_async(opts)
  opts = opts or {}
  local function done(res)
    if opts.on_done then pcall(opts.on_done, res) end
  end

  local path = M.config_path()
  local existing = _read(path)

  if _is_installed(existing) then
    done({ ok = true, changed = false, path = path, reason = "already-installed" })
    return false
  end
  if _has_key(existing) then
    done({ ok = true, changed = false, path = path, reason = "key-present" })
    return false
  end

  local backup = nil
  if existing ~= nil then
    backup = path .. ".neoai-backup-" .. tostring(os.time())
    local bok = _atomic_write(backup, existing)
    if not bok then
      done({ ok = false, path = path, error = "backup-failed" })
      return false
    end
  end

  local wok = _atomic_write(path, _compose(existing))
  if not wok then
    done({ ok = false, path = path, error = "write-failed" })
    return false
  end

  local function on_result(ok, detail)
    if ok then
      _reload_async()
      done({ ok = true, changed = true, path = path, backup = backup })
    else
      if backup then
        local orig = _read(backup)
        if orig ~= nil then _atomic_write(path, orig) end
      else
        vim.uv.fs_unlink(path)
      end
      done({ ok = false, path = path, error = "config-check-failed: " .. tostring(detail) })
    end
  end

  if not _validate_async(on_result) then
    local vok, detail = _validate_sync()
    on_result(vok, detail)
  end
  return true
end

--- 卸载片段：移除受管块（写入后校验，失败回滚）
--- @return table { ok, changed, path, reason?, error? }
function M.uninstall()
  local path = M.config_path()
  local existing = _read(path)
  if existing == nil then
    return { ok = true, changed = false, path = path, reason = "no-config" }
  end
  local stripped = _remove_block(existing)
  if stripped == nil then
    return { ok = true, changed = false, path = path, reason = "not-installed" }
  end

  local backup = path .. ".neoai-backup-" .. tostring(os.time())
  local bok, berr = _atomic_write(backup, existing)
  if not bok then return { ok = false, path = path, error = "backup-failed: " .. tostring(berr) } end

  local wok, werr = _atomic_write(path, stripped)
  if not wok then return { ok = false, path = path, error = "write-failed: " .. tostring(werr) } end

  local vok, detail = _validate_sync()
  if not vok then
    _atomic_write(path, existing)
    return { ok = false, path = path, error = "config-check-failed: " .. tostring(detail) }
  end

  _reload_async()
  return { ok = true, changed = true, path = path }
end

return M
