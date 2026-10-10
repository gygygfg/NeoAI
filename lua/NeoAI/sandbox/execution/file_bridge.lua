--- 沙箱命名空间文件桥
--- @module NeoAI.sandbox.execution.file_bridge
--- 让**进程内文件工具**的读写经由常驻沙箱命名空间执行，而非宿主侧直接落盘：
---   * 读取为 overlay 合并视图（有暂存读暂存，否则读真实 lower）；
---   * 写入落在 overlay 暂存层，真实工作区在用户确认发布前不受影响。
--- 底层复用 `resident.file_op`（在命名空间内的 `F` 帧），无独立状态。
---
--- 可用性：常驻实例未运行时 `available()` 返回 false，所有操作返回 `nil, "RESIDENT_UNAVAILABLE"`，
--- 调用方须回退到既有宿主暂存路径（不静默降级为「写真实盘」）。

local M = {}

-- ========== 私有函数 ==========

--- @return table|nil resident 模块
local function _resident()
  local ok, mod = pcall(require, "NeoAI.sandbox.execution.resident")
  if ok and mod then return mod end
  return nil
end

--- @param op string
--- @param path string
--- @param content string|nil
--- @param opts table|nil
--- @return table|nil
--- @return string|nil
local function _op(op, path, content, opts)
  local resident = _resident()
  if not resident or type(resident.file_op) ~= "function" then
    return nil, "RESIDENT_UNAVAILABLE"
  end
  return resident.file_op(op, path, content, opts)
end

-- ========== 公开接口 ==========

--- 命名空间文件桥是否可用（常驻实例在运行且未禁用）。
--- @return boolean
function M.available()
  local cfg_ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.inproc_namespace")
  end)
  if cfg_ok and cfg == false then return false end
  local resident = _resident()
  if not resident or type(resident.active) ~= "function" then return false end
  local ok, inst = pcall(resident.active)
  return ok and inst ~= nil
end

--- 读取文件内容（命名空间合并视图）。
--- @param path string
--- @return string|nil content
--- @return string|nil err
function M.read(path)
  local res, err = _op("r", path, nil)
  if not res then return nil, err end
  if res.code ~= 0 then return nil, "READ_FAILED" end
  return res.stdout
end

--- 写入文件（命名空间 overlay 暂存层）。
--- @param path string
--- @param content string
--- @return boolean ok
--- @return string|nil err
function M.write(path, content)
  local res, err = _op("w", path, content or "")
  if not res then return false, err end
  return res.code == 0, (res.code == 0 and nil or "WRITE_FAILED")
end

--- 路径是否存在（命名空间视图）。
--- @param path string
--- @return boolean|nil
function M.exists(path)
  local res = _op("e", path, nil)
  if not res then return nil end
  return res.stdout == "1"
end

--- stat：目录返回 { type = "directory" }；文件返回 { type = "file", size = n }；缺失返回 nil。
--- @param path string
--- @return table|nil
function M.stat(path)
  local res = _op("s", path, nil)
  if not res or res.code ~= 0 then return nil end
  local s = res.stdout or ""
  if s == "d" then return { type = "directory" } end
  local size = tonumber(s:match("^f%s+(%d+)"))
  if size then return { type = "file", size = size } end
  return nil
end

--- 递归创建目录。
--- @param path string
--- @return boolean
function M.mkdir(path)
  local res = _op("m", path, nil)
  return res ~= nil and res.code == 0
end

--- 删除路径（文件或目录树）。
--- @param path string
--- @return boolean
function M.unlink(path)
  local res = _op("u", path, nil)
  return res ~= nil and res.code == 0
end

--- 列目录（单层，返回条目名数组；含子目录但无尾斜杠）。
--- @param path string
--- @return table|nil names
function M.list(path)
  local res = _op("l", path, nil)
  if not res or res.code ~= 0 then return nil end
  local out = {}
  for name in (res.stdout or ""):gmatch("[^\n]+") do
    if name ~= "." and name ~= ".." then out[#out + 1] = name end
  end
  return out
end

return M
