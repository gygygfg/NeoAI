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
--- @type table<string, { effect: string, paths?: string[], read_only?: boolean }>
local SPECS = {
  -- 文件读
  read_file = { effect = "read", paths = { "file_path" } },
  list_files = { effect = "read", paths = { "path" } },
  search_files = { effect = "read", paths = { "path" } },
  file_exists = { effect = "read", paths = { "file_path" } },
  -- 文件写
  edit_file = { effect = "fs_write", paths = { "file_path" } },
  create_directory = { effect = "fs_write", paths = { "file_path" } },
  ensure_dir = { effect = "fs_write", paths = { "file_path" } },
  delete_file = { effect = "fs_write", paths = { "file_path" } },
  -- 进程
  run_command = { effect = "process" },
  reload_all = { effect = "process" },
  -- git：读操作在沙箱命名空间内执行（与 run_command 同一 overlay），看到暂存内容而非真实磁盘；
  -- read_only 表示不捕获候选（只读，无副作用）。
  git_status = { effect = "process", read_only = true },
  git_diff = { effect = "process", read_only = true },
  git_log = { effect = "process", read_only = true },
  git_commit_detail = { effect = "process", read_only = true },
  git_branch = { effect = "process", read_only = true },
  git_file_history = { effect = "process", read_only = true },
  -- git 变更：在沙箱内执行（看到暂存工作区），`.git` 改动由候选管线**原子化**捕获
  -- （对象先于指针，见 `runtime.git_path_class`）后进入审批悬浮窗，用户确认后原子应用。
  git_rollback = { effect = "process" },
  git_add = { effect = "process" },
  git_commit = { effect = "process" },
  git_stash = { effect = "process" },
  git_restore = { effect = "process" },
  git_auto_commit_config = { effect = "in_process" },
  -- 日志
  log_message = { effect = "fs_write" },
  get_log_levels = { effect = "in_process" },
  -- treesitter / lsp：读为主，写入经 persist_buffer 暂存
  parse_file = { effect = "read", paths = { "file_path" } },
  query_tree = { effect = "read", paths = { "file_path" } },
  get_node_at_position = { effect = "read", paths = { "file_path" } },
  get_node_type = { effect = "read", paths = { "file_path" } },
  get_node_range = { effect = "read", paths = { "file_path" } },
  is_named_node = { effect = "read", paths = { "file_path" } },
  get_parent_node = { effect = "read", paths = { "file_path" } },
  get_child_nodes = { effect = "read", paths = { "file_path" } },
  get_node_code = { effect = "read", paths = { "file_path" } },
  delete_node = { effect = "fs_write", paths = { "file_path" } },
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
  -- 长驻服务（service_*）：start/stop 为进程效果（门禁预检+脚本扫描+硬拒绝），但隔离与候选
  -- 结算由 sandbox.service 自建（见 wrapper 的 long_lived 分支）；logs/status 为只读。
  service_start = { effect = "process" },
  service_stop = { effect = "process" },
  service_logs = { effect = "read" },
  service_status = { effect = "read" },
  -- 网络
  web_fetch = { effect = "network" },
  -- read_image 的 file_path 可为本地路径：进程内读盘，必须纳入遮蔽判定（URL 分支不受影响）。
  read_image = { effect = "network", paths = { "file_path" } },
  -- 进程内交互 / 子 agent
  confirm_file_change = { effect = "in_process" },
  ask_user = { effect = "in_process" },
  enter_plan_mode = { effect = "in_process" },
  -- 交互式终端控制：仅操作已存在的 PTY 会话，不新起进程。
  terminal_send_text = { effect = "in_process" },
  terminal_send_keys = { effect = "in_process" },
  terminal_kill = { effect = "in_process" },
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
--- @return table { effect: string, paths: string[], read_only: boolean }
function M.get(name, category)
  local spec = SPECS[name]
  if spec then
    return { effect = spec.effect, paths = spec.paths or {}, read_only = spec.read_only == true }
  end
  local effect = CATEGORY_DEFAULT[category or "other"] or "process"
  if not EFFECTS[effect] then effect = "process" end
  return { effect = effect, paths = {}, read_only = false }
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
