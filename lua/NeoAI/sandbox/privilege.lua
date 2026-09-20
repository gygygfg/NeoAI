--- 沙箱权限档位与自动提权
--- @module NeoAI.sandbox.privilege
--- 为外部进程定义分级权限档位（最小权限 → 提权 → 特权），把「命令所需权限」
--- 映射为具体隔离参数（cap_add / 额外挂载 / 解除遮蔽 / 网络 / 嵌套 userns）。
---
--- 设计模型（见 docs/sandbox.md §17）：
---   T0 最小权限：默认档位，cap-drop ALL + seccomp + 遮蔽 + 默认隔离网络；
---   T1 提权（隔离内）：网络访问、受控 docker socket；自动授权、隔离执行、留痕；
---   T2 特权（主机影响）：在嵌套 userns 内自动执行，主机效果冻结为提案异步审批。
--- 自动提权只「发起请求」，是否放行由策略/授权/审查决定；不静默降级。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 档位常量 ==========

M.TIER = { MINIMAL = 0, ELEVATED = 1, PRIVILEGED = 2 }

-- 档位默认（配置缺省时兜底；与 default_config.lua 保持一致）
local TIER_DEFAULTS = {
  -- T0 默认放行网络（仅记录）但经 host_proxy 拦截本机访问；offline=true 时仍硬隔离。
  -- 档位默认不授予任何 capability（受控启动：全局 cap_add 默认空 → --cap-drop ALL），
  -- 包安装所需的窄能力由 resolve() 按 `packages.cap_add` 按需加回。
  [0] = { name = "minimal", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {} },
  -- T1 提权不默认解除 docker.sock 遮蔽：socket 仅在命令被分类为 docker（req.docker）时
  -- 由 resolve() 按需挂载并解除遮蔽，避免 `pip install` 这类 T1 命令连带放行 docker。
  [1] = {
    name = "elevated", review = "auto", network = true, cap_add = {}, mounts = {}, unmask = {},
  },
  -- T2 特权：嵌套 userns 内授予完整能力（caps 被 userns 作用域限制，够不到宿主；
  -- 主机效果冻结为提案异步审批）。seccomp 基线仍然生效（mount/init_module 等被拦）。
  [2] = {
    name = "privileged", review = "approve", network = true, userns = true, cap_add = { "ALL" },
    mounts = {}, unmask = {},
  },
}

-- 提权失败模式：T0 命令失败时据此建议升级档位（仅发起请求，不静默执行）
local ESCALATION_PATTERNS = {
  {
    tier = M.TIER.ELEVATED, reason = "DOCKER_SOCKET_UNAVAILABLE",
    pats = {
      "cannot connect to the docker daemon", "is the docker daemon running",
      "dial unix /var/run/docker.sock", "docker.sock: connect",
    },
  },
  {
    tier = M.TIER.ELEVATED, reason = "NETWORK_UNREACHABLE",
    pats = {
      "could not resolve host", "temporary failure in name resolution",
      "network is unreachable", "connection refused", "connection timed out",
      "no route to host", "couldn't connect to server", "failed to connect",
    },
  },
  {
    tier = M.TIER.PRIVILEGED, reason = "PRIVILEGE_DENIED",
    pats = {
      "operation not permitted", "permission denied", "read-only file system",
      "must be root", "are you root",
      "requires root", "requires cap_", "you need to be root",
    },
  },
}

-- 可跳过的命令前缀（不含 sudo/doas：它们本身就是特权信号，保留分类）
local SKIP_PREFIX = {
  env = true, command = true, nohup = true, time = true, nice = true,
  stdbuf = true, xargs = true,
}

-- 识别包管理器时需要跳过的「包装器/外壳」token：`sudo apt`、`env sudo apt`、
-- `bash -c 'apt …'`、`for …; do apt …; done` 等都应能识别出真正的包管理器，
-- 否则会漏判为包安装，进而触发密钥误报升到 L3。
local WRAPPER_BINS = {
  sudo = true, doas = true,
  bash = true, sh = true, zsh = true, dash = true, ksh = true,
  ["do"] = true, ["then"] = true, ["else"] = true, ["elif"] = true, ["if"] = true,
  ["while"] = true, ["until"] = true, ["for"] = true, ["in"] = true, ["done"] = true,
  ["fi"] = true, esac = true, case = true,
}

-- 包安装的良性伴随段：只消费 stdin、无任意文件读取能力的命令（如 `apt update | tee log`、
-- `apt install -y x 2>&1` 的重定向残段）。它们不单独构成包安装，仅影响 `package_all`
-- 统计标记；capability 授予以 `package`（任一含包管理器的段）为准（见 resolve）。
local PKG_COMPANIONS = { tee = true }

-- `mount` 变更型选项（出现即视为特权操作）
local MOUNT_MUTATING_OPTS = {
  ["-a"] = true, ["--all"] = true, ["-o"] = true, ["--options"] = true,
  ["-B"] = true, ["--bind"] = true, ["-R"] = true, ["--rbind"] = true,
  ["-M"] = true, ["--move"] = true,
  ["--make-shared"] = true, ["--make-slave"] = true, ["--make-private"] = true,
  ["--make-unbindable"] = true, ["--make-rshared"] = true, ["--make-rslave"] = true,
  ["--make-rprivate"] = true, ["--make-runbindable"] = true,
}

-- `mount` 带独立取值的选项（其后的 token 是值而非位置参数）
local MOUNT_VALUE_OPTS = {
  ["-t"] = true, ["--types"] = true, ["-O"] = true, ["--test-opts"] = true,
  ["-L"] = true, ["--label"] = true, ["-U"] = true, ["--uuid"] = true,
  ["--source"] = true, ["--target"] = true, ["--namespace"] = true, ["-N"] = true,
  ["--mount-prefix"] = true, ["--options-mode"] = true, ["--options-source"] = true,
}

--- `mount` 是否会产生变更（存在位置参数或变更型选项）；仅列举返回 false。
--- 裸 `mount`、`mount -l`、`mount --show-labels`、`mount -t ext4` 只读取挂载表，
--- 不应被视为特权操作（`mount | grep` 这类只读管道同样如此）。
--- @param toks table 全部 token
--- @param start number `mount` 之后的第一个 token 下标
--- @return boolean
local function _mount_mutates(toks, start)
  local i = start
  while i <= #toks do
    local a = toks[i]
    if a:sub(1, 1) == "-" and a ~= "-" then
      local opt = a:match("^([^=]+)")
      if MOUNT_MUTATING_OPTS[a] or MOUNT_MUTATING_OPTS[opt] then return true end
      if MOUNT_VALUE_OPTS[opt] and not a:find("=", 1, true) then i = i + 1 end
    else
      return true -- 位置参数（设备/挂载点）→ 会执行挂载
    end
    i = i + 1
  end
  return false
end

-- 包管理器状态/安装路径特征（子串匹配）：命中即视为「由包管理器修改」，
-- 风险封顶 L2（见 risk.classify 与 wrapper._settle_candidate）。
local PACKAGE_PATH_SIGNS = {
  { manager = "apt", subs = { "/var/lib/apt/", "/var/cache/apt/", "/var/lib/dpkg/", "/var/cache/debconf/" } },
  { manager = "rpm", subs = { "/var/lib/rpm/", "/var/cache/dnf/", "/var/cache/yum/", "/var/lib/zypp/" } },
  { manager = "pacman", subs = { "/var/lib/pacman/", "/var/cache/pacman/" } },
  { manager = "apk", subs = { "/lib/apk/", "/var/cache/apk/" } },
  { manager = "npm", subs = {
    "/node_modules/", "/.npm/", "/.cache/yarn/", "/.pnpm-store/",
    "/usr/lib/node_modules/", "/usr/local/lib/node_modules/", "/usr/share/nodejs/",
  } },
  { manager = "pip", subs = { "/site-packages/", "/dist-packages/", "/.cache/pip/", "/.cache/uv/", "/.local/lib/python" } },
  { manager = "conda", subs = { "/conda/", "/miniconda", "/anaconda", "/conda/pkgs/", "/conda/envs/" } },
  { manager = "cargo", subs = { "/.cargo/", "/.rustup/" } },
  { manager = "go", subs = { "/go/pkg/mod/", "/go/bin/" } },
  { manager = "gem", subs = { "/.gem/", "/var/lib/gems/", "/.local/share/gem/" } },
  { manager = "composer", subs = { "/.composer/", "/.cache/composer/" } },
  { manager = "nuget", subs = { "/.nuget/" } },
  { manager = "dotnet", subs = { "/.dotnet/" } },
  { manager = "vcpkg", subs = { "/vcpkg/" } },
  { manager = "conan", subs = { "/.conan/" } },
}

--- 配置的包管理器名单（集合）
--- @return table<string, boolean>
local function _package_managers()
  local set = {}
  local list = (config_store.get("tools.sandbox.packages") or {}).managers
  if type(list) == "table" then
    for _, m in ipairs(list) do if type(m) == "string" then set[m] = true end end
  end
  return set
end

--- 去掉 token 两侧的引号/括号/分号等外壳字符（`'apt` -> `apt`）。
--- @param w string
--- @return string
local function _strip_token(w)
  return (tostring(w):gsub("^[%s%'\"`%(]+", ""):gsub("[%s%'\"`%;%)]+$", ""))
end

--- Python 解释器名（`python`/`python3`/`python3.13`/`py`）：`<interp> -m <module>` 的模块
--- 可能就是包管理器（`python3 -m pip install …`），需据此识别为包安装。
--- @param bin string
--- @return boolean
local function _is_python_interp(bin)
  if bin == "python" or bin == "py" then return true end
  return bin:match("^python%d") ~= nil
end

--- 从解释器 token 之后定位 `-m <module>` 的模块名（跳过其他短选项）。
--- @param toks table
--- @param k number 解释器 token 下标
--- @return number|nil module_idx
--- @return string|nil module
local function _python_module(toks, k)
  local j = k + 1
  while toks[j] and toks[j]:sub(1, 1) == "-" and toks[j] ~= "-m" do j = j + 1 end
  if toks[j] == "-m" then
    local mod = vim.fn.fnamemodify(_strip_token(toks[j + 1] or ""), ":t")
    if mod ~= "" then return j + 1, mod end
  end
  return nil, nil
end

--- 定位命令段中真正的包管理器可执行名：跳过 env 赋值、包装器/外壳（sudo/doas/bash -c/
--- for…do 等）与选项，命中配置的包管理器即返回。若首个「真实命令」不是包管理器则返回 nil
--- （避免把 `echo npm` 这类误判为包安装）。
--- @param seg string
--- @param managers table<string, boolean>
--- @return string|nil
local function _segment_package(seg, managers)
  local toks = {}
  for w in tostring(seg):gmatch("%S+") do toks[#toks + 1] = w end
  for k, raw in ipairs(toks) do
    if not raw:match("^[%w_]+=") then
      local w = _strip_token(raw)
      if w ~= "" and w:sub(1, 1) ~= "-" then
        local bin = vim.fn.fnamemodify(w, ":t")
        if managers[bin] then return bin end
        -- `python3 -m pip install …`：模块即包管理器。
        if _is_python_interp(bin) then
          local _, mod = _python_module(toks, k)
          if mod and managers[mod] then return mod end
          return nil
        end
        if not SKIP_PREFIX[w] and not WRAPPER_BINS[w] then return nil end
      end
    end
  end
  return nil
end

-- ========== 私有函数 ==========

local function _cfg()
  return config_store.get("tools.sandbox.privilege") or {}
end

local function _docker_cfg()
  return config_store.get("tools.sandbox.docker") or {}
end

--- 切分前归一化 shell 重定向语法（仅用于分类，不影响真实执行）：
--- `2>&1`/`>&2` 的 `&`、`&> file` 的 `&`、`|&` 管道都是重定向符号而非命令分隔符，
--- 不归一化会把 `apt update 2>&1` 撕成两段、误判为「非纯包安装」而不授予能力。
--- @param command string
--- @return string
local function _normalize_redirects(command)
  return (tostring(command):gsub(">&", ">"):gsub("&>", ">"):gsub("|&", "|"))
end

--- 判断某段是否为包安装的良性伴随段（首个真实命令是 tee 等）
--- @param seg string
--- @return boolean
local function _is_package_companion(seg)
  for raw in tostring(seg):gmatch("%S+") do
    if not raw:match("^[%w_]+=") then
      local w = _strip_token(raw)
      if w ~= "" and w:sub(1, 1) ~= "-" then
        return PKG_COMPANIONS[vim.fn.fnamemodify(w, ":t")] == true
      end
    end
  end
  return false
end

--- 按分隔符切分复合命令（`;` `|` `&&` `||` 换行）
--- @param command string
--- @return table 数组
local function _segments(command)
  local out = {}
  for seg in _normalize_redirects(command):gmatch("[^;|&\n]+") do
    local t = seg:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

--- @param value string
--- @param list table
--- @return boolean
local function _in(value, list)
  for _, v in ipairs(list or {}) do if v == value then return true end end
  return false
end

--- 对单个命令段分类，返回最高匹配档位与规则名
--- @param seg string
--- @param rules table
--- @return number|nil tier
--- @return string|nil name
local function _classify_segment(seg, rules)
  local toks = {}
  for w in seg:gmatch("%S+") do toks[#toks + 1] = w end
  local i = 1
  while i <= #toks and toks[i]:match("^[%w_]+=") do i = i + 1 end
  while i <= #toks and SKIP_PREFIX[toks[i]] do i = i + 1 end
  local raw = toks[i]
  if not raw then return nil, nil end
  local bin = vim.fn.fnamemodify(raw, ":t")
  local sub = toks[i + 1]
  -- 只读列举的 `mount`（无位置参数、无变更型选项）不算特权操作。
  if bin == "mount" and not _mount_mutates(toks, i + 1) then
    return nil, nil
  end
  local best, name
  for _, rule in ipairs(rules or {}) do
    local hit = false
    if rule.bins then
      hit = _in(bin, rule.bins)
    elseif rule.bin and bin == rule.bin then
      hit = (not rule.subs) or _in(sub or "", rule.subs)
    end
    if hit then
      if not best or (rule.tier or 0) > best then best, name = rule.tier or 0, rule.name end
    end
  end
  return best, name
end

--- 合并档位配置（配置值优先，缺省用内置默认）
--- @param tier number
--- @return table
local function _tier_cfg(tier)
  local cfg = _cfg()
  local tiers = cfg.tiers or {}
  local t = tiers[tier] or tiers[tostring(tier)] or {}
  local d = TIER_DEFAULTS[tier] or TIER_DEFAULTS[0]
  local out = {}
  for k, v in pairs(d) do out[k] = vim.deepcopy(v) end
  for k, v in pairs(t) do out[k] = vim.deepcopy(v) end
  return out
end

--- 解析 docker 档位应挂载的 socket（受控优先，宿主仅 T2）
--- @param tier number
--- @param want_docker boolean
--- @return table|nil mount
--- @return string|nil err
--- @return string|nil docker_host
local function _docker_mount(tier, want_docker)
  if not want_docker then return nil, nil, nil end
  local d = _docker_cfg()
  local mode = d.mode or "controlled"
  if mode == "off" then
    return nil, "DOCKER_DISABLED", nil
  end
  if mode == "host" then
    if tier < M.TIER.PRIVILEGED then
      return nil, "DOCKER_HOST_REQUIRES_TIER2", nil
    end
    return { src = "/var/run/docker.sock", dst = "/var/run/docker.sock", mode = "rw" }, nil,
      "unix:///var/run/docker.sock"
  end
  -- controlled：指向外部受控 socket（rootless / socket-proxy / dind）
  local sock = d.socket
  if type(sock) ~= "string" or sock == "" then
    return nil, "DOCKER_SOCKET_NOT_CONFIGURED", nil
  end
  if vim.uv.fs_stat(sock) == nil then
    return nil, "DOCKER_SOCKET_UNAVAILABLE: " .. sock, nil
  end
  return { src = sock, dst = "/var/run/docker.sock", mode = "rw" }, nil,
    "unix:///var/run/docker.sock"
end

-- ========== 公开 API ==========

-- 包安装子命令（用于跳过子命令本身，提取真正的包名）
local PKG_INSTALL_SUBS = {
  install = true, i = true, ci = true, add = true, update = true, upgrade = true,
  download = true, get = true, require = true, publish = true,
}

--- 提取包安装命令的包管理器与包名（用于「按安装命令」合并审批与界面标注）。
--- 例：`npm install express` -> { manager="npm", packages={"express"}, key="npm:express" }；
--- `pip install requests flask` -> key="pip:requests,flask"；无显式包名（如 `npm ci`）-> key="npm:*"。
--- @param command string|nil
--- @return table|nil { manager, packages, key, command }
function M.package_info(command)
  if type(command) ~= "string" or command == "" then return nil end
  local cfg = _cfg()
  local managers = (config_store.get("tools.sandbox.packages") or {}).managers
  local manager_set = {}
  if type(managers) == "table" then
    for _, m in ipairs(managers) do if type(m) == "string" then manager_set[m] = true end end
  end
  local rules = cfg.classify or {}
  local function is_pkg_bin(bin, sub)
    if manager_set[bin] then return true end
    for _, rule in ipairs(rules) do
      if rule.name == "package" then
        if rule.bins and _in(bin, rule.bins) then return true end
        if rule.bin and bin == rule.bin and ((not rule.subs) or _in(sub or "", rule.subs)) then return true end
      end
    end
    return false
  end
  for _, seg in ipairs(_segments(command)) do
    local toks = {}
    for w in seg:gmatch("%S+") do toks[#toks + 1] = w end
    -- 定位真正的包管理器 token：跳过 env 赋值、包装器/外壳（sudo/doas/bash -c/for…do 等）
    -- 与选项；首个「真实命令」不是包管理器则跳过该段。
    local i = nil
    for k, raw in ipairs(toks) do
      if not raw:match("^[%w_]+=") then
        local w = _strip_token(raw)
        if w ~= "" and w:sub(1, 1) ~= "-" then
          local bin = vim.fn.fnamemodify(w, ":t")
          if is_pkg_bin(bin, _strip_token(toks[k + 1] or "")) then
            i = k
            break
          end
          -- `python3 -m pip install …`：模块即包管理器。
          if _is_python_interp(bin) then
            local mi, mod = _python_module(toks, k)
            if mi and is_pkg_bin(mod, _strip_token(toks[mi + 1] or "")) then
              i = mi
            end
            break
          end
          if not SKIP_PREFIX[w] and not WRAPPER_BINS[w] then break end
        end
      end
    end
    if i then
      local bin = vim.fn.fnamemodify(_strip_token(toks[i]), ":t")
      local sub = _strip_token(toks[i + 1] or "")
      local packages = {}
      local j = i + 1
      if sub and PKG_INSTALL_SUBS[sub] then j = i + 2 end
      while j <= #toks do
        local w = _strip_token(toks[j])
        if w ~= "" and w:sub(1, 1) ~= "-" and not w:find("[><=&|;]") then packages[#packages + 1] = w end
        j = j + 1
      end
      local key = bin .. ":" .. (#packages > 0 and table.concat(packages, ",") or "*")
      return { manager = bin, packages = packages, key = key, command = command }
    end
  end
  return nil
end

-- 包安装中会改动「第三方软件源 / 密钥」的片段：命中则视为敏感安装，不自动放行。
-- 放宽后的包安装仅需保证不引入/篡改第三方软件源、不改动 GPG/信任密钥（见 docs/sandbox.md §15）。
local PACKAGE_SENSITIVE_PATS = {
  -- 第三方软件源
  "add%-apt%-repository", "apt%-add%-repository",
  "sources%.list", "sources%.list%.d", "/etc/apt/",
  "dnf%s+config%-manager", "yum%-config%-manager", "%-%-add%-repo", "addrepo",
  "zypper%s+ar%f[%A]", "zypper%s+addrepo",
  "pip%s+config%s+set", "%-%-index%-url", "%-%-extra%-index%-url",
  "npm%s+config%s+set", "npm%s+set%s+registry", "%-%-registry",
  "gem%s+sources", "composer%s+config%s+repositories",
  "go%s+env%s+%-w%s+goproxy", "goproxy=", "goprivate=",
  "brew%s+tap",
  -- 密钥 / 信任链
  "apt%-key", "trusted%.gpg", "keyring",
  "rpm%s+%-%-import", "pacman%-key",
  "gpg%s+%-%-import", "gpg%s+%-%-recv%-keys", "%-%-import",
}

--- 包安装命令是否改动第三方软件源或密钥/信任链（敏感安装，需人工确认）。
--- 普通安装（apt/pip/npm install …）不命中，可自动放行。
--- @param command string|nil
--- @return boolean
function M.package_sensitive(command)
  if type(command) ~= "string" or command == "" then return false end
  local s = command:lower()
  for _, pat in ipairs(PACKAGE_SENSITIVE_PATS) do
    if s:find(pat) then return true end
  end
  return false
end

--- 判断某路径是否属于包管理器的状态/安装目录（子串特征匹配）。
--- 命中即视为「由包管理器修改」——风险封顶 L2（不因工作区外/高熵误报升到 L3）。
--- @param path string|nil
--- @return string|nil manager 命中的管理器名
function M.package_path_manager(path)
  if type(path) ~= "string" or path == "" then return nil end
  for _, rule in ipairs(PACKAGE_PATH_SIGNS) do
    for _, sub in ipairs(rule.subs) do
      if path:find(sub, 1, true) then return rule.manager end
    end
  end
  return nil
end

--- 分类命令所需权限档位
--- `package`：任一命令段命中包管理器（用于风险封顶、审批合并、可写根，以及按需授予
--- `packages.cap_add` 窄能力——链式命令如 `apt-get install …; echo; tail` 也需这些能力）。
--- `package_all`：**所有**段都是包管理器（或 tee 等良性伴随段）；仅作统计/展示标记。
--- @param tool string|nil
--- @param args table|nil
--- @param spec table|nil { effect }
--- @param opts table|nil { effective_command?=string } 折叠脚本间接执行后的命令文本
--- @return table { tier, reasons, docker, container, network, package, package_all, sysadmin, apt }
function M.classify(tool, args, spec, opts)
  local cfg = _cfg()
  if cfg.enabled == false then
    return { tier = M.TIER.MINIMAL, reasons = { "PRIVILEGE_DISABLED" }, docker = false, container = false, network = false, package = false, package_all = false, sysadmin = false, apt = false }
  end
  if not spec or spec.effect ~= "process" then
    return { tier = M.TIER.MINIMAL, reasons = { "NON_PROCESS_EFFECT" }, docker = false, container = false, network = false, package = false, package_all = false, sysadmin = false, apt = false }
  end
  local command = tostring((args and (args.command or args.cmd)) or "")
  -- 脚本间接执行：用折叠后的 effective 文本做档位/包识别，使 `bash deploy.sh` 内的
  -- `pip install`、`sudo mount` 等也能被正确分类（见 sandbox/script_scan）。
  if opts and type(opts.effective_command) == "string" and opts.effective_command ~= "" then
    command = opts.effective_command
  end
  if command == "" then
    return { tier = M.TIER.MINIMAL, reasons = { "NO_COMMAND" }, docker = false, container = false, network = false, package = false, package_all = false, sysadmin = false, apt = false }
  end
  local rules = cfg.classify or {}
  local managers = _package_managers()
  local tier, reasons = M.TIER.MINIMAL, {}
  local docker, container, network, package, sysadmin = false, false, false, false, false
  local apt = false
  local has_pkg, all_pkg = false, true
  for _, seg in ipairs(_segments(command)) do
    local t, name = _classify_segment(seg, rules)
    if t then
      if t > tier then tier = t end
      reasons[#reasons + 1] = name or ("TIER_" .. tostring(t))
      if name == "docker" then docker = true end
      if name == "container" then container = true; network = true end
      if name == "network" then network = true end
      if name == "package" then package = true; network = true end
      -- 系统管理命令（useradd/chown/passwd 等）：按需加回窄能力并解除账户库遮蔽。
      if name == "sysadmin" then sysadmin = true end
    end
    -- 包管理器名单（apt/pip/npm/npx/uv/conda/cargo 等）统一识别为包安装（T1 + 网络）。
    -- 跳过 sudo/doas/env/bash -c/for…do 等包装器，避免漏判导致风险误升到 L3。
    local bin = _segment_package(seg, managers)
    if bin then
      has_pkg = true
      package = true
      network = true
      -- apt 系列：需关闭 apt 自身的 `_apt` 降权（见 resolve / packages.apt_sandbox_user）。
      if bin == "apt" or bin == "apt-get" or bin == "aptitude" then apt = true end
      if tier < M.TIER.ELEVATED then tier = M.TIER.ELEVATED end
      reasons[#reasons + 1] = "package"
    elseif not _is_package_companion(seg) then
      -- 非包管理器、非良性伴随段的命令段（cat/curl/任意可执行）存在 → 不授予窄能力。
      all_pkg = false
    end
  end
  return {
    tier = tier, reasons = reasons, docker = docker, container = container,
    network = network, package = package, package_all = has_pkg and all_pkg,
    sysadmin = sysadmin, apt = apt,
  }
end

--- 解析档位对应的具体隔离参数
--- @param tier number
--- @param req table|nil classify() 返回（含 docker/network）
--- @return table { ok, privileges?, reason? }
function M.resolve(tier, req)
  local cfg = _cfg()
  if cfg.enabled == false then
    return { ok = false, reason = "PRIVILEGE_DISABLED" }
  end
  local max_tier = cfg.max_tier or 0
  if tier > max_tier then
    return { ok = false, reason = "PRIVILEGE_TIER_EXCEEDS_MAX: " .. tostring(tier) .. " > " .. tostring(max_tier) }
  end
  local t = _tier_cfg(tier)
  local priv = {
    tier = tier,
    name = t.name,
    review = t.review or "auto",
    network = t.network ~= false,
    cap_add = vim.deepcopy(t.cap_add or {}),
    mounts = vim.deepcopy(t.mounts or {}),
    unmask = vim.deepcopy(t.unmask or {}),
    userns = t.userns == true,
    env = {},
  }
  if req and req.docker then
    local mount, err, host = _docker_mount(tier, true)
    if err then return { ok = false, reason = err } end
    if mount then priv.mounts[#priv.mounts + 1] = mount end
    if host then priv.env.DOCKER_HOST = host end
    -- docker socket 的 rw bind 挂在遮蔽之前，需解除遮蔽才不被空 tmpfs 覆盖。
    -- 仅 docker 命令（req.docker）解除，不随 T1 档位连带放行（如 pip install）。
    for _, sock in ipairs({ "/run/docker.sock", "/var/run/docker.sock" }) do
      if not vim.tbl_contains(priv.unmask, sock) then priv.unmask[#priv.unmask + 1] = sock end
    end
  end
  -- 包安装（受控启动）：dpkg/apt/pip/npm 需要 root 能力（--cap-drop ALL 下 root 失去
  -- DAC_OVERRIDE，连 `_apt` 拥有的 0700 目录都不可写；apt 还需 CAP_CHOWN/SETUID/SETGID 才能
  -- chown/setuid 到 `_apt`）。只要命令**含包管理器**（req.package）即按 packages.cap_add
  -- 加回窄能力：原先仅限「整条命令都是包管理器」（package_all），会把 `apt-get install …;
  -- echo; tail`、`apt update | tee log` 这类常见链式命令误判为混合命令而不授予，导致安装失败。
  -- 写入仍全部进 overlay 暂存，敏感路径由遮蔽挂载保护，故混合命令继承窄能力不扩大宿主面。
  if req and req.package then
    local pcaps = (config_store.get("tools.sandbox.packages") or {}).cap_add
    if type(pcaps) == "table" then
      for _, c in ipairs(pcaps) do
        if type(c) == "string" and c ~= "" then priv.cap_add[#priv.cap_add + 1] = c end
      end
    end
  end
  -- apt 系列：apt 在 root 下默认把下载/校验降权到 `_apt` 用户（setgroups + setuid/setgid）。
  -- 嵌套 user namespace / 受限容器中 setgroups 返回 EPERM，导致 `apt-get update`/`install`
  -- 直接失败（`setgroups failed - Operation not permitted`）。沙箱已由命名空间 + overlay 暂存
  -- 隔离，载荷本就以 root 运行，故默认注入 apt 配置关闭该降权（`APT::Sandbox::User "<value>"`，
  -- 默认 `"root"`；配置为 `"_apt"` 或空串则保留 apt 默认行为）。配置片段由 runtime 以只读
  -- 绑定挂载并以 APT_CONFIG 指向，写入仍全部进 overlay 暂存。
  if req and req.apt then
    local asu = (config_store.get("tools.sandbox.packages") or {}).apt_sandbox_user
    if type(asu) == "string" and asu ~= "" and asu ~= "_apt" then
      priv.apt_sandbox_user = asu
    end
  end
  -- 系统管理命令（useradd/usermod/groupadd/chown/passwd 等）：默认最小权限下这些命令会因
  -- 缺少 CHOWN/SETUID/SETGID/DAC_OVERRIDE 而失败（如 useradd 无法锁 /etc/passwd、打不开
  -- /etc/gshadow），且账户数据库被遮蔽。命中即按 privilege.sysadmin 加回窄能力并解除对应
  -- 遮蔽；写入仍全部进 overlay 暂存，真实账户库不受影响（与 packages.cap_add 同一思路）。
  if req and req.sysadmin then
    local scfg = cfg.sysadmin or {}
    if type(scfg.cap_add) == "table" then
      for _, c in ipairs(scfg.cap_add) do
        if type(c) == "string" and c ~= "" then priv.cap_add[#priv.cap_add + 1] = c end
      end
    end
    if type(scfg.unmask) == "table" then
      for _, p in ipairs(scfg.unmask) do
        if type(p) == "string" and p ~= "" and not vim.tbl_contains(priv.unmask, p) then
          priv.unmask[#priv.unmask + 1] = p
        end
      end
    end
  end
  -- PEP 668：Debian/Ubuntu 的 `EXTERNALLY-MANAGED` 会拒绝向系统 Python 安装包。沙箱内
  -- 允许突破——所有写入仍进 overlay 暂存并冻结为候选，绝不落宿主。仅对包安装命令注入。
  if req and req.package then
    priv.env.PIP_BREAK_SYSTEM_PACKAGES = "1"
    priv.env.PIP_ROOT_USER_ACTION = "ignore"
  end
  return { ok = true, privileges = priv }
end

--- 档位对应的审查严格度
--- @param tier number
--- @return string "auto" | "confirm" | "approve"
function M.review_mode(tier)
  return _tier_cfg(tier).review or "auto"
end

--- 档位对应的信封 severity
--- @param tier number
--- @return string
function M.severity(tier)
  if tier >= M.TIER.PRIVILEGED then return "CRITICAL" end
  if tier >= M.TIER.ELEVATED then return "HIGH" end
  return "LOW"
end

--- 依据失败输出建议升级档位（仅建议，不执行）
--- @param result table|nil { code, stdout, stderr }
--- @return table|nil { tier, reason }
function M.detect_escalation(result)
  if type(result) ~= "table" then return nil end
  if result.code == 0 or result.code == nil then return nil end
  local text = (tostring(result.stderr or "") .. "\n" .. tostring(result.stdout or "")):lower()
  local best = nil
  for _, rule in ipairs(ESCALATION_PATTERNS) do
    for _, p in ipairs(rule.pats) do
      if text:find(p, 1, true) then
        if not best or rule.tier > best.tier then best = { tier = rule.tier, reason = rule.reason } end
        break
      end
    end
  end
  return best
end

--- 留痕：一次权限档位裁决/升级（证据 + 事件）
--- @param meta table { tool?, command?, command_id?, attempt_id?, from_tier?, to_tier?, reasons?, reason? }
function M.record(meta)
  meta = meta or {}
  if _cfg().record == false then return end
  pcall(function()
    require("NeoAI.sandbox.evidence").add("privilege", {
      tool = meta.tool, command = meta.command,
      from_tier = meta.from_tier, to_tier = meta.to_tier,
      reasons = meta.reasons or (meta.reason and { meta.reason } or {}),
      source = "observed", coverage = "full",
    }, { tool = meta.tool, command_id = meta.command_id, attempt_id = meta.attempt_id })
  end)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").SANDBOX_PRIVILEGE_RECORDED, {
        tool = meta.tool, from_tier = meta.from_tier, to_tier = meta.to_tier,
        reasons = meta.reasons, reason = meta.reason, command_id = meta.command_id,
      })
  end)
end

--- 重置（测试用）
function M.reset()
  -- 无模块级状态
end

M._segments = _segments
M._classify_segment = _classify_segment

return M
