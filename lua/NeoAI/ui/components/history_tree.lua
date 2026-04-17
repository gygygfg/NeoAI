local M = {}

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    tree_data = {},
    expanded_nodes = {},
    selected_node_id = nil
}

--- 初始化历史树组件
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    state.initialized = true
end

--- 渲染历史树
--- @param session_id string 会话ID
function M.render(session_id)
    if not state.initialized then
        return
    end

    -- 加载树数据
    M._load_tree_data(session_id)

    -- 这里应该返回渲染后的树数据
    -- 目前只是返回树数据
    return state.tree_data
end

--- 展开节点
--- @param node_id string 节点ID
function M.expand_node(node_id)
    if not state.initialized then
        return
    end

    state.expanded_nodes[node_id] = true
end

--- 折叠节点
--- @param node_id string 节点ID
function M.collapse_node(node_id)
    if not state.initialized then
        return
    end

    state.expanded_nodes[node_id] = nil
end

--- 更新历史树
--- @param session_id string 会话ID
--- @param new_data table 新数据
function M.update(session_id, new_data)
    if not state.initialized then
        return
    end
    
    -- 更新树数据
    state.tree_data = new_data or {}
    
    -- 触发更新事件
    if state.config.on_update then
        state.config.on_update(session_id, state.tree_data)
    end
end

--- 获取选中的项目
--- @return table|nil 选中的节点
function M.get_selected_item()
    if not state.initialized or not state.selected_node_id then
        return nil
    end
    
    -- 在树数据中查找选中的节点
    local function find_node(nodes, node_id)
        for _, node in ipairs(nodes) do
            if node.id == node_id then
                return node
            end
            if node.children then
                local found = find_node(node.children, node_id)
                if found then
                    return found
                end
            end
        end
        return nil
    end
    
    return find_node(state.tree_data, state.selected_node_id)
end

--- 选择节点
--- @param node_id string 节点ID
function M.select_node(node_id)
    if not state.initialized then
        return
    end

    state.selected_node_id = node_id
end

--- 更新节点
--- @param node_id string 节点ID
--- @param data table 节点数据
function M.update_node(node_id, data)
    if not state.initialized then
        return
    end

    -- 查找并更新节点
    local function update_node_recursive(nodes)
        for _, node in ipairs(nodes) do
            if node.id == node_id then
                for k, v in pairs(data) do
                    node[k] = v
                end
                return true
            end
            
            if node.children and #node.children > 0 then
                if update_node_recursive(node.children) then
                    return true
                end
            end
        end
        return false
    end

    update_node_recursive(state.tree_data)
end

--- 获取选中节点
--- @return string|nil 选中节点ID
function M.get_selected_node()
    return state.selected_node_id
end

--- 获取树数据
--- @return table 树数据
function M.get_tree_data()
    return vim.deepcopy(state.tree_data)
end

--- 获取展开的节点
--- @return table 展开的节点ID列表
function M.get_expanded_nodes()
    local nodes = {}
    for node_id, _ in pairs(state.expanded_nodes) do
        table.insert(nodes, node_id)
    end
    return nodes
end

--- 清空树数据
function M.clear()
    state.tree_data = {}
    state.expanded_nodes = {}
    state.selected_node_id = nil
end

--- 查找节点
--- @param predicate function 谓词函数
--- @return table|nil 找到的节点
function M.find_node(predicate)
    if not state.initialized or type(predicate) ~= "function" then
        return nil
    end

    local function find_recursive(nodes)
        for _, node in ipairs(nodes) do
            if predicate(node) then
                return node
            end
            
            if node.children and #node.children > 0 then
                local found = find_recursive(node.children)
                if found then
                    return found
                end
            end
        end
        return nil
    end

    return find_recursive(state.tree_data)
end

--- 获取节点路径
--- @param node_id string 节点ID
--- @return table 节点路径
function M.get_node_path(node_id)
    if not state.initialized then
        return {}
    end

    local path = {}

    local function find_path_recursive(nodes, current_path)
        for _, node in ipairs(nodes) do
            local new_path = vim.deepcopy(current_path)
            table.insert(new_path, node.id)
            
            if node.id == node_id then
                return new_path
            end
            
            if node.children and #node.children > 0 then
                local found = find_path_recursive(node.children, new_path)
                if found then
                    return found
                end
            end
        end
        return nil
    end

    return find_path_recursive(state.tree_data, {}) or {}
end

--- 获取子节点
--- @param node_id string 节点ID
--- @return table 子节点列表
function M.get_children(node_id)
    if not state.initialized then
        return {}
    end

    local node = M.find_node(function(n)
        return n.id == node_id
    end)

    if node and node.children then
        return vim.deepcopy(node.children)
    end

    return {}
end

--- 获取父节点
--- @param node_id string 节点ID
--- @return table|nil 父节点
function M.get_parent(node_id)
    if not state.initialized then
        return nil
    end

    local function find_parent_recursive(nodes, parent)
        for _, node in ipairs(nodes) do
            if node.id == node_id then
                return parent
            end
            
            if node.children and #node.children > 0 then
                local found = find_parent_recursive(node.children, node)
                if found then
                    return found
                end
            end
        end
        return nil
    end

    return find_parent_recursive(state.tree_data, nil)
end

--- 添加节点
--- @param parent_id string|nil 父节点ID
--- @param node_data table 节点数据
--- @return boolean 是否添加成功
function M.add_node(parent_id, node_data)
    if not state.initialized or not node_data or not node_data.id then
        return false
    end

    if not parent_id then
        -- 添加到根节点
        table.insert(state.tree_data, node_data)
        return true
    end

    local parent = M.find_node(function(n)
        return n.id == parent_id
    end)

    if not parent then
        return false
    end

    if not parent.children then
        parent.children = {}
    end

    table.insert(parent.children, node_data)
    return true
end

--- 删除节点
--- @param node_id string 节点ID
--- @return boolean 是否删除成功
function M.delete_node(node_id)
    if not state.initialized then
        return false
    end

    local function delete_recursive(nodes)
        for i, node in ipairs(nodes) do
            if node.id == node_id then
                table.remove(nodes, i)
                
                -- 从展开节点中移除
                state.expanded_nodes[node_id] = nil
                
                -- 如果删除的是选中节点，清空选中
                if state.selected_node_id == node_id then
                    state.selected_node_id = nil
                end
                
                return true
            end
            
            if node.children and #node.children > 0 then
                if delete_recursive(node.children) then
                    return true
                end
            end
        end
        return false
    end

    return delete_recursive(state.tree_data)
end

--- 移动节点
--- @param node_id string 节点ID
--- @param new_parent_id string 新父节点ID
--- @return boolean 是否移动成功
function M.move_node(node_id, new_parent_id)
    if not state.initialized then
        return false
    end

    -- 查找节点
    local node_to_move = nil
    local old_parent_nodes = nil
    local node_index = nil

    local function find_node_recursive(nodes, parent_nodes)
        for i, node in ipairs(nodes) do
            if node.id == node_id then
                node_to_move = node
                old_parent_nodes = parent_nodes or nodes
                node_index = i
                return true
            end
            
            if node.children and #node.children > 0 then
                if find_node_recursive(node.children, node.children) then
                    return true
                end
            end
        end
        return false
    end

    if not find_node_recursive(state.tree_data) then
        return false
    end

    -- 从原位置移除
    table.remove(old_parent_nodes, node_index)

    -- 添加到新位置
    if not new_parent_id then
        -- 移动到根节点
        table.insert(state.tree_data, node_to_move)
    else
        local new_parent = M.find_node(function(n)
            return n.id == new_parent_id
        end)
        
        if not new_parent then
            -- 如果找不到新父节点，回滚
            table.insert(old_parent_nodes, node_index, node_to_move)
            return false
        end

        if not new_parent.children then
            new_parent.children = {}
        end

        table.insert(new_parent.children, node_to_move)
    end

    return true
end

--- 加载树数据（内部使用）
--- @param session_id string 会话ID
function M._load_tree_data(session_id)
    -- 这里应该从会话管理器加载树数据
    -- 目前使用模拟数据
    state.tree_data = {
        {
            id = "session_1",
            name = "主会话",
            type = "session",
            metadata = {
                message_count = 5,
                created_at = os.time() - 3600
            },
            children = {
                {
                    id = "branch_1",
                    name = "主分支",
                    type = "branch",
                    metadata = {
                        message_count = 5,
                        created_at = os.time() - 3600
                    },
                    children = {
                        {
                            id = "branch_2",
                            name = "功能开发",
                            type = "branch",
                            metadata = {
                                message_count = 3,
                                created_at = os.time() - 1800
                            },
                            children = {}
                        }
                    }
                }
            }
        },
        {
            id = "session_2",
            name = "测试会话",
            type = "session",
            metadata = {
                message_count = 2,
                created_at = os.time() - 7200
            },
            children = {
                {
                    id = "branch_3",
                    name = "测试分支",
                    type = "branch",
                    metadata = {
                        message_count = 2,
                        created_at = os.time() - 7200
                    },
                    children = {}
                }
            }
        }
    }

    -- 默认展开根节点
    for _, root_node in ipairs(state.tree_data) do
        state.expanded_nodes[root_node.id] = true
    end
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
    if not state.initialized then
        return
    end

    state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M