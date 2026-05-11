-- NeoAI 自动 Git 管理模块
-- 监听工具执行事件，自动暂存和提交文件更改
-- 提供 git diff/log/rollback 等功能的伪 Git 实现

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")

-- ========== 状态 ==========

local state = {
  initialized = false,
  git_available = nil, -- nil=未检测, true/false
  git_root = nil,
  auto_commit_enabled = true,
  last_commit_hash = nil,
  -- 伪 Git 模式（无真实 git 时使用）
  pseudo = {
    enabled = false,
    snapshots = {}, -- { hash, timestamp, message, files: {filepath: content} }
    current_snapshot = {}, -- filepath -> content (当前工作区状态)
    snapshot_dir = nil, -- 快照存储目录
  },
  -- 监听器注册信息
  listeners = {},
}

-- ========== Git 环境检测 ==========

--- 检测 git 是否可用
function M._check_git()
  local ok = pcall(vim.fn.system, "git --version 2>/dev/null")
  if vim.v.shell_error == 0 then
    state.git_available = true
    -- 获取 git 根目录
    local root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("%s+$", "")
    if vim.v.shell_error == 0 and root ~= "" then
      state.git_root = root
    else
      state.git_root = vim.fn.getcwd()
    end
    return true
  end
  state.git_available = false
  state.git_root = vim.fn.getcwd()
  return false
end

--- 初始化伪 Git 模式
function M._init_pseudo()
  if state.pseudo.enabled then
    return
  end
  state.pseudo.enabled = true
  state.pseudo.snapshot_dir = vim.fn.stdpath("cache") .. "/neoai_git_snapshots"
  vim.fn.mkdir(state.pseudo.snapshot_dir, "p")

  -- 加载已有快照索引
  local index_file = state.pseudo.snapshot_dir .. "/index.json"
  local fd = vim.uv.fs_open(index_file, "r", 438)
  if fd then
    local stat = vim.uv.fs_fstat(fd)
    if stat and stat.size > 0 then
      local data = vim.uv.fs_read(fd, stat.size, 0)
      vim.uv.fs_close(fd)
      if data then
        local ok, parsed = pcall(vim.json.decode, data)
        if ok and type(parsed) == "table" then
          state.pseudo.snapshots = parsed.snapshots or {}
          state.pseudo.current_snapshot = parsed.current or {}
        end
      end
    else
      vim.uv.fs_close(fd)
    end
  end

  -- 扫描工作目录，建立初始快照
  M._scan_workspace_for_pseudo()
end

--- 扫描工作目录建立伪 Git 快照
-- 使用 vim.uv 异步扫描，避免阻塞
-- 跳过隐藏目录、node_modules、.git 等大目录
local SKIP_DIRS = {
  [".git"] = true,
  ["node_modules"] = true,
  [".venv"] = true,
  ["venv"] = true,
  ["__pycache__"] = true,
  [".cache"] = true,
  ["dist"] = true,
  ["build"] = true,
  [".next"] = true,
  ["target"] = true,
}

function M._scan_workspace_for_pseudo()
  local root = state.git_root or vim.fn.getcwd()
  local scanned_count = 0
  local max_files = 500 -- 最多扫描 500 个文件

  local function scan_dir(dir, callback)
    vim.uv.fs_scandir(dir, function(err, handle)
      if err or not handle then
        if callback then callback() end
        return
      end

      local function read_next()
        if scanned_count >= max_files then
          vim.uv.fs_closedir(handle)
          if callback then callback() end
          return
        end
        vim.uv.fs_readdir(handle, function(read_err, entries)
          if read_err or not entries then
            vim.uv.fs_closedir(handle)
            if callback then callback() end
            return
          end
          local pending = 0
          for _, entry in ipairs(entries) do
            local name = entry.name
            local full = dir .. "/" .. name
            -- 跳过隐藏目录和常见非代码目录
            if name:sub(1, 1) == "." or SKIP_DIRS[name] then
              goto continue
            end
            if entry.type == "file" then
              scanned_count = scanned_count + 1
              if scanned_count <= max_files then
                local fd = vim.uv.fs_open(full, "r", 438)
                if fd then
                  local stat = vim.uv.fs_fstat(fd)
                  if stat and stat.size > 0 and stat.size < 1048576 then
                    local content = vim.uv.fs_read(fd, stat.size, 0)
                    if content then
                      state.pseudo.current_snapshot[full] = content
                    end
                  end
                  vim.uv.fs_close(fd)
                end
              end
            elseif entry.type == "directory" then
              pending = pending + 1
              scan_dir(full, function()
                pending = pending - 1
                if pending <= 0 then
                  read_next()
                end
              end)
            end
            ::continue::
          end
          if pending <= 0 then
            read_next()
          end
        end)
      end
      read_next()
    end)
  end

  scan_dir(root)
end

--- 保存伪 Git 快照索引
function M._save_pseudo_index()
  local index_file = state.pseudo.snapshot_dir .. "/index.json"
  local data = vim.json.encode({
    snapshots = state.pseudo.snapshots,
    current = state.pseudo.current_snapshot,
  })
  local fd = vim.uv.fs_open(index_file, "w", 438)
  if fd then
    vim.uv.fs_write(fd, data, 0)
    vim.uv.fs_close(fd)
  end
end

-- ========== 文件变更检测 ==========

--- 获取文件的当前内容
function M._get_file_content(filepath)
  local fd = vim.uv.fs_open(filepath, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil
  end
  local content = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return content
end

--- 检测文件是否被更改（对比伪 Git 快照）
function M._is_file_changed_pseudo(filepath)
  local old_content = state.pseudo.current_snapshot[filepath]
  local new_content = M._get_file_content(filepath)
  if old_content == nil and new_content == nil then
    return false
  end
  if old_content == nil or new_content == nil then
    return true
  end
  return old_content ~= new_content
end

--- 检测文件是否被更改（对比真实 git）
function M._is_file_changed_git(filepath)
  if not state.git_root then
    return false
  end
  -- 检查文件是否在 git 跟踪中
  local rel_path = filepath:sub(#state.git_root + 2)
  local status = vim.fn.system(string.format("git -C %s status --porcelain %s 2>/dev/null", state.git_root, rel_path))
  if vim.v.shell_error ~= 0 then
    return false
  end
  -- 非空输出表示有变更
  return status:gsub("%s+$", "") ~= ""
end

--- 判断工具调用是否修改了文件
--- @param tool_name string 工具名称
--- @param args table 工具参数
--- @return boolean, string|nil 是否修改了文件, 被修改的文件路径
function M._is_file_modifying_tool(tool_name, args)
  local modifying_tools = {
    edit_file = true,
    create_file = true,
    delete_file = true,
    write_file = true,
    insert_edit_into_file = true,
  }
  if not modifying_tools[tool_name] then
    return false, nil
  end
  if not args then
    return false, nil
  end
  local filepath = args.filepath or args.file or args.path
  if not filepath or type(filepath) ~= "string" then
    return false, nil
  end
  return true, filepath
end

-- ========== Git 操作（真实 git） ==========

--- 执行 git add
function M._git_add(filepath)
  if not state.git_available or not state.git_root then
    return false, "git 不可用"
  end
  local rel_path = filepath:sub(#state.git_root + 2)
  vim.fn.system(string.format("git -C %s add %s 2>/dev/null", state.git_root, rel_path))
  if vim.v.shell_error ~= 0 then
    return false, "git add 失败"
  end
  return true, nil
end

--- 执行 git commit
function M._git_commit(message)
  if not state.git_available or not state.git_root then
    return false, "git 不可用"
  end
  local escaped_msg = message:gsub("'", "'\\''")
  vim.fn.system(string.format("git -C %s commit -m '%s' 2>/dev/null", state.git_root, escaped_msg))
  if vim.v.shell_error ~= 0 then
    return false, "git commit 失败"
  end
  -- 获取最新 commit hash
  local hash = vim.fn.system("git -C " .. state.git_root .. " rev-parse HEAD 2>/dev/null"):gsub("%s+$", "")
  state.last_commit_hash = hash
  return true, hash
end

--- 获取 git diff
function M._git_diff(filepath)
  if not state.git_available or not state.git_root then
    return nil
  end
  local rel_path = filepath and filepath:sub(#state.git_root + 2) or ""
  local cmd
  if rel_path and rel_path ~= "" then
    cmd = string.format("git -C %s diff -- %s 2>/dev/null", state.git_root, rel_path)
  else
    cmd = string.format("git -C %s diff 2>/dev/null", state.git_root)
  end
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

--- 获取 git log
function M._git_log(max_count)
  max_count = max_count or 20
  local cmd = string.format("git -C %s log --oneline --abbrev-commit -%d 2>/dev/null", state.git_root, max_count)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

--- 获取 git show
function M._git_show(commit_hash)
  local cmd = string.format("git -C %s show --stat --format='%%H%%n%%s%%n%%ai%%n%%an' %s 2>/dev/null", state.git_root, commit_hash)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

--- 执行 git checkout（回滚文件）
function M._git_checkout(filepath_or_commit)
  local cmd
  if state.pseudo.enabled then
    return false, "伪 Git 模式不支持 git checkout"
  end
  cmd = string.format("git -C %s checkout %s 2>/dev/null", state.git_root, filepath_or_commit)
  vim.fn.system(cmd)
  return vim.v.shell_error == 0, vim.v.shell_error ~= 0 and "git checkout 失败" or nil
end

--- 执行 git reset
function M._git_reset(commit_hash, mode)
  mode = mode or "soft"
  local cmd = string.format("git -C %s reset --%s %s 2>/dev/null", state.git_root, mode, commit_hash)
  vim.fn.system(cmd)
  return vim.v.shell_error == 0, vim.v.shell_error ~= 0 and "git reset 失败" or nil
end

--- 执行 git stash
function M._git_stash()
  local cmd = string.format("git -C %s stash 2>/dev/null", state.git_root)
  vim.fn.system(cmd)
  return vim.v.shell_error == 0, vim.v.shell_error ~= 0 and "git stash 失败" or nil
end

--- 执行 git stash pop
function M._git_stash_pop()
  local cmd = string.format("git -C %s stash pop 2>/dev/null", state.git_root)
  vim.fn.system(cmd)
  return vim.v.shell_error == 0, vim.v.shell_error ~= 0 and "git stash pop 失败" or nil
end

--- 获取 git status
function M._git_status()
  local cmd = string.format("git -C %s status --short 2>/dev/null", state.git_root)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

-- ========== 伪 Git 操作 ==========

--- 生成伪 Git 快照 hash
function M._pseudo_generate_hash()
  local seed = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
  -- 简单的哈希函数
  local hash = 0
  for i = 1, #seed do
    hash = (hash * 31 + seed:byte(i)) % 0xFFFFFFFF
  end
  return string.format("%08x", hash)
end

--- 伪 Git：创建快照
function M._pseudo_commit(message)
  local hash = M._pseudo_generate_hash()
  local snapshot = {
    hash = hash,
    timestamp = os.time(),
    message = message,
    files = {},
  }

  -- 记录当前所有文件的快照
  for filepath, content in pairs(state.pseudo.current_snapshot) do
    snapshot.files[filepath] = content
  end

  table.insert(state.pseudo.snapshots, snapshot)
  M._save_pseudo_index()
  return true, hash
end

--- 伪 Git：获取 diff
function M._pseudo_diff(filepath)
  local lines = {}
  local current = state.pseudo.current_snapshot

  if filepath then
    -- 单文件 diff
    local content = current[filepath] or ""
    table.insert(lines, string.format("--- a/%s", filepath))
    table.insert(lines, string.format("+++ b/%s", filepath))
    local file_lines = vim.split(content, "\n", { plain = true })
    for i, line in ipairs(file_lines) do
      table.insert(lines, string.format(" %s", line))
    end
  else
    -- 全量 diff（显示所有跟踪文件）
    for fp, content in pairs(current) do
      table.insert(lines, string.format("--- a/%s", fp))
      table.insert(lines, string.format("+++ b/%s", fp))
      local file_lines = vim.split(content, "\n", { plain = true })
      for _, line in ipairs(file_lines) do
        table.insert(lines, string.format(" %s", line))
      end
    end
  end

  return table.concat(lines, "\n")
end

--- 伪 Git：获取 log
function M._pseudo_log(max_count)
  max_count = max_count or 20
  local snapshots = state.pseudo.snapshots
  local lines = {}
  local start = math.max(1, #snapshots - max_count + 1)
  for i = #snapshots, start, -1 do
    local s = snapshots[i]
    local date_str = os.date("%Y-%m-%d %H:%M:%S", s.timestamp)
    table.insert(lines, string.format("%s %s (%s)", s.hash:sub(1, 8), s.message, date_str))
  end
  return table.concat(lines, "\n")
end

--- 伪 Git：回滚到指定快照
function M._pseudo_rollback(hash)
  for i, snapshot in ipairs(state.pseudo.snapshots) do
    if snapshot.hash == hash then
      -- 恢复该快照的文件内容
      for filepath, content in pairs(snapshot.files) do
        state.pseudo.current_snapshot[filepath] = content
        -- 写入磁盘
        local dir = filepath:match("^(.*/)[^/]+$")
        if dir then
          vim.fn.mkdir(dir, "p")
        end
        local fd = vim.uv.fs_open(filepath, "w", 438)
        if fd then
          vim.uv.fs_write(fd, content, 0)
          vim.uv.fs_close(fd)
        end
      end
      M._save_pseudo_index()
      return true, nil
    end
  end
  return false, "未找到快照: " .. hash
end

--- 伪 Git：获取状态
function M._pseudo_status()
  local lines = {}
  local has_changes = false
  for filepath, content in pairs(state.pseudo.current_snapshot) do
    -- 检查文件是否仍然存在且内容一致
    local current = M._get_file_content(filepath)
    if current == nil then
      table.insert(lines, string.format(" D %s", filepath))
      has_changes = true
    elseif current ~= content then
      table.insert(lines, string.format(" M %s", filepath))
      has_changes = true
    end
  end
  if not has_changes then
    return "无变更"
  end
  return table.concat(lines, "\n")
end

--- 伪 Git：获取文件历史
function M._pseudo_file_history(filepath)
  local lines = {}
  for i = #state.pseudo.snapshots, 1, -1 do
    local s = state.pseudo.snapshots[i]
    if s.files[filepath] ~= nil then
      local date_str = os.date("%Y-%m-%d %H:%M:%S", s.timestamp)
      table.insert(lines, string.format("%s %s (%s)", s.hash:sub(1, 8), s.message, date_str))
    end
  end
  if #lines == 0 then
    return "文件无历史记录: " .. filepath
  end
  return table.concat(lines, "\n")
end

-- ========== 核心：自动暂存和提交 ==========

--- 生成提交信息
function M._generate_commit_message(tool_name, filepath)
  local filename = filepath:match("([^/]+)$") or filepath
  local tool_labels = {
    edit_file = "编辑",
    create_file = "创建",
    delete_file = "删除",
    write_file = "写入",
    insert_edit_into_file = "编辑",
  }
  local action = tool_labels[tool_name] or "修改"
  return string.format("[NeoAI] %s %s", action, filename)
end

--- 自动暂存并提交文件更改
--- @param tool_name string 工具名称
--- @param filepath string 被修改的文件路径
--- @param args table 工具参数
function M._auto_stage_and_commit(tool_name, filepath, args)
  if not state.auto_commit_enabled then
    return
  end

  local message = M._generate_commit_message(tool_name, filepath)

  if state.git_available then
    -- 真实 git 模式
    local add_ok, add_err = M._git_add(filepath)
    if not add_ok then
      logger.warn("[git_auto] git add 失败: %s", add_err)
      return
    end
    local commit_ok, commit_result = M._git_commit(message)
    if commit_ok then
      logger.info("[git_auto] 自动提交成功: %s (%s)", message, commit_result)
    else
      logger.warn("[git_auto] git commit 失败: %s", commit_result)
    end
  elseif state.pseudo.enabled then
    -- 伪 Git 模式：更新快照
    local content = M._get_file_content(filepath)
    if content then
      state.pseudo.current_snapshot[filepath] = content
    else
      state.pseudo.current_snapshot[filepath] = nil
    end
    local commit_ok, commit_result = M._pseudo_commit(message)
    if commit_ok then
      logger.info("[git_auto] 伪 Git 自动提交成功: %s (%s)", message, commit_result)
    end
  end
end

--- 工具执行完成回调
function M._on_tool_executed(event_data)
  if not event_data then
    return
  end

  local tool_name = event_data.tool_name
  local args = event_data.args
  local result = event_data.result

  -- 检查是否是文件修改工具
  local is_modifying, filepath = M._is_file_modifying_tool(tool_name, args)
  if not is_modifying or not filepath then
    return
  end

  -- 检查执行是否成功（有 result 且没有 error）
  if event_data.error_msg then
    return
  end

  -- 自动暂存并提交
  vim.schedule(function()
    M._auto_stage_and_commit(tool_name, filepath, args)
  end)
end

-- ========== 注册事件监听 ==========

function M._register_listeners()
  if #state.listeners > 0 then
    return
  end

  -- 监听工具执行完成事件
  local group = vim.api.nvim_create_augroup("NeoAIGitAuto", { clear = true })
  local id = vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = event_constants.TOOL_EXECUTION_COMPLETED,
    callback = function(ev)
      M._on_tool_executed(ev.data)
    end,
  })
  table.insert(state.listeners, { group = group, id = id })
end

-- ========== 初始化 ==========

function M.initialize(config)
  if state.initialized then
    return
  end

  config = config or {}
  state.auto_commit_enabled = config.auto_git_commit ~= false

  -- 检测 git 环境
  local has_git = M._check_git()
  if not has_git then
    logger.info("[git_auto] git 不可用，启用伪 Git 模式")
    M._init_pseudo()
  else
    logger.info("[git_auto] git 可用，工作目录: %s", state.git_root)
  end

  -- 注册事件监听
  M._register_listeners()

  state.initialized = true
  logger.info("[git_auto] 初始化完成 (git=%s, auto_commit=%s)", has_git, state.auto_commit_enabled)
end

-- ========== 公共 API（供 git_tools 调用） ==========

--- 获取 diff
--- @param filepath string|nil 可选，指定文件路径
--- @return string|nil
function M.get_diff(filepath)
  if state.git_available then
    return M._git_diff(filepath)
  end
  return M._pseudo_diff(filepath)
end

--- 获取 log
--- @param max_count number|nil 最大条目数
--- @return string|nil
function M.get_log(max_count)
  if state.git_available then
    return M._git_log(max_count)
  end
  return M._pseudo_log(max_count)
end

--- 获取状态
--- @return string
function M.get_status()
  if state.git_available then
    local result = M._git_status()
    return result or "无变更"
  end
  return M._pseudo_status()
end

--- 获取提交详情
--- @param commit_hash string 提交 hash
--- @return string|nil
function M.get_commit_detail(commit_hash)
  if state.git_available then
    return M._git_show(commit_hash)
  end
  -- 伪 Git：查找快照
  for _, s in ipairs(state.pseudo.snapshots) do
    if s.hash == commit_hash then
      local lines = {}
      table.insert(lines, string.format("提交: %s", s.hash))
      table.insert(lines, string.format("时间: %s", os.date("%Y-%m-%d %H:%M:%S", s.timestamp)))
      table.insert(lines, string.format("消息: %s", s.message))
      table.insert(lines, "")
      table.insert(lines, "文件:")
      for fp in pairs(s.files) do
        table.insert(lines, string.format("  %s", fp))
      end
      return table.concat(lines, "\n")
    end
  end
  return nil
end

--- 回滚到指定提交
--- @param commit_hash string 提交 hash
--- @param filepath string|nil 可选，仅回滚指定文件
--- @return boolean, string|nil
function M.rollback(commit_hash, filepath)
  if state.git_available then
    if filepath then
      -- 回滚单个文件
      local ok, err = M._git_checkout(commit_hash .. " -- " .. filepath)
      if ok then
        M._auto_stage_and_commit("rollback", filepath, { filepath = filepath })
      end
      return ok, err
    else
      -- 回滚整个提交
      local ok, err = M._git_reset(commit_hash, "hard")
      return ok, err
    end
  end
  return M._pseudo_rollback(commit_hash)
end

--- 获取文件历史
--- @param filepath string 文件路径
--- @return string
function M.get_file_history(filepath)
  if state.git_available then
    local cmd = string.format("git -C %s log --oneline -- %s 2>/dev/null", state.git_root, filepath)
    local result = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 or result:gsub("%s+$", "") == "" then
      return "文件无历史记录: " .. filepath
    end
    return result
  end
  return M._pseudo_file_history(filepath)
end

--- 获取 git 是否可用
--- @return boolean
function M.is_git_available()
  return state.git_available == true
end

--- 获取 git 根目录
--- @return string|nil
function M.get_git_root()
  return state.git_root
end

--- 获取最近一次提交 hash
--- @return string|nil
function M.get_last_commit_hash()
  if state.git_available then
    local hash = vim.fn.system("git -C " .. state.git_root .. " rev-parse HEAD 2>/dev/null"):gsub("%s+$", "")
    if vim.v.shell_error == 0 and hash ~= "" then
      return hash
    end
    return nil
  end
  local last = state.pseudo.snapshots[#state.pseudo.snapshots]
  return last and last.hash or nil
end

--- 启用/禁用自动提交
--- @param enabled boolean
function M.set_auto_commit(enabled)
  state.auto_commit_enabled = enabled
end

--- 获取自动提交状态
--- @return boolean
function M.is_auto_commit_enabled()
  return state.auto_commit_enabled
end

return M
