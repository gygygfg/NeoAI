--- 沙箱私有网络命名空间 + 宿主 HTTP 代理桥
--- @module 'NeoAI.sandbox.net.isolate'
---
--- 目标（默认网络模式）：载荷运行在**私有 netns**（只有 loopback），外部访问必须经宿主侧
--- `host_proxy`。因此：
---   * 裸 TCP/UDP、裸 socket、`/dev/tcp` 都无路由（fail-closed）；
---   * 宿主回环/网卡/云元数据地址不可达；
---   * 遵守 `HTTP(S)_PROXY` 的 curl/pip/git/npm 仍可出网，并继续经 host_proxy 做
---     本机拦截、记录与同意。
---
--- 链路：
---   沙箱 curl → 127.0.0.1:3128（会话内 socat）
---             → UNIX-CONNECT /run/neoai-net/proxy.sock（bind mount）
---             → 宿主 socat UNIX-LISTEN → host_proxy TCP 127.0.0.1:PORT
---
--- 两种实现：
---   * root：宿主用 `ip netns add` 建 netns 并把 lo 拉起，bwrap 以 `ip netns exec` 进入；
---     载荷**不需要 CAP_NET_ADMIN**（能力基线不变）。
---   * 非 root：bwrap 自身 `--unshare-all` 已建 userns+netns；载荷临时持有
---     CAP_NET_ADMIN（仅作用于该 userns/netns），由 boot 片段 `ip link set lo up`。
---
--- 不支持时（无 socat / 无 bwrap / 无法建 netns）：由调用方按
--- `tools.sandbox.network.isolation_fail_closed` 选择拒网或退回共享 netns（绝不静默）。

local M = {}

local GUEST_DIR = "/run/neoai-net"
local GUEST_SOCK = GUEST_DIR .. "/proxy.sock"
local INNER_PORT = 3128

local state = {
  active = false,
  mode = nil, -- "netns" | "userns"
  reason = nil,
  ns = nil,
  host_dir = nil,
  host_sock = nil,
  bridge_job = nil,
  proxy_port = nil,
  autocmd = nil,
}

-- ========== 私有函数 ==========

local function _cfg()
  return require("NeoAI.kernel.config_store").get("tools.sandbox.network") or {}
end

local function _sandbox_cfg()
  return require("NeoAI.kernel.config_store").get("tools.sandbox") or {}
end

local function _is_root()
  return vim.uv.getuid and vim.uv.getuid() == 0
end

local function _run(argv)
  local out = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    return nil, tostring(out)
  end
  return true
end

--- 清理 netns / 宿主 socat / socket。
local function _teardown()
  if state.bridge_job then
    pcall(vim.fn.jobstop, state.bridge_job)
    state.bridge_job = nil
  end
  if state.ns then
    pcall(vim.fn.system, { "ip", "netns", "del", state.ns })
    state.ns = nil
  end
  if state.host_sock then pcall(vim.uv.fs_unlink, state.host_sock) end
  if state.autocmd then
    pcall(vim.api.nvim_del_autocmd, state.autocmd)
    state.autocmd = nil
  end
  state.active = false
  state.mode = nil
  state.host_dir = nil
  state.host_sock = nil
  state.proxy_port = nil
end

--- 启动宿主侧 Unix→TCP 桥（socat）。
--- @param sock string
--- @param port number
--- @return boolean ok
--- @return string|nil err
local function _start_host_bridge(sock, port)
  pcall(vim.uv.fs_unlink, sock)
  local job = vim.fn.jobstart({
    "socat",
    "UNIX-LISTEN:" .. sock .. ",fork,mode=666",
    "TCP:127.0.0.1:" .. tostring(port),
  }, { on_stderr = function() end })
  if job <= 0 then return false, "SOCAT_JOB_FAILED" end
  state.bridge_job = job
  local ok = vim.wait(3000, function()
    local st = vim.uv.fs_stat(sock)
    return st ~= nil
  end, 20)
  if not ok then
    pcall(vim.fn.jobstop, job)
    state.bridge_job = nil
    return false, "SOCAT_SOCKET_TIMEOUT"
  end
  return true, nil
end

--- 宿主代理地址（isolation 不依赖 host_local_block 配置：总是需要一个代理承接外部流量）。
--- @return table|nil { host, port }
local function _ensure_host_proxy()
  local hp = require("NeoAI.sandbox.net.host_proxy")
  local addr = hp.ensure()
  if addr then return addr end
  -- host_local_block=false 时 ensure() 不启动；isolation 仍必须有代理才能出网。
  local a = hp.start("127.0.0.1", 0)
  if a then
    state._started_host_proxy = true
    return a
  end
  return nil
end

-- ========== 公开 API ==========

--- 是否启用隔离网络（配置）。
--- @return boolean
function M.enabled()
  return _cfg().isolation ~= "off"
end

--- 隔离是否已就绪。
--- @return boolean
function M.active()
  return state.active == true
end

--- 当前实现方式："netns" | "userns" | nil。
--- @return string|nil
function M.mode()
  return state.mode
end

--- 未就绪原因（诊断用）。
--- @return string|nil
function M.reason()
  return state.reason
end

--- 沙箱内代理 URL。
--- @return string
function M.proxy_url()
  return ("http://127.0.0.1:%d"):format(INNER_PORT)
end

--- 是否需要给载荷临时授予 CAP_NET_ADMIN（仅非 root 的 userns 模式）。
--- @return boolean
function M.needs_cap()
  return state.active and state.mode == "userns"
end

--- bwrap 之外的前缀（root netns 模式）；其它模式返回空数组。
--- @return table
function M.exec_prefix()
  if state.active and state.mode == "netns" and state.ns then
    return { "ip", "netns", "exec", state.ns }
  end
  return {}
end

--- 挂载规格：宿主代理 socket 目录 → 沙箱内固定路径。
--- @return table|nil { src, dst }
function M.mount_spec()
  if not state.active or not state.host_dir then return nil end
  return { src = state.host_dir, dst = GUEST_DIR }
end

--- 会话启动片段：拉起 lo（userns 模式）并启动会话内 socat。
--- @return string|nil
function M.boot_snippet()
  if not state.active then return nil end
  local lines = {}
  if state.mode == "userns" then
    lines[#lines + 1] = "ip link set lo up 2>/dev/null || true"
  end
  lines[#lines + 1] = "(socat TCP-LISTEN:" .. INNER_PORT
    .. ",bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:" .. GUEST_SOCK
    .. " >/dev/null 2>&1 &)"
  lines[#lines + 1] = "sleep 0.2"
  return table.concat(lines, "\n")
end

--- 准备隔离网络（幂等）。失败返回 false + 原因；绝不抛错。
--- @return boolean ok
--- @return string|nil err
function M.ensure()
  if state.active then
    -- 配置关闭或代理端口变化时重建。
    if not M.enabled() then M.stop(); return false, "ISOLATION_OFF" end
    local hp = require("NeoAI.sandbox.net.host_proxy").address()
    if hp and hp.port == state.proxy_port then return true, nil end
    _teardown()
  end
  state.reason = nil
  if not M.enabled() then state.reason = "ISOLATION_OFF"; return false, state.reason end
  if _sandbox_cfg().offline == true then state.reason = "OFFLINE"; return false, state.reason end
  local okg, ng = pcall(require, "NeoAI.sandbox.net.net_gateway")
  if okg and ng and ng.enabled() then state.reason = "GATEWAY_MODE"; return false, state.reason end
  if vim.fn.executable("socat") ~= 1 then state.reason = "SOCAT_MISSING"; return false, state.reason end

  local addr = _ensure_host_proxy()
  if not addr then state.reason = "HOST_PROXY_UNAVAILABLE"; return false, state.reason end

  local store = require("NeoAI.sandbox.state.store")
  local root = (store.root and store.root()) or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")
  local dir = root .. "/net"
  vim.fn.mkdir(dir, "p")
  pcall(vim.uv.fs_chmod, dir, 493) -- 0755（沙箱内需可遍历；宿主父目录仍为 0700）
  local sock = dir .. "/proxy.sock"
  local ok, err = _start_host_bridge(sock, addr.port)
  if not ok then
    state.reason = err
    return false, err
  end
  state.host_dir, state.host_sock, state.proxy_port = dir, sock, addr.port

  if _is_root() and vim.fn.executable("ip") == 1 then
    local name = ("neoai-iso-%d-%d"):format(vim.uv.os_getpid(), math.random(1, 1e6))
    local ok_add = _run({ "ip", "netns", "add", name })
    if ok_add then
      local ok_lo = _run({ "ip", "netns", "exec", name, "ip", "link", "set", "lo", "up" })
      if ok_lo then
        state.ns, state.mode, state.active = name, "netns", true
      else
        pcall(vim.fn.system, { "ip", "netns", "del", name })
      end
    end
    if not state.active then
      state.reason = "NETNS_SETUP_FAILED"
    end
  else
    -- 非 root：bwrap 的 userns+netns 已由 USER_FLAGS 创建；boot 里拉起 lo。
    state.mode, state.active = "userns", true
  end

  if not state.active then
    _teardown()
    return false, state.reason or "ISOLATION_UNAVAILABLE"
  end

  -- nvim 退出时清理 netns/socat（jobstop 只能杀直接子进程）。
  if not state.autocmd then
    local group = vim.api.nvim_create_augroup("NeoAISandboxNetIsolate", { clear = true })
    state.autocmd = vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function() pcall(M.stop) end,
    })
  end
  return true, nil
end

--- 停止并清理。
function M.stop()
  local started = state._started_host_proxy
  _teardown()
  if started then
    pcall(function() require("NeoAI.sandbox.net.host_proxy").stop() end)
  end
  state._started_host_proxy = nil
end

--- 状态（诊断/命令）。
--- @return table
function M.status()
  return {
    enabled = M.enabled(),
    active = state.active,
    mode = state.mode,
    reason = state.reason,
    namespace = state.ns,
    proxy = state.active and M.proxy_url() or nil,
    socket = state.host_sock,
  }
end

--- 测试/热重载。
function M.reset()
  M.stop()
  state.reason = nil
end

return M
