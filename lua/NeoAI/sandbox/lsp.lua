--- AI 专用沙箱 LSP 客户端
--- @module NeoAI.sandbox.lsp
--- 为 AI 的 `lsp_*` 工具提供**独立的**沙箱化 LSP 客户端：把 server 启动命令放进
--- bwrap 挂载命名空间，并在工作区根上挂 overlayfs（lower=真实工作区只读，
--- upper=沙箱私有可写层）。效果：该 server 读取磁盘时看到 AI 尚未发布的暂存内容
--- （真实路径），与进程内工具的用户态暂存保持一致；宿主真实文件不被改动。
---
--- 与编辑器自身的 LSP **完全隔离**：不再全局包装 `vim.lsp.rpc.start`，编辑器 LSP
--- 进程照常读写真实磁盘。只有 AI 工具调用时按需克隆编辑器同名 server（名称加
--- `@neoai-sandbox` 后缀），克隆体才走沙箱命名空间与暂存层，且其诊断不外溢到编辑器。
---
--- 仅覆盖「磁盘读取」；LSP 返回的编辑仍由 Neovim 应用到 buffer，写盘经
--- `tool_helpers.persist_buffer` 重定向到暂存层。LSP 自身缓存目录以 rw bind
--- 直连宿主，避免把缓存写入 overlay 或待审队列。
---
--- 默认开启（`tools.sandbox.lsp_overlay.enabled = true`）；overlay 不可用（如 tmpfs
--- 工作区）时自动跳过，AI 工具回退到编辑器客户端，不影响正常使用。

local fs = require("NeoAI.utils.fs")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

-- 克隆客户端缓存：key = "<editor_name>\0<root_dir>" -> client_id
local clones = {}

-- ========== 私有函数 ==========

--- 读取配置（缺省关闭）
--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.lsp_overlay") or {}
end

--- overlay upper/work 宿主目录：位于暂存基目录（`conceal.base_host`，默认磁盘）之下，
--- 须在工作区之外，避免 upper 落在 lower 之下。
--- 用稳定目录而非会话目录：LSP server 生命周期跨 agent 会话，overlay 挂载点不能随会话轮换。
--- 按 cwd hash 分片，避免多项目共用同一 upper 造成相对路径串扰。
--- @param cwd string
--- @return string
local function _base_dir(cwd)
  local function hash(s)
    local ok, hex = pcall(vim.fn.sha256, s)
    return ok and hex or (s or ""):gsub("[^%w]", "_")
  end
  local root = require("NeoAI.sandbox.conceal").base_host() .. "/lsp"
  return root .. "/" .. hash(cwd)
end

--- LSP 需要可写的工作区外目录（缓存/状态），直连宿主，避免污染 overlay/待审队列。
--- @return table 路径数组
local function _rw_dirs()
  local dirs, seen = {}, {}
  local function add(d)
    if not d or d == "" then return end
    d = d:gsub("/+$", "")
    if d == "" or seen[d] then return end
    if vim.fn.isdirectory(d) == 1 then seen[d] = true; dirs[#dirs + 1] = d end
  end
  add(vim.fn.stdpath("cache"))
  add(vim.fn.stdpath("data"))
  add(vim.fn.stdpath("state"))
  add(vim.fn.expand("~/.cache"))
  add(vim.fn.expand("~/.local/share"))
  add(vim.fn.expand("~/.local/state"))
  -- npm/npx 缓存直连宿主：否则 npx 下载的包会写进 overlay upper，而每次 LSP 启动
  -- 都会 _wipe_upper，导致（如 copilot）每会话重新下载/解包，失败即 exit 1。
  add(vim.fn.expand("~/.npm"))
  -- LSP server 的配置/认证状态目录（XDG_CONFIG_HOME，默认 ~/.config）必须可写：
  -- 否则 server 打开其状态库（如 copilot 的 ~/.config/github-copilot/auth.db）时报
  -- `attempt to write a readonly database` 并退出（exit 1）。敏感子路径（~/.config/gh、
  -- gcloud、git/credentials 等）仍由随后的 mask_paths 遮蔽，不随本 bind 暴露。
  add(vim.fn.stdpath("config") and vim.fn.fnamemodify(vim.fn.stdpath("config"), ":h") or "")
  add(vim.fn.expand("$XDG_CONFIG_HOME"))
  add(vim.fn.expand("~/.config"))
  return dirs
end

--- overlay 规格：与 `run_command` **完全同构**（`wrapper.build_overlay_specs`）——同一读取面
--- （`read_all` 时整机只读/可写暂存）、同一可写根集合（cwd + `process_roots` + 所有已暂存
--- 路径所在目录）。overlay 不可用时返回 nil（调用方跳过包装，不降级为 bind）。
--- 稳定目录（不随会话轮换）：LSP server 生命周期跨 agent 会话，挂载点不能随会话销毁。
--- @param cwd string
--- @return table|nil 数组 { root, upper, work, bind, mode }
local function _resolve_specs(cwd)
  local runtime = require("NeoAI.sandbox.runtime")
  if not runtime.overlay_available() then return nil end
  local candidate = require("NeoAI.sandbox.candidate")
  local wrapper = require("NeoAI.sandbox.wrapper")
  local cfg = config_store.get("tools.sandbox") or {}
  local base = _base_dir(cwd)
  -- 已暂存的包安装根 + 所有已暂存路径的覆盖根（与 run_command 的补齐逻辑一致）。
  local extra = {}
  for _, r in ipairs(candidate.staged_roots()) do extra[#extra + 1] = r end
  local known = { cwd }
  if type(cfg.process_roots) == "table" then
    for _, r in ipairs(cfg.process_roots) do known[#known + 1] = r end
  end
  for _, r in ipairs(candidate.staged_overlay_roots(known)) do extra[#extra + 1] = r end
  local specs = wrapper.build_overlay_specs(cwd, base, extra)
  local any = false
  for _, s in ipairs(specs) do
    if runtime.overlay_writable(s.root, s.upper, s.work) then
      s.mode = "overlay"; any = true
    else
      s.mode = "bind"
    end
  end
  if not any then return nil end
  return specs
end

--- 清空 overlay upper 内容（保留目录本身，overlay 挂载点不可删除）。
--- @param specs table
local function _wipe_upper(specs)
  for _, spec in ipairs(specs or {}) do
    local handle = vim.uv.fs_scandir(spec.upper)
    if handle then
      while true do
        local name = vim.uv.fs_scandir_next(handle)
        if not name then break end
        pcall(vim.fn.delete, spec.upper .. "/" .. name, "rf")
      end
    end
  end
end

--- 构造 bwrap 前缀：复用 `runtime.process_prefix`——与 `run_command` **同一命名空间构造**
--- （相同隔离标志、读取面、overlay/遮蔽、seccomp、能力收敛）。LSP server 因此与
--- `run_command` 调用 LSP 看到完全一致的沙箱视图；缓存/状态目录经 `priv.mounts` rw 直连宿主。
--- @param specs table
--- @param cwd string
--- @return table|nil argv
--- @return string|nil err
local function _prefix(specs, cwd)
  local runtime = require("NeoAI.sandbox.runtime")
  local priv = { network = true, cap_add = {}, mounts = {}, userns = false }
  for _, d in ipairs(_rw_dirs()) do
    priv.mounts[#priv.mounts + 1] = { src = d, dst = d, mode = "rw" }
  end
  local base = _base_dir(cwd)
  local fallback = base .. "/bind"
  fs.ensure_dir(fallback)
  local prefix, err = runtime.process_prefix({
    cwd = cwd,
    overlays = specs,
    privileges = priv,
    session_tmp_dir = base,
    fallback_cwd = fallback,
    -- Node 系 LSP server（copilot/pyright 等）在 `--unshare-pid` 下启动后即退出（exit 1）；
    -- 不隔离 PID。文件视图（overlay/遮蔽）与 run_command 保持一致，仅放弃 PID 隔离。
    no_pid_ns = true,
  })
  if not prefix then return nil, err end
  return prefix
end

-- ========== 公开 API ==========

--- 刷新 LSP overlay：用当前工作区暂存重新物化 upper（LSP server 在命名空间内即时可见）。
--- @param cwd string|nil
--- @return table|nil specs
function M.refresh(cwd)
  local cfg = _cfg()
  if cfg.enabled ~= true then return nil end
  cwd = cwd or vim.fn.getcwd()
  local specs = _resolve_specs(cwd)
  if not specs then return nil end
  _wipe_upper(specs)
  -- upper 已被清空：强制全量重物化（否则版本未变的暂存项会被跳过，LSP 视图看不到改动）。
  local conflicts = require("NeoAI.sandbox.candidate").materialize_overlay(specs, { force = true })
  if conflicts and #conflicts > 0 then
    -- 类型冲突无法安全物化：拒绝启用沙箱 LSP（避免与只读工具视图分裂），回退调用方处理。
    require("NeoAI.kernel.logger").warn(
      "[sandbox] LSP 物化类型冲突，跳过沙箱 LSP：%s", tostring(conflicts[1] and conflicts[1].real))
    return nil
  end
  return specs
end

--- 包装 LSP server 启动命令；不满足条件时返回 nil（调用方使用原命令）。
--- @param cmd string[]
--- @param extra table|nil { cwd?, env?, detached? }
--- @return table|nil wrapped
function M.wrap_cmd(cmd, extra)
  local cfg = _cfg()
  if cfg.enabled ~= true then return nil end
  if type(cmd) ~= "table" or #cmd == 0 then return nil end
  if cmd[1] == "bwrap" then return nil end -- 已包装，避免重复
  local cwd = (extra and extra.cwd) or vim.fn.getcwd()
  local specs = M.refresh(cwd)
  if not specs then return nil end
  local full, err = _prefix(specs, cwd)
  if not full then
    require("NeoAI.kernel.logger").warn("[sandbox] LSP 沙箱前缀构造失败，回退编辑器客户端：%s", tostring(err))
    return nil
  end
  for _, v in ipairs(cmd) do full[#full + 1] = v end
  return full
end

--- 克隆客户端名称后缀（用于识别与编辑器客户端的区别）。
local CLONE_SUFFIX = "@neoai-sandbox"

--- @param name string|nil
--- @return boolean
local function _is_clone(name)
  return type(name) == "string" and name:sub(-#CLONE_SUFFIX) == CLONE_SUFFIX
end

--- 某 buffer 上的编辑器 LSP 客户端（排除本模块的克隆体）。
--- @param bufnr number
--- @return table[]
local function _editor_clients(bufnr)
  local out = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if not _is_clone(c.name) then out[#out + 1] = c end
  end
  return out
end

--- 基于编辑器客户端构造沙箱克隆配置；cmd 无法包装（函数式 / overlay 不可用）时返回 nil。
--- @param ec table 编辑器客户端
--- @return table|nil
local function _clone_cfg(ec)
  local base = ec.config or {}
  local wrapped = M.wrap_cmd(base.cmd, { cwd = base.root_dir, env = base.cmd_env, detached = base.detached })
  if not wrapped then return nil end
  return {
    name = base.name .. CLONE_SUFFIX,
    cmd = wrapped,
    root_dir = base.root_dir,
    filetypes = base.filetypes,
    capabilities = base.capabilities,
    init_options = base.init_options,
    settings = base.settings,
    cmd_cwd = base.cmd_cwd,
    cmd_env = base.cmd_env,
    detached = base.detached,
    -- 克隆体的诊断不外溢到编辑器（避免重复诊断/悬浮噪音）；AI 通过 pull diagnostics 读取。
    handlers = { ["textDocument/publishDiagnostics"] = function() end },
  }
end

--- 已推送暂存文本记录：`clone_id\0uri` -> { text, version }。避免重复推送同一内容。
local pushed_text = {}
--- 每克隆的已推送版本号（保证 didChange version 单调递增，覆盖 Neovim 自身的 changedtick）。
local pushed_version = {}

--- 把**暂存内容**推给沙箱克隆（`textDocument/didChange`），使克隆的文档文本与 overlay
--- 磁盘视图一致，**不触碰用户 buffer**。用户已打开的文件此前会以真实 buffer 文本 didOpen，
--- 导致 LSP 与文件工具视图分裂；此处在每次取用克隆前校正文档文本。
--- 版本号取 `max(changedtick, 上次推送) + 1`，确保不被 Neovim 的自动 didChange 覆盖。
--- @param clone table LSP 客户端
--- @param bufnr number 真实路径对应的 buffer（用于 URI 与版本基准）
--- @param realpath string 真实文件路径
local function _push_staged_text(clone, bufnr, realpath)
  if not (clone and bufnr and type(realpath) == "string" and realpath ~= "") then return end
  local ok_cand, cand = pcall(require, "NeoAI.sandbox.candidate")
  if not ok_cand or not cand or type(cand.read_path) ~= "function" then return end
  local staged = cand.read_path(realpath)
  if not staged then return end
  local content = require("NeoAI.utils.fs").read_file(staged)
  if content == nil then return end
  local uri = vim.uri_from_bufnr(bufnr)
  local key = tostring(clone.id) .. "\0" .. uri
  local last = pushed_text[key]
  if last and last.text == content then return end
  local tick = 0
  pcall(function() tick = vim.api.nvim_buf_get_changedtick(bufnr) end)
  local version = math.max(tick, pushed_version[clone.id] or 0) + 1
  pushed_version[clone.id] = version
  pcall(function()
    clone:notify("textDocument/didChange", {
      textDocument = { uri = uri, version = version },
      contentChanges = { { text = content } },
    })
  end)
  pushed_text[key] = { text = content, version = version }
end

--- 取得某编辑器客户端的沙箱克隆（按 name+root 缓存并复用）。
--- @param ec table 编辑器客户端
--- @param bufnr number
--- @return table|nil
local function _clone_of(ec, bufnr)
  local key = tostring(ec.name) .. "\0" .. tostring((ec.config or {}).root_dir or "")
  local id = clones[key]
  local clone = id and vim.lsp.get_client_by_id(id)
  if clone and clone:is_stopped() then
    clone = nil
  end
  if not clone then
    local cfg = _clone_cfg(ec)
    if not cfg then return nil end
    local ok, new_id = pcall(vim.lsp.start, cfg, { bufnr = bufnr })
    if not ok or not new_id then return nil end
    clones[key] = new_id
    clone = vim.lsp.get_client_by_id(new_id)
  elseif bufnr and not clone.attached_buffers[bufnr] then
    pcall(vim.lsp.buf_attach_client, bufnr, clone.id)
  end
  return clone
end

--- 取得某 buffer 上所有编辑器 LSP 的沙箱克隆（按需启动）。
--- 配置关闭 / overlay 不可用 / 函数式 cmd 时跳过对应 server。
--- @param bufnr number|nil
--- @return table[] clients
function M.clients_for(bufnr)
  if _cfg().enabled ~= true then return {} end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  local realpath = vim.api.nvim_buf_get_name(bufnr)
  local out = {}
  for _, ec in ipairs(_editor_clients(bufnr)) do
    local clone = _clone_of(ec, bufnr)
    if clone then
      _push_staged_text(clone, bufnr, realpath)
      out[#out + 1] = clone
    end
  end
  return out
end

--- 沙箱 LSP 是否启用（供工具侧决定是否允许回退编辑器客户端）。
--- @return boolean
function M.enabled()
  return _cfg().enabled == true
end

--- 找一个支持指定方法的沙箱克隆。
--- bufnr 为 nil 时在所有已存在的克隆里查找。
--- @param method string
--- @param bufnr number|nil
--- @return table|nil
function M.client_supporting(method, bufnr)
  if _cfg().enabled ~= true then return nil end
  local list = {}
  if bufnr then
    list = M.clients_for(bufnr)
  else
    for _, id in pairs(clones) do
      local c = vim.lsp.get_client_by_id(id)
      if c and not c:is_stopped() then list[#list + 1] = c end
    end
  end
  for _, c in ipairs(list) do
    if c:supports_method(method, bufnr) then return c end
  end
  return nil
end

--- 停止全部沙箱克隆并清空缓存。
function M.stop_all()
  for key, id in pairs(clones) do
    local c = vim.lsp.get_client_by_id(id)
    if c then pcall(function() c:stop() end) end
    clones[key] = nil
  end
  pushed_text = {}
  pushed_version = {}
end

--- 重置（测试用）
function M.reset()
  M.stop_all()
end

return M
