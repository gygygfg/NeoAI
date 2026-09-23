--- 伪造的 systemd 用户解析器（沙箱内无真实 systemd/dbus）
--- @module NeoAI.sandbox.systemd_user
--- 沙箱环境是临时的：不启动真实 `systemd --user`（依赖 dbus、cgroup 委派与 `/run/systemd` 标记，
--- 在临时容器/评测环境中不稳定）。`systemctl --user` 改由门面（`sandbox/systemd.lua`）用
--- **伪造的解析器**处理：
---   * 从用户单元根（`~/.config/systemd/user`、`/etc/systemd/user`、`/usr/lib/systemd/user`、
---     `/run/systemd/user`，优先沙箱暂存副本）解析 `.service`；
---   * `start`/`stop`/`restart`/`is-active`/`status`/`show` 由沙箱服务状态合成（简单启动/停止）；
---   * `enable`/`disable` 的软链暂存到用户单元根（不落宿主机，进入待审）；
---   * `daemon-reload` 为无操作（门面每次重新读取单元文件）。
--- 本模块只报告「伪造用户 systemd 是否可用」，不再引导真实用户实例。
---
--- 兼容旧接口：`runtime_dir()`/`boot_snippet()` 保留但不再用于真实启动（`needs_boot()` 恒为 false）。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

M.fake = true

local RUNTIME_DIR = "/run/neoai-user"

--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.systemd") or {}
end

--- 伪造用户 systemd 是否可用：仅要求门面启用（不再要求 dbus/systemd 二进制/真实 user manager）。
--- @return boolean
--- @return string|nil reason
function M.available()
  local cfg = _cfg()
  if cfg.enabled == false then return false, "SYSTEMD_DISABLED" end
  if (cfg.user or {}).enabled == false then return false, "SYSTEMD_USER_DISABLED" end
  return true
end

--- 是否需要启动真实 systemd 用户实例并注入 dbus/XDG 环境。伪造实现恒为 false。
--- @return boolean
function M.needs_boot()
  return false
end

--- 沙箱内私有 XDG_RUNTIME_DIR（伪造实现不再使用，保留兼容）。
--- @return string
function M.runtime_dir()
  return RUNTIME_DIR
end

--- 服务器引导片段：伪造实现无需任何引导。
--- @return string
function M.boot_snippet()
  return ""
end

return M
