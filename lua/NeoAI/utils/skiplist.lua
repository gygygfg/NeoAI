---@module "NeoAI.utils.skiplist"
--- 跳表（Skip List）实现
---
--- 核心思想：多层链表，不同层级（forward[i]）代表不同"方向"
---   - forward[1]: 底层方向，连接所有节点（完整有序链表）
---   - forward[2]: 第2层方向，跳过部分节点（快速通道）
---   - forward[N]: 第N层方向，跳过更多节点（高速通道）
---
--- 每个节点有多个 forward 指针，指向不同层级的后继节点。
--- 层级越高，跳过的节点越多，查询越快。
---
--- 使用方式:
---   local SkipList = require("NeoAI.utils.skiplist")
---   local list = SkipList:new({ max_level = 16, probability = 0.5 })
---   list:insert(100, { id = "msg_1", content = "hello" })
---   local val = list:search(100)
---   local results = list:range(50, 200)

local M = {}

local DEFAULT_MAX_LEVEL = 16
local DEFAULT_PROBABILITY = 0.5

--- 创建跳表节点
--- @param key number 键
--- @param value any 值
--- @param level number 节点层级（forward 指针数量）
--- @return table 节点
local function create_node(key, value, level)
  return {
    key = key,
    value = value,
    -- forward[i] 是第 i 层方向上的下一个节点
    -- forward[1] = 底层方向（连接所有节点）
    -- forward[2] = 第2层方向（跳过部分节点）
    -- forward[level] = 最高层方向（跳过最多节点）
    forward = {},
    level = level,
  }
end

--- 随机生成节点层级（决定该节点有多少个 forward 方向）
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
---   - unique: boolean 是否允许重复 key（默认 true）
--- @return table 跳表实例
function M:new(opts)
  opts = opts or {}
  local max_level = opts.max_level or DEFAULT_MAX_LEVEL
  local probability = opts.probability or DEFAULT_PROBABILITY
  local unique = opts.unique ~= false

  local list = {
    max_level = max_level,
    probability = probability,
    unique = unique,
    level = 1,  -- 当前最高层级（当前有多少个方向可用）
    size = 0,   -- 节点数量
    header = create_node(-math.huge, nil, max_level),
    tail = create_node(math.huge, nil, max_level),
  }

  -- 头节点的所有方向都指向尾节点
  for i = 1, max_level do
    list.header.forward[i] = list.tail
  end

  setmetatable(list, self)
  self.__index = self

  return list
end

--- 插入节点
--- 从最高层方向开始查找，逐层下降，记录每层需要更新的节点
--- @param key number 键
--- @param value any 值
--- @return boolean
function M:insert(key, value)
  -- update[i] = 在第 i 层方向上，新节点应该插入在 update[i] 之后
  local update = {}
  local current = self.header

  -- 从最高层方向开始，逐层向下查找插入位置
  for i = self.level, 1, -1 do
    -- 在当前方向上，一直向前直到遇到更大的 key
    while current.forward[i] and current.forward[i].key < key do
      current = current.forward[i]
    end
    -- 记录第 i 层方向上需要更新的节点
    update[i] = current
  end

  -- 到达底层方向（forward[1]），检查是否已存在
  current = current.forward[1]

  if self.unique and current and current.key == key then
    current.value = value
    return true
  end

  -- 随机决定新节点有多少个 forward 方向
  local new_level = random_level(self.max_level, self.probability)

  if new_level > self.level then
    -- 新节点比当前最高层还高，补充 update 数组
    for i = self.level + 1, new_level do
      update[i] = self.header
    end
    self.level = new_level
  end

  local new_node = create_node(key, value, new_level)

  -- 在每一层方向上插入新节点
  for i = 1, new_level do
    new_node.forward[i] = update[i].forward[i]
    update[i].forward[i] = new_node
  end

  self.size = self.size + 1
  return true
end

--- 搜索指定 key 的节点
--- 从最高层方向开始，快速跳过不需要的节点
--- @param key number 键
--- @return any|nil
function M:search(key)
  local current = self.header

  -- 从最高层方向开始查找，逐层下降
  for i = self.level, 1, -1 do
    while current.forward[i] and current.forward[i].key < key do
      current = current.forward[i]
    end
  end

  -- 到达底层方向，检查目标节点
  current = current.forward[1]

  if current and current.key == key then
    return current.value
  end

  return nil
end

--- 删除指定 key 的节点
--- @param key number 键
--- @return boolean
function M:delete(key)
  local update = {}
  local current = self.header

  -- 从最高层方向开始，记录每层需要更新的节点
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

  -- 在每一层方向上跳过被删除的节点
  for i = 1, self.level do
    if update[i].forward[i] ~= current then
      break
    end
    update[i].forward[i] = current.forward[i]
  end

  -- 降低跳表层数（如果最高层方向已空）
  while self.level > 1 and self.header.forward[self.level] == self.tail do
    self.level = self.level - 1
  end

  self.size = self.size - 1
  return true
end

--- 范围查询：获取 key 在 [min_key, max_key] 范围内的所有值
--- 利用高层方向快速定位起点，然后沿底层方向遍历
--- @param min_key number 最小 key（包含）
--- @param max_key number 最大 key（包含）
--- @param opts table|nil
---   - limit: number 最大返回数量
---   - reverse: boolean 是否逆序
--- @return table 值列表
function M:range(min_key, max_key, opts)
  opts = opts or {}
  local limit = opts.limit or math.huge
  local reverse = opts.reverse or false

  local result = {}
  local current = self.header

  -- 从最高层方向快速定位到 >= min_key 的位置
  for i = self.level, 1, -1 do
    while current.forward[i] and current.forward[i].key < min_key do
      current = current.forward[i]
    end
  end

  current = current.forward[1]

  if reverse then
    -- 先沿底层方向收集所有符合条件的节点
    local temp = {}
    while current and current ~= self.tail and current.key <= max_key do
      table.insert(temp, current.value)
      current = current.forward[1]
    end
    -- 反转截取
    for i = #temp, math.max(1, #temp - limit + 1), -1 do
      table.insert(result, temp[i])
    end
  else
    local count = 0
    while current and current ~= self.tail and current.key <= max_key and count < limit do
      table.insert(result, current.value)
      count = count + 1
      current = current.forward[1]
    end
  end

  return result
end

--- 获取所有节点
--- @param reverse boolean|nil 是否逆序
--- @return table 值列表
function M:all(reverse)
  return self:range(-math.huge, math.huge, {
    reverse = reverse or false,
  })
end

--- 获取第一个节点（底层方向第一个）
--- @return any|nil
function M:first()
  local node = self.header.forward[1]
  if node and node ~= self.tail then
    return node.value
  end
  return nil
end

--- 获取最后一个节点（沿最高层方向快速定位）
--- @return any|nil
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
--- @return number
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
--- 沿底层方向（forward[1]）遍历，保证有序
--- @param reverse boolean|nil 是否逆序遍历
--- @return function 迭代器函数 (key, value)
function M:iter(reverse)
  if reverse then
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
