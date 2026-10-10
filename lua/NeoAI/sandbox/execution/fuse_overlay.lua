--- 用户态 overlay 兜底（fuse-overlayfs）
--- @module NeoAI.sandbox.execution.fuse_overlay
--- 当内核 overlayfs 不可挂载（容器内「overlay 套 overlay」、lower/upper 跨挂载/userns 归属
--- 不同等会 `EINVAL`）时，用 root 在**宿主 init 命名空间**里以用户态 `fuse-overlayfs` 建立
--- 「lower=`/`（或指定根）只读 + upper/work 会话私有可写」的合并视图，再经 bwrap `--bind` 进
--- 沙箱。这样命令仍看到真实文件、写入落 upper 暂存并冻结为候选，功能与内核 overlay 一致。
---
--- 仅当内核 overlay 不可用且本模块可用时才启用；本模块不可用时回退既有 bind/降级视图。

local M = {}

local state = {
  avail = nil, -- { ok = boolean, reason? = string }
  mounts = {}, -- key -> mnt，复用同一 (lower,upper,work) 的挂载
}

-- ========== 私有函数 ==========

--- 读取宿主挂载点集合（mountinfo 第 5 字段），用于判定挂载是否就绪。
--- @return table<string, boolean>
local function _mount_set()
  local set = {}
  local ok, lines = pcall(vim.fn.readfile, "/proc/self/mountinfo")
  if ok and type(lines) == "table" then
    for _, line in ipairs(lines) do
      local mp = tostring(line):match("^%S+ %S+ %S+ %S+ (%S+)")
      if mp then
        mp = (mp:gsub("\\(%d%d%d)", function(o) return string.char(tonumber(o, 8) or 63) end))
        set[mp] = true
      end
    end
  end
  return set
end

--- @param p string
--- @return boolean
local function _is_mounted(p)
  return _mount_set()[p] == true
end

local function _esc(s) return (tostring(s):gsub("([^%w])", "%%%1")) end

-- ========== 公开 API ==========

--- 本模块是否可用（fuse-overlayfs + /dev/fuse + 卸载工具）。
--- @return boolean
--- @return string|nil 不可用原因
function M.available()
  if state.avail then return state.avail.ok, state.avail.reason end
  local function miss(r) state.avail = { ok = false, reason = r }; return false, r end
  if vim.fn.executable("fuse-overlayfs") ~= 1 then return miss("NO_FUSE_OVERLAYFS") end
  if vim.uv.fs_stat("/dev/fuse") == nil then return miss("NO_DEV_FUSE") end
  if vim.fn.executable("fusermount") ~= 1 and vim.fn.executable("fusermount3") ~= 1
    and vim.fn.executable("umount") ~= 1 then
    return miss("NO_UNMOUNT_TOOL")
  end
  state.avail = { ok = true }
  return true, nil
end

--- 建立（或复用）一个用户态 overlay 合并视图。
--- @param lower string 只读 lower（如 "/" 或某真实根）
--- @param upper string 会话私有可写层
--- @param work string 会话私有 work
--- @return string|nil mnt 宿主挂载点
--- @return string|nil err
function M.mount(lower, upper, work)
  local ok, reason = M.available()
  if not ok then return nil, reason end
  if type(lower) ~= "string" or lower == "" or type(upper) ~= "string" or upper == ""
    or type(work) ~= "string" or work == "" then
    return nil, "BAD_ARGS"
  end
  local key = lower .. "|" .. upper .. "|" .. work
  local cached = state.mounts[key]
  if cached and _is_mounted(cached) then return cached, nil end
  -- 基础目录：upper 所在规格目录下的 `mnt`（与 lower/upper/work 均不重叠）。
  local base = vim.fn.fnamemodify(upper, ":h")
  local mnt = base .. "/mnt"
  pcall(vim.fn.mkdir, upper, "p")
  pcall(vim.fn.mkdir, work, "p")
  pcall(vim.fn.mkdir, mnt, "p")
  if _is_mounted(mnt) then state.mounts[key] = mnt; return mnt, nil end
  local opts = "lowerdir=" .. lower .. ",upperdir=" .. upper .. ",workdir=" .. work
  local cmd = { "fuse-overlayfs", "-o", opts, mnt }
  local pid = vim.fn.jobstart(cmd, { detach = true })
  if pid == nil or pid == 0 then return nil, "FUSE_SPAWN_FAILED" end
  -- 等待挂载就绪（最多 ~3s）。
  for _ = 1, 60 do
    if _is_mounted(mnt) then state.mounts[key] = mnt; return mnt, nil end
    vim.wait(50, function() return false end)
  end
  pcall(vim.fn.delete, mnt, "d")
  return nil, "FUSE_MOUNT_TIMEOUT"
end

--- 卸载某个挂载点（幂等）。
--- @param mnt string
--- @return boolean
function M.unmount(mnt)
  if type(mnt) ~= "string" or mnt == "" then return false end
  for k, v in pairs(state.mounts) do
    if v == mnt then state.mounts[k] = nil end
  end
  if not _is_mounted(mnt) then return true end
  for _, cmd in ipairs({ { "fusermount", "-u", mnt }, { "fusermount3", "-u", mnt }, { "umount", "-l", mnt } }) do
    if vim.fn.executable(cmd[1]) == 1 then
      vim.fn.system(cmd)
      if not _is_mounted(mnt) then return true end
    end
  end
  return not _is_mounted(mnt)
end

--- 卸载某目录之下的全部挂载（会话轮换时清理旧会话挂载）。
--- @param prefix string
function M.release_under(prefix)
  if type(prefix) ~= "string" or prefix == "" then return end
  local p = prefix:gsub("/+$", "")
  for _, mnt in pairs(state.mounts) do
    if mnt == p or mnt:sub(1, #p + 1) == p .. "/" then M.unmount(mnt) end
  end
end

--- 卸载全部已建立的挂载（会话轮换/重置/关闭时调用）。
function M.release_all()
  for _, mnt in pairs(state.mounts) do M.unmount(mnt) end
  state.mounts = {}
end

--- 重置（测试用）。
function M.reset()
  M.release_all()
  state.avail = nil
end

M._is_mounted = _is_mounted

return M
