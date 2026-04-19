local M = {}

--- 获取文件工具
--- @return table 工具列表
function M.get_tools()
  return {
    {
      name = "ensure_dir",
      description = "确保目录存在，如果不存在则创建",
      func = M.ensure_dir,
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "目录路径",
          },
          parents = {
            type = "boolean",
            description = "是否创建父目录",
            default = true,
          },
        },
        required = { "path" },
      },
      returns = {
        type = "boolean",
        description = "是否成功",
      },
      category = "file",
      permissions = {
        write = true,
      },
    },
  }
end

--- 确保目录存在
--- @param args table|nil 参数
--- @return boolean 是否成功
function M.ensure_dir(args)
  if not args or not args.path then
    return false
  end

  local path = args.path
  local parents = args.parents ~= false -- 默认为true

  -- 移除末尾的斜杠
  path = path:gsub("/+$", "")

  -- 检查目录是否已存在
  local cmd = '[ -d "' .. path .. '" ] && echo "exists"'
  local handle = io.popen(cmd)
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result:find("exists") then
      return true
    end
  end

  -- 创建目录
  local mkdir_cmd
  if parents then
    mkdir_cmd = 'mkdir -p "' .. path .. '" 2>/dev/null'
  else
    mkdir_cmd = 'mkdir "' .. path .. '" 2>/dev/null'
  end

  local result = os.execute(mkdir_cmd)
  return result == 0 or result == true
end

-- 测试用例
local function test_ensure_dir()
  print("测试 ensure_dir 函数...")

  -- 测试用例1: 无效参数
  local success = M.ensure_dir(nil)
  print("测试无效参数: " .. tostring(success) .. " (应为 false)")

  -- 测试用例2: 路径为空
  success = M.ensure_dir({})
  print("测试空路径: " .. tostring(success) .. " (应为 false)")

  -- 测试用例3: 创建目录（假设在临时目录）
  local test_dir = "/tmp/test_lua_dir"
  success = M.ensure_dir({ path = test_dir })
  print("测试创建目录: " .. tostring(success) .. " (应为 true)")

  -- 清理：删除测试目录（可选）
  os.execute('rmdir "' .. test_dir .. '" 2>/dev/null')

  print("测试完成")
end

-- 只有在直接运行此文件时才执行测试
if arg and arg[0] and arg[0]:match("file_utils_tools") then
  test_ensure_dir()
end

return M
