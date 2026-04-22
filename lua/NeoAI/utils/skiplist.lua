---@module "NeoAI.utils.skiplist"
--- 跳表（Skip List）实现
--- 支持按 key 排序的 O(log n) 插入、查找、删除和范围查询
---
--- 使用方式:
---   local SkipList = require("NeoAI.utils.skiplist")
---   local list = SkipList:new({ max_level = 16, probability = 0.5 })
---   list:insert(100, { id = "msg_1", content = "hello" })
---   local val = list:search(100)
---   local results = list:range(50, 200)

local M = {}

--- 默认最大层级
local DEFAULT_MAX_LEVEL = 16
--- 默认晋升概率
local DEFAULT_PROBABILITY = 0.5

--- 创建跳表节点
--- @param key number 键（时间戳或序号）
--- @param value any 值
--- @param level number 节点层级
--- @return table 节点
local function create_node(key, value, level)
  return {
    key = key,
    value = value,
    forward = {}, -- forward[1..level] 前向指针
    level = level,
  }
end

--- 随机生成层级
--- @param max_level number 最大层级
--- @param probability number 晋升概率
--- @return number 层级
local function random_level(max_level, probability)
  local level = 1
  while level < max_level and math.random() < probability do
    level = level + 1
  end
  return level
end

--- 创建一个新的跳表
--- @param opts table|nil 可选参数
---   - max_level: number 最大层级（默认 16）
---   - probability: number 晋升概率（默认 0.5）
---   - unique: boolean 是否允许重复 key（默认 true，允许重复）
--- @return table 跳表实例
function M:new(opts)
  opts = opts or {}
  local max_level = opts.max_level or DEFAULT_MAX_LEVEL
  local probability = opts.probability or DEFAULT_PROBABILITY
  local unique = opts.unique ~= false -- 默认允许重复

  local list = {
    max_level = max_level,
    probability = probability,
    unique = unique,
    level = 1, -- 当前最高层级
    size = 0,  -- 节点数量
    header = create_node(-math.huge, nil, max_level),
    tail = create_node(math.huge, nil, max_level),
  }

  -- 初始化 header 的所有 forward 指向 tail
  for i = 1, max_level do
    list.header.forward[i] = list.tail
  end

  setmetatable(list, self)
  self.__index = self

  return list
end

--- 插入节点
--- 如果 unique=true 且 key 已存在，则覆盖旧值
--- @param key number 键
--- @param value any 值
--- @return boolean 是否成功插入（unique=false 时始终返回 true）
function M:insert(key, value)
  local update = {} -- update[i] = 第 i 层需要更新的节点
  local current = self.header

  -- 从最高层开始查找插入位置
  for i = self.level, 1, -1 do
    while current.forward[i] and current.forward[i].key < key do
      current = current.forward[i]
    end
    update[i] = current
  end

  -- 到达底层，检查是否已存在
  current = current.forward[1]

  if self.unique and current and current.key == key then
    -- 覆盖旧值
    current.value = value
    return true
  end

  -- 生成新节点的层级
  local new_level = random_level(self.max_level, self.probability)

  if new_level > self.level then
    -- 补充 update 数组
    for i = self.level + 1, new_level do
      update[i] = self.header
    end
    self.level = new_level
  end

  -- 创建新节点
  local new_node = create_node(key, value, new_level)

  -- 插入节点
  for i = 1, new_level do
    new_node.forward[i] = update[i].forward[i]
    update[i].forward[i] = new_node
  end

  self.size = self.size + 1
  return true
end

--- 搜索指定 key 的节点
--- @param key number 键
--- @return any|nil 找到的值，未找到返回 nil
function M:search(key)
  local current = self.header

  -- 从最高层开始查找
  for i = self.level, 1, -1 do
    while current.forward[i] and current.forward[i].key < key do
      current = current.forward[i]
    end
  end

  -- 到达底层
  current = current.forward[1]

  if current and current.key == key then
    return current.value
  end

  return nil
end

--- 删除指定 key 的节点
--- @param key number 键
--- @return boolean 是否删除成功
function M:delete(key)
  local update = {}
  local current = self.header

  -- 查找要删除的节点
  for i = self.level, 1, -1 do
    while current.forward[i] and current.forward[i].key < key do
      current = current.forward[i]
    end
    update[i] = current
  end

  current = current.forward[1]

  if not current or current.key ~= key then
    return false
  end

  -- 删除节点
  for i = 1, self.level do
    if update[i].forward[i] ~= current then
      break
    end
    update[i].forward[i] = current.forward[i]
  end

  -- 更新跳表层数
  while self.level > 1 and self.header.forward[self.level] == self.tail do
    self.level = self.level - 1
  end

  self.size = self.size - 1
  return true
end

--- 范围查询：获取 key 在 [min_key, max_key] 范围内的所有值
--- @param min_key number 最小 key（包含）
--- @param max_key number 最大 key（包含）
--- @param opts table|nil 可选参数
---   - limit: number 最大返回数量
---   - reverse: boolean 是否逆序返回
--- @return table 值列表
function M:range(min_key, max_key, opts)
  opts = opts or {}
  local limit = opts.limit or math.huge
  local reverse = opts.reverse or false

  local result = {}
  local current = self.header

  -- 找到第一个 >= min_key 的节点
  for i = self.level, 1, -1 do
    while current.forward[i] and current.forward[i].key < min_key do
      current = current.forward[i]
    end
  end

  current = current.forward[1]

  if reverse then
    -- 逆序：先收集所有符合条件的节点，再反转
    local temp = {}
    while current and current ~= self.tail and current.key <= max_key do
      table.insert(temp, current.value)
      current = current.forward[1]
    end
    -- 反转并截取
    for i = #temp, math.max(1, #temp - limit + 1), -1 do
      table.insert(result, temp[i])
    end
  else
    -- 正序
    local count = 0
    while current and current ~= self.tail and current.key <= max_key and count < limit do
      table.insert(result, current.value)
      count = count + 1
      current = current.forward[1]
    end
  end

  return result
end

--- 获取所有节点（按 key 排序）
--- @param reverse boolean|nil 是否逆序
--- @return table 值列表
function M:all(reverse)
  return self:range(-math.huge, math.huge, {
    reverse = reverse or false,
  })
end

--- 获取第一个节点
--- @return any|nil 第一个值
function M:first()
  local node = self.header.forward[1]
  if node and node ~= self.tail then
    return node.value
  end
  return nil
end

--- 获取最后一个节点
--- @return any|nil 最后一个值
function M:last()
  local current = self.header
  for i = self.level, 1, -1 do
    while current.forward[i] and current.forward[i] ~= self.tail do
      current = current.forward[i]
    end
  end
  if current ~= self.header then
    return current.value
  end
  return nil
end

--- 获取节点数量
--- @return number 节点数量
function M:get_size()
  return self.size
end

--- 清空跳表
function M:clear()
  for i = 1, self.max_level do
    self.header.forward[i] = self.tail
  end
  self.level = 1
  self.size = 0
end

--- 检查是否为空
--- @return boolean
function M:is_empty()
  return self.size == 0
end

--- 遍历所有节点（迭代器）
--- @param reverse boolean|nil 是否逆序遍历
--- @return function 迭代器函数
function M:iter(reverse)
  if reverse then
    -- 逆序遍历：先收集所有节点
    local nodes = {}
    local current = self.header.forward[1]
    while current and current ~= self.tail do
      table.insert(nodes, { key = current.key, value = current.value })
      current = current.forward[1]
    end
    local i = #nodes
    return function()
      if i < 1 then return nil end
      local node = nodes[i]
      i = i - 1
      return node.key, node.value
    end
  else
    local current = self.header.forward[1]
    return function()
      if not current or current == self.tail then return nil end
      local key, value = current.key, current.value
      current = current.forward[1]
      return key, value
    end
  end
end

--- 转换为 Lua 表（用于序列化）
--- @return table { keys = number[], values = any[] }
function M:to_table()
  local keys = {}
  local values = {}
  local current = self.header.forward[1]
  while current and current ~= self.tail do
    table.insert(keys, current.key)
    table.insert(values, current.value)
    current = current.forward[1]
  end
  return { keys = keys, values = values }
end

--- 从 Lua 表恢复跳表
--- @param data table { keys = number[], values = any[] }
--- @param opts table|nil 可选参数（同 new）
--- @return table 跳表实例
function M.from_table(data, opts)
  local list = M:new(opts)
  if data and data.keys and data.values then
    for i = 1, #data.keys do
      list:insert(data.keys[i], data.values[i])
    end
  end
  return list
end

return M
