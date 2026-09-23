--- NeoAI 主入口
--- @module NeoAI
--- 极薄入口：setup() 仅做 配置加载 → 内核引导 → 登记插件 → 注册命令/键位占位。
--- 懒加载（无配置）：首次调用命令/键位/主动 API 时才分两阶段异步启动插件图：
---   阶段 1（UI 就绪所需）完成后立即打开界面；阶段 2（工具/沙箱/skills/mcp 等）后台分帧加载。
--- 业务模块一律懒加载，首次使用时才 require；对外通过 kernel.services.use 获取服务。
--- 只读访问器（get_*_service / get_statusline*）不会触发启动，未就绪时返回 nil/""。

local kernel = require("NeoAI.kernel")
local config_store = require("NeoAI.kernel.config_store")
local services = require("NeoAI.kernel.services")

-- ========== 私有状态 ==========

local state = {
  loaded = false,
  phase1_started = false,
  phase1_done = false,
  phase1_failed = false,
  phase2_started = false,
  phase2_failed = false,
  fully_started = false,
}

local phase1_waiters = {}
local full_waiters = {}

local M = {}

-- ========== 私有函数 ==========

--- 注册关闭钩子（逆序执行：persist 先于 stop_all，保证 Agent 被销毁前落盘）
local function _register_shutdown_hooks()
  kernel.lifecycle.on_shutdown(function()
    require("NeoAI.kernel.plugins").stop_all()
  end)
  kernel.lifecycle.on_shutdown(function()
    local chat = services.use("services.chat_service")
    if chat and chat.persist_active_sessions then
      pcall(chat.persist_active_sessions)
    end
  end)
end

--- 清空并回调等待队列
--- @param list table
--- @param ok boolean
local function _drain(list, ok)
  local pending = {}
  for i = 1, #list do pending[i] = list[i] end
  for i = #list, 1, -1 do list[i] = nil end
  for _, cb in ipairs(pending) do pcall(cb, ok) end
end

--- 分帧启动指定阶段
--- @param phase number 1|2
--- @param on_done function(ok: boolean)
local function _run_phase(phase, on_done)
  local plugins = require("NeoAI.kernel.plugins")
  local catalog = require("NeoAI.plugins.catalog")
  local ids = catalog.phase_ids(phase)
  plugins.start_list_async(ids, function(ok, info)
    if not ok then
      require("NeoAI.kernel.logger").error(
        "[NeoAI] 阶段 %d 插件启动失败: %s: %s",
        phase, tostring(info and info.failed), tostring(info and info.error))
    end
    on_done(ok)
  end)
end

--- 启动阶段 2 并从等待队列完成全量启动
local function _start_phase2()
  if state.phase2_started then return end
  state.phase2_started = true
  _run_phase(2, function(ok)
    if ok then
      state.fully_started = true
    else
      state.phase2_failed = true
    end
    _drain(full_waiters, ok)
  end)
end

--- 启动阶段 1；完成后回调阶段 1 等待者并自动继续阶段 2
local function _start_phase1()
  if state.phase1_started then return end
  state.phase1_started = true
  _run_phase(1, function(ok)
    if not ok then
      state.phase1_failed = true
      state.phase2_failed = true
      _drain(phase1_waiters, false)
      -- 阶段 1 失败：全量等待者也一并失败
      _drain(full_waiters, false)
      return
    end
    state.phase1_done = true
    _drain(phase1_waiters, true)
    _start_phase2()
  end)
end

-- ========== 公开 API ==========

--- 设置插件配置（只登记，不启动；首次使用时懒加载）
--- @param user_config table 用户配置
--- @return table 插件实例
function M.setup(user_config)
  if state.loaded then return M end
  state.loaded = true

  -- 纯函数：合并 + 校验，返回不可变配置
  config_store.load(user_config or {})

  -- 启动早期放大 libuv 线程池：libuv 默认仅 4 个 worker 线程，大量读写文件（命令产物
  -- 冻结/token 化/落盘）会因此只跑 4 个核。必须在任何 worker/异步任务创建线程池之前调用
  -- （池大小一旦创建不可再变）；用户已显式设置 UV_THREADPOOL_SIZE 时尊重用户值。
  require("NeoAI.utils.work").configure_threadpool()

  -- Neovim >= 0.13 起由 autoread 自动把外部改动的文件重载进 buffer，
  -- 替代内置工具写盘后的手动缓冲区同步；更早版本走 sync_buffer_from_disk。
  if vim.fn.has("nvim-0.13") == 1 then
    vim.opt.autoread = true
  end

  -- 内核引导：事件常量表、日志、生命周期
  kernel.bootstrap()

  -- 强制多线程：CPU 密集计算/阻塞 I/O 一律卸载到 libuv 线程池，无同步回退。
  -- 需要 Neovim 0.10+ 的 vim.uv.new_work；不可用时显式报错而非静默降级。
  -- 同时跑一次 worker 往返自检，确认 worker 内 vim.mpack 可用（run_codec 的硬前提）。
  require("NeoAI.utils.work").require()

  -- 仅登记内置插件（服务提供方 + 副作用 + 每个内置工具），不启动
  local catalog = require("NeoAI.plugins.catalog")
  catalog.register_builtins()

  -- 关闭时统一卸载插件（释放服务/工具/命令/事件订阅/MCP/UI 注入）
  _register_shutdown_hooks()

  -- 注册命令/键位占位：首次触发才异步启动插件图
  local lazy = require("NeoAI.plugins.builtin.lazy")
  local lazy_cleanup = lazy.register({
    ensure_phase1 = M.ensure_phase1,
    ensure_started = M.ensure_started,
    is_started = function() return state.phase1_done end,
  })
  -- 未启动阶段 1 时（占位符仍生效）在关闭时移除；已启动时由真实插件宿主清理。
  kernel.lifecycle.on_shutdown(function()
    if lazy_cleanup then lazy_cleanup() end
  end)

  return M
end

--- 阶段 1（UI 就绪所需服务）完成后回调；未启动则触发启动
--- @param cb function(ok: boolean)|nil
function M.ensure_phase1(cb)
  cb = cb or function() end
  if state.phase1_done then return cb(true) end
  if state.phase1_failed then return cb(false) end
  phase1_waiters[#phase1_waiters + 1] = cb
  _start_phase1()
end

--- 全量（含工具/沙箱/skills/mcp 等后台服务）启动完成后回调
--- @param cb function(ok: boolean)|nil
function M.ensure_fully_started(cb)
  cb = cb or function() end
  if state.fully_started then return cb(true) end
  if state.phase2_failed then return cb(false) end
  full_waiters[#full_waiters + 1] = cb
  -- 未启动阶段 1 则触发；阶段 1 完成后会自动继续阶段 2
  _start_phase1()
end

--- 全量启动完成后回调（别名）
--- @param cb function(ok: boolean)|nil
function M.ensure_started(cb)
  return M.ensure_fully_started(cb)
end

--- 同步等待全量启动完成（测试 / 热重载 / CLI 用）
--- @param timeout_ms number|nil 默认 60000
--- @return boolean ok
function M.ensure_started_sync(timeout_ms)
  if state.fully_started then return true end
  local done, ok = false, false
  M.ensure_fully_started(function(r)
    ok = r
    done = true
  end)
  local waited = pcall(vim.wait, timeout_ms or 60000, function() return done end, 10)
  if not waited then return false end
  return done and ok
end

--- 阶段 1 是否已完成（UI 就绪）
--- @return boolean
function M.is_phase1_done()
  return state.phase1_done
end

--- 是否已全量启动
--- @return boolean
function M.is_fully_started()
  return state.fully_started
end

-- ========== 界面 API（阶段 1 就绪即可） ==========

--- 调用 ui 服务方法；未就绪则触发懒加载并在就绪后执行
--- @param method string
--- @param ... any
--- @return any
local function _ui_call(method, ...)
  local args = { n = select("#", ...), ... }
  if state.phase1_done then
    local ui = services.use("services.ui")
    if ui and ui[method] then return ui[method](unpack(args, 1, args.n)) end
    return nil
  end
  M.ensure_phase1(function(ok)
    if not ok then return end
    local ui = services.use("services.ui")
    if ui and ui[method] then ui[method](unpack(args, 1, args.n)) end
  end)
  return nil
end

--- 打开默认界面（懒加载 ui 服务）
--- @return any
function M.open_default()
  return _ui_call("open_default")
end

--- 打开聊天界面
--- @return any
function M.open_chat()
  return _ui_call("open_chat")
end

--- 打开会话树界面
--- @return any
function M.open_tree()
  return _ui_call("open_tree")
end

--- 关闭所有窗口
--- @return any
function M.close_all()
  return _ui_call("close_all")
end

-- ========== 服务访问器（只读，不触发启动） ==========

--- 获取聊天服务
--- @return table|nil chat_service
function M.get_chat_service()
  return services.use("services.chat_service")
end

--- 获取工具服务
--- @return table|nil tool_service
function M.get_tool_service()
  return services.use("services.tool_service")
end

--- 获取模型服务
--- @return table|nil model_service
function M.get_model_service()
  return services.use("services.model_service")
end

--- 获取状态栏服务，用于 nvim-lualine 集成
--- @return table|nil status_service
function M.get_status_service()
  return services.use("services.status")
end

--- 获取状态栏信息（方便其它插件 / 状态栏消费）
--- @return table|nil 当前 Agent 的用量/缓存/容量信息
function M.get_statusline_info()
  local status = services.use("services.status")
  return status and status.get_info() or nil
end

--- 生成 lualine 状态栏文本
--- @return string
function M.get_statusline()
  local status = services.use("services.status")
  return status and status.component() or ""
end

--- 手动把 NeoAI lualine 扩展注入 lualine（幂等；一般无需手动调用）
--- 会触发懒加载（显式意图）。
--- @return boolean
function M.enable_statusline()
  if state.fully_started then
    local status = services.use("services.status")
    return status and status.ensure_lualine_extension() or false
  end
  M.ensure_started(function(ok)
    if not ok then return end
    local status = services.use("services.status")
    if status then pcall(status.ensure_lualine_extension) end
  end)
  return false
end

return M
