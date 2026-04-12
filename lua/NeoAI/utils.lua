-- NeoAI 工具函数
local M = {}

function M.ensure_dir(dir)
  -- 确保目录存在，不存在则创建
  if dir == nil then
    return false
  end
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
    return true
  end
  return false
end

function M.deep_extend(defaults, overrides)
  -- 深度合并两个表
  local result = vim.deepcopy(defaults)
  for key, value in pairs(overrides) do
    if type(value) == "table" and type(result[key]) == "table" then
      result[key] = M.deep_extend(result[key], value)
    else
      result[key] = value
    end
  end
  return result
end

function M.format_timestamp(timestamp)
  -- 格式化时间戳为可读字符串
  return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

function M.format_time(timestamp)
  -- 格式化时间戳为短时间
  return os.date("%H:%M", timestamp)
end

function M.generate_id()
  -- 生成简单唯一ID
  return os.time() .. math.random(1000, 9999)
end

function M.truncate(str, max_length)
  -- 截断字符串到最大长度
  if #str <= max_length then
    return str
  end
  return str:sub(1, max_length - 3) .. "..."
end

function M.split_lines(str)
  -- 按换行符分割字符串
  local lines = {}
  for line in str:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end

function M.join_lines(lines)
  -- 用换行符连接行
  return table.concat(lines, "\n")
end

function M.escape_special_chars(str)
  -- 转义特殊字符用于显示
  return str:gsub("[\r\n\t]", {
    ["\r"] = "\\r",
    ["\n"] = "\\n",
    ["\t"] = "\\t",
  })
end

function M.is_neovim()
  -- 检查是否在 Neovim 中运行
  return vim.fn.has("nvim") == 1
end

function M.get_config_path()
  -- 获取配置路径
  return vim.fn.stdpath("config")
end

function M.get_data_path()
  -- 获取数据路径
  return vim.fn.stdpath("data")
end

return M
