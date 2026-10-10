--- 沙箱能力桥（core ↔ sandbox 解耦）
--- @module 'NeoAI.kernel.sandbox_bridge'
--- core 侧（如 Agent 上下文密钥泄漏处理、附件缩放）需要少量沙箱能力，但 core 不得直接依赖
--- sandbox、sandbox 也不得依赖 core。由组合根（plugins/catalog）在启动沙箱服务时把相关能力
--- 注入本桥；core 经本桥调用，双方仅依赖 kernel。
---
--- 未注入（沙箱被禁用/不可用）时各 getter 返回 nil，调用方按「沙箱不可用」降级。

local M = {}

local hooks = {}

--- 注入沙箱能力实现（由组合根设置；传 nil 清除）。
--- @param h table|nil {
---   secret_alert?: table,                -- sandbox.secret_alert 模块（available/request）
---   record_secret_flow?: function(event, meta),
---   exec?: table,                        -- sandbox.exec 模块（ensure_shared/run）
---   candidate_read_path?: function(path) -> string|nil,
--- }
function M.set(h)
  hooks = h or {}
end

--- 密钥告警模块（可用则返回，供 core 弹窗请求；否则 nil）。
--- @return table|nil
function M.secret_alert()
  return hooks.secret_alert
end

--- 记录一次密钥数据流事件（无实现时 no-op）。
--- @param event string
--- @param meta table
function M.record_secret_flow(event, meta)
  if hooks.record_secret_flow then
    pcall(hooks.record_secret_flow, event, meta)
  end
end

--- 沙箱进程执行模块（可用则返回，否则 nil）。
--- @return table|nil
function M.exec()
  return hooks.exec
end

--- 读取沙箱候选中的文件真实路径（无实现时原样返回 path）。
--- @param path string
--- @return string
function M.candidate_read_path(path)
  if hooks.candidate_read_path then
    return hooks.candidate_read_path(path) or path
  end
  return path
end

--- 复位（插件卸载/测试用）。
function M.reset()
  hooks = {}
end

return M
