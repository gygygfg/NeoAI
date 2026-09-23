--- systemd 门面 IPC 桥（宿主侧）
--- @module NeoAI.sandbox.systemd_ipc
--- 沙箱内 `/usr/bin/systemctl`、`/usr/bin/journalctl` 是**极薄入口**（只负责转发）：把 argv
--- 以 NUL 分隔写入宿主绑定进来的收件目录，等待响应文件，再按结果打印 stdout/stderr 并以真实
--- 退出码退出。**全部解析与实现都在 Lua**（`NeoAI.sandbox.systemd.exec`），因此脚本/管道里的
--- systemctl 与独立调用行为完全一致，也不会暴露沙箱指纹。
---
--- 传输（文件 IPC，无网络/无外部客户端依赖）：
---   * 宿主目录（无特征基目录下）只读绑定进沙箱为 `GUEST_DIR`（默认 /run/systemd/units）。
---   * 请求：`req.<id>`（NUL 分隔 argv）；响应：`out.<id>` / `err.<id>` / `code.<id>` / `done.<id>`。
---   * 宿主以 fs_event（+ 兜底定时器）扫描并处理，处理完删除 `req.<id>`。

local M = {}

--- 沙箱内 IPC 目录（宿主绑定注入；命名取真实 systemd 运行时目录，降低可识别性）。
local GUEST_DIR = "/run/systemd/units"

local state = {
  host_dir = nil,
  fs_handle = nil,
  timer = nil,
  socket_handle = nil,
  socket_path = nil,
  started = false,
}

--- @return string
function M.guest_dir()
  return GUEST_DIR
end

--- @return string
local function _host_dir()
  local ok, conceal = pcall(require, "NeoAI.sandbox.conceal")
  local base = (ok and conceal and conceal.base_host and conceal.base_host()) or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local dir = base .. "/systemd-ipc"
  pcall(vim.fn.mkdir, dir, "p")
  -- 载荷可能是降权后的专用 uid：目录需可写（仅存在于沙箱挂载视图内，且宿主侧不可枚举敏感内容）。
  pcall(vim.uv.fs_chmod, dir, tonumber("0777", 8))
  return dir
end

--- @param path string
--- @return string|nil
local function _read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

--- @param path string
--- @param data string
--- @return boolean
local function _write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

--- @param s string
--- @return table
local function _split_nul(s)
  local out, start = {}, 1
  while true do
    local i = s:find("\0", start, true)
    if not i then
      if start <= #s then out[#out + 1] = s:sub(start) end
      break
    end
    if i > start then out[#out + 1] = s:sub(start, i - 1) end
    start = i + 1
  end
  return out
end

--- @param dir string
--- @param id string
--- @param res table
local function _respond(dir, id, res)
  _write_file(dir .. "/out." .. id, tostring(res and res.stdout or ""))
  _write_file(dir .. "/err." .. id, tostring(res and res.stderr or ""))
  _write_file(dir .. "/code." .. id, tostring((res and res.code) or 0))
  _write_file(dir .. "/done." .. id, "")
end

--- @param dir string
--- @param id string
local function _handle(dir, id)
  local req = _read_file(dir .. "/req." .. id)
  if not req then return end
  pcall(vim.uv.fs_unlink, dir .. "/req." .. id)
  local argv = _split_nul(req)
  if #argv == 0 then return _respond(dir, id, { stdout = "", stderr = "", code = 0 }) end
  local ok, systemd = pcall(require, "NeoAI.sandbox.systemd")
  if not ok or not systemd or type(systemd.exec) ~= "function" then
    return _respond(dir, id, { stdout = "", stderr = "systemctl: transport error", code = 1 })
  end
  local d = systemd.exec(argv)
  d:then_(function(res) _respond(dir, id, res) end,
    function(e) _respond(dir, id, { stdout = "", stderr = tostring(e), code = 1 }) end)
end

--- @param dir string
local function _scan(dir)
  local h = vim.uv.fs_scandir(dir)
  if not h then return end
  local now = os.time()
  while true do
    local name, t = vim.uv.fs_scandir_next(h)
    if not name then break end
    local id = name:match("^req%.(.+)$")
    if id and t == "file" then
      _handle(dir, id)
    elseif t == "file" and (name:match("^tmp%.") or name:match("^out%.") or name:match("^err%.")
        or name:match("^code%.") or name:match("^done%.")) then
      -- 兜底清理：命令被杀死时残留的中间/响应文件。
      local st = vim.uv.fs_stat(dir .. "/" .. name)
      if st and (now - (st.mtime.sec or now)) > 120 then
        pcall(vim.uv.fs_unlink, dir .. "/" .. name)
      end
    end
  end
end

--- 启动 IPC 服务（幂等）。返回宿主目录；失败返回 nil。
--- @return string|nil
function M.ensure()
  if state.started then return state.host_dir end
  state.host_dir = _host_dir()
  local dir = state.host_dir
  pcall(function()
    local h = vim.uv.new_fs_event()
    h:start(dir, {}, vim.schedule_wrap(function() _scan(dir) end))
    state.fs_handle = h
  end)
  -- 兜底定时器：fs_event 可能合并/丢失事件。
  pcall(function()
    local t = vim.uv.new_timer()
    t:start(1000, 1000, vim.schedule_wrap(function() _scan(dir) end))
    state.timer = t
  end)
  state.started = true
  return dir
end

--- 建立 `/run/systemd/private` 占位 socket（仅外观：真实 systemd 的私有控制 socket）。
--- 不实现 D-Bus 协议；深度探测仍可能识破。返回宿主 socket 路径或 nil。
--- @return string|nil
function M.ensure_private_socket()
  if state.socket_path and vim.uv.fs_stat(state.socket_path) then return state.socket_path end
  -- 放在收件目录之外：收件目录绑定为 /run/systemd/units，不应混入 socket 文件。
  local ok_c, conceal = pcall(require, "NeoAI.sandbox.conceal")
  local base = (ok_c and conceal and conceal.base_host and conceal.base_host())
    or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local path = base .. "/sd-private.sock"
  pcall(vim.uv.fs_unlink, path)
  local ok, handle = pcall(function()
    local p = vim.uv.new_pipe(false)
    p:bind(path)
    p:listen(16, function(err, client)
      if err or not client then return end
      pcall(function() client:close() end)
    end)
    return p
  end)
  if ok and handle then
    state.socket_handle = handle
    state.socket_path = path
    return path
  end
  return nil
end

--- 停止（卸载/重置）。
function M.stop()
  pcall(function() if state.fs_handle then state.fs_handle:stop(); state.fs_handle:close() end end)
  pcall(function() if state.timer then state.timer:stop(); state.timer:close() end end)
  pcall(function() if state.socket_handle then state.socket_handle:close() end end)
  state.fs_handle, state.timer, state.socket_handle, state.started = nil, nil, nil, false
  if state.socket_path then pcall(vim.uv.fs_unlink, state.socket_path) end
  state.socket_path = nil
end

--- 重置（测试用）。
function M.reset()
  M.stop()
  state.host_dir = nil
end

return M
