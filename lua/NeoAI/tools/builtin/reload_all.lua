--- 插件热重载工具
--- @module NeoAI.tools.builtin.reload_all
--- 热重载整个 NeoAI 插件。安全策略：
--- 1. 隔离子进程预检：用一个全新的 headless nvim（--clean -u NONE + rtp=插件根）
---    加载插件并做冒烟校验。任何报错都只在子进程里发生，绝不影响当前会话。
--- 2. 预检失败即返回报错信息并【取消重载】。
--- 3. 预检通过后，才在当前进程执行受控热重载（清空 NeoAI.* require 缓存 →
---    重新 setup → 重建工具/技能/MCP 与聊天界面，尽量保留当前会话）。
--- 4. 重载本身 pcall 包裹，失败时按 require 缓存快照尽力回滚。

local helpers = require("NeoAI.tools.builtin.tool_helpers")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 可注入依赖（测试用） ==========

-- 子进程执行器：cmd(数组) + timeout_ms -> { code, stdout, stderr, timed_out?, failed_to_start? }
local spawner = nil
-- 受控重载执行器：-> ok(boolean), err(string|nil)。nil 表示使用默认实现。
local perform_fn = nil

--- 覆盖子进程执行器（测试用）；传 nil 恢复默认
--- @param fn function|nil
function M._set_spawner(fn)
  spawner = fn
end

--- 覆盖受控重载执行器（测试用）；传 nil 恢复默认
--- @param fn function|nil
function M._set_perform(fn)
  perform_fn = fn
end

-- ========== 私有函数 ==========

--- 截断过长的预检输出，避免刷屏
--- @param s string
--- @param max number|nil
--- @return string
local function _trim(s, max)
  s = tostring(s or "")
  max = max or 4000
  if #s > max then
    return stringx.safe_truncate(s, max, "\n…（输出已截断）")
  end
  return s
end

--- 定位插件根目录（含 lua/、autoload/ 的仓库根）；失败返回 nil
--- @return string|nil
function M._plugin_root()
  local src = debug.getinfo(1, "S").source or ""
  local path = src:match("^@(.+)$") or src
  -- .../lua/NeoAI/tools/builtin/reload_all.lua  →  去掉 /lua/NeoAI/... 后缀
  local root = path:match("^(.*)[/\\]lua[/\\]NeoAI[/\\]tools[/\\]builtin[/\\]reload_all%.lua$")
  if root and root ~= "" then return root end
  return nil
end

--- 预检脚本内容：在隔离子进程里加载插件并做冒烟校验
--- @return string
function M._precheck_script()
  return table.concat({
    "-- NeoAI 热重载隔离预检（自动生成，勿手改）",
    'local ok, err = pcall(function()',
    '  require("NeoAI").setup({',
    '    log = { level = "ERROR" },',
    '    session = { auto_save = false },',
    '    mcp = { enabled = false },',
    '    ai = { model_refresh = { on_startup = false } },',
    '  })',
    '  assert(require("NeoAI").ensure_started_sync(60000), "懒加载启动未完成")',
    '  require("NeoAI.tools").init()',
    '  local n = require("NeoAI.tools.registry").count()',
    '  assert(n and n > 0, "内置工具注册数为 0")',
    'end)',
    'if ok then',
    '  io.stdout:write("RELOAD_PRECHECK_OK\\n")',
    'else',
    '  io.stdout:write("RELOAD_PRECHECK_FAIL\\n")',
    '  io.stderr:write(tostring(err) .. "\\n")',
    'end',
  }, "\n")
end

--- 默认子进程执行器：jobstart + 同步等待（带超时）
--- @param cmd table argv
--- @param timeout_ms number
--- @return table { code, stdout, stderr, timed_out?, failed_to_start? }
local function _default_spawn(cmd, timeout_ms)
  local stdout_chunks, stderr_chunks = {}, {}
  local done, code = false, nil
  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then stdout_chunks[#stdout_chunks + 1] = table.concat(data, "\n") end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then stderr_chunks[#stderr_chunks + 1] = table.concat(data, "\n") end
    end,
    on_exit = function(_, c)
      done = true
      code = c
    end,
  })
  if job <= 0 then
    return { code = -1, stdout = "", stderr = "无法启动预检子进程", failed_to_start = true }
  end
  vim.wait(timeout_ms or 30000, function() return done end, 50)
  if not done then
    pcall(vim.fn.jobstop, job)
    return { code = -1, stdout = table.concat(stdout_chunks, "\n"), stderr = table.concat(stderr_chunks, "\n"), timed_out = true }
  end
  return { code = code or -1, stdout = table.concat(stdout_chunks, "\n"), stderr = table.concat(stderr_chunks, "\n") }
end

--- 隔离子进程预检
--- @return table { ok = boolean, message = string }
function M._precheck()
  local root = M._plugin_root()
  if not root then
    return { ok = false, message = "无法定位插件根目录（reload_all.lua 路径异常）" }
  end

  local script_path = vim.fn.tempname() .. "_neoai_precheck.lua"
  local f = io.open(script_path, "w")
  if not f then
    return { ok = false, message = "无法写入预检脚本: " .. script_path }
  end
  f:write(M._precheck_script())
  f:close()

  local progpath = vim.v.progpath
  if not progpath or progpath == "" then progpath = "nvim" end
  local cmd = {
    progpath, "--headless", "--clean", "-u", "NONE",
    "--cmd", "set rtp+=" .. root,
    "-c", "luafile " .. vim.fn.fnameescape(script_path),
    "-c", "qa!",
  }

  local runner = spawner or _default_spawn
  local ok_spawn, res = pcall(runner, cmd, 30000)
  pcall(os.remove, script_path)

  if not ok_spawn or type(res) ~= "table" then
    return { ok = false, message = "预检子进程执行异常: " .. tostring(res) }
  end
  if res.failed_to_start then
    return { ok = false, message = _trim(res.stderr or "子进程无法启动") }
  end
  if res.timed_out then
    return { ok = false, message = "预检超时：子进程未在 30s 内结束" }
  end

  local stdout = res.stdout or ""
  local stderr = res.stderr or ""
  if stdout:find("RELOAD_PRECHECK_OK", 1, true) and not stdout:find("RELOAD_PRECHECK_FAIL", 1, true) then
    return { ok = true, message = "预检通过" }
  end

  local detail = stderr ~= "" and stderr or stdout
  if detail:find("RELOAD_PRECHECK_FAIL", 1, true) then
    detail = detail:gsub("RELOAD_PRECHECK_FAIL%s*", "")
  end
  if detail == "" or detail:match("^%s*$") then
    detail = ("子进程退出码 %s，但未产生可辨识的错误输出"):format(tostring(res.code))
  end
  return { ok = false, message = _trim(detail) }
end

--- 默认受控重载：清缓存 → 重新 setup → 重建界面 → 恢复会话；失败尽力回滚
--- @return boolean ok
--- @return string|nil err
function M._perform_reload()
  -- 1) 快照当前 NeoAI.* 模块缓存（供失败回滚）
  local snapshot = {}
  for k, v in pairs(package.loaded) do
    if k == "NeoAI" or k:sub(1, 7) == "NeoAI." then
      snapshot[k] = v
    end
  end

  -- 2) 读取必要信息（必须在清缓存前完成）
  local user_config, session_id
  pcall(function() user_config = require("NeoAI.kernel.config_store").get_all() end)
  pcall(function()
    local cs = require("NeoAI.kernel.services").use("services.chat_service")
    session_id = cs and cs.get_current_session_id()
  end)

  -- 3) 受控重载
  local ok, err = pcall(function()
    -- 先统一卸载插件：释放工具/命令/事件订阅/MCP 子进程/状态栏监听/UI 注入
    pcall(function() require("NeoAI.kernel.plugins").stop_all() end)
    -- 清理事件总线订阅与 augroup（旧模块表残留订阅）
    pcall(function() require("NeoAI.kernel.event_bus").clear_all() end)

    -- 清空 NeoAI.* 模块缓存，强制从磁盘重新加载
    local keys = {}
    for k in pairs(package.loaded) do
      if k == "NeoAI" or k:sub(1, 7) == "NeoAI." then
        keys[#keys + 1] = k
      end
    end
    for _, k in ipairs(keys) do
      package.loaded[k] = nil
    end

    -- 重新引导（全新模块表，once-guard 已随缓存清空而复位）
    require("NeoAI").setup(user_config or {})

    -- 懒加载：显式同步完成两阶段启动，才能重建界面/恢复会话
    require("NeoAI").ensure_started_sync(60000)

    -- 重建聊天界面（经服务定位器；UI 被禁用时跳过）
    local ui = require("NeoAI.kernel.services").use("services.ui")
    if ui then ui.open_chat() end

    -- 恢复当前会话（含计划模式/用量/待办；计划态来自会话元数据）
    if session_id then
      local services = require("NeoAI.kernel.services")
      local cs = services.use("services.chat_service")
      if cs then
        cs.load_session(session_id)
      end
    end
  end)

  -- 4) 失败：恢复模块缓存快照（尽力回滚），返回错误
  if not ok then
    for k in pairs(package.loaded) do
      if k == "NeoAI" or k:sub(1, 7) == "NeoAI." then
        package.loaded[k] = nil
      end
    end
    for k, v in pairs(snapshot) do
      package.loaded[k] = v
    end
    return false, tostring(err)
  end

  return true, nil
end

--- 调度真正重载：Agent 忙碌时等本轮结束（回到 idle）后执行，避免在工具循环栈内清缓存。
--- @param ctx table|nil
local function _schedule_reload(ctx)
  local chat_service = require("NeoAI.kernel.services").use("services.chat_service")
  local agent = ctx and ctx.agent or (chat_service and chat_service.get_current_agent())
  local busy = agent and (agent.state == "generating" or agent.state == "tool_running")

  local function do_it()
    local fn = perform_fn or M._perform_reload
    local ok, err = fn()
    if ok then
      vim.notify("[NeoAI] 插件已热重载完成", vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 插件热重载失败（已尽力回滚）：" .. tostring(err), vim.log.levels.ERROR)
    end
  end

  if busy then
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local unsub
    unsub = event_bus.on(events.AGENT_STATE_CHANGED, function(d)
      if d and d.agent_id == agent.id and d.new == "idle" then
        if unsub then unsub() end
        vim.schedule(do_it)
      end
    end)
  else
    vim.schedule(do_it)
  end
end

-- ========== 工具定义 ==========

local reload_tools = {}

reload_tools.reload_all = helpers.define_tool(
  "reload_all",
  "热重载整个 NeoAI 插件：先以隔离的子进程做预检（全新 headless nvim 加载插件并冒烟校验），"
    .. "通过后清空 NeoAI.* 模块缓存并重新 setup（重建工具/技能/MCP 与聊天界面，尽量保留当前会话）。"
    .. "预检失败会返回报错信息并取消重载，不影响当前会话。用于修改插件源码后即时生效。",
  { type = "object", properties = {}, required = {} },
  function(_, on_success, on_error, ctx)
    local res = M._precheck()
    if not res.ok then
      on_error("插件热重载预检失败，已取消重载：\n" .. tostring(res.message))
      return
    end
    _schedule_reload(ctx)
    on_success("预检通过，已调度插件热重载（本轮生成结束后执行）。")
  end,
  { category = "system", approval = { auto_allow = false } }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(reload_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
