--- 沙箱进程实例身份
--- @module NeoAI.sandbox.instance
--- 为并发的多个 nvim 实例提供彼此隔离的沙箱存储根：每个 nvim 进程使用
--- `<workspace_root>/instances/<pid>_<started_at>` 作为自己的 store 根，
--- 待审队列、候选、回执、证据均不再跨进程共享（设计文档「环境隔离」原则）。
---
--- 身份经 `vim.g` 缓存：同一进程内热重载（清空 `package.loaded` 后重新 setup）
--- 保持同一实例 id，从而保留本进程的待审队列与暂存候选；进程退出后由 `gc()`
--- 回收其它已死进程遗留的实例目录。

local M = {}

-- ========== 私有状态 ==========

local VIM_G_KEY = "neoai_sandbox_instance"

-- ========== 私有函数 ==========

--- 解析实例目录名中的 pid（形如 `<pid>_<epoch>`）；不可解析返回 nil。
--- @param name string
--- @return number|nil
local function _pid_of(name)
  return tonumber(tostring(name or ""):match("^(%d+)_"))
end

--- 进程是否仍存活（保守：无法判定时视为存活，绝不误删）。
--- @param pid number
--- @return boolean
local function _alive(pid)
  local ok, res = pcall(vim.uv.kill, pid, 0)
  if not ok then return true end
  return res == true or res == 0
end

-- ========== 公开 API ==========

--- 当前进程的沙箱实例 id（跨热重载稳定）
--- @return string
function M.id()
  local id = vim.g[VIM_G_KEY]
  if type(id) == "string" and id ~= "" then return id end
  id = string.format("%d_%d", vim.fn.getpid(), os.time())
  vim.g[VIM_G_KEY] = id
  return id
end

--- 实例作用域的 store 根：`<base>/instances/<id>`
--- @param base string 配置的 workspace_root
--- @return string
function M.root(base)
  return tostring(base or "") .. "/instances/" .. M.id()
end

--- 实例容器目录（所有实例的父目录）：`<base>/instances`
--- @param base string
--- @return string
function M.container(base)
  return tostring(base or "") .. "/instances"
end

--- 由实例根反推配置基根（`<base>/instances/<id>` → `<base>`）
--- @param root string 实例根
--- @return string
function M.base_of(root)
  return vim.fn.fnamemodify(tostring(root or ""), ":h:h")
end

--- 回收已死进程遗留的实例目录（幂等；保守，不触碰存活进程）。
--- @param base string 配置的 workspace_root
--- @return number 删除的实例数
function M.gc(base)
  local dir = M.container(base)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return 0 end
  local self_pid = vim.fn.getpid()
  local removed = 0
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    local pid = _pid_of(name)
    if pid and pid ~= self_pid and not _alive(pid) then
      if vim.fn.delete(dir .. "/" .. name, "rf") == 0 then removed = removed + 1 end
    end
  end
  return removed
end

--- 覆盖实例 id（测试用）；传 nil 恢复按进程自动派生
--- @param id string|nil
function M.set_id(id)
  vim.g[VIM_G_KEY] = id
end

--- 重置（测试用）：清除实例 id 缓存
function M.reset()
  vim.g[VIM_G_KEY] = nil
end

return M
