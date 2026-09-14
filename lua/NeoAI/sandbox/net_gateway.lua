--- 沙箱网络网关的 netns/veth 编排
--- @module NeoAI.sandbox.net_gateway
--- 为「独立 netns + 宿主网关」模式创建网络命名空间与 veth 对，使沙箱进程只能到达宿主网关
--- （默认路由指向网关），无法直接访问宿主服务或其他网络；网关（`sandbox.gateway`）在宿主侧
--- 对目标端口做探针并把拦截原因返回给客户端。
---
--- 需要 root 与 `ip`（`ip netns` 依赖 CAP_NET_ADMIN）。创建的资源在会话/插件卸载时清理。
--- 平台为 Linux；不可用时返回明确错误（fail-closed，不静默降级）。

local config_store = require("NeoAI.kernel.config_store")
local gateway = require("NeoAI.sandbox.gateway")

local M = {}

-- ========== 私有状态 ==========

local state = {
  ns = nil,       -- netns 名
  host_if = nil,  -- 宿主侧 veth
  peer_if = nil,  -- 沙箱侧 veth
  gw_ip = nil,
  sb_ip = nil,
  fw_rule = false, -- 是否插入了宿主防火墙放行规则
}

-- ========== 私有函数 ==========

--- 配置：网关模式是否启用
--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.network.gateway") or {}
end

--- 同步执行 ip 命令，失败返回 nil, err
--- @param argv table
--- @return boolean|nil
--- @return string|nil
local function _run(argv)
  local out = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    return nil, ("%s: %s"):format(table.concat(argv, " "), tostring(out))
  end
  return true
end

--- 执行 `ip netns exec <ns> <argv...>`
--- @param ns string
--- @param argv table
--- @return boolean|nil
--- @return string|nil
local function _ns_run(ns, argv)
  local full = { "ip", "netns", "exec", ns }
  for _, v in ipairs(argv) do full[#full + 1] = v end
  return _run(full)
end

-- ========== 公开 API ==========

--- 网关模式是否启用（配置开关）
--- @return boolean
function M.enabled()
  return _cfg().enabled == true
end

--- 运行环境是否具备创建 netns 的条件（root + ip）
--- @return boolean
--- @return string|nil
function M.available()
  if vim.uv.getuid and vim.uv.getuid() ~= 0 then
    return false, "GATEWAY_NEEDS_ROOT"
  end
  if vim.fn.executable("ip") ~= 1 then
    return false, "GATEWAY_IP_UNAVAILABLE"
  end
  return true
end

--- 幂等地创建 netns + veth 并启动网关；返回连接信息。
--- @return table|nil { ns, host, port }
--- @return string|nil err
function M.ensure()
  if state.ns then return { ns = state.ns, host = gateway.address() and gateway.address().host, port = gateway.address() and gateway.address().port } end
  if not M.enabled() then return nil, "GATEWAY_DISABLED" end
  local ok_env, env_err = M.available()
  if not ok_env then return nil, env_err end

  local tag = tostring(vim.fn.getpid())
  local ns = "neoai-gw-" .. tag
  local h = "nh" .. tag:sub(-10)
  local s = "ns" .. tag:sub(-10)
  local oct = (tonumber(tag) % 200) + 1
  local gw_ip = ("10.213.%d.1"):format(oct)
  local sb_ip = ("10.213.%d.2"):format(oct)

  local function fail(err)
    M.teardown()
    return nil, err
  end

  if not _run({ "ip", "netns", "add", ns }) then return fail("GATEWAY_NETNS_ADD_FAILED") end
  state.ns = ns
  if not _run({ "ip", "link", "add", h, "type", "veth", "peer", "name", s }) then
    return fail("GATEWAY_VETH_ADD_FAILED")
  end
  state.host_if, state.peer_if = h, s
  if not _run({ "ip", "link", "set", s, "netns", ns }) then return fail("GATEWAY_VETH_MOVE_FAILED") end
  if not _run({ "ip", "addr", "add", gw_ip .. "/30", "dev", h }) then return fail("GATEWAY_ADDR_FAILED") end
  if not _run({ "ip", "link", "set", h, "up" }) then return fail("GATEWAY_LINK_UP_FAILED") end
  if not _ns_run(ns, { "ip", "addr", "add", sb_ip .. "/30", "dev", s }) then return fail("GATEWAY_PEER_ADDR_FAILED") end
  if not _ns_run(ns, { "ip", "link", "set", s, "up" }) then return fail("GATEWAY_PEER_UP_FAILED") end
  _ns_run(ns, { "ip", "link", "set", "lo", "up" })
  if not _ns_run(ns, { "ip", "route", "add", "default", "via", gw_ip }) then return fail("GATEWAY_ROUTE_FAILED") end

  -- 宿主防火墙（如 ufw）默认丢弃来自 veth 的新连接；仅放行本网关接口的入站，
  -- 并在 teardown 时移除。规则绑定具体接口名，接口删除后即失效，无残留影响。
  if vim.fn.executable("iptables") == 1 then
    if _run({ "iptables", "-I", "INPUT", "1", "-i", h, "-j", "ACCEPT" }) then
      state.fw_rule = true
    end
  end

  local addr, gerr = gateway.start(gw_ip, 0)
  if not addr then return fail("GATEWAY_START_FAILED: " .. tostring(gerr)) end
  state.gw_ip, state.sb_ip = gw_ip, sb_ip
  return { ns = ns, host = addr.host, port = addr.port }
end

--- netns 执行前缀（放在命令最前）
--- @return table
function M.exec_prefix()
  if not state.ns then return {} end
  return { "ip", "netns", "exec", state.ns }
end

--- 网关代理环境变量（HTTP(S)_PROXY 指向网关；清空 NO_PROXY 使 localhost 也走网关）
--- @return table
function M.env()
  local a = gateway.address()
  if not a then return {} end
  local url = ("http://%s:%d"):format(a.host, a.port)
  return {
    http_proxy = url, HTTP_PROXY = url,
    https_proxy = url, HTTPS_PROXY = url,
    no_proxy = "", NO_PROXY = "",
  }
end

--- 当前网关地址
--- @return table|nil { host, port }
function M.address()
  return gateway.address()
end

--- 清理 netns/veth 与网关
function M.teardown()
  gateway.stop()
  if state.fw_rule and state.host_if then
    pcall(vim.fn.system, { "iptables", "-D", "INPUT", "-i", state.host_if, "-j", "ACCEPT" })
    state.fw_rule = false
  end
  if state.ns then
    pcall(vim.fn.system, { "ip", "netns", "del", state.ns })
  end
  if state.host_if then
    pcall(vim.fn.system, { "ip", "link", "del", state.host_if })
  end
  state.ns, state.host_if, state.peer_if = nil, nil, nil
  state.gw_ip, state.sb_ip = nil, nil
end

--- 重置（测试用）
function M.reset()
  M.teardown()
end

return M
