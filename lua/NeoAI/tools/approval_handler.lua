--- NeoAI 工具审批处理器
--- 职责：管理工具调用的审批队列、显示审批对话框、处理审批结果
--- 从 tool_executor.lua 提取，减轻其负担

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local tool_registry = require("NeoAI.tools.tool_registry")

local M = {}

-- ========== 状态 ==========

local state = {
  approval_queue = {},
  approval_showing = false,
  -- 审批暂停机制
  approval_paused = false, -- 是否因审批而暂停
  pause_start_time = nil, -- 暂停开始时间
  total_paused_duration = 0, -- 累计暂停时长（秒）
  pause_callbacks = {}, -- 暂停/恢复回调列表
}

-- ========== 审批队列管理 ==========

--- 将工具加入审批队列
--- @param item table { tool_name, resolved_args, raw_args, on_success, on_error, on_progress, start_time, pack_name, session_id }
function M.enqueue(item)
  table.insert(state.approval_queue, item)
end

--- 处理审批队列
--- 从队列头部取出一个待审批的工具，显示审批窗口
function M.process_queue()
  if state.approval_showing then
    return
  end
  if #state.approval_queue == 0 then
    return
  end

  state.approval_showing = true
  local item = table.remove(state.approval_queue, 1)

  if not item or not item.tool_name then
    state.approval_showing = false
    logger.warn("[approval_handler] 审批队列项无效，跳过")
    vim.schedule(function()
      M.process_queue()
    end)
    return
  end

  M._show_approval_dialog(item)
end

--- 清空审批队列
function M.clear_queue()
  state.approval_queue = {}
  -- 如果正在暂停，恢复计时
  if state.approval_paused then
    M.resume_timer()
  end
  if state.approval_showing then
    local ok, tool_approval = pcall(require, "NeoAI.ui.components.tool_approval")
    if ok and tool_approval.close then
      tool_approval.close()
    end
    state.approval_showing = false
  end
end

-- ========== 暂停/恢复机制 ==========

--- 注册暂停/恢复回调
--- 当审批暂停或恢复时，会调用注册的回调
--- @param callback function(is_paused: boolean) 暂停时为 true，恢复时为 false
--- @return function 取消注册的函数
function M.register_pause_callback(callback)
  table.insert(state.pause_callbacks, callback)
  return function()
    for i, cb in ipairs(state.pause_callbacks) do
      if cb == callback then
        table.remove(state.pause_callbacks, i)
        break
      end
    end
  end
end

--- 暂停计时（审批窗口打开时调用）
--- 记录暂停开始时间，通知所有注册的回调
function M.pause_timer()
  if state.approval_paused then
    return -- 已经暂停，避免重复暂停
  end
  state.approval_paused = true
  state.pause_start_time = os.time()
  logger.debug("[approval_handler] ⏸️ 审批暂停计时开始")

  -- 通知所有注册的回调
  for _, cb in ipairs(state.pause_callbacks) do
    local ok, err = pcall(cb, true)
    if not ok then
      logger.warn("[approval_handler] pause 回调执行失败: %s", tostring(err))
    end
  end
end

--- 恢复计时（审批窗口关闭时调用）
--- 计算暂停时长并累加到 total_paused_duration，通知所有注册的回调
function M.resume_timer()
  if not state.approval_paused then
    return -- 没有暂停，无需恢复
  end

  local pause_duration = 0
  if state.pause_start_time then
    pause_duration = os.time() - state.pause_start_time
    state.total_paused_duration = state.total_paused_duration + pause_duration
  end

  state.approval_paused = false
  state.pause_start_time = nil
  logger.debug(
    "[approval_handler] ▶️ 审批恢复计时，本次暂停 %d 秒，累计暂停 %d 秒",
    pause_duration,
    state.total_paused_duration
  )

  -- 通知所有注册的回调
  for _, cb in ipairs(state.pause_callbacks) do
    local ok, err = pcall(cb, false)
    if not ok then
      logger.warn("[approval_handler] resume 回调执行失败: %s", tostring(err))
    end
  end
end

--- 获取累计暂停时长
--- @return number 累计暂停时长（秒）
function M.get_total_paused_duration()
  local total = state.total_paused_duration
  -- 如果当前正在暂停，加上当前这次暂停的时长
  if state.approval_paused and state.pause_start_time then
    total = total + (os.time() - state.pause_start_time)
  end
  return total
end

--- 检查是否正在暂停
--- @return boolean
function M.is_paused()
  return state.approval_paused
end

--- 重置暂停状态（用于测试或重新开始）
function M.reset_pause_state()
  state.approval_paused = false
  state.pause_start_time = nil
  state.total_paused_duration = 0
  state.pause_callbacks = {}
end

--- 获取队列长度
--- @return number
function M.queue_length()
  return #state.approval_queue
end

--- 检查是否正在显示审批
--- @return boolean
function M.is_showing()
  return state.approval_showing
end

-- ========== 审批对话框 ==========

--- 显示审批对话框
--- @param item table 审批队列项
function M._show_approval_dialog(item)
  local tool_approval = require("NeoAI.ui.components.tool_approval")
  tool_approval.initialize()

  local tool_info = tool_registry.get(item.tool_name)
  local tools_for_approval = {}
  if tool_info then
    table.insert(tools_for_approval, {
      name = tool_info.name,
      description = tool_info.description or "",
      category = tool_info.category or "uncategorized",
      raw = tool_info,
      args = item.resolved_args, -- 传递参数详情，供审批窗口显示
    })
  else
    table.insert(tools_for_approval, {
      name = item.tool_name,
      description = "",
      category = "unknown",
      raw = nil,
      args = item.resolved_args,
    })
  end

  if #state.approval_queue > 0 then
    local queue_count = #state.approval_queue
    if tools_for_approval[1] and tools_for_approval[1].description then
      tools_for_approval[1].description = tools_for_approval[1].description
        .. string.format(" (队列中还有 %d 个待审批工具)", queue_count)
    end
  end

  local approval_closed = false
  local win_closed_autocmd_id = nil

  -- ===== 暂停计时：审批窗口即将打开 =====
  M.pause_timer()

  local open_ok, open_err = pcall(tool_approval.open, tools_for_approval, {
    on_select = function(selected, extra_opts)
      extra_opts = extra_opts or {}
      if approval_closed then
        return
      end
      approval_closed = true
      state.approval_showing = false
      if win_closed_autocmd_id then
        pcall(vim.api.nvim_del_autocmd, win_closed_autocmd_id)
        win_closed_autocmd_id = nil
      end

      -- ===== 恢复计时：审批窗口已关闭 =====
      M.resume_timer()

      -- 如果用户选择了"允许所有"，清空审批队列
      if extra_opts and extra_opts.allow_all then
        logger.debug(
          "[approval_handler] 用户选择允许所有，清空审批队列 (%d 个待审批)",
          #state.approval_queue
        )
        -- 逐个执行队列中的工具（不经过审批）
        local queued_items = vim.deepcopy(state.approval_queue)
        state.approval_queue = {}
        for _, queued_item in ipairs(queued_items) do
          local tool_executor = require("NeoAI.tools.tool_executor")
          tool_executor._continue_execution(
            queued_item.tool_name,
            queued_item.resolved_args,
            queued_item.raw_args,
            queued_item.on_success,
            queued_item.on_error,
            queued_item.on_progress,
            queued_item.start_time,
            queued_item.pack_name
          )
        end
      end

      logger.debug("[approval_handler] 用户已审批工具: %s", selected.name)
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_APPROVED,
        data = {
          tool_name = selected.name,
          tool = selected.raw,
          args = item.raw_args,
          session_id = item.session_id,
        },
      })

      local tool_executor = require("NeoAI.tools.tool_executor")
      local wrapped_on_success = function(result)
        if item.on_success then
          local ok_call, err_call = pcall(item.on_success, result)
          if not ok_call then
            logger.warn("[approval_handler] on_success 回调执行失败: %s", tostring(err_call))
          end
        end
        M.process_queue()
      end
      local wrapped_on_error = function(err)
        if item.on_error then
          local ok_call, err_call = pcall(item.on_error, err)
          if not ok_call then
            logger.warn("[approval_handler] on_error 回调执行失败: %s", tostring(err_call))
          end
        end
        M.process_queue()
      end

      tool_executor._continue_execution(
        item.tool_name,
        item.resolved_args,
        item.raw_args,
        wrapped_on_success,
        wrapped_on_error,
        item.on_progress,
        item.start_time,
        item.pack_name
      )
    end,
    on_cancel = function(extra_opts)
      extra_opts = extra_opts or {}
      if approval_closed then
        return
      end
      approval_closed = true
      state.approval_showing = false
      if win_closed_autocmd_id then
        pcall(vim.api.nvim_del_autocmd, win_closed_autocmd_id)
        win_closed_autocmd_id = nil
      end

      -- ===== 恢复计时：审批窗口已关闭 =====
      M.resume_timer()

      local cancel_reason = extra_opts.reason or "用户未提供原因"
      logger.debug("[approval_handler] 用户拒绝工具: %s，原因: %s", item.tool_name, cancel_reason)
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_APPROVAL_CANCELLED,
        data = {
          tool_name = item.tool_name,
          args = item.raw_args,
          session_id = item.session_id,
        },
      })

      local duration = os.time() - item.start_time
      local err_msg = "用户取消了工具执行: " .. item.tool_name
      local ok_fire, _ = pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_EXECUTION_ERROR,
        data = {
          tool_name = item.tool_name,
          pack_name = item.pack_name,
          args = item.raw_args,
          error_msg = err_msg,
          duration = duration,
          session_id = item.session_id,
        },
      })
      if not ok_fire then
        vim.schedule(function()
          pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = event_constants.TOOL_EXECUTION_ERROR,
            data = {
              tool_name = item.tool_name,
              pack_name = item.pack_name,
              args = item.raw_args,
              error_msg = err_msg,
              duration = duration,
              session_id = item.session_id,
            },
          })
        end)
      end
      if item.on_error then
        local ok_on_err, _ = pcall(item.on_error, err_msg)
        if not ok_on_err then
          vim.schedule(function()
            pcall(item.on_error, err_msg)
          end)
        end
      end
      M.process_queue()
    end,
  })

  if not open_ok then
    state.approval_showing = false
    logger.warn("[approval_handler] 打开审批窗口失败: %s", tostring(open_err))
    table.insert(state.approval_queue, 1, item)
    vim.schedule(function()
      M.process_queue()
    end)
    return
  end

  if tool_approval.get_win_id then
    local approval_win_id = tool_approval.get_win_id()
    if approval_win_id then
      win_closed_autocmd_id = vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(approval_win_id),
        once = true,
        callback = function()
          if approval_closed then
            return
          end
          approval_closed = true
          state.approval_showing = false
          -- ===== 恢复计时：审批窗口被外部关闭 =====
          M.resume_timer()
          logger.debug("[approval_handler] 审批窗口被外部关闭: %s", item.tool_name)
          local duration = os.time() - item.start_time
          local err_msg = "审批窗口被关闭，工具执行已取消: " .. item.tool_name
          pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = event_constants.TOOL_EXECUTION_ERROR,
            data = {
              tool_name = item.tool_name,
              pack_name = item.pack_name,
              args = item.raw_args,
              error_msg = err_msg,
              duration = duration,
              session_id = item.session_id,
            },
          })
          if item.on_error then
            local ok_on_err, _ = pcall(item.on_error, err_msg)
            if not ok_on_err then
              vim.schedule(function()
                pcall(item.on_error, err_msg)
              end)
            end
          end
          M.process_queue()
        end,
      })
    end
  end
end

return M
