--- NeoAI 健康检查与诊断
--- @module 'NeoAI.health'
--- 提供两处入口：
---   1. `:checkhealth NeoAI`（Neovim 自动发现 `lua/NeoAI/health.lua` 并调用 `M.check()`）；
---   2. `:NeoAIDoctor`（把同一份结果以 `vim.notify` 汇总输出，便于随手排查）。
--- 覆盖：Neovim 版本、curl、libuv 线程池、API key / 默认 provider、沙箱内核能力、可选依赖、插件状态。
--- 纯只读探测，不产生副作用。

local M = {}

-- ========== 私有函数 ==========

--- 依版本要求判定状态
--- @param current { major: number, minor: number }
--- @param need { major: number, minor: number }
--- @return boolean
local function _ge(current, need)
  if current.major ~= need.major then return current.major > need.major end
  return current.minor >= need.minor
end

--- 解析 "0.10.0" → { major, minor }
--- @param s string
--- @return table
local function _parse_ver(s)
  local major, minor = tostring(s):match("^(%d+)%.(%d+)")
  return { major = tonumber(major) or 0, minor = tonumber(minor) or 0 }
end

--- 取得 Neovim 版本字符串（兼容 vim.version 不可用的构建）。
--- @return string
local function _version_string()
  local ok, v = pcall(function() return vim.version() end)
  if ok and v then
    return tostring(v.version or (v.major .. "." .. v.minor .. "." .. (v.patch or 0)))
  end
  local out = vim.fn.execute("version")
  return out:match("NVIM v([%d%.]+)") or "unknown"
end

--- 收集检查项（结构化）
--- @return table 数组 { name, status: "ok"|"warn"|"error", info: string[] }
function M.collect()
  local out = {}
  local function add(name, status, info)
    out[#out + 1] = { name = name, status = status, info = info or {} }
  end

  -- Neovim 版本
  local cur = _parse_ver(_version_string())
  local need = { major = 0, minor = 10 }
  if _ge(cur, need) then
    add("Neovim 版本", "ok", { ("%s（要求 >= 0.10）"):format(_version_string()) })
  else
    add("Neovim 版本", "error", {
      ("%s 低于最低要求 0.10；NeoAI 依赖 vim.uv 多线程 API。"):format(_version_string()),
    })
  end
  if vim.fn.has("nvim-0.13") ~= 1 then
    add("autoread（可选）", "warn", { "Neovim < 0.13：外部改动文件不自动重载，内置工具写盘需手动 :edit。" })
  end

  -- curl（HTTP 传输依赖：唯一传输后端，无内置回退，见 utils/http.lua）
  if vim.fn.executable("curl") == 1 then
    add("curl", "ok", { "已找到 curl（所有模型请求经 curl 发送）。" })
  else
    add("curl", "error", {
      "未找到 curl：NeoAI 的 HTTP 请求无内置回退，无法发送任何模型请求。",
      "安装：Debian/Ubuntu `sudo apt install -y curl`｜Fedora `sudo dnf install -y curl`｜"
        .. "Arch `sudo pacman -S curl`｜Alpine `sudo apk add curl`｜Termux `pkg install curl`。",
    })
  end

  -- libuv 线程池（CPU/IO 卸载）
  local ok_work, work = pcall(require, "NeoAI.utils.work")
  if ok_work and work.available() then
    add("多线程（vim.uv.new_work）", "ok", { ("可用；并行度=%s"):format(tostring(work.parallelism and work.parallelism() or "?")) })
  else
    add("多线程（vim.uv.new_work）", "error", { "不可用；NeoAI 需要 Neovim 0.10+ 的 vim.uv.new_work。" })
  end

  -- API key / 默认 provider
  local config_store = require("NeoAI.kernel.config_store")
  local ai = config_store.get("ai") or {}
  local providers = ai.providers or {}
  local with_key = {}
  for pname, pc in pairs(providers) do
    local key = type(pc) == "table" and (pc.api_key or "") or ""
    if type(key) == "string" and key ~= "" then with_key[#with_key + 1] = pname end
  end
  table.sort(with_key)
  local default_provider = ai.default_provider
  local dp = providers[default_provider]
  local dp_key = type(dp) == "table" and (dp.api_key or "") or ""
  if #with_key == 0 then
    add("API Key", "error", {
      "未检测到任何已配置 api_key 的提供商。",
      "请设置环境变量（如 DEEPSEEK_API_KEY / OPENAI_API_KEY）或在 setup 中配置 ai.providers.*.api_key。",
    })
  elseif type(dp_key) ~= "string" or dp_key == "" then
    add("API Key", "warn", {
      ("默认提供商 '%s' 未配置 key，但以下提供商可用: %s"):format(tostring(default_provider), table.concat(with_key, ", ")),
      "可设置 ai.default_provider 指向已配置 key 的提供商。",
    })
  else
    add("API Key", "ok", {
      ("默认提供商 '%s' 已配置 key；可用提供商: %s"):format(tostring(default_provider), table.concat(with_key, ", ")),
    })
  end

  -- 沙箱内核能力（可选；缺失时沙箱禁用并退回审批模式）
  -- 判定与 runtime.backend()/isolation_available() 同源：**功能实测**（bwrap 真实启动、
  -- unshare 真实建非特权 userns），不因「装了二进制」或「装了 docker」而误报可用。
  do
    local ok_runtime, runtime = pcall(require, "NeoAI.sandbox.execution.runtime")
    local ok_deps, deps = pcall(require, "NeoAI.sandbox.execution.deps")
    local report
    if ok_runtime and ok_deps and type(runtime) == "table" and type(deps) == "table"
      and type(runtime.capabilities) == "function" then
      local ok_caps, caps = pcall(runtime.capabilities)
      if ok_caps and type(caps) == "table" then
        local ok_backend, backend = pcall(runtime.backend)
        local ok_report, built = pcall(deps.backend_report, {
          backend = (ok_backend and type(backend) == "string") and backend or nil,
          bwrap = caps.bwrap, unshare = caps.unshare, userns = caps.userns,
          overlayfs = caps.overlayfs, seccomp = caps.seccomp, cgroup2 = caps.cgroup2,
          setpriv = vim.fn.executable("setpriv") == 1,
          docker = vim.fn.executable("docker") == 1,
          podman = vim.fn.executable("podman") == 1,
        })
        if ok_report and type(built) == "table" and type(built.lines) == "table" then
          report = built
        end
      end
    end
    if report then
      local info = {}
      for _, line in ipairs(report.lines) do info[#info + 1] = line end
      info[#info + 1] = "详见 :NeoAISandboxCaps / docs/sandbox.md。"
      add("沙箱内核能力", report.status, info)
    else
      -- 探测不可用（极少数裁剪环境）：退回二进制检查，保证 :checkhealth 不报错，
      -- 且「只装了 unshare」仍判 warn（无法确认非特权 userns 是否可用）。
      local function has(bin) return vim.fn.executable(bin) == 1 end
      local found = {}
      for _, bin in ipairs({ "bwrap", "unshare" }) do
        if has(bin) then found[#found + 1] = bin end
      end
      local lines = {}
      if #found > 0 then
        lines[#lines + 1] = "已找到：" .. table.concat(found, ", ")
          .. "（沙箱能力探测不可用，未能确认 bwrap / 非特权 userns 是否真可隔离）"
      else
        lines[#lines + 1] = "未找到 bwrap（bubblewrap 包）与 unshare（util-linux 包）："
          .. "无命名空间隔离后端，将禁用沙箱并退回审批模式"
          .. "（命令经事前审批后直接在宿主执行，写入直接落盘、不冻结待审候选）。"
      end
      lines[#lines + 1] = "详见 :NeoAISandboxCaps / docs/sandbox.md。"
      add("沙箱内核能力", has("bwrap") and "ok" or "warn", lines)
    end
  end

  -- 沙箱网络同意（诊断「网络请求不弹窗 / 审批悬浮窗无条目」）
  do
    local ok_nc, nc = pcall(require, "NeoAI.sandbox.net.net_consent")
    local ok_hp, hp = pcall(require, "NeoAI.sandbox.net.host_proxy")
    local ok_gw, gw = pcall(require, "NeoAI.sandbox.net.net_gateway")
    local netcfg = config_store.get("tools.sandbox.network") or {}
    local sandbox_cfg = config_store.get("tools.sandbox") or {}
    local offline = sandbox_cfg.offline == true
    local gateway_on = ok_gw and gw.enabled() == true
    local hlb = netcfg.host_local_block ~= false
    local proxy = ok_hp and hp.address() or nil
    local avail = ok_nc and nc.available() == true
    local can = ok_nc and nc.can_prompt() == true
    local lines = {
      ("策略 access=%s；host_local_block=%s；offline=%s；netns 网关=%s"):format(
        tostring(ok_nc and nc.policy() or "?"), tostring(hlb), tostring(offline), tostring(gateway_on)),
      proxy and ("宿主过滤代理已启动: %s:%s"):format(tostring(proxy.host), tostring(proxy.port))
        or (hlb and not offline and "宿主过滤代理未启动（沙箱外命令不经过同意门禁）" or "宿主过滤代理未启用"),
      ("网络同意 UI 可用=%s；可弹窗=%s"):format(tostring(avail), tostring(can)),
    }
    local status = "ok"
    if offline then
      lines[#lines + 1] = "offline=true：网络硬隔离，无需同意弹窗。"
    elseif hlb and not gateway_on and not proxy then
      status = "warn"
      lines[#lines + 1] = "宿主过滤代理未启动（可能绑定失败）：外部网络请求不会弹窗，将直连。"
    elseif hlb and not gateway_on and not avail then
      status = "warn"
      lines[#lines + 1] = "网络同意 UI 未注册（UI 未初始化？）：外部网络请求失败关闭且不弹窗。"
    elseif gateway_on then
      status = "warn"
      lines[#lines + 1] = "netns 网关模式不接入网络同意弹窗（仅端口探针）；如需逐目标同意请关闭 gateway。"
    elseif netcfg.host_local_block == false then
      status = "warn"
      lines[#lines + 1] = "host_local_block=false：沙箱外命令直连，无同意弹窗。"
    end
    add("沙箱网络同意", status, lines)
  end

  -- 可选依赖
  local opt = {}
  if vim.fn.executable("git") == 1 then opt[#opt + 1] = "git" end
  if vim.fn.executable("node") == 1 then opt[#opt + 1] = "node" end
  if vim.fn.executable("npm") == 1 then opt[#opt + 1] = "npm" end
  add("可选依赖", "ok", { #opt > 0 and ("已找到: " .. table.concat(opt, ", ")) or "未找到 git/node/npm（git 工具与 web_fetch 渲染将不可用）。" })

  -- 插件 / 服务状态
  local ok_plugins, plugins = pcall(require, "NeoAI.kernel.plugins")
  local ok_services, services = pcall(require, "NeoAI.kernel.services")
  if ok_plugins and ok_services then
    local provided = services.list and services.list() or {}
    add("插件状态", "ok", {
      ("已登记插件=%d；已提供服务=%d"):format(#(plugins.list and plugins.list() or {}), #provided),
      "启动详情见 :messages（NeoAI 日志）。",
    })
  end

  return out
end

--- 取得 health 报告器（vim.health 或全局 health；不可用时返回 nil）。
--- @return table|nil
local function _reporter()
  local ok, h = pcall(function() return vim.health end)
  if ok and h and h.start then return h end
  local ok2, h2 = pcall(require, "health")
  if ok2 and h2 and h2.start then return h2 end
  return nil
end

--- Neovim :checkhealth NeoAI 入口
function M.check()
  local health = _reporter()
  local all = M.collect()
  if not health then
    -- 构建缺失 health 模块（极少数裁剪版）：降级为 notify，避免 :checkhealth 直接报错。
    vim.notify(M.summary(), vim.log.levels.INFO, { title = "NeoAI" })
    return
  end
  health.start("NeoAI")
  for _, item in ipairs(all) do
    local fn = health.ok
    if item.status == "error" then fn = health.error
    elseif item.status == "warn" then fn = health.warn end
    fn(item.name)
    for _, line in ipairs(item.info) do
      health.info("  " .. line)
    end
  end
  health.info("")
  health.info("运行 :NeoAIDoctor 可取得同样的摘要（便于随手排查）。")
end

--- 汇总为一行行文本（供 :NeoAIDoctor 输出）
--- @return string
function M.summary()
  local icon = { ok = "✓", warn = "!", error = "✗" }
  local lines = { "NeoAI 诊断（:NeoAIDoctor）" }
  for _, item in ipairs(M.collect()) do
    local mark = icon[item.status] or "?"
    lines[#lines + 1] = ("[%s] %s"):format(mark, item.name)
    for _, l in ipairs(item.info) do
      lines[#lines + 1] = "    " .. l
    end
  end
  lines[#lines + 1] = "提示：:checkhealth NeoAI 提供同样的分节视图。"
  return table.concat(lines, "\n")
end

--- :NeoAIDoctor 命令入口：notify 汇总（有 error 用 ERROR 级，warn 用 WARN 级）。
function M.doctor()
  local items = M.collect()
  local worst = "ok"
  for _, it in ipairs(items) do
    if it.status == "error" then worst = "error" break end
    if it.status == "warn" then worst = "warn" end
  end
  local level = vim.log.levels.INFO
  if worst == "error" then level = vim.log.levels.ERROR
  elseif worst == "warn" then level = vim.log.levels.WARN end
  local lines = {}
  for _, l in ipairs(vim.split(M.summary(), "\n", { plain = true })) do
    lines[#lines + 1] = l
  end
  vim.notify(table.concat(lines, "\n"), level, { title = "NeoAI Doctor" })
end

--- 首次运行引导：当未配置任何 provider api_key 时，提示一次配置方法。
--- 以 state 目录标记位去重，避免每次启动重复打扰。可在 init.setup 内 vim.schedule 调用。
function M.first_run_hint()
  local config_store = require("NeoAI.kernel.config_store")
  local providers = config_store.get("ai.providers") or {}
  local has_key = false
  for _, pc in pairs(providers) do
    local k = type(pc) == "table" and (pc.api_key or "") or ""
    if type(k) == "string" and k ~= "" then has_key = true break end
  end
  if has_key then return end
  -- 去重：state 目录下的标记位
  local marker = (vim.fn.stdpath("state") or vim.fn.stdpath("cache")) .. "/neoai_onboarded"
  if vim.uv.fs_stat(marker) then return end
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(marker, ":h"), "p")
  pcall(function()
    local f = io.open(marker, "w")
    if f then f:write(os.date("%Y-%m-%d")) f:close() end
  end)
  vim.notify(
    "[NeoAI] 尚未配置任何 AI 提供商的 API Key，AI 功能不可用。\n"
      .. "请设置环境变量（如 DEEPSEEK_API_KEY / OPENAI_API_KEY）或在 setup 中配置 "
      .. "ai.providers.*.api_key，然后运行 :NeoAIDoctor 确认。",
    vim.log.levels.WARN, { title = "NeoAI 首次使用" })
end

return M
