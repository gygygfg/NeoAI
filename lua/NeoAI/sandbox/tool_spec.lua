--- 沙箱工具能力规格
--- @module NeoAI.sandbox.tool_spec
--- 为每个工具声明执行影响类别（effect）与需要暂存的路径参数。
--- 未知工具按类别默认值归类；仍未知则按最保守的 process 处理（必须隔离）。

local M = {}

-- ========== 私有常量 ==========

--- effect 语义：
---   read        只读，进程内执行，记录只读回执
---   in_process  进程内状态变更（todo/plan/ask_user 等），无宿主 fs 影响
---   fs_write    写宿主文件系统，必须暂存为候选
---   process     启动外部进程，必须经运行时后端隔离
---   network     网络副作用，默认离线拒绝
local EFFECTS = {
  read = true, in_process = true, fs_write = true, process = true, network = true,
}

--- 已知工具的显式规格
--- @type table<string, { effect: string, paths?: string[] }>
local SPECS = {
  -- 文件读
  read_file = { effect = "read", paths = { "filepath" } },
  list_files = { effect = "read", paths = { "path" } },
  search_files = { effect = "read", paths = { "path" } },
  file_exists = { effect = "read", paths = { "filepath" } },
  -- 文件写
  edit_file = { effect = "fs_write", paths = { "filepath" } },
  create_directory = { effect = "fs_write", paths = { "filepath" } },
  ensure_dir = { effect = "fs_write", paths = { "filepath" } },
  delete_file = { effect = "fs_write", paths = { "filepath" } },
  -- 进程
  run_command = { effect = "process" },
  reload_all = { effect = "process" },
  -- git
  git_status = { effect = "read" },
  git_diff = { effect = "read" },
  git_log = { effect = "read" },
  git_commit_detail = { effect = "read" },
  git_branch = { effect = "read" },
  git_file_history = { effect = "read" },
  git_rollback = { effect = "process" },
  git_auto_commit_config = { effect = "in_process" },
  -- 日志
  log_message = { effect = "fs_write" },
  get_log_levels = { effect = "in_process" },
  -- treesitter / lsp：读为主，写入经 persist_buffer 暂存
  parse_file = { effect = "read", paths = { "filepath" } },
  query_tree = { effect = "read", paths = { "filepath" } },
  get_node_at_position = { effect = "read", paths = { "filepath" } },
  get_node_type = { effect = "read", paths = { "filepath" } },
  get_node_range = { effect = "read", paths = { "filepath" } },
  is_named_node = { effect = "read", paths = { "filepath" } },
  get_parent_node = { effect = "read", paths = { "filepath" } },
  get_child_nodes = { effect = "read", paths = { "filepath" } },
  get_node_code = { effect = "read", paths = { "filepath" } },
  delete_node = { effect = "fs_write", paths = { "filepath" } },
  lsp_hover = { effect = "read" },
  lsp_definition = { effect = "read" },
  lsp_references = { effect = "read" },
  lsp_document_symbols = { effect = "read" },
  lsp_workspace_symbols = { effect = "read" },
  lsp_diagnostics = { effect = "read" },
  lsp_client_info = { effect = "read" },
  lsp_code_action = { effect = "read" },
  lsp_signature_help = { effect = "read" },
  lsp_completion = { effect = "read" },
  lsp_type_definition = { effect = "read" },
  lsp_declaration = { effect = "read" },
  lsp_implementation = { effect = "read" },
  lsp_service_info = { effect = "read" },
  lsp_rename = { effect = "fs_write" },
  lsp_format = { effect = "fs_write" },
  -- 网络
  web_fetch = { effect = "network" },
  read_image = { effect = "network" },
  -- 进程内交互 / 子 agent
  confirm_file_change = { effect = "in_process" },
  ask_user = { effect = "in_process" },
  enter_plan_mode = { effect = "in_process" },
  exit_plan_mode = { effect = "in_process" },
  create_sub_agent = { effect = "in_process" },
  get_sub_agent_status = { effect = "in_process" },
  wait_sub_agent = { effect = "in_process" },
  cancel_sub_agent = { effect = "in_process" },
  todo_write = { effect = "in_process" },
  todo_read = { effect = "in_process" },
  todo_clear = { effect = "in_process" },
  list_skills = { effect = "read" },
  load_skill = { effect = "in_process" },
}

--- 类别默认 effect（工具未显式声明时）
local CATEGORY_DEFAULT = {
  file = "read",
  system = "process",
  git = "process",
  treesitter = "read",
  lsp = "read",
  log = "in_process",
  agent = "in_process",
  mcp = "process",
  skill = "read",
  web = "network",
  other = "process",
}

-- ========== 公开 API ==========

--- 获取工具规格
--- @param name string
--- @param category string|nil
--- @return table { effect: string, paths: string[] }
function M.get(name, category)
  local spec = SPECS[name]
  if spec then
    return { effect = spec.effect, paths = spec.paths or {} }
  end
  local effect = CATEGORY_DEFAULT[category or "other"] or "process"
  if not EFFECTS[effect] then effect = "process" end
  return { effect = effect, paths = {} }
end

--- 该 effect 是否产生可暂存的文件系统影响
--- @param effect string
--- @return boolean
function M.is_fs_write(effect)
  return effect == "fs_write"
end

--- 该 effect 是否必须经外部运行时隔离
--- @param effect string
--- @return boolean
function M.is_external(effect)
  return effect == "process" or effect == "network"
end

--- 注册/覆盖工具规格（供插件扩展）
--- @param name string
--- @param spec table { effect, paths? }
function M.register(name, spec)
  if type(name) ~= "string" or type(spec) ~= "table" then return false end
  if not EFFECTS[spec.effect] then return false end
  SPECS[name] = { effect = spec.effect, paths = spec.paths or {} }
  return true
end

M.EFFECTS = EFFECTS

return M
