--- 运行时请求弹窗统一广播
--- @module 'NeoAI.sandbox.review.consent'
--- 三类运行时审批请求——**白名单外网络请求**（`network`）、**危险命令访问**（`behavior`：危险设备
--- 访问 / 代理规避等）、**敏感隐私文件读取**（`resource`：命中遮蔽目录等资源访问审批）——统一经
--- **同一个事件** `SANDBOX_CONSENT_REQUESTED` 广播，由 `payload.page` 参数区分归属页；其余参数按
--- 类型附带（如网络请求的 host/port、危险命令的工具/命令/原因、资源访问的路径等）。
--- 审批分流中心（`approval_hub`）据此在对应页新建条目并刷新审批悬浮窗。

local M = {}

--- 广播一次运行时请求（同一事件、按 page 区分）。
--- @param page string "network" | "behavior" | "resource"
--- @param payload table|nil 类型相关参数（host/port/tool/command/devices/path/reason …）
function M.emit(page, payload)
  local p = vim.tbl_extend("force", { page = page, at = os.time() }, payload or {})
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").SANDBOX_CONSENT_REQUESTED, p)
  end)
end

return M
