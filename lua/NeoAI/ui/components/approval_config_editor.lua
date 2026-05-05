--- 审批配置编辑器组件
--- 从 chat_window.lua 分离，负责展示和修改工具的运行时审批配置
--- 使用 vim.ui.select 进行交互

local M = {}

local Events = require("NeoAI.core.events")
local approval_state = require("NeoAI.tools.approval_state")

--- 打开修改审批配置悬浮窗
--- 从 tool_registry 获取所有工具，通过 vim.ui.select 模糊匹配选择工具，
--- 然后显示该工具的运行时审批配置，允许用户修改
function M.open()
  local ok, tool_registry = pcall(require, "NeoAI.tools.tool_registry")
  if not ok or not tool_registry then
    vim.notify("[NeoAI] 工具注册表不可用", vim.log.levels.WARN)
    return
  end

  pcall(tool_registry.initialize, {})

  local all_tools = tool_registry.list()
  if #all_tools == 0 then
    vim.notify("[NeoAI] 没有可用的工具", vim.log.levels.INFO)
    return
  end

  -- 从 approval_state 读取运行时审批配置（所有模块共享同一变量）
  local approval_configs = approval_state.get_all_tool_configs()

  -- 构建选择项（按分类分组显示，带审批状态标记）
  local items = {}
  for _, tool in ipairs(all_tools) do
    local category = tool.category or "uncategorized"
    local tool_cfg = approval_configs[tool.name]
    local behavior_mark = ""
    if tool_cfg then
      if tool_cfg.auto_allow == true then
        behavior_mark = " [auto_approve]"
      elseif tool_cfg.auto_allow == false then
        behavior_mark = " [require_user]"
      end
    end
    table.insert(items, {
      display = string.format("[%s] %s%s", category, tool.name, behavior_mark),
      name = tool.name,
      raw = tool,
    })
  end
  table.sort(items, function(a, b)
    return a.display < b.display
  end)

  -- 第一步：模糊匹配选择工具
  vim.ui.select(items, {
    prompt = "选择要修改审批配置的工具:",
    format_item = function(item)
      return item.display
    end,
  }, function(selected)
    if not selected then
      return
    end
    -- 第二步：显示并修改该工具的审批配置
    M._show_editor(selected.name, selected.raw)
  end)
end

--- 显示审批配置编辑器
--- 展示工具当前运行时审批配置，让用户修改各字段
--- 前端显示 behavior（require_user / auto_approve），后端存储 auto_allow（true / false）
--- 支持修改：behavior, allowed_directories, allowed_param_groups
--- @param tool_name string 工具名称
--- @param tool table 工具定义
function M._show_editor(tool_name, tool)
  local tool_registry = require("NeoAI.tools.tool_registry")

  -- 从 approval_state 读取运行时配置（所有模块共享），回退到注册表默认配置
  local runtime_config = approval_state.get_tool_config(tool_name)
  local registry_config = tool_registry.get_approval_config(tool_name)

  -- 当前生效的配置（auto_allow 布尔值）
  local current_auto_allow = nil
  if runtime_config and runtime_config.auto_allow ~= nil then
    current_auto_allow = runtime_config.auto_allow
  elseif registry_config and registry_config.auto_allow ~= nil then
    current_auto_allow = registry_config.auto_allow
  else
    current_auto_allow = true
  end

  -- 当前允许目录和参数组
  local current_allowed_directories = {}
  if runtime_config and runtime_config.allowed_directories then
    current_allowed_directories = vim.deepcopy(runtime_config.allowed_directories)
  elseif registry_config and registry_config.allowed_directories then
    current_allowed_directories = vim.deepcopy(registry_config.allowed_directories)
  end

  local current_allowed_param_groups = {}
  if runtime_config and runtime_config.allowed_param_groups then
    current_allowed_param_groups = vim.deepcopy(runtime_config.allowed_param_groups)
  elseif registry_config and registry_config.allowed_param_groups then
    current_allowed_param_groups = vim.deepcopy(registry_config.allowed_param_groups)
  end

  -- 前端显示辅助：auto_allow → behavior 文本
  local function behavior_text(auto_allow)
    if auto_allow then
      return "auto_approve"
    else
      return "require_user"
    end
  end

  -- 递归编辑菜单，支持修改多个字段
  local function show_field_menu()
    local dirs_str = #current_allowed_directories > 0
      and table.concat(current_allowed_directories, ", ")
      or "(空)"
    local groups_str = ""
    for k, v in pairs(current_allowed_param_groups) do
      local vals = type(v) == "table" and table.concat(v, ", ") or tostring(v)
      groups_str = groups_str .. k .. "=" .. vals .. " "
    end
    if groups_str == "" then
      groups_str = "(空)"
    end

    local field_options = {
      {
        display = string.format("behavior: %s", behavior_text(current_auto_allow)),
        field = "behavior",
      },
      {
        display = string.format("allowed_directories: %s", dirs_str),
        field = "allowed_directories",
      },
      {
        display = string.format("allowed_param_groups: %s", groups_str),
        field = "allowed_param_groups",
      },
      {
        display = "✓ 保存并退出",
        field = "__save__",
      },
    }

    vim.ui.select(field_options, {
      prompt = string.format("工具 [%s] 审批配置 - 选择要修改的字段:", tool_name),
      format_item = function(item)
        return item.display
      end,
    }, function(selected)
      if not selected then
        return
      end

      if selected.field == "__save__" then
        -- 保存配置到 approval_state（所有模块共享同一个表）
        local save_config = {
          auto_allow = current_auto_allow,
          allowed_directories = current_allowed_directories,
          allowed_param_groups = current_allowed_param_groups,
          allow_all = current_auto_allow,  -- 允许所有与 auto_allow 同步
        }
        approval_state.set_tool_config(tool_name, save_config)

        vim.notify(
          string.format("[NeoAI] 工具 '%s' 运行时审批配置已更新", tool_name),
          vim.log.levels.INFO
        )

        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = Events.TOOL_APPROVAL_CONFIG_CHANGED,
          data = {
            tool_name = tool_name,
            config = save_config,
          },
        })
        return
      end

      -- 根据字段类型显示不同的编辑器
      if selected.field == "behavior" then
        local behavior_options = {
          { display = "auto_approve - 自动批准（无需用户确认）", value = true },
          { display = "require_user - 需要用户审批", value = false },
        }
        vim.ui.select(behavior_options, {
          prompt = string.format(
            "工具 [%s] 当前 behavior: %s",
            tool_name,
            behavior_text(current_auto_allow)
          ),
          format_item = function(item)
            local marker = (item.value == current_auto_allow) and "✓ " or "  "
            return marker .. item.display
          end,
        }, function(selected_behavior)
          if selected_behavior ~= nil then
            current_auto_allow = selected_behavior.value
          end
          show_field_menu()
        end)

      elseif selected.field == "allowed_directories" then
        local dirs_options = {
          { display = "添加目录", action = "add" },
          { display = "删除目录", action = "remove" },
          { display = "清空所有目录", action = "clear" },
          { display = "返回上级菜单", action = "back" },
        }
        vim.ui.select(dirs_options, {
          prompt = string.format(
            "当前允许目录 (%d 个): %s",
            #current_allowed_directories,
            dirs_str
          ),
          format_item = function(item)
            return item.display
          end,
        }, function(selected_action)
          if not selected_action or selected_action.action == "back" then
            show_field_menu()
            return
          end

          if selected_action.action == "add" then
            vim.ui.input({
              prompt = "输入允许的目录路径（支持相对/绝对路径，多个用逗号分隔）: ",
            }, function(input)
              if input and input ~= "" then
                for _, dir in ipairs(vim.split(input, ",")) do
                  local trimmed = vim.trim(dir)
                  if trimmed ~= "" then
                    local exists = false
                    for _, d in ipairs(current_allowed_directories) do
                      if d == trimmed then
                        exists = true
                        break
                      end
                    end
                    if not exists then
                      table.insert(current_allowed_directories, trimmed)
                    end
                  end
                end
              end
              show_field_menu()
            end)

          elseif selected_action.action == "remove" then
            if #current_allowed_directories == 0 then
              vim.notify("[NeoAI] 没有可删除的目录", vim.log.levels.INFO)
              show_field_menu()
              return
            end
            local remove_options = {}
            for _, dir in ipairs(current_allowed_directories) do
              table.insert(remove_options, { display = dir, value = dir })
            end
            table.insert(remove_options, { display = "返回", value = "__back__" })
            vim.ui.select(remove_options, {
              prompt = "选择要删除的目录:",
              format_item = function(item)
                return item.display
              end,
            }, function(to_remove)
              if to_remove and to_remove.value ~= "__back__" then
                for i, dir in ipairs(current_allowed_directories) do
                  if dir == to_remove.value then
                    table.remove(current_allowed_directories, i)
                    break
                  end
                end
              end
              show_field_menu()
            end)

          elseif selected_action.action == "clear" then
            current_allowed_directories = {}
            show_field_menu()
          end
        end)

      elseif selected.field == "allowed_param_groups" then
        local groups_options = {
          { display = "添加参数组", action = "add" },
          { display = "删除参数组", action = "remove" },
          { display = "清空所有参数组", action = "clear" },
          { display = "返回上级菜单", action = "back" },
        }
        vim.ui.select(groups_options, {
          prompt = string.format(
            "当前允许参数组: %s",
            groups_str
          ),
          format_item = function(item)
            return item.display
          end,
        }, function(selected_action)
          if not selected_action or selected_action.action == "back" then
            show_field_menu()
            return
          end

          if selected_action.action == "add" then
            vim.ui.input({
              prompt = "输入参数名（如 command）: ",
            }, function(param_name)
              if not param_name or param_name == "" then
                show_field_menu()
                return
              end
              param_name = vim.trim(param_name)
              vim.ui.input({
                prompt = string.format("输入参数 '%s' 的允许值（多个用逗号分隔）: ", param_name),
              }, function(values_input)
                if values_input and values_input ~= "" then
                  local values = {}
                  for _, v in ipairs(vim.split(values_input, ",")) do
                    local trimmed = vim.trim(v)
                    if trimmed ~= "" then
                      table.insert(values, trimmed)
                    end
                  end
                  if #values > 0 then
                    current_allowed_param_groups[param_name] = values
                  end
                end
                show_field_menu()
              end)
            end)

          elseif selected_action.action == "remove" then
            local keys = vim.tbl_keys(current_allowed_param_groups)
            if #keys == 0 then
              vim.notify("[NeoAI] 没有可删除的参数组", vim.log.levels.INFO)
              show_field_menu()
              return
            end
            local remove_options = {}
            for _, k in ipairs(keys) do
              local vals = type(current_allowed_param_groups[k]) == "table"
                and table.concat(current_allowed_param_groups[k], ", ")
                or tostring(current_allowed_param_groups[k])
              table.insert(remove_options, { display = string.format("%s = [%s]", k, vals), value = k })
            end
            table.insert(remove_options, { display = "返回", value = "__back__" })
            vim.ui.select(remove_options, {
              prompt = "选择要删除的参数组:",
              format_item = function(item)
                return item.display
              end,
            }, function(to_remove)
              if to_remove and to_remove.value ~= "__back__" then
                current_allowed_param_groups[to_remove.value] = nil
              end
              show_field_menu()
            end)

          elseif selected_action.action == "clear" then
            current_allowed_param_groups = {}
            show_field_menu()
          end
        end)
      end
    end)
  end

  -- 开始编辑
  show_field_menu()
end

return M
