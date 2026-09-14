--- 沙箱隐匿层
--- @module NeoAI.sandbox.conceal
--- 降低沙箱内运行的 AI 通过外部命令识别「自己处在沙箱」的能力，常开、无配置开关。
--- 两个层面：
---   1. 进程级去特征：overlay 私有层/会话状态目录改用无特征命名（不含 NeoAI/sandbox
---      字样），会话包装变量改名；前缀构造见 `sandbox.runtime`（`--as-pid-1`、root 下
---      不建 user namespace）。
---   2. 命令输出脱敏：`redact()` 抹去 overlay 挂载选项、bwrap 进程名、沙箱自有路径与
---      外层容器路径等明显指纹，供 `run_command` 回传模型前调用。
---
--- 边界：本层为「抬高识别门槛」的尽力而为，不声称让沙箱不可检测；namespace inode、
--- 能力位、宿主自身容器信息等固有痕迹无法在不破坏隔离的前提下抹除（见 docs/sandbox.md）。

local M = {}

-- ========== 私有状态 ==========

local state = {
  tag = nil,
}

-- ========== 私有函数 ==========

--- 稳定短标签：基于 nvim 缓存目录 + 进程号派生，跨热重载稳定、并发的多个 nvim 实例互不冲突。
--- 不引入 NeoAI/sandbox 字样，使生成的目录名看起来像普通私有缓存目录。
--- @return string
local function _tag()
  if state.tag then return state.tag end
  local seed = tostring(vim.fn.stdpath("cache")) .. "|" .. tostring(vim.fn.getpid())
  local ok, hex = pcall(vim.fn.sha256, seed)
  state.tag = (ok and hex or seed:gsub("[^%w]", "")):sub(1, 8)
  return state.tag
end

--- 会话 shell 状态挂载点 basename（沙箱内 /tmp 为私有 tmpfs，不与宿主冲突）。
--- 选不易与用户文件重名的形态，避免 overlay 捕获时误排除真实 `.cache` 等常见目录。
--- @return string
local function _session_basename()
  return ".s-" .. _tag()
end

--- 按规则表顺序对文本做替换
--- @param text string
--- @return string
local function _apply(text)
  local s = text
  -- overlay 挂载选项：暴露 lower/upper/work 的真实路径与 overlay 特征
  s = s:gsub("lowerdir=[^,%s]+", "lowerdir=hidden")
  s = s:gsub("upperdir=[^,%s]+", "upperdir=hidden")
  s = s:gsub("workdir=[^,%s]+", "workdir=hidden")
  s = s:gsub(",userxattr", "")
  s = s:gsub("uuid=on,", "")
  -- 挂载类型 overlay → 普通内存文件系统（mountinfo / mounts / mount 三种格式）
  s = s:gsub("%- overlay overlay", "- tmpfs tmpfs")
  s = s:gsub("overlay (%S+) overlay", "tmpfs %1 tmpfs")
  s = s:gsub("overlay on ", "tmpfs on ")
  s = s:gsub("type overlay", "type tmpfs")
  -- bwrap 进程名/工具名
  s = s:gsub("bwrap", "init")
  -- 沙箱自有命名与路径
  s = s:gsub("NeoAI%-sandbox", ".cache")
  s = s:gsub("neoai_session", ".s")
  s = s:gsub("__neoai", "_state")
  -- 动态路径（overlay 基目录、会话挂载点）及其 basename
  s = s:gsub(vim.pesc(M.base_host()), "/tmp/.cache")
  s = s:gsub(vim.pesc(M.session_mount()), "/tmp/.cache")
  s = s:gsub(vim.pesc(M.session_basename()), ".cache")
  s = s:gsub(vim.pesc(vim.fn.fnamemodify(M.base_host(), ":t")), ".cache")
  -- 外层容器（宿主自身）路径线索
  s = s:gsub("/var/lib/containerd[%w%._%-/]*", "/var/lib/.data")
  s = s:gsub("docker/rootfs/overlayfs[%w%._%-/]*", "docker/rootfs")
  return s
end

-- ========== 公开 API ==========

--- overlay 私有暂存基目录（宿主路径）。优先 /dev/shm；不可用时退回沙箱根下。
--- @return string
function M.base_host()
  local shm = "/dev/shm"
  if vim.fn.isdirectory(shm) == 1 and vim.fn.filewritable(shm) == 2 then
    return shm .. "/.cache-" .. _tag()
  end
  local ok, store = pcall(require, "NeoAI.sandbox.store")
  local root = (ok and store.root and store.root()) or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  return root .. "/process"
end

--- 会话 shell 状态在沙箱内的固定挂载点
--- @return string
function M.session_mount()
  return "/tmp/" .. _session_basename()
end

--- 沙箱内某 tmpfs 根（如 /tmp）的宿主私有基目录：位于该根之下的隐藏临时子目录。
--- 命名空间把「该子目录」bind 回根路径，使沙箱内的 /tmp 只暴露会话私有临时子目录，
--- 宿主 /tmp 的真实内容对 AI 不可见（隔离 AI）。目录名同样无特征。
--- @param root string 宿主根路径（如 "/tmp"）
--- @return string
function M.tmp_base_host(root)
  root = tostring(root or ""):gsub("/+$", "")
  return root .. "/.cache-" .. _tag()
end

--- 会话挂载点 basename（供 overlay 捕获排除）
--- @return string
function M.session_basename()
  return _session_basename()
end

--- 对命令输出脱敏，抹去沙箱/容器指纹。非字符串原样返回。
--- @param text any
--- @return any
function M.redact(text)
  if type(text) ~= "string" or text == "" then return text end
  local ok, out = pcall(_apply, text)
  return ok and out or text
end

--- 重置（测试用）
function M.reset()
  state.tag = nil
end

return M
