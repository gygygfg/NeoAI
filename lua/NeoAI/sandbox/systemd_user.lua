--- 嵌套 systemd --user（沙箱内真实用户级 systemd）
--- @module NeoAI.sandbox.systemd_user
--- 在会话级常驻沙箱实例内运行一个**真实的 systemd 用户实例**（`systemd --user`）：
---   * `/run/systemd/system` 标记满足 `sd_booted()`（否则 systemd --user 直接退出）；
---   * 私有 `XDG_RUNTIME_DIR`（`/run/neoai-user`，mode 0700）与私有会话 dbus；
---   * `/sys/fs/cgroup` 绑定为**委派的会话 cgroup 子树**（可写），使 user manager 只能在本
---     子树内创建/移动 cgroup，不污染宿主其它 cgroup；
---   * 单元文件位于工作区 overlay（`$HOME/.config/systemd/user`），写入被冻结为候选。
--- 因此 AI 的 `systemctl --user ...` 命中**真实** systemd 语义，且所有修改都不落到宿主机。
---
--- 引导在常驻实例的**命令服务器**进入读取循环前执行（幂等），确保首条 systemctl 命令前
--- user manager 已就绪。配置：`tools.sandbox.systemd.user = { enabled }`（默认关闭）。

local config_store = require("NeoAI.kernel.config_store")
local runtime = require("NeoAI.sandbox.runtime")

local M = {}

local RUNTIME_DIR = "/run/neoai-user"

--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.systemd") or {}
end

--- @return string|nil
local function _systemd_bin()
  if vim.uv.fs_stat("/usr/lib/systemd/systemd") then return "/usr/lib/systemd/systemd" end
  local p = vim.fn.exepath("systemd")
  if p ~= "" then return p end
  return nil
end

--- 是否启用且环境可用。
--- @return boolean
--- @return string|nil reason
function M.available()
  local cfg = _cfg()
  local ucfg = cfg.user or {}
  if cfg.enabled == false then return false, "SYSTEMD_DISABLED" end
  if ucfg.enabled ~= true then return false, "SYSTEMD_USER_DISABLED" end
  if runtime.backend() ~= "bwrap" then return false, "SYSTEMD_USER_REQUIRES_BWRAP" end
  if vim.fn.executable("dbus-daemon") ~= 1 then return false, "SYSTEMD_USER_REQUIRES_DBUS" end
  if not _systemd_bin() then return false, "SYSTEMD_USER_REQUIRES_SYSTEMD" end
  return true
end

--- 沙箱内私有 XDG_RUNTIME_DIR。
--- @return string
function M.runtime_dir()
  return RUNTIME_DIR
end

--- 服务器引导片段（幂等）：建立 sd_booted 标记、私有 runtime 目录、会话 dbus 与
--- systemd --user，并等待 user manager 就绪。在命令服务器进入读取循环前执行。
--- 注意：不使用 `pgrep -f`（服务器自身命令行含相同文本会自匹配而跳过启动）；服务器脚本
--- 每次启动只运行一次，直接启动即可。
--- @return string
function M.boot_snippet()
  local sdbin = _systemd_bin() or "/usr/lib/systemd/systemd"
  return table.concat({
    "__rt=" .. RUNTIME_DIR,
    "mkdir -p /run/systemd/system \"$__rt\" \"$HOME/.config/systemd/user\" 2>/dev/null",
    "chown \"$(id -u)\":\"$(id -g)\" \"$__rt\" 2>/dev/null",
    "chmod 700 \"$__rt\" 2>/dev/null",
    "export XDG_RUNTIME_DIR=\"$__rt\"",
    "export DBUS_SESSION_BUS_ADDRESS=\"unix:path=$__rt/bus\"",
    "/usr/bin/dbus-daemon --session --address=\"$DBUS_SESSION_BUS_ADDRESS\" --nofork --nopidfile >/tmp/.neoai_dbus.log 2>&1 &",
    sdbin .. " --user >/tmp/.neoai_systemd.log 2>&1 &",
    "for __i in $(seq 1 60); do [ -S \"$__rt/systemd/private\" ] && break; sleep 0.25; done",
  }, "\n")
end

return M
