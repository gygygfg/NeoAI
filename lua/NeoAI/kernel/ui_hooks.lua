--- UI 钩子注册表（core/sandbox/ui ↔ tools 解耦）
--- @module NeoAI.kernel.ui_hooks
--- 中性汇合点：UI 组件把「展示实现」注册到本表，工具/业务从本表读取，双方仅依赖 kernel。
--- 解耦适用场景：UI 组件（ui/）不得直接 require 工具/业务模块（tools/），反之亦然。
--- 当前用例：向用户提问 UI（ui/components/ask_user 注册，tools/builtin/ask_user 读取）。

local M = {}

local hooks = {}

--- 注册一个 UI 钩子实现（幂等覆盖；传 nil 等价于清除）。
--- @param name string
--- @param impl table|nil
function M.set(name, impl)
  if name == nil then return end
  if impl == nil then
    hooks[name] = nil
  else
    hooks[name] = impl
  end
end

--- 读取 UI 钩子实现（不存在返回 nil）。
--- @param name string
--- @return table|nil
function M.get(name)
  if name == nil then return nil end
  return hooks[name]
end

--- 清除单个 UI 钩子（幂等）。
--- @param name string
function M.clear(name)
  if name == nil then return end
  hooks[name] = nil
end

--- 清空全部（测试/会话清理用）。
function M.reset()
  hooks = {}
end

return M
