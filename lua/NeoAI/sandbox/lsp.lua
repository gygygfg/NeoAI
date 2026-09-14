--- LSP 进程命名空间覆盖
--- @module NeoAI.sandbox.lsp
--- 通过包装 `vim.lsp.rpc.start`，把 LSP server 启动命令放进 bwrap 挂载命名空间，
--- 并在工作区根上挂 overlayfs（lower=真实工作区只读，upper=沙箱私有可写层）。
--- 效果：LSP server 读取磁盘时看到 AI 尚未发布的暂存内容（真实路径），
--- 与进程内工具的用户态暂存保持一致；宿主真实文件不被改动。
---
--- 仅覆盖「磁盘读取」；LSP 返回的编辑仍由 Neovim 应用到 buffer，写盘经
--- `tool_helpers.persist_buffer` 重定向到暂存层。LSP 自身缓存目录以 rw bind
--- 直连宿主，避免把缓存写入 overlay 或待审队列。
---
--- 需 opt-in：`tools.sandbox.lsp_overlay.enabled = true`；overlay 不可用（如 tmpfs
--- 工作区）时自动跳过，不影响 LSP 正常使用。

local fs = require("NeoAI.utils.fs")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  installed = false,
  original_start = nil,
}

-- ========== 私有函数 ==========

--- 读取配置（缺省关闭）
--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.lsp_overlay") or {}
end

--- overlay upper/work 宿主目录：优先 /dev/shm（须在工作区之外，避免 upper 落在 lower 之下）。
--- 用稳定目录而非会话目录：LSP server 生命周期跨 agent 会话，overlay 挂载点不能随会话轮换。
--- 按 cwd hash 分片，避免多项目共用同一 upper 造成相对路径串扰。
--- @param cwd string
--- @return string
local function _base_dir(cwd)
  local function hash(s)
    local ok, hex = pcall(vim.fn.sha256, s)
    return ok and hex or (s or ""):gsub("[^%w]", "_")
  end
  local root
  local shm = "/dev/shm"
  if vim.fn.isdirectory(shm) == 1 and vim.fn.filewritable(shm) == 2 then
    root = require("NeoAI.sandbox.conceal").base_host() .. "/lsp"
  else
    root = (require("NeoAI.sandbox.store").root() or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")) .. "/lsp"
  end
  return root .. "/" .. hash(cwd)
end

--- LSP 需要可写的工作区外目录（缓存/状态），直连宿主，避免污染 overlay/待审队列。
--- @return table 路径数组
local function _rw_dirs()
  local dirs = {}
  local function add(d)
    if d and d ~= "" and vim.fn.isdirectory(d) == 1 then dirs[#dirs + 1] = d end
  end
  add(vim.fn.stdpath("cache"))
  add(vim.fn.stdpath("data"))
  add(vim.fn.stdpath("state"))
  add(vim.fn.expand("~/.cache"))
  add(vim.fn.expand("~/.local/share"))
  add(vim.fn.expand("~/.local/state"))
  return dirs
end

--- 工作区根的 overlay 规格；overlay 不可用时返回 nil（调用方跳过包装，不降级为 bind）。
--- @param cwd string
--- @return table|nil 数组 { root, upper, work, bind, mode }
local function _resolve_specs(cwd)
  local runtime = require("NeoAI.sandbox.runtime")
  if not runtime.overlay_available() then return nil end
  local base = _base_dir(cwd)
  local upper, work, bind = base .. "/upper", base .. "/work", base .. "/bind"
  fs.ensure_dir(upper)
  fs.ensure_dir(work)
  fs.ensure_dir(bind)
  if not runtime.overlay_mountable(cwd, upper, work) then return nil end
  return { { root = cwd, upper = upper, work = work, bind = bind, mode = "overlay" } }
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

--- 构造 bwrap 前缀：只读 rootfs + 工作区 overlay + 缓存 rw bind + chdir。
--- @param specs table
--- @param cwd string
--- @return table argv
local function _prefix(specs, cwd)
  local argv = {
    "bwrap", "--unshare-all", "--die-with-parent", "--new-session",
  }
  -- 最小只读系统集（与 run_command 一致的读取面），不再 `--ro-bind / /`。
  local runtime = require("NeoAI.sandbox.runtime")
  runtime.append_readonly(argv)
  for _, f in ipairs({ "--dev", "/dev", "--proc", "/proc" }) do
    table.insert(argv, f)
  end
  -- 临时根用私有 tmpfs，并隐藏 /proc 泄露项（与 run_command 一致）。
  runtime.append_tmpfs_roots(argv)
  runtime.append_hidden_proc(argv)
  for _, ov in ipairs(specs or {}) do
    table.insert(argv, "--overlay-src"); table.insert(argv, ov.root)
    table.insert(argv, "--overlay"); table.insert(argv, ov.upper)
    table.insert(argv, ov.work); table.insert(argv, ov.root)
  end
  for _, d in ipairs(_rw_dirs()) do
    table.insert(argv, "--bind"); table.insert(argv, d); table.insert(argv, d)
  end
  table.insert(argv, "--chdir"); table.insert(argv, cwd)
  return argv
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
  require("NeoAI.sandbox.candidate").materialize_overlay(specs)
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
  local full = _prefix(specs, cwd)
  for _, v in ipairs(cmd) do full[#full + 1] = v end
  return full
end

--- 安装 `vim.lsp.rpc.start` 包装（幂等）。
--- @return function|nil cleanup 卸载函数
function M.install()
  if state.installed then return M._cleanup end
  if type(vim.lsp) ~= "table" or type(vim.lsp.rpc) ~= "table"
    or type(vim.lsp.rpc.start) ~= "function" then
    return nil
  end
  state.original_start = vim.lsp.rpc.start
  vim.lsp.rpc.start = function(cmd, dispatchers, extra_spawn_params)
    local ok, wrapped = pcall(M.wrap_cmd, cmd, extra_spawn_params)
    if ok and wrapped then cmd = wrapped end
    return state.original_start(cmd, dispatchers, extra_spawn_params)
  end
  state.installed = true
  return M._cleanup
end

--- 卸载包装，恢复原始 `vim.lsp.rpc.start`。
function M._cleanup()
  if not state.installed then return end
  if state.original_start and type(vim.lsp) == "table" and type(vim.lsp.rpc) == "table" then
    vim.lsp.rpc.start = state.original_start
  end
  state.installed = false
  state.original_start = nil
end

--- 重置（测试用）
function M.reset()
  M._cleanup()
end

return M
