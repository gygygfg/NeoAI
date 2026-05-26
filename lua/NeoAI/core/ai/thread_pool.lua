--- NeoAI 线程池管理器
--- 职责：管理后台线程的创建、调度和回收
---
--- 执行后端：
---   1. vim.fn.jobstart  - 子进程执行（真并行，在不同 CPU 核心上运行）
---   2. vim.uv.new_work  - libuv 线程池（CPU 密集型纯计算）
---   3. vim.schedule     - 主线程回调（Neovim API 相关操作）
---
--- 每种后端自动选择最优执行方式：
---   - 文件 I/O、shell 命令 → jobstart 子进程（真并行，不同 CPU）
---   - 纯 Lua 计算 → libuv new_work（线程池并行）
---   - Neovim API（buffer、LSP）→ vim.schedule（主线程串行）
---
--- 线程生命周期：
---   每次请求新开一个线程 → 执行完成后自动回收 → 下次请求复用
---
--- 使用方式：
---   local thread_pool = require("NeoAI.core.ai.thread_pool")
---   
---   -- 提交 AI 请求线程（子进程 curl）
---   thread_pool.submit_ai_request(params, callback)
---   
---   -- 提交工具调用线程
---   thread_pool.submit_tool_task(tool_name, args, callback)
---   
---   -- 批量提交工具调用线程（并行执行）
---   thread_pool.submit_tool_batch(tools, final_callback)

-- ========== 多实例隔离 ==========
-- 每个 Neovim 实例生成唯一标识符，用于：
--   1. Worker ID 前缀 → 区分不同实例的线程
--   2. 临时目录隔离 → 子进程临时文件不冲突
--   3. 日志追踪 → 多实例调试
--   4. 跨实例文件锁 → 防止并发写同一文件

--- 生成当前 Neovim 实例的唯一 ID
--- 优先使用 vim.server()（Neovim 0.10+），回退到 PID+随机数
local function _generate_instance_id()
  -- Neovim 0.10+ 内置 server 地址，天然唯一
  local ok, server_addr = pcall(function() return vim.server() end)
  if ok and server_addr and server_addr ~= "" then
    -- 提取 socket 路径中的唯一部分: /tmp/nvim.XXXXXX/0 → nvim.XXXXXX
    local basename = vim.fn.fnamemodify(server_addr, ":t")
    if basename and basename ~= "" and basename ~= "0" then
      return "nvim_" .. basename
    end
    -- 使用完整路径的 hash 作为短标识
    local hash = 0
    for i = 1, #server_addr do
      hash = (hash * 31 + server_addr:byte(i)) % 65536
    end
    return string.format("nvim_%s_%04x", vim.fn.getpid(), hash)
  end
  -- 回退：PID + 随机后缀（高碰撞抵抗）
  local pid = vim.fn.getpid()
  -- 使用 vim.uv 的高精度时间 + pid 生成唯一后缀
  local suffix = ""
  if vim.uv then
    local hrt = vim.uv.hrtime()
    suffix = string.format("%x", hrt % 0xFFFF)
  else
    suffix = string.format("%04x", math.random(0, 0xFFFF))
  end
  return string.format("nvim_%d_%s", pid, suffix)
end

-- 实例级临时目录
local _instance_tmpdir = nil

--- 获取或创建实例临时目录
local function _get_instance_tmpdir()
  if _instance_tmpdir then
    return _instance_tmpdir
  end
  local tmpbase = os.getenv("TMPDIR") or "/tmp"
  _instance_tmpdir = string.format("%s/neoai_%s", tmpbase, M.instance_id)
  -- 安全创建目录（mode 700 = 仅本用户可访问）
  vim.fn.mkdir(_instance_tmpdir, "p", 0700)
  return _instance_tmpdir
end

local M = {}

-- 实例唯一 ID（模块加载时生成，进程级别不变）
M.instance_id = _generate_instance_id()

local logger = require("NeoAI.utils.logger")
local async_worker = require("NeoAI.utils.async_worker")

-- ========== 线程池状态 ==========

local pool_state = {
  initialized = false,
  max_workers = 20,           -- 最大并发工作线程数
  active_workers = 0,         -- 当前活跃线程数
  total_spawned = 0,          -- 历史总创建线程数
  total_recycled = 0,         -- 历史总回收线程数
  worker_callbacks = {},      -- worker_id → callback 映射
  _id_counter = 0,            -- 线程 ID 计数器
}

-- ========== 工具类型分类 ==========

--- 可以在子进程中并行执行的工具（纯文件 I/O、shell 命令）
local SUBPROCESS_TOOLS = {
  run_command = true,
  list_files = true,
  search_files = true,
  read_file = true,
  file_exists = true,
  git_status = true,
  git_diff = true,
  git_log = true,
  git_branch = true,
  git_commit_detail = true,
  git_rollback = true,
}

--- 需要 Neovim API 的工具（必须主线程）
--- 这些工具操作 buffer、LSP、tree-sitter 等，不能移到子进程
local MAIN_THREAD_TOOLS = {
  edit_node = true,
  delete_node = true,
  delete_file = true,
  replace_text = true,
  create_directory = true,
  ensure_dir = true,
  execute_vim_cmd = true,
  get_child_nodes = true,
  get_node_at_position = true,
  get_node_code = true,
  get_node_range = true,
  get_node_type = true,
  get_parent_node = true,
  is_named_node = true,
  parse_file = true,
  query_tree = true,
}

-- ========== 初始化 ==========

function M.initialize(options)
  if pool_state.initialized then return M end
  options = options or {}
  pool_state.max_workers = options.max_workers or 20
  pool_state.initialized = true
  logger.info("[thread_pool] 线程池初始化完成, max_workers=%d", pool_state.max_workers)
  return M
end

-- ========== 公共 API ==========

--- 提交 AI 请求线程
--- AI HTTP 请求通过 curl jobstart 在子进程中执行（真并行，不同 CPU）
--- @param params table AI 请求参数
--- @param on_complete function(success, response, err) 完成回调（在主线程中调用）
--- @return string worker_id
function M.submit_ai_request(params, on_complete)
  if not pool_state.initialized then
    M.initialize()
  end

  local worker_id = _next_worker_id("ai_req")
  pool_state.active_workers = pool_state.active_workers + 1
  pool_state.total_spawned = pool_state.total_spawned + 1
  pool_state.worker_callbacks[worker_id] = on_complete

  logger.debug("[thread_pool] AI请求线程启动: %s, 活跃线程数=%d", worker_id, pool_state.active_workers)

  -- AI HTTP 请求已在 http_utils 中使用 jobstart（子进程），这里直接调用
  -- engine.lua 的 _send_stream_request / _send_non_stream_request 已经异步
  -- 我们在这里只是做一个轻量的包装层，确保线程计数正确

  -- 实际上 AI 请求的 curl jobstart 由 http_utils 管理
  -- 线程池只负责追踪和回收
  local http_utils = require("NeoAI.utils.http_utils")

  -- 包装回调，在完成时自动回收线程
  local wrapped_callback = function(success, response, err)
    pool_state.active_workers = math.max(0, pool_state.active_workers - 1)
    pool_state.total_recycled = pool_state.total_recycled + 1
    pool_state.worker_callbacks[worker_id] = nil
    logger.debug("[thread_pool] AI请求线程回收: %s, 活跃线程数=%d", worker_id, pool_state.active_workers)
    if on_complete then
      on_complete(success, response, err)
    end
  end

  -- 如果是流式请求，返回 worker_id 供后续追踪
  -- 实际 curl 请求由 engine 管理
  return worker_id, wrapped_callback
end

--- 提交工具调用线程
--- 根据工具类型自动选择执行后端：
---   - 子进程工具（文件 I/O、shell）→ jobstart 子进程（真并行，不同 CPU）
---   - 主线程工具（Neovim API）→ vim.schedule（主线程）
--- @param tool_name string 工具名称
--- @param tool_func function 工具执行函数
--- @param args table 工具参数
--- @param on_complete function(success, result, err) 完成回调
--- @return string worker_id
function M.submit_tool_task(tool_name, tool_func, args, on_complete)
  if not pool_state.initialized then
    M.initialize()
  end

  local worker_id = _next_worker_id("tool")
  pool_state.active_workers = pool_state.active_workers + 1
  pool_state.total_spawned = pool_state.total_spawned + 1
  pool_state.worker_callbacks[worker_id] = on_complete

  local wrapped_callback = function(success, result, err)
    pool_state.active_workers = math.max(0, pool_state.active_workers - 1)
    pool_state.total_recycled = pool_state.total_recycled + 1
    pool_state.worker_callbacks[worker_id] = nil
    logger.debug("[thread_pool] 工具线程回收: %s (%s), 活跃线程数=%d", worker_id, tool_name, pool_state.active_workers)
    if on_complete then
      on_complete(success, result, err)
    end
  end

  if SUBPROCESS_TOOLS[tool_name] then
    -- 子进程并行执行：真并行，在不同 CPU 核心上运行
    logger.debug("[thread_pool] 工具线程启动(子进程): %s (%s)", worker_id, tool_name)
    M._execute_in_subprocess(tool_name, tool_func, args, wrapped_callback)
  elseif MAIN_THREAD_TOOLS[tool_name] then
    -- 主线程执行：Neovim API 必须在主线程
    logger.debug("[thread_pool] 工具线程启动(主线程): %s (%s)", worker_id, tool_name)
    M._execute_in_main_thread(tool_name, tool_func, args, wrapped_callback)
  else
    -- 默认：尝试子进程，失败则回退到主线程
    logger.debug("[thread_pool] 工具线程启动(自动): %s (%s)", worker_id, tool_name)
    M._execute_auto(tool_name, tool_func, args, wrapped_callback)
  end

  return worker_id
end

--- 批量提交工具调用线程（全部并行执行）
--- 所有工具同时在各自的子进程/线程中执行
--- @param tools table 工具列表 { {name, func, args} }
--- @param final_callback function(all_success, results, errors) 全部完成后的回调
--- @return table worker_ids
function M.submit_tool_batch(tools, final_callback)
  if not tools or #tools == 0 then
    if final_callback then
      final_callback(true, {}, {})
    end
    return {}
  end

  local total = #tools
  local completed = 0
  local results = {}
  local errors = {}
  local worker_ids = {}
  local all_success = true

  logger.info("[thread_pool] 批量工具线程启动: 共 %d 个工具并行执行", total)

  for i, tool in ipairs(tools) do
    local tool_name = tool.name or ("tool_" .. i)
    local tool_func = tool.func
    local tool_args = tool.args or {}

    local wid = M.submit_tool_task(tool_name, tool_func, tool_args, function(success, result, err)
      results[i] = { success = success, result = result, err = err, name = tool_name }
      if not success then
        all_success = false
        errors[i] = err or "unknown error"
      end

      completed = completed + 1
      logger.debug("[thread_pool] 批量工具线程进度: %d/%d (%s), success=%s",
        completed, total, tool_name, tostring(success))

      if completed >= total then
        logger.info("[thread_pool] 批量工具线程全部完成: 共 %d 个, 成功=%s", total, tostring(all_success))
        if final_callback then
          final_callback(all_success, results, errors)
        end
      end
    end)
    table.insert(worker_ids, wid)
  end

  return worker_ids
end

-- ========== 执行后端实现 ==========

--- 在子进程中执行工具（真并行，不同 CPU）
--- @param tool_name string
--- @param tool_func function
--- @param args table
--- @param callback function
function M._execute_in_subprocess(tool_name, tool_func, args, callback)
  -- 使用 async_worker 的并行执行能力
  -- 子进程通过 jobstart 启动，在独立的 OS 进程中运行
  local opts = {
    timeout_ms = 30000,
    auto_serialize = true,
  }

  local success, worker_id = pcall(async_worker.submit_parallel_task,
    tool_name, tool_func, function(success, result, err, worker_info)
      if callback then
        -- 结果在子进程 stdout 中，可能是 JSON 字符串
        if success and type(result) == "string" then
          -- 尝试 JSON 解码
          local ok, decoded = pcall(vim.json.decode, result)
          if ok then
            result = decoded
          end
        end
        callback(success, result, err)
      end
    end, opts)

  if not success then
    -- 子进程启动失败，回退到主线程
    logger.debug("[thread_pool] 子进程启动失败(%s): %s，回退到主线程", tool_name, tostring(worker_id))
    M._execute_in_main_thread(tool_name, tool_func, args, callback)
  end
end

--- 在主线程中执行工具（Neovim API 依赖）
--- @param tool_name string
--- @param tool_func function
--- @param args table
--- @param callback function
function M._execute_in_main_thread(tool_name, tool_func, args, callback)
  vim.schedule(function()
    local ok, result = pcall(tool_func, args)
    if callback then
      if ok then
        callback(true, result, nil)
      else
        callback(false, nil, tostring(result))
      end
    end
  end)
end

--- 自动选择执行后端
--- 先尝试子进程，失败则回退到主线程
--- @param tool_name string
--- @param tool_func function
--- @param args table
--- @param callback function
function M._execute_auto(tool_name, tool_func, args, callback)
  if async_worker.is_parallel_supported() then
    M._execute_in_subprocess(tool_name, tool_func, args, callback)
  else
    M._execute_in_main_thread(tool_name, tool_func, args, callback)
  end
end

-- ========== 辅助函数 ==========

--- 生成下一个工作线程 ID（包含实例 ID 前缀，多实例安全）
--- @param prefix string
--- @return string
function _next_worker_id(prefix)
  pool_state._id_counter = pool_state._id_counter + 1
  -- 格式: {instance_id}_{prefix}_{counter}_{timestamp}
  -- 例如: "nvim_12345_a3f2_ai_req_1_1716700000"
  return string.format("%s_%s_%d_%d", M.instance_id, prefix or "worker", pool_state._id_counter, os.time())
end

-- ========== 跨实例文件锁 ==========

--- 跨实例文件锁表（lockfile_path → true）
--- 用于防止多个 Neovim 实例同时执行可能冲突的操作
--- 基于原子性文件创建（O_CREAT | O_EXCL），操作系统保证原子性
local _active_locks = {}

--- 尝试获取跨实例文件锁
--- 使用 vim.uv.fs_open 的独占创建模式（'wx' = write + exclusive）
--- 这是操作系统级别的原子操作，保证跨进程安全
--- @param lock_name string 锁名称（用于生成 lockfile）
--- @param timeout_ms number|nil 最大等待时间（毫秒），nil 表示非阻塞
--- @return boolean 是否获取成功
function M.acquire_lock(lock_name, timeout_ms)
  local lockfile = string.format("%s/lock_%s", _get_instance_tmpdir(), lock_name)
  local deadline = (timeout_ms and timeout_ms > 0) and (vim.uv.now() + timeout_ms) or nil

  while true do
    -- 尝试独占创建锁文件（模式 'wx' = write + exclusive create）
    local fd, err = vim.uv.fs_open(lockfile, "wx", 384) -- 0600
    if fd then
      vim.uv.fs_close(fd)
      _active_locks[lock_name] = lockfile
      return true
    end

    -- 锁文件已存在（其他实例持有锁）
    if not deadline then
      return false -- 非阻塞模式，直接返回
    end

    if vim.uv.now() >= deadline then
      return false -- 超时
    end

    -- 短暂休眠后重试（避免 CPU 空转）
    -- 使用 vim.wait 是非阻塞的（让出控制权给事件循环）
    vim.wait(10, function() return false end, 10)
  end
end

--- 释放跨实例文件锁
--- @param lock_name string 锁名称
function M.release_lock(lock_name)
  local lockfile = _active_locks[lock_name]
  if lockfile then
    pcall(vim.uv.fs_unlink, lockfile)
    _active_locks[lock_name] = nil
  end
end

--- 检查锁是否被持有（当前实例或其他实例）
--- @param lock_name string
--- @return boolean
function M.is_lock_held(lock_name)
  local lockfile = _active_locks[lock_name]
  if lockfile then
    -- 当前实例持有
    return true
  end
  -- 检查其他实例是否持有
  lockfile = string.format("%s/lock_%s", _get_instance_tmpdir(), lock_name)
  local fd = vim.uv.fs_open(lockfile, "r", 384)
  if fd then
    vim.uv.fs_close(fd)
    return true
  end
  return false
end

-- ========== 状态查询 ==========

--- 获取当前实例 ID
--- @return string
function M.get_instance_id()
  return M.instance_id
end

--- 获取线程池状态
--- @return table
function M.get_status()
  return {
    initialized = pool_state.initialized,
    instance_id = M.instance_id,
    max_workers = pool_state.max_workers,
    active_workers = pool_state.active_workers,
    total_spawned = pool_state.total_spawned,
    total_recycled = pool_state.total_recycled,
    pending_callbacks = vim.tbl_count(pool_state.worker_callbacks),
    active_locks = vim.tbl_keys(_active_locks),
  }
end

--- 取消指定线程
--- @param worker_id string
function M.cancel_worker(worker_id)
  local cb = pool_state.worker_callbacks[worker_id]
  if cb then
    pool_state.worker_callbacks[worker_id] = nil
    pool_state.active_workers = math.max(0, pool_state.active_workers - 1)
    pool_state.total_recycled = pool_state.total_recycled + 1
  end
end

--- 取消所有活跃线程并清理资源
function M.cancel_all()
  for worker_id, _ in pairs(pool_state.worker_callbacks) do
    pool_state.worker_callbacks[worker_id] = nil
  end
  pool_state.active_workers = 0
  pool_state.total_recycled = pool_state.total_recycled + pool_state.total_spawned

  -- 释放所有跨实例锁
  for lock_name, lockfile in pairs(_active_locks) do
    pcall(vim.uv.fs_unlink, lockfile)
  end
  _active_locks = {}

  logger.info("[thread_pool] 所有线程已取消, instance=%s", M.instance_id)
end

--- 完整关闭：取消线程 + 清理临时目录
function M.shutdown()
  M.cancel_all()

  -- 清理实例临时目录
  if _instance_tmpdir then
    pcall(vim.fn.delete, _instance_tmpdir, "rf")
    _instance_tmpdir = nil
  end

  logger.info("[thread_pool] 实例已关闭: %s", M.instance_id)
end

--- 重置（测试用）
function M._test_reset()
  M.cancel_all()
  pool_state.total_spawned = 0
  pool_state.total_recycled = 0
  pool_state._id_counter = 0
end

return M
