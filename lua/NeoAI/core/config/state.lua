--- NeoAI 统一状态管理器
--- 集中管理所有模块的共享状态，消除分散在各模块中的重复状态表
---
--- 功能：
---   1. 状态切片（slice）：模块注册自己的状态域，支持读写和变更监视
---   2. 协程上下文：协程安全的闭包上下文隔离（session_id、tools 等）
---   3. 协程内全局共享表（shared）：协程内所有模块可直接读写，无需注册切片
---   4. 事件触发辅助：封装 Neovim 原生 User 事件，提供一致的触发接口
---
--- 设计原则：
---   - 事件机制使用 Neovim 原生 vim.api.nvim_exec_autocmds，不自行实现事件总线
---   - 状态切片之间互不干扰，通过 slice_name 隔离
---   - 协程上下文在协程开始时创建，结束时自动清理
---   - 协程内共享表随上下文自动清理，无需手动管理
---
--- 使用方式：
---   local sm = require("NeoAI.core.config.state")
---
---   -- 方式一：状态切片（适合跨协程、需监视的持久状态）
---   sm.register_slice("ai_engine", { tools = {}, is_generating = false })
---   sm.set_state("ai_engine", "is_generating", true)
---   local tools = sm.get_state("ai_engine", "tools")
---   sm.watch("ai_engine", "is_generating", function(new, old) print("changed") end)
---
---   -- 方式二：协程内全局共享表（适合协程内多模块共享，无需注册，自动隔离）
---   -- 在协程开始时创建上下文，将共享变量放入 _shared 表
---   -- 协程内所有模块（ai_engine、tool_orchestrator、http_client、chat_window 等）
---   -- 直接通过 get_shared() 读写，不需要知道是谁注册的
---   --
---   -- 推荐的共享变量（按协程隔离）：
---   --   session_id      - 当前会话 ID
---   --   generation_id   - 当前生成 ID
---   --   window_id       - 当前窗口 ID
---   --   model_index     - 当前模型索引
---   --   ai_preset       - 当前 AI 配置
---   --   options         - 生成选项（tools_enabled, reasoning_enabled 等）
---   --   messages        - 上下文消息列表
---   --   accumulated_usage - 累积 token 用量
---   --   last_reasoning  - 最后一次思考内容
---   --   stop_requested  - 停止请求标志
---   --   user_cancelled  - 用户取消标志
---   --
---   local ctx = sm.create_context({ session_id = "sess_001" })
---   sm.with_context(ctx, function()
---     -- 协程内任意模块直接读写
---     sm.set_shared("current_tool", "web_scout")
---     local tool = sm.get_shared_value("current_tool")
---     -- 或直接操作共享表引用（适合嵌套结构）
---     local shared = sm.get_shared()
---     shared.some_key = { nested = true }
---   end)

local M = {}

local logger = require("NeoAI.utils.logger")

-- ========== 状态切片 ==========
local _slices = {}
local _slice_order = {}
local _watcher_id_counter = 0

-- ========== 协程上下文 ==========
local _coroutine_contexts = {}

-- ========== 状态切片 API ==========

--- 注册一个状态切片
--- 模块在 initialize 时调用，注册自己的状态域
--- @param slice_name string 切片名称，如 "ai_engine", "tool_orchestrator"
--- @param initial_data table 初始数据
function M.register_slice(slice_name, initial_data)
  if _slices[slice_name] then
    logger.debug("[state] 状态切片 '%s' 已存在，跳过注册", slice_name)
    return
  end
  _slices[slice_name] = {
    data = initial_data or {},
    watchers = {}, -- { [key] = { [watcher_id] = fn(new, old) } }
  }
  table.insert(_slice_order, slice_name)
  logger.debug("[state] 注册状态切片: %s", slice_name)
end

--- 获取整个状态切片
--- @param slice_name string
--- @return table|nil
function M.get_slice(slice_name)
  local slice = _slices[slice_name]
  return slice and slice.data or nil
end

--- 获取状态切片中的某个值（支持点号路径）
--- @param slice_name string
--- @param key string 如 "tools", "active_generations"
--- @param default any 默认值
--- @return any
function M.get_state(slice_name, key, default)
  local slice = _slices[slice_name]
  if not slice then
    return default
  end
  if not key then
    return slice.data
  end
  local keys = vim.split(key, ".", { plain = true })
  local value = slice.data
  for _, k in ipairs(keys) do
    if type(value) ~= "table" then
      return default
    end
    value = value[k]
  end
  if value == nil then
    return default
  end
  return value
end

--- 通知 watcher（内部函数，需在 set_state 之前定义）
local function _notify_watchers(slice_name, key, new_val, old_val)
  local slice = _slices[slice_name]
  if not slice or not slice.watchers[key] then
    return
  end
  for _, cb in pairs(slice.watchers[key]) do
    pcall(cb, new_val, old_val)
  end
end

--- 设置状态切片中的值，并通知 watcher
--- @param slice_name string
--- @param key string 如 "tools", "is_generating"
--- @param value any
--- @return boolean
function M.set_state(slice_name, key, value)
  local slice = _slices[slice_name]
  if not slice then
    logger.warn("[state] 设置状态失败: 切片 '%s' 不存在", slice_name)
    return false
  end
  local old_value = slice.data[key]
  slice.data[key] = value
  _notify_watchers(slice_name, key, value, old_value)
  return true
end

--- 更新状态切片中的嵌套值（支持点号路径）
--- @param slice_name string
--- @param key_path string 如 "active_generations.gen_123"
--- @param value any
function M.set_state_path(slice_name, key_path, value)
  local slice = _slices[slice_name]
  if not slice then
    return false
  end
  local keys = vim.split(key_path, ".", { plain = true })
  local target = slice.data
  for i = 1, #keys - 1 do
    local k = keys[i]
    if type(target[k]) ~= "table" then
      target[k] = {}
    end
    target = target[k]
  end
  local last_key = keys[#keys]
  local old_value = target[last_key]
  target[last_key] = value
  _notify_watchers(slice_name, key_path, value, old_value)
  return true
end

--- 删除状态切片中的某个键
--- @param slice_name string
--- @param key string
function M.del_state(slice_name, key)
  local slice = _slices[slice_name]
  if not slice then
    return
  end
  local old_value = slice.data[key]
  slice.data[key] = nil
  _notify_watchers(slice_name, key, nil, old_value)
end

--- 监视某个状态变化
--- @param slice_name string
--- @param key string 要监视的键
--- @param callback function(new_val, old_val) 回调
--- @return string watcher_id 用于取消监视
function M.watch(slice_name, key, callback)
  local slice = _slices[slice_name]
  if not slice then
    logger.warn("[state] 监视失败: 切片 '%s' 不存在", slice_name)
    return nil
  end
  _watcher_id_counter = _watcher_id_counter + 1
  local watcher_id = "w_" .. _watcher_id_counter
  if not slice.watchers[key] then
    slice.watchers[key] = {}
  end
  slice.watchers[key][watcher_id] = callback
  return watcher_id
end

--- 取消监视
--- @param slice_name string
--- @param key string
--- @param watcher_id string
function M.unwatch(slice_name, key, watcher_id)
  local slice = _slices[slice_name]
  if not slice or not slice.watchers[key] then
    return
  end
  slice.watchers[key][watcher_id] = nil
end

-- ========== 事件触发辅助 ==========

--- 触发 Neovim User 事件（封装 pcall 保护）
--- 统一使用此函数替代直接调用 vim.api.nvim_exec_autocmds
--- @param event_name string 事件名称（如 event_constants.GENERATION_STARTED）
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
--- 上下文自动绑定到当前协程，协程结束时无需手动清理
--- 每个协程自动拥有一个 _shared 共享表，协程内所有模块可直接读写
---
--- @param context_data table 初始上下文数据，如 { session_id = "...", tools = {...} }
--- @return table context 上下文对象
function M.create_context(context_data)
  local context = {
    _data = context_data or {},
    _children = {},
    _parent = nil,
    _shared = {}, -- 协程内全局共享表，所有模块可直接读写
  }

  --- 获取上下文值
  function context:get(key, default)
    return self._data[key] ~= nil and self._data[key] or default
  end

  --- 设置上下文值
  function context:set(key, value)
    self._data[key] = value
  end

  --- 获取协程内全局共享表
  --- 协程内所有模块可直接通过此表读写共享状态，无需注册切片
  --- @return table
  function context:shared()
    return self._shared
  end

  --- 创建子上下文（继承父上下文的值，子上下文修改不影响父上下文）
  --- 注意：子上下文共享同一个 _shared 表（父协程内的所有模块看到同一份共享数据）
  function context:child(extra_data)
    local child_data = vim.tbl_extend("keep", extra_data or {}, self._data)
    local child_ctx = M.create_context(child_data)
    child_ctx._parent = self
    -- 子上下文共享父上下文的 _shared 表
    child_ctx._shared = self._shared
    table.insert(self._children, child_ctx)
    return child_ctx
  end

  return context
end

-- ========== 协程内全局共享表快捷 API ==========

--- 获取当前协程的全局共享表
--- 协程内任意模块可直接调用，无需先获取 context 对象
--- 如果不在协程中或没有上下文，返回一个临时空表（不会持久化）
--- 注意：此函数在 Neovim 事件回调（autocmd、jobstart on_stdout/on_exit、
--- vim.schedule、vim.defer_fn 等）中也会被调用，这些场景不在协程上下文中。
--- 调用方应通过函数参数传递必要数据，get_shared 仅作为备选降级方案。
--- @return table 共享表，读写直接操作此表即可
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
--- 函数执行期间，当前协程的上下文被临时替换
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
  _slices = {}
  _slice_order = {}
  _watcher_id_counter = 0
  _coroutine_contexts = {}
end

-- ========== 调试工具 ==========

--- 获取所有已注册的状态切片名称
function M.list_slices()
  local names = {}
  for _, name in ipairs(_slice_order) do
    table.insert(names, name)
  end
  return names
end

-- ========== 初始化状态检查 ==========

--- 检查状态管理器是否已初始化
--- 通过检查 app 切片是否存在来判断
--- @return boolean
function M.is_initialized()
  return _slices["app"] ~= nil
end

return M
