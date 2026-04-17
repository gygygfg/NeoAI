local M = {}

-- 分支存储
local branches = {}
local branch_counter = 0
local current_branch_id = nil

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil
}

--- 初始化分支管理器
--- @param options table 选项
function M.initialize(options)
    if state.initialized then
        return
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}
    state.initialized = true
end

--- 创建分支
--- @param parent_id string 父分支ID
--- @param name string 分支名称
--- @return string 分支ID
function M.create_branch(parent_id, name)
    if not state.initialized then
        error("Branch manager not initialized")
    end

    branch_counter = branch_counter + 1
    local branch_id = "branch_" .. branch_counter

    local branch = {
        id = branch_id,
        name = name or ("Branch " .. branch_counter),
        parent_id = parent_id,
        created_at = os.time(),
        children = {},
        message_ids = {}
    }

    branches[branch_id] = branch

    -- 添加到父分支的子节点
    if parent_id and branches[parent_id] then
        table.insert(branches[parent_id].children, branch_id)
    end

    -- 设置当前分支
    current_branch_id = branch_id

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("branch_created", branch_id, branch)
    end

    return branch_id
end

--- 切换分支
--- @param branch_id string 分支ID
function M.switch_branch(branch_id)
    if not branches[branch_id] then
        error("Branch not found: " .. branch_id)
    end

    local old_branch_id = current_branch_id
    current_branch_id = branch_id

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("branch_switched", branch_id, old_branch_id)
    end
end

--- 获取分支树
--- @param session_id string 会话ID
--- @return table 分支树结构
function M.get_branch_tree(session_id)
    -- 这里需要根据会话ID过滤分支
    -- 目前返回所有分支的树结构
    local root_branches = {}

    for branch_id, branch in pairs(branches) do
        if not branch.parent_id then
            table.insert(root_branches, M._build_tree_node(branch_id))
        end
    end

    return root_branches
end

--- 删除分支
--- @param branch_id string 分支ID
function M.delete_branch(branch_id)
    if not branches[branch_id] then
        return
    end

    local branch = branches[branch_id]

    -- 递归删除子分支
    for _, child_id in ipairs(branch.children) do
        M.delete_branch(child_id)
    end

    -- 从父分支中移除
    if branch.parent_id and branches[branch.parent_id] then
        local parent = branches[branch.parent_id]
        for i, child_id in ipairs(parent.children) do
            if child_id == branch_id then
                table.remove(parent.children, i)
                break
            end
        end
    end

    -- 删除分支
    branches[branch_id] = nil

    -- 如果删除的是当前分支，重置当前分支
    if current_branch_id == branch_id then
        current_branch_id = nil
        for id, _ in pairs(branches) do
            current_branch_id = id
            break
        end
    end

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("branch_deleted", branch_id)
    end
end

--- 获取当前分支
--- @return string|nil 当前分支ID
function M.get_current_branch()
    return current_branch_id
end

--- 获取分支列表
--- @param session_id string 会话ID
--- @return table 分支列表
function M.list_branches(session_id)
    local result = {}
    
    for branch_id, branch in pairs(branches) do
        -- 这里需要根据会话ID过滤分支
        -- 目前返回所有分支
        table.insert(result, {
            id = branch_id,
            name = branch.name,
            parent_id = branch.parent_id,
            created_at = branch.created_at
        })
    end
    
    return result
end

--- 获取分支信息
--- @param branch_id string 分支ID
--- @return table|nil 分支信息
function M.get_branch(branch_id)
    return vim.deepcopy(branches[branch_id])
end

--- 构建树节点（内部使用）
--- @param branch_id string 分支ID
--- @return table 树节点
function M._build_tree_node(branch_id)
    local branch = branches[branch_id]
    if not branch then
        return nil
    end

    local node = {
        id = branch_id,
        name = branch.name,
        created_at = branch.created_at,
        children = {}
    }

    for _, child_id in ipairs(branch.children) do
        local child_node = M._build_tree_node(child_id)
        if child_node then
            table.insert(node.children, child_node)
        end
    end

    return node
end

return M