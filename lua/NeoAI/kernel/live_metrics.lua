--- 实时指标桥（core ↔ ui 解耦）
--- @module 'NeoAI.kernel.live_metrics'
--- 存放**按引用**共享的运行态对象：
---   1) 工具的可暂停计时器（`set`/`get`/`clear`）；
---   2) 工具**已完成但尚未落库**的结果（`set_result`/`get_result`/`clear_result`）。
--- 事件总线经 `nvim_exec_autocmds` 传递 data 会深拷贝并丢失元表/方法，计时器的 `elapsed()`
--- 无法随事件传播；而 core（工具循环）与 ui（折叠渲染）都不得相互直接依赖。故以本 kernel 设施
--- 作为中立汇合点：core `set()`/`set_result()` 注入，ui `get()`/`get_result()` 读取；两者仅依赖 kernel。
---
--- 为何需要结果通道：并发工具调用的结果按「原始调用顺序」统一落库（保证 tool 消息顺序与
--- assistant.tool_calls 一致，API 兼容且前缀缓存确定），因此只要本轮有一个工具未完成，
--- 其余已完成工具的结果就进不了 messages，界面无法展示（表现为「一个慢工具拖住全部结果」）。
--- 这里让每个工具**完成即发布**自己的结果，UI 对尚未配对的结果消息用它渲染，落库后清除。
---
--- 生命周期由写入方（core，工具完成时）与读取方（ui，记录结束/清理时）共同 clear，避免泄漏。

local M = {}

local store = {}
local results = {}

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

--- 发布一个工具的运行期结果（已完成、尚未写入消息队列）。
--- @param key string tool_call_id
--- @param result table { content: string, duration_ms?: number, notice?: string, secret_paths?: table }
function M.set_result(key, result)
  if key == nil or type(result) ~= "table" then return end
  results[key] = result
end

--- 读取工具的运行期结果（不存在返回 nil）。
--- @param key string tool_call_id
--- @return table|nil { content, duration_ms?, notice?, secret_paths? }
function M.get_result(key)
  if key == nil then return nil end
  return results[key]
end

--- 清除单个运行期结果（结果已落库或会话结束时调用，幂等）。
--- @param key string
function M.clear_result(key)
  if key == nil then return end
  results[key] = nil
end

--- 清空全部实时指标（测试/会话清理用）。
function M.reset()
  store = {}
  results = {}
end

return M
