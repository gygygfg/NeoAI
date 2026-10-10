--- 实时指标桥（core ↔ ui 解耦）
--- @module 'NeoAI.kernel.live_metrics'
--- 存放**按引用**共享的运行态对象（当前仅工具的可暂停计时器）。
--- 事件总线经 `nvim_exec_autocmds` 传递 data 会深拷贝并丢失元表/方法，计时器的 `elapsed()`
--- 无法随事件传播；而 core（工具循环）与 ui（折叠渲染）都不得相互直接依赖。故以本 kernel 设施
--- 作为中立汇合点：core `set()` 注入原对象，ui `get()` 读取实时值；两者仅依赖 kernel（方向合法）。
---
--- 生命周期由写入方（core，工具完成时）与读取方（ui，记录结束/清理时）共同 clear，避免泄漏。

local M = {}

local store = {}

--- 注入/更新一个实时指标对象（按引用）。
--- @param key string
--- @param obj any
function M.set(key, obj)
  if key == nil then return end
  store[key] = obj
end

--- 读取实时指标对象（不存在返回 nil）。
--- @param key string
--- @return any
function M.get(key)
  if key == nil then return nil end
  return store[key]
end

--- 清除单个实时指标（幂等）。
--- @param key string
function M.clear(key)
  if key == nil then return end
  store[key] = nil
end

--- 清空全部实时指标（测试/会话清理用）。
function M.reset()
  store = {}
end

return M
