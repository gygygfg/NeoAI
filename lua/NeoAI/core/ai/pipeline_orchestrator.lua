-- pipeline_orchestrator.lua
-- 多 AI 流水线编排器
-- 管理多个 AI agent 的串联执行，每个 agent 有独立的提示词和上下文
--
-- 流水线流程：
--   用户提问 → [工具A: 判断是否修改项目 + 获取项目地址]
--            → [工具B: 判断文件是否可被语法树解析]
--            → [工具C: 列出语法树块结构]
--            → AI1(初筛): 循环读取代码，直到认为足够
--            → AI2(编辑): 循环编辑文件
--            → AI3(测试): 循环测试
--
-- 每个 AI 结束时总结传递给下一个 AI

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local state_manager = require("NeoAI.core.config.state")
local pipeline_agent = require("NeoAI.core.ai.pipeline_agent")
local pipeline_tools = require("NeoAI.core.ai.pipeline_tools")

-- ========== 流水线阶段定义 ==========

local PIPELINE_STAGES = {
  ANALYZE = "analyze",       -- 分析阶段：判断项目类型、语法树可解析性
  SCREENING = "screening",   -- 初筛阶段：AI1 读取代码
  EDITING = "editing",       -- 编辑阶段：AI2 编辑文件
  TESTING = "testing",       -- 测试阶段：AI3 运行测试
}

-- 每个 AI 的提示词定义
local AGENT_PROMPTS = {
  [PIPELINE_STAGES.SCREENING] = {
    system = [[你是一个**代码初筛助手**。你的任务是：

1. 读取用户指定的代码文件
2. 理解代码结构和功能
3. 总结关键信息供后续编辑使用

### 规则
- 使用 parse_file、get_node_code、read_file 等只读工具
- 不要修改任何文件
- 不要运行任何命令
- 当认为已获取足够信息时，直接返回纯文本总结

### 总结格式
请在最后返回以下格式的总结：

## 代码结构总结
- 文件列表及各自功能
- 关键函数/类/模块
- 数据流和依赖关系
- 需要修改的位置和原因

## 传递给编辑助手的指令
- 需要修改哪些文件
- 需要修改什么内容
- 注意事项和约束]],

    tools = { "read_file", "parse_file", "get_node_code", "get_node_type", "get_node_range",
              "get_child_nodes", "get_parent_node", "get_node_at_position", "query_tree",
              "list_files", "search_files", "file_exists", "grep_search" },
  },

  [PIPELINE_STAGES.EDITING] = {
    system = [[你是一个**代码编辑助手**。你的任务是：

1. 根据初筛助手的总结，执行实际的代码修改
2. 每次修改后校验结果
3. 修改完成后返回总结

### 规则
- 使用 replace_text、edit_node、delete_node、create_file 等写入工具
- 每次修改后调用 read_file 确认内容正确
- 如果发现信息不足，在总结中说明

### 总结格式
请在最后返回以下格式的总结：

## 修改总结
- 修改了哪些文件
- 修改了什么内容
- 修改前后的对比

## 传递给测试助手的指令
- 需要运行哪些测试
- 测试命令
- 预期结果]],

    tools = { "read_file", "parse_file", "get_node_code", "get_node_type",
              "replace_text", "edit_node", "delete_node", "create_file",
              "create_directory", "delete_file", "file_exists",
              "list_files", "search_files", "run_command" },
  },

  [PIPELINE_STAGES.TESTING] = {
    system = [[你是一个**测试验证助手**。你的任务是：

1. 根据编辑助手的总结，运行测试验证修改正确性
2. 检查 LSP 诊断确保没有引入语法错误
3. 如果发现问题，在总结中说明需要修正的内容

### 规则
- 使用 run_command 运行测试
- 使用 read_file 读取修改后的文件
- 不要直接修改文件（如需修改，在总结中说明）

### 总结格式
请在最后返回以下格式的总结：

## 测试结果
- 运行了哪些测试
- 测试结果（通过/失败）
- LSP 诊断信息

## 最终结论
- 任务是否完成
- 存在的问题（如果有）
- 建议的后续步骤]],

    tools = { "read_file", "parse_file", "get_node_code", "run_command",
              "list_files", "search_files", "file_exists" },
  },
}

-- ========== 流水线状态 ==========

local _pipeline_state = {}

-- ========== 内部工具：判断是否修改项目 ==========

--- 判断用户提问是否涉及修改项目代码
--- @param query string 用户提问
--- @return boolean is_modification, string|nil project_path
local function _detect_modification_intent(query)
  if not query or query == "" then
    return false, nil
  end

  local lower = query:lower()

  -- 修改类关键词
  local modify_keywords = {
    "修改", "添加", "删除", "更新", "修复", "重构", "优化",
    "实现", "增加", "改动", "变更", "编辑", "改写",
    "add", "remove", "delete", "update", "fix", "refactor",
    "optimize", "implement", "change", "modify", "edit",
    "create", "write", "rewrite",
  }

  -- 查询类关键词（不修改）
  local query_keywords = {
    "什么是", "怎么", "如何", "解释", "说明", "介绍",
    "what is", "how to", "explain", "describe", "tell me",
    "show me", "help", "guide", "tutorial",
  }

  -- 先检查是否是纯查询
  for _, kw in ipairs(query_keywords) do
    if lower:find(kw, 1, true) then
      return false, nil
    end
  end

  -- 检查是否涉及修改
  for _, kw in ipairs(modify_keywords) do
    if lower:find(kw, 1, true) then
      -- 尝试从查询中提取项目路径
      local project_path = vim.fn.getcwd()
      return true, project_path
    end
  end

  return false, nil
end

--- 判断文件是否可被 Tree-sitter 语法树解析
--- @param filepath string 文件路径
--- @return boolean parseable, string|nil lang, string|nil error
local function _check_tree_sitter_parseable(filepath)
  if not filepath or filepath == "" then
    return false, nil, "文件路径为空"
  end

  -- 检查 Tree-sitter 是否可用
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return false, nil, "Tree-sitter 不可用（需要 Neovim >= 0.5）"
  end

  -- 从文件路径推断语言
  local lm = require("NeoAI.utils.language_map")
  local ext = vim.fn.fnamemodify(filepath, ":e")
  local lang = nil
  if ext and ext ~= "" then
    lang = lm.ext_to_parser["." .. ext:lower()]
  end

  if not lang then
    -- 尝试匹配完整文件名
    local basename = vim.fn.fnamemodify(filepath, ":t")
    local name_map = {
      Makefile = "make",
      Dockerfile = "dockerfile",
      ["docker-compose.yml"] = "yaml",
      ["docker-compose.yaml"] = "yaml",
    }
    lang = name_map[basename]
  end

  if not lang then
    return false, nil, string.format("无法从文件路径推断 Tree-sitter 语言: %s", filepath)
  end

  -- 检查解析器是否已安装
  local ok_inspect, _ = pcall(ts.language.inspect, lang)
  if not ok_inspect then
    return false, lang, string.format("Tree-sitter 解析器 '%s' 未安装", lang)
  end

  return true, lang, nil
end

--- 列出文件的所有语法树块结构节点
--- @param filepath string 文件路径
--- @return table|nil blocks, string|nil error
local function _list_tree_blocks(filepath)
  if not filepath or filepath == "" then
    return nil, "文件路径为空"
  end

  local neovim_tree = require("NeoAI.tools.builtin.neovim_tree")
  local block_node_types = neovim_tree.block_node_types or {}

  -- 使用 parse_file 工具解析文件
  local result = nil
  local err_msg = nil
  local done = false

  neovim_tree.parse_file({
    filepath = filepath,
    max_depth = -1,  -- 不限深度
  }, function(r)
    result = r
    done = true
  end, function(err)
    err_msg = err
    done = true
  end)

  -- 等待异步回调完成（使用 vim.wait）
  vim.wait(10000, function() return done end, 50)

  if err_msg then
    return nil, err_msg
  end

  if not result or not result.nodes then
    return nil, "解析结果为空"
  end

  -- 过滤出块结构节点
  local blocks = {}
  local seen_types = {}

  for _, node in ipairs(result.nodes) do
    if block_node_types[node.type] and node.depth > 0 then
      if not seen_types[node.type] then
        seen_types[node.type] = true
      end
      table.insert(blocks, {
        type = node.type,
        text = (node.text:match("^[^\n]+") or node.text):sub(1, 100),
        start_row = node.start_row,
        end_row = node.end_row,
        depth = node.depth,
        type_index = node.type_index,
      })
    end
  end

  return {
    filepath = filepath,
    language = result.language,
    block_types = seen_types,
    blocks = blocks,
    total_blocks = #blocks,
  }, nil
end

-- ========== 流水线执行 ==========

--- 启动流水线
--- @param params table
---   - query: string - 用户提问
---   - session_id: string - 会话 ID
---   - window_id: number - 窗口 ID
---   - options: table - AI 选项
---   - model_index: number - 模型索引
---   - ai_preset: table - AI 配置
---   - on_complete: function - 完成回调
function M.start_pipeline(params)
  if not params or not params.query then
    if params and params.on_complete then
      params.on_complete(false, nil, "缺少必要参数: query")
    end
    return
  end

  local session_id = params.session_id or ("pipeline_" .. os.time())
  local window_id = params.window_id
  local query = params.query
  local options = params.options or {}
  local model_index = params.model_index or 1
  local ai_preset = params.ai_preset or {}
  local on_complete = params.on_complete

  -- 初始化流水线状态
  _pipeline_state[session_id] = {
    query = query,
    session_id = session_id,
    window_id = window_id,
    options = options,
    model_index = model_index,
    ai_preset = ai_preset,
    on_complete = on_complete,
    current_stage = PIPELINE_STAGES.ANALYZE,
    accumulated_usage = {},
    summaries = {},  -- 每个 AI 的总结
    project_path = nil,
    parseable_files = {},  -- 可解析的文件列表
    tree_blocks = {},      -- 语法树块结构
    stop_requested = false,
  }

  -- 开始分析阶段
  _run_analyze_stage(session_id)
end

-- ========== 分析阶段 ==========

--- 运行分析阶段
--- 判断用户是否要修改项目、获取项目地址、检查语法树可解析性
--- @param session_id string
local function _run_analyze_stage(session_id)
  local state = _pipeline_state[session_id]
  if not state or state.stop_requested then
    return
  end

  local query = state.query

  -- 步骤1: 判断是否要修改项目
  local is_modification, project_path = _detect_modification_intent(query)

  if not is_modification then
    -- 不是修改项目，直接返回给用户
    _finalize_pipeline(session_id, false, "用户提问不涉及代码修改，无需启动流水线。")
    return
  end

  state.project_path = project_path

  -- 步骤2: 尝试从查询中提取文件路径
  local target_files = _extract_file_paths(query, project_path)

  if #target_files == 0 then
    -- 没有指定具体文件，使用搜索工具查找
    _search_target_files(session_id)
    return
  end

  -- 步骤3: 检查语法树可解析性
  _check_files_parseable(session_id, target_files)
end

--- 从查询中提取文件路径
--- @param query string
--- @param project_path string
--- @return table filepaths
local function _extract_file_paths(query, project_path)
  local filepaths = {}

  -- 尝试匹配文件路径模式
  local path_patterns = {
    "([%w_%-%.]+%.[%w_%-%.]+)",  -- 匹配 filename.ext
    "([%w_%-%./\\]+%.[%w_%-%.]+)", -- 匹配 path/to/filename.ext
  }

  for _, pattern in ipairs(path_patterns) do
    for match in query:gmatch(pattern) do
      -- 检查文件是否存在
      local full_path = match
      if not vim.startswith(full_path, "/") then
        full_path = project_path .. "/" .. match
      end
      local fu = require("NeoAI.utils.file_utils")
      if fu.exists(full_path) then
        table.insert(filepaths, full_path)
      end
    end
  end

  return filepaths
end

--- 搜索目标文件
--- @param session_id string
local function _search_target_files(session_id)
  local state = _pipeline_state[session_id]
  if not state then return end

  -- 从查询中提取关键词进行搜索
  local query = state.query
  local keywords = {}

  -- 提取文件名关键词
  for word in query:gmatch("[%w_%-%.]+%.[%w_%-%.]+") do
    table.insert(keywords, word)
  end

  if #keywords == 0 then
    -- 没有具体文件名，使用项目根目录
    local fu = require("NeoAI.utils.file_utils")
    local files = fu.list_files(state.project_path, "**/*.{lua,py,js,ts,go,rs,java,cpp,c,h,hpp}")
    if #files > 0 then
      -- 取前 10 个文件
      local target_files = {}
      for i = 1, math.min(10, #files) do
        table.insert(target_files, files[i])
      end
      _check_files_parseable(session_id, target_files)
    else
      _finalize_pipeline(session_id, false, "未找到目标文件。")
    end
    return
  end

  -- 搜索文件
  local found_files = {}
  for _, keyword in ipairs(keywords) do
    local grep_cmd = string.format("find %s -name '%s' -type f 2>/dev/null | head -5", state.project_path, keyword)
    local handle = io.popen(grep_cmd)
    if handle then
      for line in handle:lines() do
        if line and line ~= "" then
          table.insert(found_files, line)
        end
      end
      handle:close()
    end
  end

  if #found_files > 0 then
    _check_files_parseable(session_id, found_files)
  else
    _finalize_pipeline(session_id, false, "未找到目标文件。请指定具体的文件路径。")
  end
end

--- 检查文件是否可被语法树解析
--- @param session_id string
--- @param filepaths table
local function _check_files_parseable(session_id, filepaths)
  local state = _pipeline_state[session_id]
  if not state then return end

  local parseable_files = {}
  local tree_blocks = {}

  for _, filepath in ipairs(filepaths) do
    local parseable, lang, err = _check_tree_sitter_parseable(filepath)
    if parseable then
      table.insert(parseable_files, {
        filepath = filepath,
        language = lang,
      })

      -- 列出语法树块结构
      local blocks, block_err = _list_tree_blocks(filepath)
      if blocks then
        tree_blocks[filepath] = blocks
      end
    else
      -- 不可解析，仍记录但标记
      table.insert(parseable_files, {
        filepath = filepath,
        language = nil,
        error = err or "不可解析",
      })
    end
  end

  state.parseable_files = parseable_files
  state.tree_blocks = tree_blocks

  -- 构建分析结果摘要
  local analysis_summary = _build_analysis_summary(state)

  -- 通知 UI
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_constants.PIPELINE_ANALYSIS_COMPLETE,
    data = {
      session_id = session_id,
      analysis = analysis_summary,
      parseable_files = parseable_files,
      tree_blocks = tree_blocks,
    },
  })

  -- 进入初筛阶段
  _run_screening_stage(session_id, analysis_summary)
end

--- 构建分析结果摘要
--- @param state table
--- @return string
local function _build_analysis_summary(state)
  local parts = {}
  table.insert(parts, "# 项目分析结果")
  table.insert(parts, string.format("\n项目路径: %s", state.project_path or "未知"))
  table.insert(parts, string.format("目标文件数: %d", #(state.parseable_files or {})))

  table.insert(parts, "\n## 文件列表")
  for _, f in ipairs(state.parseable_files or {}) do
    local lang_info = f.language and string.format("(%s)", f.language) or (f.error or "(不可解析)")
    table.insert(parts, string.format("- %s %s", f.filepath, lang_info))
  end

  table.insert(parts, "\n## 语法树块结构")
  for filepath, blocks in pairs(state.tree_blocks or {}) do
    table.insert(parts, string.format("\n### %s", filepath))
    table.insert(parts, string.format("语言: %s", blocks.language))
    table.insert(parts, string.format("块类型: %s", table.concat(vim.tbl_keys(blocks.block_types), ", ")))
    table.insert(parts, string.format("块数量: %d", blocks.total_blocks))

    -- 按深度分组显示
    local by_depth = {}
    for _, block in ipairs(blocks.blocks) do
      if not by_depth[block.depth] then
        by_depth[block.depth] = {}
      end
      table.insert(by_depth[block.depth], block)
    end

    local depths = vim.tbl_keys(by_depth)
    table.sort(depths)
    for _, depth in ipairs(depths) do
      local indent = string.rep("  ", depth)
      for _, block in ipairs(by_depth[depth]) do
        table.insert(parts, string.format("%s[%s] %s (行 %d-%d)",
          indent, block.type, block.text, block.start_row + 1, block.end_row + 1))
      end
    end
  end

  return table.concat(parts, "\n")
end

-- ========== 初筛阶段 (AI1) ==========

--- 运行初筛阶段
--- AI1 循环读取代码，直到认为足够
--- @param session_id string
--- @param analysis_summary string
local function _run_screening_stage(session_id, analysis_summary)
  local state = _pipeline_state[session_id]
  if not state then return end

  state.current_stage = PIPELINE_STAGES.SCREENING

  local agent_prompt = AGENT_PROMPTS[PIPELINE_STAGES.SCREENING]

  -- 构建消息
  local messages = {
    {
      role = "system",
      content = agent_prompt.system,
    },
    {
      role = "user",
      content = string.format(
        "用户提问: %s\n\n项目分析结果:\n%s\n\n请读取相关代码文件，理解代码结构后返回总结。",
        state.query,
        analysis_summary
      ),
    },
  }

  -- 启动 AI1 循环
  pipeline_agent.start_agent_loop({
    session_id = session_id .. "_screening",
    parent_session_id = session_id,
    window_id = state.window_id,
    messages = messages,
    options = state.options,
    model_index = state.model_index,
    ai_preset = state.ai_preset,
    allowed_tools = agent_prompt.tools,
    stage = PIPELINE_STAGES.SCREENING,
    on_summary = function(summary, usage)
      _on_screening_complete(session_id, summary, usage)
    end,
    on_error = function(err)
      _finalize_pipeline(session_id, false, "初筛阶段失败: " .. tostring(err))
    end,
  })
end

--- 初筛完成回调
--- @param session_id string
--- @param summary string
--- @param usage table
local function _on_screening_complete(session_id, summary, usage)
  local state = _pipeline_state[session_id]
  if not state then return end

  state.summaries[PIPELINE_STAGES.SCREENING] = summary
  _accumulate_usage(state, usage)

  logger.info("[pipeline] 初筛阶段完成, session=%s", session_id)

  -- 检查是否需要进行编辑
  if summary and summary ~= "" then
    _run_editing_stage(session_id, summary)
  else
    _finalize_pipeline(session_id, false, "初筛阶段未返回总结。")
  end
end

-- ========== 编辑阶段 (AI2) ==========

--- 运行编辑阶段
--- AI2 循环编辑文件
--- @param session_id string
--- @param screening_summary string
local function _run_editing_stage(session_id, screening_summary)
  local state = _pipeline_state[session_id]
  if not state then return end

  state.current_stage = PIPELINE_STAGES.EDITING

  local agent_prompt = AGENT_PROMPTS[PIPELINE_STAGES.EDITING]

  -- 构建消息
  local messages = {
    {
      role = "system",
      content = agent_prompt.system,
    },
    {
      role = "user",
      content = string.format(
        "用户提问: %s\n\n初筛总结:\n%s\n\n请根据初筛总结执行修改。",
        state.query,
        screening_summary
      ),
    },
  }

  -- 启动 AI2 循环
  pipeline_agent.start_agent_loop({
    session_id = session_id .. "_editing",
    parent_session_id = session_id,
    window_id = state.window_id,
    messages = messages,
    options = state.options,
    model_index = state.model_index,
    ai_preset = state.ai_preset,
    allowed_tools = agent_prompt.tools,
    stage = PIPELINE_STAGES.EDITING,
    on_summary = function(summary, usage)
      _on_editing_complete(session_id, summary, usage)
    end,
    on_error = function(err)
      _finalize_pipeline(session_id, false, "编辑阶段失败: " .. tostring(err))
    end,
  })
end

--- 编辑完成回调
--- @param session_id string
--- @param summary string
--- @param usage table
local function _on_editing_complete(session_id, summary, usage)
  local state = _pipeline_state[session_id]
  if not state then return end

  state.summaries[PIPELINE_STAGES.EDITING] = summary
  _accumulate_usage(state, usage)

  logger.info("[pipeline] 编辑阶段完成, session=%s", session_id)

  -- 进入测试阶段
  _run_testing_stage(session_id, summary)
end

-- ========== 测试阶段 (AI3) ==========

--- 运行测试阶段
--- AI3 循环测试
--- @param session_id string
--- @param editing_summary string
local function _run_testing_stage(session_id, editing_summary)
  local state = _pipeline_state[session_id]
  if not state then return end

  state.current_stage = PIPELINE_STAGES.TESTING

  local agent_prompt = AGENT_PROMPTS[PIPELINE_STAGES.TESTING]

  -- 构建消息
  local messages = {
    {
      role = "system",
      content = agent_prompt.system,
    },
    {
      role = "user",
      content = string.format(
        "用户提问: %s\n\n编辑总结:\n%s\n\n请运行测试验证修改正确性。",
        state.query,
        editing_summary
      ),
    },
  }

  -- 启动 AI3 循环
  pipeline_agent.start_agent_loop({
    session_id = session_id .. "_testing",
    parent_session_id = session_id,
    window_id = state.window_id,
    messages = messages,
    options = state.options,
    model_index = state.model_index,
    ai_preset = state.ai_preset,
    allowed_tools = agent_prompt.tools,
    stage = PIPELINE_STAGES.TESTING,
    on_summary = function(summary, usage)
      _on_testing_complete(session_id, summary, usage)
    end,
    on_error = function(err)
      _finalize_pipeline(session_id, false, "测试阶段失败: " .. tostring(err))
    end,
  })
end

--- 测试完成回调
--- @param session_id string
--- @param summary string
--- @param usage table
local function _on_testing_complete(session_id, summary, usage)
  local state = _pipeline_state[session_id]
  if not state then return end

  state.summaries[PIPELINE_STAGES.TESTING] = summary
  _accumulate_usage(state, usage)

  logger.info("[pipeline] 测试阶段完成, session=%s", session_id)

  -- 构建最终结果
  local final_result = _build_final_result(state)
  _finalize_pipeline(session_id, true, final_result)
end

-- ========== 辅助函数 ==========

--- 累积 usage
--- @param state table
--- @param usage table
local function _accumulate_usage(state, usage)
  if not usage or not next(usage) then
    return
  end
  local acc = state.accumulated_usage
  acc.prompt_tokens = (acc.prompt_tokens or 0) + (usage.prompt_tokens or usage.input_tokens or 0)
  acc.completion_tokens = (acc.completion_tokens or 0) + (usage.completion_tokens or usage.output_tokens or 0)
  acc.total_tokens = (acc.total_tokens or 0) + (usage.total_tokens or 0)
end

--- 构建最终结果
--- @param state table
--- @return string
local function _build_final_result(state)
  local parts = {}

  table.insert(parts, "# 流水线执行完成\n")

  -- 分析结果
  table.insert(parts, "## 项目分析")
  table.insert(parts, string.format("- 项目路径: %s", state.project_path or "未知"))
  table.insert(parts, string.format("- 目标文件数: %d", #(state.parseable_files or {})))
  for _, f in ipairs(state.parseable_files or {}) do
    local lang_info = f.language and string.format("(%s)", f.language) or ""
    table.insert(parts, string.format("  - %s %s", f.filepath, lang_info))
  end

  -- 各阶段总结
  local stage_names = {
    [PIPELINE_STAGES.SCREENING] = "初筛阶段",
    [PIPELINE_STAGES.EDITING] = "编辑阶段",
    [PIPELINE_STAGES.TESTING] = "测试阶段",
  }

  for _, stage in ipairs({ PIPELINE_STAGES.SCREENING, PIPELINE_STAGES.EDITING, PIPELINE_STAGES.TESTING }) do
    local summary = state.summaries[stage]
    if summary and summary ~= "" then
      table.insert(parts, string.format("\n## %s\n%s", stage_names[stage] or stage, summary))
    end
  end

  -- Token 用量
  local usage = state.accumulated_usage
  table.insert(parts, "\n## Token 用量")
  table.insert(parts, string.format("- Prompt tokens: %d", usage.prompt_tokens or 0))
  table.insert(parts, string.format("- Completion tokens: %d", usage.completion_tokens or 0))
  table.insert(parts, string.format("- Total tokens: %d", usage.total_tokens or 0))

  return table.concat(parts, "\n")
end

--- 结束流水线
--- @param session_id string
--- @param success boolean
--- @param result string
local function _finalize_pipeline(session_id, success, result)
  local state = _pipeline_state[session_id]
  if not state then return end

  local on_complete = state.on_complete
  local saved_usage = state.accumulated_usage or {}

  -- 清理状态
  _pipeline_state[session_id] = nil

  -- 触发事件
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_constants.PIPELINE_COMPLETED,
    data = {
      session_id = session_id,
      success = success,
      result = result,
      usage = saved_usage,
    },
  })

  -- 回调
  if on_complete then
    vim.schedule(function()
      on_complete(success, result, saved_usage)
    end)
  end
end

-- ========== 停止控制 ==========

--- 请求停止流水线
--- @param session_id string
function M.request_stop(session_id)
  local state = _pipeline_state[session_id]
  if state then
    state.stop_requested = true
  end

  -- 停止所有子 agent
  for stage in pairs(PIPELINE_STAGES) do
    local agent_session_id = session_id .. "_" .. stage:lower()
    pipeline_agent.request_stop(agent_session_id)
  end
end

--- 获取流水线状态
--- @param session_id string
--- @return table|nil
function M.get_pipeline_state(session_id)
  return _pipeline_state[session_id]
end

--- 获取当前阶段
--- @param session_id string
--- @return string|nil
function M.get_current_stage(session_id)
  local state = _pipeline_state[session_id]
  return state and state.current_stage or nil
end

-- ========== 清理 ==========

--- 清理所有流水线
function M.cleanup_all()
  for session_id, state in pairs(_pipeline_state) do
    state.stop_requested = true
    -- 停止所有子 agent
    for stage in pairs(PIPELINE_STAGES) do
      local agent_session_id = session_id .. "_" .. stage:lower()
      pipeline_agent.request_stop(agent_session_id)
    end
  end
  _pipeline_state = {}
end

return M
