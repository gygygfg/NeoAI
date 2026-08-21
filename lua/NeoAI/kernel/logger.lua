--- NeoAI 日志系统
--- @module NeoAI.kernel.logger
--- 分级日志，文件输出 + 轮转。级别：DEBUG < INFO < WARN < ERROR < FATAL

local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 私有状态 ==========

local LEVELS = {
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
  FATAL = 5,
}

local state = {
  level = LEVELS.WARN,
  path = nil,
  max_size = 10485760,
  max_backups = 5,
  format = "[{time}] [{level}] {message}",
  enabled = true,
}

-- ========== 私有函数 ==========

local function _now_str()
  local t = os.date("*t")
  return string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function _rotate(path)
  -- 检查大小并轮转备份
  local stat = vim.loop.fs_stat(path)
  if stat and stat.size > state.max_size then
    for i = state.max_backups - 1, 1, -1 do
      local src = path .. "." .. i
      local dst = path .. "." .. (i + 1)
      if fs.exists(src) then
        vim.loop.fs_rename(src, dst)
      end
    end
    if fs.exists(path) then
      vim.loop.fs_rename(path, path .. ".1")
    end
  end
end

local function _write(line)
  if not state.path then return end
  fs.ensure_dir(fs.dirname(state.path))
  _rotate(state.path)
  fs.append_file(state.path, line .. "\n")
end

--- 格式化日志行（printf 风格：message + 变长参数）
local function _format(message, ...)
  local args = { ... }
  if #args > 0 then
    local n = 1
    message = (message:gsub("%%([sdqf%s])", function(spec)
      local v = args[n]
      n = n + 1
      if v == nil then return tostring(spec) end
      if spec == "s" then return tostring(v) end
      if spec == "d" then return tostring(v) end
      if spec == "q" then return string.format("%q", v) end
      if spec == "f" then return tostring(v) end
      return " " .. tostring(v)
    end))
  end
  return message
end

local function _log(level_name, message, ...)
  if not state.enabled then return end
  local lvl = LEVELS[level_name] or LEVELS.INFO
  if lvl < state.level then return end
  local line = state.format
    :gsub("%{time%}", _now_str())
    :gsub("%{level%}", level_name)
    :gsub("%{message%}", _format(message, ...))
  _write(line)
  if state.print_debug or lvl >= LEVELS.ERROR then
    vim.notify("[NeoAI] " .. line, vim.log.levels[lvl == LEVELS.FATAL and "ERROR" or level_name] or vim.log.levels.INFO)
  end
end

-- ========== 初始化 ==========

--- 初始化日志
--- @param config table|nil
function M.init(config)
  config = config or {}
  state.level = LEVELS[config.level] or LEVELS.WARN
  state.path = config.path
  state.max_size = config.max_size or 10485760
  state.max_backups = config.max_backups or 5
  state.format = config.format or "[{time}] [{level}] {message}"
  state.print_debug = config.print_debug or false
  state.enabled = true
  if state.path then
    fs.ensure_dir(fs.dirname(state.path))
  end
  return M
end

-- ========== 公开 API ==========

function M.debug(message, ...) _log("DEBUG", message, ...) end
function M.info(message, ...) _log("INFO", message, ...) end
function M.warn(message, ...) _log("WARN", message, ...) end
function M.error(message, ...) _log("ERROR", message, ...) end
function M.fatal(message, ...) _log("FATAL", message, ...) end

--- 获取当前日志级别名
--- @return string
function M.get_level()
  for name, lvl in pairs(LEVELS) do
    if lvl == state.level then return name end
  end
  return "WARN"
end

--- 设置日志级别
--- @param level string|number
function M.set_level(level)
  if type(level) == "string" and LEVELS[level] then
    state.level = LEVELS[level]
  elseif type(level) == "number" then
    state.level = level
  end
end

--- 暂停日志
function M.disable()
  state.enabled = false
end

--- 恢复日志
function M.enable()
  state.enabled = true
end

--- 获取日志路径
--- @return string|nil
function M.get_path()
  return state.path
end

return M
