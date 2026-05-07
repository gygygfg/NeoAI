--- NeoAI 历史持久化模块
--- 职责：文件序列化/反序列化、写入队列、事务性保存
---
--- 文件格式：每行一个会话，格式为 "id:json"
--- 示例：
---   session_1:{"id":"session_1","name":"...",...}
---   session_2:{"id":"session_2","name":"...",...}
---
--- 行号缓存：读取时建立 id→行号 映射，下次只解析有变化的行
--- 使用 async_worker 的任务队列，保证原子性和实时保存

local M = {}

local logger = require("NeoAI.utils.logger")
local async_worker = require("NeoAI.utils.async_worker")

-- ========== 状态 ==========

local state = {
  initialized = false,
  config = nil,
  save_path = nil,

  -- 写入队列（FIFO）
  _write_queue = {},       -- { {type, data, callback, id}, ... }
  _write_in_progress = false,
  _queue_counter = 0,

  -- 防抖状态
  _debounce_timer = nil,
  _debounce_active = false,
  _pending_flush = false,

  -- 退出标志
  _is_shutting_down = false,

  -- 行号缓存：{ [id] = line_number }，1-based
  _line_map = {},
  -- 文件行数缓存（用于快速判断是否有新增行）
  _file_line_count = 0,
}

-- ========== 配置 ==========

--- 获取存储文件路径
function M.get_filepath()
  local save_path = state.save_path
  if not save_path or save_path == "" then
    save_path = vim.fn.stdpath("cache") .. "/NeoAI"
  end
  return save_path .. "/sessions.json"
end

-- ========== 序列化 ==========

--- 判断会话是否为空（无有效对话内容）
--- @param session table 会话对象
--- @return boolean
local function is_empty_session(session)
  if not session then return true end
  if session.user and session.user ~= "" then return false end
  local asst = session.assistant
  if type(asst) == "table" and #asst > 0 then return false end
  if type(asst) == "string" and asst ~= "" then return false end
  return true
end

--- 序列化所有会话为 "id:json\n" 格式
--- @param sessions table 会话表 { [id] = session }
--- @return string|nil 序列化字符串，失败返回 nil
function M.serialize(sessions)
  local arr = {}
  for _, session in pairs(sessions) do
    if not is_empty_session(session) then
      table.insert(arr, session)
    end
  end
  table.sort(arr, function(a, b)
    return (a.updated_at or a.created_at or 0) < (b.updated_at or b.created_at or 0)
  end)
  if #arr == 0 then
    return ""
  end

  local parts = {}
  for _, session in ipairs(arr) do
    local ok, json = pcall(vim.json.encode, session)
    if ok and json then
      -- 格式：id:json
      table.insert(parts, session.id .. ":" .. json)
    else
      logger.warn("[history_persistence] 序列化跳过无效会话: " .. (session.id or "unknown"))
    end
  end
  return table.concat(parts, "\n")
end

--- 从 "id:json" 行中提取 id
--- @param line string 一行内容
--- @return string|nil id，格式错误返回 nil
local function extract_id_from_line(line)
  if not line or line == "" then
    return nil
  end
  local colon_pos = line:find(":", 1, true)
  if not colon_pos then
    return nil
  end
  return line:sub(1, colon_pos - 1)
end

--- 从 "id:json" 行中解析 session
--- @param line string 一行内容
--- @return table|nil session，解析失败返回 nil
local function parse_session_from_line(line)
  if not line or line == "" then
    return nil
  end
  local colon_pos = line:find(":", 1, true)
  if not colon_pos then
    return nil
  end
  local json_str = line:sub(colon_pos + 1)
  local ok, session = pcall(vim.json.decode, json_str)
  if ok and type(session) == "table" and session.id then
    return session
  end
  return nil
end

--- 反序列化（增量解析，只解析有变化的行）
--- @param content string|nil 文件内容，nil 表示从文件重新读取
--- @return table 会话表 { [id] = session }
function M.deserialize(content)
  local sessions = {}

  -- 读取文件内容
  if content == nil then
    local filepath = M.get_filepath()
    if vim.fn.filereadable(filepath) ~= 1 then
      state._line_map = {}
      state._file_line_count = 0
      return sessions
    end
    local lines = vim.fn.readfile(filepath)
    if not lines or #lines == 0 then
      state._line_map = {}
      state._file_line_count = 0
      return sessions
    end
    content = table.concat(lines, "\n")
  end

  if not content or content == "" then
    state._line_map = {}
    state._file_line_count = 0
    return sessions
  end

  local lines = vim.split(content, "\n")
  local new_line_count = #lines
  local old_line_map = state._line_map
  local new_line_map = {}

  for line_num, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed == "" then
      goto continue
    end

    local id = extract_id_from_line(trimmed)
    if not id then
      goto continue
    end

    new_line_map[id] = line_num

    -- 检查缓存：如果该 id 的行号没变，且 session 已存在，跳过解析
    if old_line_map[id] == line_num and state._sessions_cache and state._sessions_cache[id] then
      sessions[id] = state._sessions_cache[id]
    else
      -- 行号变了或没有缓存，解析该行
      local session = parse_session_from_line(trimmed)
      if session then
        sessions[id] = session
      end
    end
    ::continue::
  end

  -- 更新缓存
  state._line_map = new_line_map
  state._file_line_count = new_line_count
  state._sessions_cache = sessions

  return sessions
end

-- ========== 文件 IO（同步） ==========

--- 确保目录存在
--- @param filepath string 文件路径
local function ensure_dir(filepath)
  local dir = filepath:match("(.*/)")
  if dir and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- 同步写入文件内容
--- @param filepath string 文件路径
--- @param content string 内容
--- @return boolean, string|nil 是否成功，错误信息
local function write_file_sync(filepath, content)
  local ok, err = pcall(function()
    ensure_dir(filepath)
    if content and content ~= "" then
      local lines = vim.split(content, "\n")
      vim.fn.writefile(lines, filepath)
    else
      -- 空内容写入空文件
      vim.fn.writefile({}, filepath)
    end
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

--- 原子写入（先写临时文件，再重命名）
--- @param filepath string 目标文件路径
--- @param content string 内容
--- @return boolean, string|nil 是否成功，错误信息
local function atomic_write(filepath, content)
  local tmp_path = filepath .. ".tmp." .. tostring(os.time())
  local ok, err = write_file_sync(tmp_path, content)
  if not ok then
    return false, "临时文件写入失败: " .. (err or "unknown")
  end

  local rename_ok, rename_err = pcall(function()
    vim.fn.rename(tmp_path, filepath)
  end)

  if not rename_ok then
    pcall(vim.fn.delete, tmp_path)
    return false, "重命名失败: " .. tostring(rename_err)
  end

  return true, nil
end

-- ========== 加载 ==========

--- 从文件加载会话数据（总是重新读取文件，但增量解析）
--- @return table 会话表 { [id] = session }
function M.load()
  local filepath = M.get_filepath()
  ensure_dir(filepath)

  -- 检查文件是否存在
  if vim.fn.filereadable(filepath) ~= 1 then
    -- 创建空文件
    write_file_sync(filepath, "")
    state._line_map = {}
    state._file_line_count = 0
    state._sessions_cache = {}
    return {}
  end

  -- 读取文件并增量解析
  local lines = vim.fn.readfile(filepath)
  if not lines or #lines == 0 then
    state._line_map = {}
    state._file_line_count = 0
    state._sessions_cache = {}
    return {}
  end

  local content = table.concat(lines, "\n")
  return M.deserialize(content)
end

--- 获取行号映射（用于外部快速判断是否有变化）
--- @return table { [id] = line_number }
function M.get_line_map()
  return state._line_map
end

--- 获取文件行数
--- @return number
function M.get_file_line_count()
  return state._file_line_count
end

--- 检查文件是否有变化（基于行号和行数）
--- @return boolean
function M.has_file_changed()
  local filepath = M.get_filepath()
  if vim.fn.filereadable(filepath) ~= 1 then
    return vim.tbl_count(state._line_map) > 0
  end

  local lines = vim.fn.readfile(filepath)
  local current_line_count = lines and #lines or 0

  -- 行数不同，肯定有变化
  if current_line_count ~= state._file_line_count then
    return true
  end

  -- 检查每行的 id 前缀是否与缓存一致
  for line_num, line in ipairs(lines or {}) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      local id = extract_id_from_line(trimmed)
      if id then
        local cached_line = state._line_map[id]
        if cached_line ~= line_num then
          return true  -- id 出现在不同行，有变化
        end
      end
    end
  end

  return false
end

-- ========== 写入队列（事务性） ==========

--- 处理队列中的下一个写入任务
local function process_queue()
  if state._write_in_progress then return end
  if #state._write_queue == 0 then return end
  if state._is_shutting_down then return end

  state._write_in_progress = true
  local task = table.remove(state._write_queue, 1)

  async_worker.submit_task(
    "history_save_" .. task.id,
    function()
      local filepath = M.get_filepath()
      ensure_dir(filepath)
      local ok, err = atomic_write(filepath, task.content)
      return ok, err
    end,
    function(success, result, error_msg)
      state._write_in_progress = false

      if success then
        logger.debug("[history_persistence] 保存成功: " .. task.type)
        if task.callback then
          task.callback(true, nil)
        end
      else
        logger.warn("[history_persistence] 保存失败: " .. (error_msg or "unknown"))
        if (task.retry_count or 0) < 3 then
          task.retry_count = (task.retry_count or 0) + 1
          table.insert(state._write_queue, 1, task)
          logger.warn("[history_persistence] 重试保存 (" .. task.retry_count .. "/3)")
        else
          logger.error("[history_persistence] 保存失败已达最大重试次数: " .. (error_msg or "unknown"))
          if task.callback then
            task.callback(false, error_msg)
          end
        end
      end

      process_queue()
    end,
    { timeout_ms = 5000 }
  )
end

--- 将保存任务加入队列
--- @param type string 任务类型（"full", "incremental"）
--- @param content string 序列化后的内容
--- @param callback function|nil 完成回调 (success, error_msg)
--- @return number 任务ID
function M.enqueue_save(type, content, callback)
  state._queue_counter = state._queue_counter + 1
  local task = {
    id = state._queue_counter,
    type = type,
    content = content,
    callback = callback,
    retry_count = 0,
    enqueued_at = os.time(),
  }
  table.insert(state._write_queue, task)

  if not state._write_in_progress then
    process_queue()
  end

  return task.id
end

--- 清空等待中的写入队列
--- @return number 被清空的任务数
function M.flush_queue()
  local count = #state._write_queue
  state._write_queue = {}
  return count
end

--- 同步保存（紧急情况使用，如 VimLeavePre）
--- @param sessions table 会话表
--- @return boolean, string|nil
function M.sync_save(sessions)
  local content = M.serialize(sessions)
  if not content then
    return false, "序列化失败"
  end

  local filepath = M.get_filepath()
  ensure_dir(filepath)

  local ok, err = write_file_sync(filepath, content)
  if not ok then
    local lines = vim.split(content, "\n")
    vim.fn.writefile(lines, filepath)
    return true, nil
  end

  return true, nil
end

-- ========== 防抖保存 ==========

--- 防抖保存（高频更新时使用）
--- @param sessions_func function 获取最新会话数据的函数
--- @param debounce_ms number|nil 防抖间隔（毫秒），默认 800ms
function M.debounced_save(sessions_func, debounce_ms)
  if state._is_shutting_down then return end

  debounce_ms = debounce_ms or 800

  if state._debounce_active then
    if state._debounce_timer and not state._debounce_timer:is_closing() then
      state._debounce_timer:again()
    end
    return
  end

  if not state._debounce_timer or state._debounce_timer:is_closing() then
    state._debounce_timer = vim.loop.new_timer()
  end

  state._debounce_active = true
  state._debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(function()
    state._debounce_active = false
    if state._debounce_timer and not state._debounce_timer:is_closing() then
      state._debounce_timer:stop()
    end

    local sessions = sessions_func()
    local content = M.serialize(sessions)
    if content then
      M.enqueue_save("debounced", content)
    end
  end))
end

-- ========== 初始化与清理 ==========

function M.initialize(options)
  if state.initialized then return end
  options = options or {}
  state.config = vim.deepcopy(options.config or options or {})
  if state.config.session and type(state.config.session) == "table" then
    for k, v in pairs(state.config.session) do
      state.config[k] = v
    end
    state.config.session = nil
  end

  local save_path = state.config.save_path
  if not save_path or save_path == "" then
    save_path = vim.fn.stdpath("cache") .. "/NeoAI"
  end
  state.save_path = save_path
  state.initialized = true

  logger.debug("[history_persistence] 初始化完成, save_path=" .. state.save_path)
end

--- 检查是否已初始化
--- @return boolean
function M.is_initialized()
  return state.initialized
end

--- 设置关闭标志
function M.set_shutting_down()
  state._is_shutting_down = true
end

--- 检查是否正在关闭
function M.is_shutting_down()
  return state._is_shutting_down
end

--- 重置（测试用）
function M._test_reset()
  state.initialized = false
  state.config = nil
  state.save_path = nil
  state._write_queue = {}
  state._write_in_progress = false
  state._queue_counter = 0
  state._is_shutting_down = false
  state._line_map = {}
  state._file_line_count = 0
  state._sessions_cache = {}
  if state._debounce_timer and not state._debounce_timer:is_closing() then
    state._debounce_timer:stop()
    state._debounce_timer:close()
  end
  state._debounce_timer = nil
  state._debounce_active = false
end

return M
