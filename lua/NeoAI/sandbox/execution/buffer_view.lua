--- 未保存 buffer → 沙箱视图基线（save-all 语义）
--- @module 'NeoAI.sandbox.execution.buffer_view'
---
--- 设计目标：**AI 看到的世界 = 用户此刻对全部 buffer 执行 `:wall` 之后的世界**。
--- 在每次工具执行边界，把 loaded+modified 的普通 buffer 写进沙箱视图（单视图 upper /
--- 旧布局暂存），并登记为 `view_base_hash` 基线：
---   * 读取工具（read_file/list/search/treesitter）、进程工具（run_command/git/lsp_check）、
---     LSP 克隆因此看到同一份内容，与「平时开发时 LSP 看到未保存内容」一致；
---   * 基线一致的文件**不产生候选**（见 candidate.finish），绝不把用户未保存内容当作 AI 改动；
---   * 若条目已有 AI/命令改动（staged != seed_hash），绝不覆盖，只标记 buffer 已分叉。
---
--- 生命周期：`install()` 注册 BufWritePost / BufUnload（返回清理由 `stop()` 统一执行）；
--- `sync()` 由 wrapper 在工具门禁入口调用。overlay 不可用时跳过（避免读工具看到 buffer、
--- 进程工具看到磁盘的分裂）。
---
--- 副作用全部可卸载；不修改真实盘、不写候选、不触碰用户 buffer 内容。

local fs = require("NeoAI.utils.fs")
local buffer_ref = require("NeoAI.utils.buffer")

local M = {}

-- ========== 私有状态 ==========

local state = {
  installed = false,
  group = "NeoAIBufferView",
  cache = {}, -- bufnr -> { tick, name }
}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.buffer_view")
  end)
  return (ok and type(cfg) == "table") and cfg or {}
end

--- @return number
local function _max_bytes()
  local v = tonumber(_cfg().max_bytes)
  return v and v > 0 and v or (2 * 1024 * 1024)
end

--- @return number
local function _max_files()
  local v = tonumber(_cfg().max_files)
  return v and v > 0 and v or 64
end

--- 视图是否可用（overlay 可用才保证进程工具也能看到同一份内容）。
--- @return boolean
local function _view_available()
  local ok, runtime = pcall(require, "NeoAI.sandbox.execution.runtime")
  if not ok or not runtime or type(runtime.overlay_available) ~= "function" then return false end
  local ok2, available = pcall(runtime.overlay_available)
  return ok2 and available == true
end

--- 路径是否位于沙箱自身存储/私有临时根（绝不把 buffer 内容写进沙箱状态目录）。
--- @param path string
--- @return boolean
local function _is_internal(path)
  if type(path) ~= "string" or path == "" then return true end
  local ok, conceal = pcall(require, "NeoAI.sandbox.observe.conceal")
  if ok and conceal and type(conceal.base_host) == "function" then
    local ok2, base = pcall(conceal.base_host)
    if ok2 and type(base) == "string" and base ~= "" then
      if path == base or path:sub(1, #base + 1) == base .. "/" then return true end
    end
  end
  local ok3, runtime = pcall(require, "NeoAI.sandbox.execution.runtime")
  if ok3 and runtime and type(runtime.tmpfs_roots) == "function" then
    local ok4, roots = pcall(runtime.tmpfs_roots)
    if ok4 and type(roots) == "table" then
      for _, r in ipairs(roots) do
        if type(r) == "string" and r ~= ""
          and (path == r or path:sub(1, #r + 1) == r .. "/") then return true end
      end
    end
  end
  return false
end

--- 路径是否在本次沙箱可写根覆盖范围内。
--- @param path string
--- @return boolean
local function _in_roots(path)
  if _is_internal(path) then return false end
  local ok, runtime = pcall(require, "NeoAI.sandbox.execution.runtime")
  if ok and runtime and type(runtime.read_all) == "function" then
    local ok2, read_all = pcall(runtime.read_all)
    if ok2 and read_all == true then return true end
  end
  local function under(p, r)
    if type(r) ~= "string" or r == "" then return false end
    r = r:gsub("/+$", "")
    return p == r or p:sub(1, #r + 1) == r .. "/"
  end
  local roots = { vim.fn.getcwd() }
  local cfg = _cfg()
  local sandbox_cfg = require("NeoAI.kernel.config_store").get("tools.sandbox") or {}
  for _, r in ipairs(sandbox_cfg.process_roots or {}) do roots[#roots + 1] = r end
  for _, r in ipairs(roots) do
    if under(path, r) then return true end
  end
  return false
end

--- buffer 是否可作为 save-all 基线来源。
--- @param buf number
--- @param name string
--- @return boolean
local function _eligible(buf, name)
  if not buffer_ref.is_normal(buf) then return false end
  if name == "" or not _in_roots(name) then return false end
  if vim.bo[buf].binary then return false end
  local fenc = vim.bo[buf].fileencoding
  if fenc ~= "" and fenc ~= "utf-8" and fenc ~= "utf8" then return false end
  local ok, bytes = pcall(vim.api.nvim_buf_get_offset, buf, vim.api.nvim_buf_line_count(buf))
  if ok and type(bytes) == "number" and bytes > _max_bytes() then return false end
  return true
end

--- 读取磁盘内容并哈希（不存在/不可读返回 nil）。
--- @param path string
--- @return string|nil content, string|nil hash
local function _disk(path)
  if vim.fn.filereadable(path) ~= 1 then return nil, nil end
  local content = fs.read_file(path)
  if content == nil then return nil, nil end
  local hash = buffer_ref.hash(content)
  return content, hash
end

--- 查找某真实路径对应的已加载普通 buffer（优先当前窗口显示者）。
--- @param path string
--- @return number|nil
local function _buf_for(path)
  if type(path) ~= "string" or path == "" then return nil end
  local abs = fs.canonical(path)
  local fallback
  for _, buf in ipairs(buffer_ref.normal_bufs()) do
    local bpath = buffer_ref.path(buf)
    if vim.api.nvim_buf_is_loaded(buf) and bpath ~= "" and fs.canonical(bpath) == abs then
      if vim.fn.bufwinid(buf) ~= -1 then return buf end
      fallback = fallback or buf
    end
  end
  return fallback
end

--- 用磁盘文本覆盖 buffer（保留换行风格；解除 modified）。
--- @param buf number
--- @param content string
local function _reload_buffer(buf, content)
  if not (buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end
  if not vim.bo[buf].modifiable then return end
  local text = content or ""
  local ff = "unix"
  if text:find("\r\n", 1, true) then ff = "dos"; text = text:gsub("\r\n", "\n") end
  local has_eol = text:sub(-1) == "\n"
  local body = has_eol and text:sub(1, -2) or text
  local lines = (body == "") and { "" } or vim.split(body, "\n", { plain = true })
  local was_modified = vim.bo[buf].modified
  local undolevels = vim.bo[buf].undolevels
  pcall(function()
    vim.bo[buf].undolevels = -1
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end)
  pcall(function() vim.bo[buf].undolevels = undolevels end)
  pcall(function()
    vim.bo[buf].fileformat = ff
    vim.bo[buf].eol = has_eol
    if not was_modified then vim.bo[buf].modified = false end
  end)
  if not was_modified then pcall(function() vim.bo[buf].modified = false end) end
end

--- 保存后维护基线（磁盘与视图同步时撤销种子；有 AI 改动时刷新 CAS 基线）。
--- @param buf number
function M.on_write(buf)
  if not _cfg().enabled or not vim.api.nvim_buf_is_valid(buf) then return end
  local name = buffer_ref.path(buf)
  if name == "" or not _in_roots(name) then return end
  local content, hash = _disk(name)
  if content ~= nil and hash then
    pcall(function()
      require("NeoAI.sandbox.execution.candidate").on_buffer_saved(name, hash)
    end)
  end
  state.cache[buf] = nil
  M.sync()
end

--- 把当前全部未保存普通 buffer 同步为视图基线。
--- @return table { seeded: number, cleared: number, skipped?: string }
function M.sync()
  if not _cfg().enabled then return { seeded = 0, cleared = 0, skipped = "disabled" } end
  local ok_env, env = pcall(require, "NeoAI.utils.env")
  if ok_env and env and type(env.in_sandbox) == "function" then
    local ok_in, inner = pcall(env.in_sandbox)
    if ok_in and inner then return { seeded = 0, cleared = 0, skipped = "in_sandbox" } end
  end
  if not _view_available() then return { seeded = 0, cleared = 0, skipped = "no_overlay" } end
  local ok_c, candidate = pcall(require, "NeoAI.sandbox.execution.candidate")
  if not ok_c or not candidate or type(candidate.seed_buffer) ~= "function" then
    return { seeded = 0, cleared = 0, skipped = "no_candidate" }
  end
  -- 单视图：先按与 run_command 相同的规则登记视图可写根，使种子直接写进视图 upper
  -- （而不是旧布局会话副本）。视图根未登记时 path_for 返回 nil，会退化出第二份副本。
  pcall(function()
    local view = require("NeoAI.sandbox.execution.view")
    if not view.enabled() or view.ready() then return end
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local specs = wrapper.build_overlay_specs(vim.fn.getcwd(), candidate.view_base(), {})
    for _, s in ipairs(specs or {}) do
      if s.mode ~= "fuse" then
        s.mode = runtime.overlay_writable(s.root, s.upper, s.work) and "overlay" or "bind"
      end
    end
    candidate.register_view(specs)
  end)
  local max_bytes = _max_bytes()
  local max_files = _max_files()
  local seeded, cleared, bytes, count = 0, 0, 0, 0
  local seen = {}
  for _, buf in ipairs(buffer_ref.normal_bufs()) do
    local name = buffer_ref.path(buf)
    if name ~= "" and _eligible(buf, name) then
      seen[buf] = true
      local modified = vim.bo[buf].modified == true
      local rec = state.cache[buf]
      if modified then
        local tick = vim.api.nvim_buf_get_changedtick(buf)
        if count < max_files and (not rec or rec.tick ~= tick or rec.name ~= name) then
          local content = buffer_ref.content(buf)
          if content ~= nil and #content <= max_bytes then
            local _, disk_hash = _disk(name)
            local ok, applied = pcall(candidate.seed_buffer, name, content, {
              tick = tick, bufnr = buf, disk_hash = disk_hash,
            })
            if ok and applied == true then
              seeded = seeded + 1
              count = count + 1
              bytes = bytes + #content
            end
            state.cache[buf] = { tick = tick, name = name }
          else
            pcall(candidate.clear_buffer_seed, name)
            state.cache[buf] = nil
          end
        end
      elseif rec then
        pcall(candidate.clear_buffer_seed, name)
        state.cache[buf] = nil
        cleared = cleared + 1
      end
    end
  end
  -- 已卸载/不再符合条件的 buffer：撤销不再有效的纯种子。
  for buf, rec in pairs(state.cache) do
    if not seen[buf] then
      if rec and rec.name then pcall(candidate.clear_buffer_seed, rec.name) end
      state.cache[buf] = nil
      cleared = cleared + 1
    end
  end
  return { seeded = seeded, cleared = cleared, bytes = bytes }
end

--- 发布前捕获「buffer 是否还停留在 save-all 基线」，供发布后安全重载。
--- @param files table 候选文件数组
--- @return table path -> { seed_real_hash, buffer_hash }
function M.capture_publish_state(files)
  local out = {}
  if not _cfg().enabled then return out end
  local ok_c, candidate = pcall(require, "NeoAI.sandbox.execution.candidate")
  if not ok_c or not candidate or type(candidate.buffer_seed_info) ~= "function" then return out end
  for _, f in ipairs(files or {}) do
    local action = f and f.action
    if action == "create" or action == "modify" then
      local path = f.path
      local buf = _buf_for(path)
      if buf and vim.bo[buf].modified then
        local info = candidate.buffer_seed_info(path)
        local content = buffer_ref.content(buf)
        if info and info.seeded and content ~= nil then
          out[path] = {
            seed_real_hash = info.seed_real_hash,
            buffer_hash = buffer_ref.hash(content),
          }
        end
      end
    end
  end
  return out
end

--- 发布成功后：安全重载未再改动的 buffer；用户有新改动时告警不覆盖。
--- @param files table 候选文件数组
--- @param captured table|nil capture_publish_state 的结果
function M.after_publish(files, captured)
  if not _cfg().enabled then return end
  local ok_c, candidate = pcall(require, "NeoAI.sandbox.execution.candidate")
  captured = captured or {}
  for _, f in ipairs(files or {}) do
    local action = f and f.action
    if action == "create" or action == "modify" then
      local path = f.path
      local buf = _buf_for(path)
      if buf then
        local disk = fs.read_file(path)
        if disk ~= nil then
          local content = buffer_ref.content(buf)
          local current_hash = content ~= nil and buffer_ref.hash(content) or nil
          local cap = captured[path]
          local modified = vim.bo[buf].modified == true
          if not modified or (cap and current_hash == cap.seed_real_hash) then
            _reload_buffer(buf, disk)
            pcall(function() vim.bo[buf].modified = false end)
          elseif cap and current_hash ~= cap.seed_real_hash then
            vim.notify(("[NeoAI] %s 已由 AI 发布，但你的 buffer 有更新；未自动覆盖，请检查合并")
              :format(path), vim.log.levels.WARN)
          end
        end
      end
      if ok_c and candidate then pcall(candidate.clear_buffer_seed, path) end
      state.cache[buf] = nil
    end
  end
end

--- 安装 buffer 生命周期钩子（幂等）。
function M.install()
  if state.installed then return end
  state.installed = true
  local group = vim.api.nvim_create_augroup(state.group, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args) pcall(M.on_write, args.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      local rec = state.cache[args.buf]
      if rec then
        state.cache[args.buf] = nil
        pcall(function()
          require("NeoAI.sandbox.execution.candidate").clear_buffer_seed(rec.name)
        end)
      end
    end,
  })
end

--- 卸载钩子并清空缓存（不删除已登记的视图条目：未发布改动跨重载保留）。
function M.stop()
  if not state.installed then return end
  state.installed = false
  pcall(vim.api.nvim_del_augroup_by_name, state.group)
  state.cache = {}
end

--- 重置（测试/插件卸载）。
function M.reset()
  M.stop()
end

--- 诊断信息（测试/`:NeoAI SandboxDiag`）。
--- @return table
function M.info()
  local out = {}
  for buf, rec in pairs(state.cache) do out[buf] = { tick = rec.tick, name = rec.name } end
  return { enabled = _cfg().enabled ~= false, installed = state.installed, cached = out }
end

return M
