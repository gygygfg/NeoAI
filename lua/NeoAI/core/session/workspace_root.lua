--- 工作目录根检测
--- @module 'NeoAI.core.session.workspace_root'
--- 创建会话时从起始目录向上查找标记，定位工作区根（写入 `session.metadata.cwd`）。
--- 两级有序检测：
---   1) `session.git_markers`（默认 `{ ".git" }`）：优先命中（标记可为目录或文件，覆盖 worktree
---      的 `.git` 文件），用于把工作目录绑定到 git 仓库根而非 cwd 子目录。
---   2) `session.root_markers`（默认工程配置文件列表）：git 未命中时回退（package.json /
---      pyproject.toml 等）。
--- 同层多标记命中取先声明者；全部未命中返回 nil（调用方回退 cwd）。
--- `session.detect_root=false` 时直接返回 nil。

local M = {}

local config_store = require("NeoAI.kernel.config_store")

-- ========== 私有函数 ==========

--- 规范化绝对目录（展开 ~，去尾斜杠）；`/` 保持原样。
--- @param dir string
--- @return string
local function _norm(dir)
  local abs = vim.fn.fnamemodify(vim.fn.expand(dir), ":p")
  if abs ~= "/" then abs = abs:gsub("/+$", "") end
  return abs
end

--- 拼接目录与标记名（避免根目录产生 `//marker`）。
--- @param dir string
--- @param name string
--- @return string
local function _join(dir, name)
  if dir == "/" then return "/" .. name end
  return dir .. "/" .. name
end

--- 标记是否存在（目录或文件均算命中）。
--- @param dir string
--- @param name string
--- @return boolean
local function _has_marker(dir, name)
  return vim.uv.fs_stat(_join(dir, name)) ~= nil
end

--- 从 start 向上逐级查找任一 marker 是否存在；命中返回该祖先目录。
--- @param start string 已规范化的绝对目录
--- @param markers string[]
--- @return string|nil
local function _walk_up(start, markers)
  if type(start) ~= "string" or start == "" or type(markers) ~= "table" or #markers == 0 then
    return nil
  end
  local dir = start
  while true do
    for _, m in ipairs(markers) do
      if type(m) == "string" and m ~= "" and _has_marker(dir, m) then return dir end
    end
    if dir == "/" then return nil end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == "" then return nil end
    parent = parent:gsub("/+$", "")
    if parent == "" then parent = "/" end
    if parent == dir then return nil end
    dir = parent
  end
end

-- ========== 公开 API ==========

--- 检测起始目录的工作区根。
--- @param start string|nil 起始目录（默认 cwd）
--- @return string|nil 工作区根（规范化绝对路径）；未命中返回 nil
function M.detect(start)
  if config_store.get("session.detect_root") == false then return nil end
  local git_markers = config_store.get("session.git_markers")
  local root_markers = config_store.get("session.root_markers")
  if type(git_markers) ~= "table" then git_markers = { ".git" } end
  if type(root_markers) ~= "table" then root_markers = {} end
  local dir = _norm(start or vim.fn.getcwd())
  if dir == "" then return nil end
  return _walk_up(dir, git_markers) or _walk_up(dir, root_markers)
end

--- 标记全部未命中时的回退工作目录：优先 `$PWD`（nvim 启动时所在目录，由 shell 导出，
--- 不受编辑器内 `:cd`/`:lcd` 影响），`$PWD` 未设置或目录已不存在时退回编辑器当前 cwd。
--- @return string 规范化绝对目录
function M.fallback_cwd()
  local pwd = vim.env.PWD
  if type(pwd) == "string" and pwd ~= "" then
    local dir = _norm(pwd)
    if dir ~= "" and vim.fn.isdirectory(dir) == 1 then return dir end
  end
  return vim.fn.getcwd()
end

--- 从当前上下文检测工作区根：优先 cwd；cwd 未命中时回退当前缓冲区所在目录（仅普通文件，
--- 覆盖「在 home 启动 nvim 后打开项目内文件」的场景）。均未命中返回 nil。
--- @return string|nil
function M.detect_from_context()
  local root = M.detect(vim.fn.getcwd())
  if root then return root end
  local buf = vim.api.nvim_get_current_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local name = vim.api.nvim_buf_get_name(buf)
    if type(name) == "string" and name ~= "" and vim.fn.filereadable(name) == 1 then
      return M.detect(vim.fn.fnamemodify(name, ":p:h"))
    end
  end
  return nil
end

--- 解析新建会话应绑定的工作目录。
---   - `session.detect_root=false`：保持旧行为，直接用编辑器当前 cwd（不做标记检测与 $PWD 回退）。
---   - 否则：标记检测（cwd → 当前缓冲区目录）命中则用命中根，全部未命中回退 `$PWD`。
--- @return string
function M.resolve()
  if config_store.get("session.detect_root") == false then return vim.fn.getcwd() end
  return M.detect_from_context() or M.fallback_cwd()
end

return M
