--- 密钥告警服务：AI 上下文/工具调用中出现**真实密钥**（疑似突破沙箱）或向非白名单地址
--- **发送密钥**时，阻塞式弹窗让用户确认；确认后继续，否则停止 Agent。headless 无 UI 时失败关闭。
--- @module NeoAI.sandbox.secret_alert
--- UI 通过 `set_ui({ show = fn })` 注册（见 ui/components/secret_alert）。`request` 返回 Deferred，
--- resolve 决策字符串：`allow_once`（保留真实密钥，仅本次允许）| `fake`（替换为假密钥并继续）|
--- `whitelist`（加入发送白名单）| `stop`。
--- 弹窗上下文 `ctx` 会携带来源命令/工具、命中的真实密钥、以及将使用的假密钥，供 UI 展示。

local M = {}

local state = {
  ui = nil,
}

--- 注册/注销 UI（ui 组件 init/reset 调用）
--- @param ui table|nil { show = function(ctx, decide) }
function M.set_ui(ui)
  state.ui = ui
end

--- 是否可用（有 UI 且未禁用）
--- @return boolean
function M.available()
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.secrets.alert")
  if type(cfg) == "table" and cfg.enabled == false then return false end
  return state.ui ~= nil and type(state.ui.show) == "function"
end

--- 阻塞式请求用户确认。
--- @param ctx table { kind, tool?, command?, agent?, secret?, secret_preview?, fake?, dest?, reason? }
--- @return Deferred resolve(decision)
function M.request(ctx)
  local async = require("NeoAI.utils.async")
  local d = async.Deferred.new()
  if not M.available() then
    -- headless / 无 UI：失败关闭
    d:resolve("stop")
    return d
  end
  local done = false
  local function decide(decision)
    if done then return end
    done = true
    if decision ~= "allow_once" and decision ~= "fake"
      and decision ~= "whitelist" and decision ~= "stop" then
      decision = "stop"
    end
    d:resolve(decision)
  end
  local ok, err = pcall(state.ui.show, ctx or {}, decide)
  if not ok then
    decide("stop")
  end
  return d
end

--- 重置（测试用）
function M.reset()
  state.ui = nil
end

return M
