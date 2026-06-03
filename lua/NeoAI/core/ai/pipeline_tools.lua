-- pipeline_tools.lua
-- 流水线专用工具模块
-- 提供判断项目修改意图、检查语法树可解析性、列出语法树块结构等工具
-- 这些工具作为编排器内部函数，不注册为 AI 可调用的工具

local M = {}

local logger = require("NeoAI.utils.logger")

-- ========== 工具1: 检测修改意图 ==========

--- 检测用户提问是否涉及修改项目代码
--- @param query string 用户提问
--- @return table result
---   - is_modification: boolean - 是否涉及修改
---   - project_path: string|nil - 项目路径
---   - confidence: number - 置信度 (0-1)
---   - reason: string - 判断理由
function M.detect_modification_intent(query)
  if not query or query == "" then
    return {
      is_modification = false,
      project_path = nil,
      confidence = 0,
      reason = "查询为空",
    }
  end

  local lower = query:lower()

  -- 修改类关键词（加权）
  local modify_keywords = {
    { words = { "修改", "添加", "删除", "更新", "修复", "重构", "优化", "实现", "增加", "改动", "变更", "编辑", "改写" }, weight = 0.8 },
    { words = { "add", "remove", "delete", "update", "fix", "refactor", "optimize", "implement", "change", "modify", "edit", "create", "write", "rewrite" }, weight = 0.7 },
    { words = { "在.*中.*添加", "给.*增加", "把.*改成", "将.*改为" }, weight = 0.9 },
  }

  -- 查询类关键词（负向加权）
  local query_keywords = {
    "什么是", "怎么", "如何", "解释", "说明", "介绍",
    "what is", "how to", "explain", "describe", "tell me",
    "show me", "help", "guide", "tutorial",
    "为什么", "why", "when", "where", "who",
  }

  -- 计算分数
  local score = 0

  -- 负向匹配
  for _, kw in ipairs(query_keywords) do
    if lower:find(kw, 1, true) then
      score = score - 0.5
    end
  end

  -- 正向匹配
  for _, entry in ipairs(modify_keywords) do
    for _, kw in ipairs(entry.words) do
      if lower:find(kw, 1, true) then
        score = score + entry.weight
        break
      end
    end
  end

  -- 检查是否包含文件路径模式
  local file_pattern = query:match("[%w_%-%.]+%.[%w_%-%.]+")
  if file_pattern then
    score = score + 0.3
  end

  -- 判断
  local is_modification = score > 0.3
  local project_path = is_modification and vim.fn.getcwd() or nil

  return {
    is_modification = is_modification,
    project_path = project_path,
    confidence = math.min(1, math.max(0, score)),
    reason = is_modification and "检测到修改意图" or "未检测到修改意图",
  }
end

-- ========== 工具2: 检查语法树可解析性 ==========

--- 检查文件是否可被 Tree-sitter 语法树解析
--- @param filepath string 文件路径
--- @return table result
---   - parseable: boolean
---   - language: string|nil
---   - error: string|nil
---   - details: table|nil
function M.check_tree_sitter_parseable(filepath)
  if not filepath or filepath == "" then
    return { parseable = false, language = nil, error = "文件路径为空" }
  end

  -- 检查 Tree-sitter 是否可用
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return { parseable = false, language = nil, error = "Tree-sitter 不可用（需要 Neovim >= 0.5）" }
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
      [".env"] = "ini",
      [".gitignore"] = "gitignore",
      ["CMakeLists.txt"] = "cmake",
      ["Cargo.toml"] = "toml",
      ["package.json"] = "json",
      ["tsconfig.json"] = "json",
      [".eslintrc.js"] = "javascript",
      [".prettierrc"] = "json",
    }
    lang = name_map[basename]
  end

  if not lang then
    return {
      parseable = false,
      language = nil,
      error = string.format("无法从文件路径推断 Tree-sitter 语言: %s", filepath),
    }
  end

  -- 检查解析器是否已安装
  local ok_inspect, _ = pcall(ts.language.inspect, lang)
  if not ok_inspect then
    return {
      parseable = false,
      language = lang,
      error = string.format("Tree-sitter 解析器 '%s' 未安装", lang),
    }
  end

  return {
    parseable = true,
    language = lang,
    error = nil,
    details = {
      filepath = filepath,
      ext = ext,
      parser = lang,
    },
  }
end

-- ========== 工具3: 列出语法树块结构 ==========

--- 列出文件的所有语法树块结构节点
--- 使用 block_node_types 过滤出有结构的代码块
--- @param filepath string 文件路径
--- @return table result
---   - success: boolean
---   - blocks: table|nil
---   - error: string|nil
function M.list_tree_blocks(filepath)
  if not filepath or filepath == "" then
    return { success = false, blocks = nil, error = "文件路径为空" }
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

  -- 等待异步回调完成
  vim.wait(10000, function() return done end, 50)

  if err_msg then
    return { success = false, blocks = nil, error = err_msg }
  end

  if not result or not result.nodes then
    return { success = false, blocks = nil, error = "解析结果为空" }
  end

  -- 过滤出块结构节点
  local blocks = {}
  local seen_types = {}
  local by_depth = {}

  for _, node in ipairs(result.nodes) do
    if block_node_types[node.type] and node.depth > 0 then
      if not seen_types[node.type] then
        seen_types[node.type] = true
      end

      local block = {
        type = node.type,
        text = (node.text:match("^[^\n]+") or node.text):sub(1, 100),
        start_row = node.start_row,
        end_row = node.end_row,
        depth = node.depth,
        type_index = node.type_index,
      }
      table.insert(blocks, block)

      if not by_depth[node.depth] then
        by_depth[node.depth] = {}
      end
      table.insert(by_depth[node.depth], block)
    end
  end

  -- 构建可读的树形结构文本
  local tree_text_parts = {}
  table.insert(tree_text_parts, string.format("文件: %s", filepath))
  table.insert(tree_text_parts, string.format("语言: %s", result.language))
  table.insert(tree_text_parts, string.format("块类型: %s", table.concat(vim.tbl_keys(seen_types), ", ")))
  table.insert(tree_text_parts, string.format("块数量: %d", #blocks))
  table.insert(tree_text_parts, "")

  local depths = vim.tbl_keys(by_depth)
  table.sort(depths)
  for _, depth in ipairs(depths) do
    local indent = string.rep("  ", depth)
    for _, block in ipairs(by_depth[depth]) do
      local line_range = string.format("行 %d-%d", block.start_row + 1, block.end_row + 1)
      table.insert(tree_text_parts, string.format("%s[%s] %s (%s)", indent, block.type, block.text, line_range))
    end
  end

  return {
    success = true,
    blocks = blocks,
    block_types = seen_types,
    total_blocks = #blocks,
    language = result.language,
    tree_text = table.concat(tree_text_parts, "\n"),
    error = nil,
  }
end

-- ========== 工具4: 从查询提取文件路径 ==========

--- 从用户查询中提取文件路径
--- @param query string 用户提问
--- @param project_path string 项目路径
--- @return table filepaths
function M.extract_file_paths(query, project_path)
  local filepaths = {}

  if not query or query == "" then
    return filepaths
  end

  -- 匹配文件路径模式
  local path_patterns = {
    "([%w_%-%.]+%.[%w_%-%.]+)",                    -- filename.ext
    "([%w_%-%./\\]+%.[%w_%-%.]+)",                  -- path/to/filename.ext
    "`([^`]+%.[%w_%-%.]+)`",                        -- `filename.ext`
    ["'([^']+%.[%w_%-%.]+)'"] = true,               -- 'filename.ext'
  }

  for _, pattern in ipairs({ "`([^`]+%.[%w_%-%.]+)`", "'([^']+%.[%w_%-%.]+)'", "([%w_%-%.]+%.[%w_%-%.]+)" }) do
    for match in query:gmatch(pattern) do
      local full_path = match
      if not vim.startswith(full_path, "/") then
        full_path = project_path .. "/" .. match
      end
      local fu = require("NeoAI.utils.file_utils")
      if fu.exists(full_path) then
        -- 去重
        local already_added = false
        for _, fp in ipairs(filepaths) do
          if fp == full_path then
            already_added = true
            break
          end
        end
        if not already_added then
          table.insert(filepaths, full_path)
        end
      end
    end
  end

  return filepaths
end

return M
