--- NeoAI 协程上下文管理器
--- 职责：
---   1. 协程上下文：协程安全的闭包上下文隔离（session_id、tools 等）
---   2. 协程内全局共享表（shared）：协程内所有模块可直接读写
---   3. 事件触发辅助：封装 Neovim 原生 User 事件，提供一致的触发接口
---
--- 注意：状态切片功能已移除，各模块使用自己的闭包 state 表管理内部状态。
--- 配置数据通过 core/init.lua 的 get_config() 读取。
---
--- 使用方式：
---   local sm = require("NeoAI.core.config.state")
---
---   -- 协程内全局共享表（协程内多模块共享，无需注册，自动隔离）
---   local ctx = sm.create_context({ session_id = "sess_001" })
---   sm.with_context(ctx, function()
---     sm.set_shared("current_tool", "web_scout")
---     local tool = sm.get_shared_value("current_tool")
---     local shared = sm.get_shared()
---     shared.some_key = { nested = true }
---   end)

local M = {}

-- ========== 协程上下文 ==========
local _coroutine_contexts = {}

-- ========== 事件触发辅助 ==========

--- 触发 Neovim User 事件（封装 pcall 保护）
--- @param event_name string 事件名称
--- @param data table 事件数据
function M.fire_event(event_name, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_name,
    data = data or {},
  })
end

-- ========== 协程上下文 API ==========

--- 创建协程上下文
--- 在协程开始时调用，返回一个上下文对象
--- 每个协程自动拥有一个 _shared 共享表，协程内所有模块可直接读写
---
--- @param shared_data table|nil 初始共享数据
--- @return table context 上下文对象
function M.create_context(shared_data)
  local context = {
    _children = {},
    _parent = nil,
    _shared = shared_data or {},
  }

  --- 获取协程内全局共享表
  function context:shared()
    return self._shared
  end

  --- 创建子上下文（共享同一个 _shared 表）
  function context:child()
    local child_ctx = M.create_context()
    child_ctx._parent = self
    child_ctx._shared = self._shared
    table.insert(self._children, child_ctx)
    return child_ctx
  end

  return context
end

-- ========== 协程内全局共享表快捷 API ==========

--- 获取当前协程的全局共享表
--- 如果不在协程中或没有上下文，返回一个临时空表（不会持久化）
--- @return table
function M.get_shared()
  local ctx = M.get_current_context()
  if not ctx then
    return {}
  end
  return ctx._shared
end

--- 设置协程内全局共享值（快捷方式）
--- @param key string
--- @param value any
function M.set_shared(key, value)
  local shared = M.get_shared()
  shared[key] = value
end

--- 获取协程内全局共享值（快捷方式）
--- @param key string
--- @param default any 默认值
--- @return any
function M.get_shared_value(key, default)
  local shared = M.get_shared()
  local v = shared[key]
  if v == nil then
    return default
  end
  return v
end

--- 获取当前协程上下文
--- @return table|nil
function M.get_current_context()
  local co = coroutine.running()
  if not co then
    return nil
  end
  return _coroutine_contexts[co]
end

--- 在指定上下文中执行函数
--- @param context table 上下文对象
--- @param fn function 要执行的函数
--- @param ... any 函数参数
--- @return ... 函数返回值
function M.with_context(context, fn, ...)
  local co = coroutine.running()
  local prev_context = co and _coroutine_contexts[co] or nil
  if co then
    _coroutine_contexts[co] = context
  end
  local ok, result1, result2, result3 = pcall(fn, ...)
  if co then
    if prev_context then
      _coroutine_contexts[co] = prev_context
    else
      _coroutine_contexts[co] = nil
    end
  end
  if not ok then
    error(result1)
  end
  return result1, result2, result3
end

--- 重置状态（测试用）
function M._test_reset()
  _coroutine_contexts = {}
end

return M
