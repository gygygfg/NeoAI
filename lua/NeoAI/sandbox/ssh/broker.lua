--- 宿主侧 SSH 能力代理（别名 / 命令构建）
--- @module 'NeoAI.sandbox.ssh.broker'
--- 目标：让 AI 能用本机密钥，但**密钥永远不进入沙箱视图**。做法是把 openssh 放回宿主侧执行：
--- 沙箱内没有任何密钥文件，AI 只能请求「对某个**别名**做某个动作」，由本模块把请求翻译成
--- 一条参数固定的宿主 ssh 命令（交给 `sandbox/execution/hostop` 冻结为待审提案）。
---
--- 三条硬约束（都是代码强制，不靠文案）：
---   1. **别名唯一**：AI 只能给 `alias`，不能给 host/port/user/`-o`。所有目标信息来自配置，
---      因此「自己编译一套 ssh」在能力层面没有收益——它拿不到可用的目标或密钥。
---   2. **指纹钉死**：`alias.fingerprint` 必须与密钥文件当前内容一致（换钥匙即失效），
---      `-F /dev/null` + `IdentitiesOnly=yes` 保证不读宿主 ssh config、不把别的钥匙递出去。
---   3. **隧道只能绑 loopback**：`-L 127.0.0.1:<lp>:<rh>:<rp>`，目标主机必须在别名白名单里；
---      不提供 `-R`/`-D`/`GatewayPorts`，`-f -N` 后台化后由 ControlPath 显式关闭。
---
--- 本模块**只构建命令**（纯函数，可单测）并记录审计；真正的执行由 hostop 审批后 replay。
--- 这样「AI 能做什么」与「用户批了什么」在同一条待审链上，密钥读写都在宿主 openssh 进程内。

local M = {}

-- ========== 私有状态 ==========

local state = { seq = 0 }

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.ssh")
  end)
  return (ok and type(cfg) == "table") and cfg or {}
end

--- @return string
local function _home()
  local h = vim.fn.expand("~")
  return type(h) == "string" and h or ""
end

--- 别名/主机/用户名的字符白名单（拒绝以 `-` 开头，避免被当作选项注入）
--- @param s any
--- @param pat string|nil
--- @return boolean
local function _safe_token(s, pat)
  return type(s) == "string" and s ~= "" and s:match(pat or "^[%w][%w%._%-]*$") ~= nil
end

--- @param p any
--- @return boolean
local function _port_ok(p)
  return type(p) == "number" and p >= 1 and p <= 65535 and math.floor(p) == p
end

--- @param v string
--- @return string
local function _q(v)
  return vim.fn.shellescape(v)
end

--- 记录一次构建尝试（审计：谁、用哪个别名、做什么动作、目标）。
--- @param alias string
--- @param op string
--- @param host string|nil
--- @param extra table|nil
local function _audit(alias, op, host, extra)
  state.seq = state.seq + 1
  local seq = state.seq
  pcall(function()
    require("NeoAI.sandbox.observe.audit").record({
      kind = "protected",
      tool = "ssh",
      level = 1,
      reasons = { "SSH_ALIAS_USE" },
      meta = vim.tbl_extend("keep", extra or {}, {
        alias = alias, op = op, host = host, seq = seq,
      }),
    })
  end)
end

--- 校验并解析别名
--- @param alias string|nil
--- @param op string "exec"|"tunnel"
--- @return table|nil spec
--- @return string|nil err
local function _resolve(alias, op)
  local cfg = _cfg()
  if cfg.enabled ~= true then
    return nil, "SSH_DISABLED: tools.sandbox.ssh.enabled 未开启（宿主侧 SSH 能力默认关闭）"
  end
  if not _safe_token(alias) then return nil, "SSH_ALIAS_INVALID: 别名缺失或含非法字符" end
  local a = (cfg.aliases or {})[alias]
  if type(a) ~= "table" then
    return nil, "SSH_ALIAS_UNKNOWN: 未配置的别名 " .. tostring(alias)
  end
  local allow = a.allow
  local allowed = false
  for _, v in ipairs(type(allow) == "table" and allow or { "exec" }) do
    if v == op or v == "*" then allowed = true break end
  end
  if not allowed then
    return nil, ("SSH_ALIAS_FORBIDDEN: 别名 %s 未允许 %s（allow 需包含该动作）"):format(alias, op)
  end
  if not _safe_token(a.host) then return nil, "SSH_ALIAS_INVALID: 主机名非法" end
  if a.user ~= nil and not _safe_token(a.user) then return nil, "SSH_ALIAS_INVALID: 用户名非法" end
  if a.port ~= nil and not _port_ok(a.port) then return nil, "SSH_ALIAS_INVALID: 端口非法" end
  local key = type(a.key) == "string" and vim.fn.expand(a.key) or nil
  if not key or vim.fn.filereadable(key) ~= 1 then
    return nil, "SSH_ALIAS_KEY_MISSING: 别名私钥不可读"
  end
  local pre = require("NeoAI.sandbox.protected.preauthorize")
  local fp = pre.fingerprint_file(key)
  if type(a.fingerprint) ~= "string" or a.fingerprint == "" then
    return nil, "SSH_ALIAS_NO_FINGERPRINT: 别名必须声明 fingerprint（:NeoAI SandboxKeys <key>）"
  end
  if fp ~= a.fingerprint then
    return nil, "SSH_ALIAS_KEY_CHANGED: 私钥指纹与配置不符（密钥被替换或改名）"
  end
  local kh = type(a.known_hosts) == "string" and vim.fn.expand(a.known_hosts)
    or (_home() .. "/.ssh/known_hosts")
  if a.accept_new ~= true and vim.fn.filereadable(kh) ~= 1 then
    return nil, "SSH_ALIAS_NO_KNOWN_HOSTS: 缺少 known_hosts（或把 accept_new 设为 true）"
  end
  return {
    name = alias, host = a.host, user = a.user, port = a.port,
    key = key, known_hosts = kh,
    accept_new = a.accept_new == true,
    connect_timeout = tonumber(a.connect_timeout) or tonumber(cfg.connect_timeout) or 10,
    tunnel = a.tunnel,
  }
end

--- 公共 ssh 参数前缀（全部固定，不接受 AI 传入的 `-o`）
--- @param a table
--- @return string[]
local function _base_argv(a)
  local argv = {
    "ssh", "-F", "/dev/null",
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "PermitLocalCommand=no",
    "-o", "ForwardAgent=no",
    "-o", "ConnectTimeout=" .. tostring(a.connect_timeout),
    "-o", "StrictHostKeyChecking=" .. (a.accept_new and "accept-new" or "yes"),
    "-o", "UserKnownHostsFile=" .. a.known_hosts,
    "-i", a.key,
  }
  if a.user then argv[#argv + 1] = "-l"; argv[#argv + 1] = a.user end
  if a.port then argv[#argv + 1] = "-p"; argv[#argv + 1] = tostring(a.port) end
  argv[#argv + 1] = a.host
  return argv
end

--- @param argv string[]
--- @return string
local function _join(argv)
  local out = {}
  for _, v in ipairs(argv) do out[#out + 1] = _q(v) end
  return table.concat(out, " ")
end

--- 隧道控制套接字目录（宿主侧、会话私有）
--- @return string
function M.tunnel_dir()
  local root
  local ok, store = pcall(require, "NeoAI.sandbox.state.store")
  if ok and type(store.root) == "function" then root = store.root() end
  if type(root) ~= "string" or root == "" then
    root = vim.fn.stdpath("cache") .. "/NeoAI/sandbox"
  end
  local dir = root .. "/ssh"
  pcall(vim.fn.mkdir, dir, "p", "0700")
  return dir
end

--- 隧道控制套接字路径（宿主侧、会话私有）
--- @param alias string
--- @param lport number
--- @return string
function M.control_path(alias, lport)
  return ("%s/%s-%d.sock"):format(M.tunnel_dir(), alias, lport)
end

-- ========== 公开 API ==========

--- 别名列表（只返回可公开字段，**不含**密钥路径/指纹明文）
--- @return table[] { name, host, user, port, allow }
function M.list()
  local out = {}
  for name, a in pairs(_cfg().aliases or {}) do
    if type(a) == "table" then
      out[#out + 1] = {
        name = name,
        host = a.host,
        user = a.user,
        port = a.port,
        allow = a.allow,
      }
    end
  end
  table.sort(out, function(x, y) return x.name < y.name end)
  return out
end

--- 构建「在远端执行一条命令」的宿主 ssh 命令
--- @param alias string
--- @param command string
--- @return string|nil command 可直接交给 hostop 的 shell 命令
--- @return string|nil err
function M.build_exec_command(alias, command)
  if type(command) ~= "string" or command == "" then
    return nil, "SSH_COMMAND_EMPTY: 远端命令为空"
  end
  if #command > 8192 then return nil, "SSH_COMMAND_TOO_LONG: 远端命令过长" end
  local a, err = _resolve(alias, "exec")
  if not a then return nil, err end
  local argv = _base_argv(a)
  argv[#argv + 1] = command
  _audit(alias, "exec", a.host)
  return _join(argv)
end

--- 校验隧道参数
--- @param a table 别名
--- @param t table { local_port, remote_host, remote_port }
--- @return table|nil { local_port, remote_host, remote_port }
--- @return string|nil err
local function _tunnel_spec(a, t)
  if type(t) ~= "table" then return nil, "SSH_TUNNEL_INVALID: 缺少隧道参数" end
  if not _port_ok(t.local_port) then return nil, "SSH_TUNNEL_INVALID: local_port 非法" end
  if not _port_ok(t.remote_port) then return nil, "SSH_TUNNEL_INVALID: remote_port 非法" end
  if not _safe_token(t.remote_host, "^[%w][%w%._%-]*$") then
    return nil, "SSH_TUNNEL_INVALID: remote_host 非法"
  end
  local cfg = a.tunnel
  if type(cfg) ~= "table" then
    return nil, "SSH_TUNNEL_DISABLED: 别名未声明 tunnel 配置（local_ports / remote_hosts）"
  end
  local lp = cfg.local_ports
  if type(lp) == "table" and _port_ok(lp[1]) and _port_ok(lp[2]) then
    if t.local_port < lp[1] or t.local_port > lp[2] then
      return nil, ("SSH_TUNNEL_PORT_FORBIDDEN: local_port 必须在 %d-%d 内"):format(lp[1], lp[2])
    end
  else
    return nil, "SSH_TUNNEL_DISABLED: 别名未声明 local_ports 范围"
  end
  local hosts = cfg.remote_hosts
  local ok_host = false
  for _, p in ipairs(type(hosts) == "table" and hosts or {}) do
    if type(p) == "string" then
      if p == t.remote_host then ok_host = true break end
      if p:sub(1, 2) == "*." and t.remote_host:sub(-#p + 1) == p:sub(2) then ok_host = true break end
    end
  end
  if not ok_host then
    return nil, ("SSH_TUNNEL_TARGET_FORBIDDEN: remote_host %s 不在别名白名单内"):format(tostring(t.remote_host))
  end
  return { local_port = t.local_port, remote_host = t.remote_host, remote_port = t.remote_port }
end

--- 构建「打开隧道」的宿主 ssh 命令（`-f -N`：认证后后台化，命令立即返回）
--- 只允许 `-L 127.0.0.1:…`；不提供 `-R`/`-D`，也不允许 `GatewayPorts`。
--- @param alias string
--- @param t table { local_port, remote_host, remote_port }
--- @return string|nil
--- @return string|nil err
function M.build_tunnel_open_command(alias, t)
  local a, err = _resolve(alias, "tunnel")
  if not a then return nil, err end
  local s, serr = _tunnel_spec(a, t)
  if not s then return nil, serr end
  -- 并发上限：按当前别名的存活控制套接字计数（`-f` 后台化后无法靠 job 句柄统计）。
  local cap = tonumber(_cfg().max_tunnels) or 4
  local live = vim.fn.glob(M.tunnel_dir() .. "/" .. alias .. "-*.sock", false, true)
  if #live >= cap then
    return nil, ("SSH_TUNNEL_LIMIT: 别名 %s 已打开 %d 条隧道（上限 %d），先 close 再开"):format(
      alias, #live, cap)
  end
  local ctl = M.control_path(alias, s.local_port)
  local argv = _base_argv(a)
  -- 选项必须放在 host 之前：在 host 之后追加会变成远端命令。
  local head = {}
  for i = 1, #argv - 1 do head[#head + 1] = argv[i] end
  for _, v in ipairs({
    "-M", "-S", ctl, "-f", "-N",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ControlMaster=yes",
    "-o", "GatewayPorts=no",
    "-L", ("127.0.0.1:%d:%s:%d"):format(s.local_port, s.remote_host, s.remote_port),
  }) do head[#head + 1] = v end
  head[#head + 1] = a.host
  _audit(alias, "tunnel_open", a.host, {
    local_port = s.local_port, remote_host = s.remote_host, remote_port = s.remote_port,
  })
  return _join(head)
end

--- 构建「关闭隧道」的宿主 ssh 命令（`-O exit`，按 ControlPath 精确关闭）
--- @param alias string
--- @param local_port number
--- @return string|nil
--- @return string|nil err
function M.build_tunnel_close_command(alias, local_port)
  local a, err = _resolve(alias, "tunnel")
  if not a then return nil, err end
  if not _port_ok(local_port) then return nil, "SSH_TUNNEL_INVALID: local_port 非法" end
  local ctl = M.control_path(alias, local_port)
  local argv = _base_argv(a)
  local head = {}
  for i = 1, #argv - 1 do head[#head + 1] = argv[i] end
  for _, v in ipairs({ "-S", ctl, "-O", "exit" }) do head[#head + 1] = v end
  head[#head + 1] = a.host
  _audit(alias, "tunnel_close", a.host, { local_port = local_port })
  return _join(head)
end

--- 关闭本实例的全部隧道（会话结束 / reset 时调用）：按控制套接字逐个 `ssh -O exit`。
--- 隧道是 `-f -N` 后台化的独立进程，没有 job 句柄；只能靠 ControlPath 精确关闭。
--- @return integer closed
function M.close_all()
  local socks = vim.fn.glob(M.tunnel_dir() .. "/*.sock", false, true)
  local closed = 0
  for _, sock in ipairs(socks) do
    local alias = vim.fn.fnamemodify(sock, ":t"):match("^(.-)%-%d+%.sock$")
    local a = alias and _resolve(alias, "tunnel")
    local argv
    if a then
      local base = _base_argv(a)
      argv = {}
      for i = 1, #base - 1 do argv[#argv + 1] = base[i] end
      for _, v in ipairs({ "-S", sock, "-O", "exit" }) do argv[#argv + 1] = v end
      argv[#argv + 1] = a.host
    else
      argv = { "ssh", "-o", "BatchMode=yes", "-S", sock, "-O", "exit", "localhost" }
    end
    pcall(vim.fn.system, argv)
    if vim.uv.fs_stat(sock) then pcall(vim.fn.delete, sock) end
    closed = closed + 1
  end
  return closed
end

--- 重置（测试用）
function M.reset()
  state.seq = 0
end

return M
