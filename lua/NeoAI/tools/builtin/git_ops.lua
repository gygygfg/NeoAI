--- Git 操作工具
--- @module NeoAI.tools.builtin.git_ops
--- Git 只读操作（diff/log/status/branch）与 rollback/commit。

local async = require("NeoAI.utils.async")
local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- 运行 git 命令
--- @param args table git 参数数组
--- @return Deferred resolve(输出)
local function _git(args, opts)
  opts = opts or {}
  local d = async.Deferred.new()
  local out = {}
  local job = vim.fn.jobstart({ "git", unpack(args) }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then out[#out + 1] = line end
      end
    end,
    on_exit = function(_, code)
      d:resolve({ code = code, output = table.concat(out, "\n") })
    end,
  })
  if job <= 0 then
    return async.reject({ kind = "git", message = "无法启动 git" })
  end
  return d
end

-- ========== 工具定义 ==========

local git_tools = {}

git_tools.git_status = helpers.define_tool(
  "git_status",
  "查看 git 状态（--short）。path 可选。",
  {
    type = "object",
    properties = { path = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error)
    _git({ "status", "--short" }):then_(function(r)
      on_success(r.code == 0 and (r.output or "工作区干净") or r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_diff = helpers.define_tool(
  "git_diff",
  "查看未提交的改动（git diff）。filepath 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error)
    local cmd = args.filepath and { "diff", "--", args.filepath } or { "diff" }
    _git(cmd):then_(function(r)
      on_success(r.output ~= "" and r.output or "无改动")
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_log = helpers.define_tool(
  "git_log",
  "查看提交历史。max 可选（默认 20）。",
  {
    type = "object",
    properties = { max = { type = "integer" }, path = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error)
    local cmd = { "log", "--oneline", "-n", tostring(args.max or 20) }
    if args.path then cmd[#cmd + 1] = "--"; cmd[#cmd + 1] = args.path end
    _git(cmd):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_commit_detail = helpers.define_tool(
  "git_commit_detail",
  "查看某次提交详情。ref 必填。",
  {
    type = "object",
    properties = { ref = { type = "string" } },
    required = { "ref" },
  },
  function(args, on_success, on_error)
    _git({ "show", "--stat", args.ref }):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_branch = helpers.define_tool(
  "git_branch",
  "查看分支列表（-a）。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success, on_error)
    _git({ "branch", "-a" }):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_file_history = helpers.define_tool(
  "git_file_history",
  "查看文件历史。filepath 必填；max 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, max = { type = "integer" } },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    _git({ "log", "--oneline", "-n", tostring(args.max or 20), "--", args.filepath }):then_(function(r)
      on_success(r.output)
    end, function(e) on_error(e.message) end)
  end,
  { category = "git" }
)

git_tools.git_rollback = helpers.define_tool(
  "git_rollback",
  "回滚文件到指定提交。filepath 必填；commit 可选（默认 HEAD）。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, commit = { type = "string" } },
    required = { "filepath" },
  },
  function(args, on_success, on_error)
    local commit = args.commit or "HEAD"
    _git({ "checkout", commit, "--", args.filepath }):then_(function(r)
      if r.code == 0 then
        helpers.reload_buffers_for(args.filepath)
        on_success(("已回滚 %s 到 %s"):format(args.filepath, commit))
      else
        on_error(r.output)
      end
    end, function(e) on_error(e.message) end)
  end,
  { category = "git", approval = { auto_allow = false } }
)

git_tools.git_auto_commit_config = helpers.define_tool(
  "git_auto_commit_config",
  "查看/设置自动提交配置。auto_commit 可选。",
  {
    type = "object",
    properties = { auto_commit = { type = "boolean" } },
    required = {},
  },
  function(args, on_success)
    on_success("自动提交配置: " .. tostring(args.auto_commit == true))
  end,
  { category = "git" }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(git_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
