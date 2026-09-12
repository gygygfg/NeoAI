--- MCP 管理器
--- @module NeoAI.services.mcp
--- 连接配置的 MCP 服务器（stdio / streamable http），把 tools/resources/prompts
--- 桥接进 NeoAI 工具系统；负责预缓存、动态刷新、失败驱动（stale）刷新、生命周期。
---
--- 工具时序（对齐需求）：
--- 1. 预缓存：init() 先读 mcp_cache 同步注册工具/资源/提示，服务器未连接即已可见；
--- 2. 动态更新：连接/重连/变更通知后刷新定义，更新缓存，发 MCP_TOOLS_UPDATED；
--- 3. 失败驱动：tools/call 因 schema 不匹配失败标记服务器 stale，下一轮发送前
---    经 tool_loop.set_pre_round_refresh 钩子刷新并重绑定 agent.tools。

local async = require("NeoAI.utils.async")
local json = require("NeoAI.utils.json")
local logger = require("NeoAI.kernel.logger")
local registry = require("NeoAI.tools.registry")
local stringx = require("NeoAI.utils.stringx")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local cache = require("NeoAI.services.mcp.cache")
local transports = require("NeoAI.services.mcp.transports")
local client_mod = require("NeoAI.services.mcp.client")

local M = {}

-- ========== 私有状态 ==========

local state = {
  enabled = false,
  servers = {}, -- name -> { cfg, transport, client, tools, resources, prompts, toolnames, state }
  started = false,
  shutting_down = false,
}

-- 工具名前缀分隔
local PREFIX = "mcp__"
local SEP = "__"

-- ========== 私有工具 ==========

--- 规范化工具名的服务器/工具段（去非法字符）
--- @param s string
--- @return string
local function _sanitize(s)
  return (tostring(s):gsub("[^%w%-_]", "_"))
end

--- 生成 NeoAI 工具名
--- @param server string
--- @param tool string
--- @return string
local function _name(server, tool)
  return PREFIX .. _sanitize(server) .. SEP .. _sanitize(tool)
end

--- 服务器配置的暴露开关
--- @param server string
--- @param key string "tools"|"resources"|"prompts"
--- @return boolean
local function _expose(server, key)
  local cfg = state.servers[server]
  if not cfg then return true end
  if cfg.cfg.expose == nil then return true end
  return cfg.cfg.expose[key] ~= false
end

--- 工具定义注册（含 resources/prompts 工具）
--- 每个远端工具注册一个 NeoAI 工具，approval 与 source=mcp 均设为可延展。
--- @param server string
--- @param raw table 远端工具 { name, description, inputSchema }
local function _register_tool(server, raw)
  local cfg = state.servers[server]
  local tool_name = _name(server, raw.name)
  local approval = (cfg and cfg.cfg.approval) or {}
  local tool = {
    name = tool_name,
    description = raw.description or ("执行 MCP 工具 " .. raw.name),
    parameters = raw.inputSchema or raw.schema or { type = "object", properties = {}, required = {} },
    func = function(args, on_success, on_error)
      M.call_tool(server, raw.name, args):then_(on_success, function(err)
        on_error(err and err.message or tostring(err))
      end)
    end,
    category = "mcp",
    source = "mcp",
    mcp_server = server,
    mcp_tool = raw.name,
    mcp_plan_safe = cfg and cfg.cfg.plan_safe == true,
    approval = {
      auto_allow = approval.auto_allow == true,
      allowed_directories = approval.allowed_directories,
      allowed_param_groups = approval.allowed_param_groups,
    },
    timeout = cfg and cfg.cfg.timeout_ms,
  }
  return tool
end

--- 注册 resources / prompts 浏览工具（每服务器一组，保持审批作用域干净）
--- @param server string
local function _browse_tools(server)
  local cfg = state.servers[server]
  local approval = (cfg and cfg.cfg.approval) or {}
  local tools = {}
  if _expose(server, "resources") then
    tools[#tools + 1] = {
      name = _name(server, "list_resources"),
      description = ("列出 MCP 服务器 '%s' 的可用资源（只读）。"):format(server),
      parameters = { type = "object", properties = {}, required = {} },
      func = function(args, on_success, on_error)
        M.list_resources(server):then_(on_success, function(e) on_error(e and e.message or tostring(e)) end)
      end,
      category = "mcp", source = "mcp", mcp_server = server, mcp_plan_safe = cfg and cfg.cfg.plan_safe == true,
      approval = { auto_allow = true },
    }
    tools[#tools + 1] = {
      name = _name(server, "read_resource"),
      description = ("读取 MCP 服务器 '%s' 的指定资源（只读）。参数 uri 必填。"):format(server),
      parameters = {
        type = "object",
        properties = { uri = { type = "string", description = "资源 URI" } },
        required = { "uri" },
      },
      func = function(args, on_success, on_error)
        M.read_resource(server, args.uri):then_(on_success, function(e) on_error(e and e.message or tostring(e)) end)
      end,
      category = "mcp", source = "mcp", mcp_server = server, mcp_plan_safe = cfg and cfg.cfg.plan_safe == true,
      approval = approval,
    }
  end
  if _expose(server, "prompts") then
    tools[#tools + 1] = {
      name = _name(server, "list_prompts"),
      description = ("列出 MCP 服务器 '%s' 的可用提示模板（只读）。"):format(server),
      parameters = { type = "object", properties = {}, required = {} },
      func = function(args, on_success, on_error)
        M.list_prompts(server):then_(on_success, function(e) on_error(e and e.message or tostring(e)) end)
      end,
      category = "mcp", source = "mcp", mcp_server = server, mcp_plan_safe = cfg and cfg.cfg.plan_safe == true,
      approval = { auto_allow = true },
    }
    tools[#tools + 1] = {
      name = _name(server, "get_prompt"),
      description = ("获取 MCP 服务器 '%s' 的指定提示模板内容，供拼接后续上下文。"):format(server),
      parameters = {
        type = "object",
        properties = {
          name = { type = "string", description = "提示模板名称" },
          arguments = { type = "object", description = "模板参数（可选）" },
        },
        required = { "name" },
      },
      func = function(args, on_success, on_error)
        M.get_prompt(server, args.name, args.arguments):then_(on_success, function(e) on_error(e and e.message or tostring(e)) end)
      end,
      category = "mcp", source = "mcp", mcp_server = server, mcp_plan_safe = cfg and cfg.cfg.plan_safe == true,
      approval = approval,
    }
  end
  for _, t in ipairs(tools) do
    registry.update(t)
  end
  return tools
end

--- 注册/覆盖某服务器的全部工具（tools + resources + prompts）
--- @param server string
--- @return table 注册的工具名数组
local function _register_server_tools(server)
  local cfg = state.servers[server]
  local names = {}
  -- 移除旧的（防残留/漂移）
  for _, old in ipairs(cfg.toolnames or {}) do
    registry.remove(old)
  end
  cfg.toolnames = {}
  -- 远端 tools
  if _expose(server, "tools") then
    for _, raw in ipairs(cfg.tools or {}) do
      local def = _register_tool(server, raw)
      registry.update(def)
      names[#names + 1] = def.name
    end
  end
  -- resources / prompts 浏览工具
  local browse = _browse_tools(server)
  for _, b in ipairs(browse) do
    names[#names + 1] = b.name
  end
  cfg.toolnames = names
  return names
end

--- 错误是否指示「参数/schema 不匹配」（触发 stale 刷新）
--- @param result table tools/call 结果 |nil
--- @return boolean
local function _is_schema_error(result)
  if not result then return false end
  -- JSON-RPC error codes
  if result.kind == "mcp" and (result.code == -32602 or result.code == -32601) then return true end
  if result.code == -32602 or result.code == -32601 then return true end
  -- isError 文本
  if result.isError then
    local text = ""
    for _, c in ipairs(result.content or {}) do
      text = text .. tostring(c.text or c.content or "")
    end
    text = text:lower()
    local patterns = {
      "unknown ", "invalid", "illegal", "not found",
      "unexpected argument", "extra", "unrecognized", "missing required",
      "does not exist", undefined,
    }
    for _, p in ipairs(patterns) do
      if text:find(p, 1, true) then return true end
    end
  end
  return false
end

--- 展平 tools/call 返回 content 为字符串
--- @param result table tools/call result
--- @return string
local function _flatten_content(result)
  local parts = {}
  for _, c in ipairs((result and result.content) or {}) do
    if type(c) == "string" then
      parts[#parts + 1] = c
    elseif type(c) == "table" then
      if c.type == "text" then
        parts[#parts + 1] = tostring(c.text or "")
      elseif c.type == "image" then
        parts[#parts + 1] = ("[image %s]"):format(tostring(c.mimeType or "unknown"))
      elseif c.text then
        parts[#parts + 1] = tostring(c.text)
      else
        parts[#parts + 1] = json.encode(c)
      end
    end
  end
  if #parts == 0 then return "（无返回内容）" end
  return table.concat(parts, "\n")
end

--- 服务器是否已就绪（连接 + 握手完成）
--- @param server string
--- @return boolean
local function _ready(server)
  local cfg = state.servers[server]
  return cfg and cfg.client and cfg.client:is_initialized() and cfg.state == "ready"
end

--- 获取已就绪的服务器客户端（供资源/提示访问）
--- @param server string
--- @return table|nil
local function _ready_client(server)
  if not _ready(server) then return nil end
  return state.servers[server].client
end

--- 获取服务器客户端，未连接则连接（惰性）
--- 复用仍存活（未关闭且传输未断开）的客户端；否则重建（含 stdio 进程退出后的重连）。
--- @param server string
--- @return table|nil client
local function _ensure_client(server)
  local cfg = state.servers[server]
  if not cfg then return nil end
  -- 复用仍存活客户端（关闭 / 传输断开都视为失效，需重建）
  if cfg.client and not cfg.client.closed and not cfg.client.transport_dead then
    return cfg.client
  end
  -- 关闭失效的旧客户端（释放子进程/会话）
  if cfg.client then pcall(cfg.client.close, cfg.client, {}) end
  cfg.client = nil
  cfg.transport = nil
  local transport = transports.create(cfg.cfg, { name = server })
  if not transport then return nil end
  cfg.transport = transport
  local client = client_mod.new(transport, {
    name = server,
    timeout_ms = cfg.cfg.timeout_ms or config_store.get("mcp.timeout_ms") or 60000,
    on_log = function(level, msg) logger.log(level, "[mcp] %s %s", server, msg) end,
    on_disconnect = function()
      cfg.state = "disconnected"
      event_bus.emit(events.MCP_DISCONNECTED, { server = server })
    end,
  })
  cfg.client = client
  transport:open()
  -- 服务器->客户端通知：工具/资源/提示列表变化时刷新
  client:on_notification("notifications/tools/list_changed", function() M.refresh(server) end)
  client:on_notification("notifications/resources/list_changed", function() M.refresh(server) end)
  client:on_notification("notifications/prompts/list_changed", function() M.refresh(server) end)
  return client
end

-- ========== 工具结果（给 model 的回传） ==========

--- 调用 MCP 工具的字符串结果生成
--- @param result table|nil tools/call 原始结果
--- @param ok boolean
--- @return string
local function _tool_result_str(result, ok)
  if ok then
    return _flatten_content(result)
  end
  -- 失败：错误 + (若 schema 错误) 提示已刷新请重试
  local msg = type(result) == "table" and (result.message or result.error) or tostring(result)
  if _is_schema_error(result) then
    msg = (msg and tostring(msg) or "工具调用失败") .. "\n[提示] 该 MCP 工具的参数定义已变化，已自动刷新工具描述，请按最新 schema 重新调用。"
  end
  return "错误: " .. tostring(msg)
end

-- ========== 连接与刷新 ==========

--- 拉取能力列表并注册工具，回写缓存，发事件；返回是否有变化。
--- 变更检测：工具定义（tools）或注册名集合（toolnames）任一变化即视为 changed，
--- 供预发钩子（pre_round）在 tool 循环里决定是否重绑定 agent.tools。
--- @param server string
--- @return Deferred resolve(boolean changed)
local function _pull_and_register(server)
  local cfg = state.servers[server]
  if not cfg then return async.resolve(false) end
  local old_tools_json = json.encode(cfg.tools or {})
  local old_names = vim.deepcopy(cfg.toolnames or {})
  local client = cfg.client
  local tasks = {}
  if _expose(server, "tools") then
    tasks[#tasks + 1] = client:request("tools/list", {}, {}):then_(function(r)
      cfg.tools = (r and r.tools) or {}
    end, function(e)
      logger.warn("[mcp] %s tools/list 失败: %s", server, tostring(e and e.message or e))
    end)
  else
    cfg.tools = {}
  end
  if _expose(server, "resources") then
    tasks[#tasks + 1] = client:request("resources/list", {}, {}):then_(function(r)
      cfg.resources = (r and r.resources) or {}
    end, function(e) logger.warn("[mcp] %s resources/list 失败: %s", server, tostring(e and e.message or e)) end)
  else
    cfg.resources = {}
  end
  if _expose(server, "prompts") then
    tasks[#tasks + 1] = client:request("prompts/list", {}, {}):then_(function(r)
      cfg.prompts = (r and r.prompts) or {}
    end, function(e) logger.warn("[mcp] %s prompts/list 失败: %s", server, tostring(e and e.message or e)) end)
  else
    cfg.prompts = {}
  end
  return async.all(tasks):then_(function()
    _register_server_tools(server)
    cache.update_all(server, { tools = cfg.tools, resources = cfg.resources or {}, prompts = cfg.prompts or {} })
    event_bus.emit(events.MCP_TOOLS_UPDATED, { server = server })
    local changed = old_tools_json ~= json.encode(cfg.tools or {})
      or json.encode(old_names) ~= json.encode(cfg.toolnames or {})
    return changed
  end)
end

--- 连接一个服务器：initialize → initialized → 拉取列表 → 注册 → 回写缓存 → 事件
--- @param server string
--- @return Deferred resolve(boolean changed)
local function _connect(server)
  local cfg = state.servers[server]
  if not cfg then return async.resolve(false) end
  if _ready(server) then return async.resolve(false) end
  -- 上一次初始化失败且未启用重连：不再重复尝试，避免每轮发送都反复连接失败
  if cfg.state == "error" and not config_store.get("mcp.reconnect") then
    return async.resolve(false)
  end
  -- 先创建客户端（可能重建断开的传输），成功后才进入 connecting 态
  local client = _ensure_client(server)
  if not client then
    cfg.state = "error"
    event_bus.emit(events.MCP_ERROR, { server = server, error = "无法创建传输" })
    return async.resolve(false)
  end
  cfg.state = "connecting"
  event_bus.emit(events.MCP_CONNECTING, { server = server })

  -- connect_timeout_ms：握手（initialize）阶段专用超时
  local timeout_ms = cfg.cfg.connect_timeout_ms or config_store.get("mcp.connect_timeout_ms") or 20000
  return client:initialize({
    protocolVersion = cfg.cfg.protocol_version or "2025-06-18",
    timeout_ms = timeout_ms,
  }):then_(function(init_result)
    cfg.server_info = (init_result and init_result.serverInfo) or {}
    cfg.client_capabilities = (init_result and init_result.capabilities) or {}
    return _pull_and_register(server):then_(function(changed)
      cfg.state = "ready"
      event_bus.emit(events.MCP_READY, { server = server, tools = #(cfg.tools or {}) })
      logger.info("[mcp] %s 就绪: %d tools, %d resources, %d prompts", server,
        #(cfg.tools or {}), #(cfg.resources or {}), #(cfg.prompts or {}))
      return changed
    end)
  end, function(err)
    cfg.state = "error"
    logger.warn("[mcp] %s 初始化失败: %s", server, tostring(err and err.message or err))
    event_bus.emit(events.MCP_ERROR, { server = server, error = err and err.message or err })
    return false
  end)
end

--- 刷新一个服务器：拉取工具/资源/提示并注册（未连接/未初始化时先连接）
--- @param server string
--- @return Deferred resolve(boolean changed)
function M.refresh(server)
  local cfg = state.servers[server]
  if not cfg then return async.resolve(false) end
  if not cfg.client or not cfg.client:is_initialized() then
    return _connect(server)
  end
  return _pull_and_register(server)
end

--- 刷新所有 stale 服务器（失败驱动：调用因 schema 变化失败后，下一轮发送前调用）
--- @return Deferred resolve(boolean changed)
function M.refresh_stale()
  local stale = cache.stale_servers()
  if #stale == 0 then return async.resolve(false) end
  local tasks = {}
  local changed = false
  for _, name in ipairs(stale) do
    tasks[#tasks + 1] = M.refresh(name):then_(function(ch)
      if ch then changed = true end
      cache.clear_stale(name)
    end)
  end
  return async.all(tasks):then_(function()
    return changed
  end)
end

-- ========== 公开 API ==========

--- 初始化 MCP 系统：读配置，预缓存注册 + 异步连接
function M.init()
  local mcp_cfg = config_store.get("mcp") or {}
  state.enabled = mcp_cfg.enabled ~= false
  if not state.enabled or state.started then return M end
  state.started = true

  cache.init(mcp_cfg.cache_path)

  local servers = mcp_cfg.servers or {}
  for name, scfg in pairs(servers) do
    if type(scfg) == "table" then
      local s = {
        cfg = scfg,
        name = name,
        client = nil,
        transport = nil,
        tools = {},
        resources = {},
        prompts = {},
        toolnames = {},
        state = "pending",
      }
      state.servers[name] = s
      -- 预缓存：连接前先把上次的工具/资源/提示注册进系统，立即可见
      local cached = cache.get(name)
      if cached then
        s.tools = cached.tools or {}
        s.resources = cached.resources or {}
        s.prompts = cached.prompts or {}
        _register_server_tools(name)
      else
        cache.mark_pending(name)
      end
      -- 异步连接
      local ok, err = pcall(_connect, name)
      if not ok then
        logger.warn("[mcp] %s 连接启动失败: %s", name, tostring(err))
      end
    end
  end
  return M
end

--- 调用某服务器的远端工具
--- @param server string
--- @param tool_name string 远端工具名
--- @param args table 参数
--- @return Deferred resolve(string)
function M.call_tool(server, tool_name, args)
  local cfg = state.servers[server]
  if not cfg then
    return async.resolve("错误: 未知 MCP 服务器 " .. tostring(server))
  end
  -- 未连接则先连接（惰性）
  if not _ready(server) then
    return _connect(server):then_(function()
      -- 连接结束后若仍不就绪（传输不可建 / 未启用重连 / 初始化失败），返回错误而非递归，
      -- 避免工具调用因不可用服务器陷入无限异步循环。
      if not _ready(server) or cfg.state == "error" then
        return "错误: MCP 服务器 '" .. tostring(server) .. "' 连接失败或不可用"
      end
      return M.call_tool(server, tool_name, args)
    end, function(e)
      return async.resolve("错误: MCP 服务器 '" .. tostring(server) .. "' 连接失败: " .. tostring(e and e.message or e))
    end)
  end
  return cfg.client:request("tools/call", { name = tool_name, arguments = args }, {}):then_(function(res)
    if res and res.isError then
      if _is_schema_error(res) then
        cache.mark_stale(server)
      end
      return _tool_result_str(res, false)
    end
    return _tool_result_str(res, true)
  end, function(err)
    if _is_schema_error(err) then
      cache.mark_stale(server)
      return _tool_result_str(err, false)
    end
    return "错误: " .. tostring(err and err.message or err)
  end)
end

--- 列出服务器资源
--- @param server string
--- @return Deferred resolve(string)
function M.list_resources(server)
  local client = _ready_client(server)
  if not client then return async.resolve("错误: MCP 服务器未就绪") end
  return client:request("resources/list", {}, {}):then_(function(r)
    local items = (r and r.resources) or {}
    if #items == 0 then return "（无资源）" end
    local lines = {}
    for _, it in ipairs(items) do
      lines[#lines + 1] = string.format("- %s  (%s)\n  %s", it.name or it.uri, it.uri or "", it.description or "")
    end
    return table.concat(lines, "\n")
  end, function(e) return "错误: " .. tostring(e and e.message or e) end)
end

--- 读取服务器资源
--- @param server string
--- @param uri string
--- @return Deferred resolve(string)
function M.read_resource(server, uri)
  local client = _ready_client(server)
  if not client then return async.resolve("错误: MCP 服务器未就绪") end
  return client:request("resources/read", { uri = uri }, {}):then_(function(r)
    local contents = (r and r.contents) or {}
    if #contents == 0 then return "（无内容）" end
    local max = config_store.get("mcp.resources.max_result_bytes") or (100 * 1024)
    local parts = {}
    local total = 0
    for _, c in ipairs(contents) do
      local text = ""
      if type(c) == "table" then
        if c.text then text = c.text
        elseif c.blob then text = ("[blob %s 字节]"):format(#c.blob)
        end
      else
        text = tostring(c)
      end
      if total + #text > max then
        text = stringx.safe_truncate(text, max - total, "…")
      end
      total = total + #text
      parts[#parts + 1] = ((c and c.uri) or uri) .. ":\n" .. text
      if total >= max then break end
    end
    return table.concat(parts, "\n\n")
  end, function(e) return "错误: " .. tostring(e and e.message or e) end)
end

--- 列出服务器提示模板
--- @param server string
--- @return Deferred resolve(string)
function M.list_prompts(server)
  local client = _ready_client(server)
  if not client then return async.resolve("错误: MCP 服务器未就绪") end
  return client:request("prompts/list", {}, {}):then_(function(r)
    local items = (r and r.prompts) or {}
    if #items == 0 then return "（无提示模板）" end
    local lines = {}
    for _, it in ipairs(items) do
      local args = {}
      for _, a in ipairs(it.arguments or {}) do
        args[#args + 1] = a.name
      end
      lines[#lines + 1] = string.format("- %s%s\n  %s", it.name, (#args > 0 and (" (" .. table.concat(args, ", ") .. ")") or ""), it.description or "")
    end
    return table.concat(lines, "\n")
  end, function(e) return "错误: " .. tostring(e and e.message or e) end)
end

--- 获取服务器提示模板内容
--- @param server string
--- @param name string
--- @param args table|nil
--- @return Deferred resolve(string)
function M.get_prompt(server, name, args)
  local client = _ready_client(server)
  if not client then return async.resolve("错误: MCP 服务器未就绪") end
  return client:request("prompts/get", { name = name, arguments = args or {} }, {}):then_(function(r)
    local messages = (r and r.messages) or {}
    if #messages == 0 then return "（空提示模板）" end
    local parts = {}
    for _, m in ipairs(messages) do
      local role = m.role or "assistant"
      local content = m.content
      if type(content) == "table" then
        local s = ""
        for _, c in ipairs(content) do
          if type(c) == "table" then s = s .. tostring(c.text or "") end
        end
        content = s
      end
      parts[#parts + 1] = ("[%s] %s"):format(role, tostring(content or ""))
    end
    return table.concat(parts, "\n\n")
  end, function(e) return "错误: " .. tostring(e and e.message or e) end)
end

--- 列出所有已注册的 MCP 工具名（供 plan_mode 等使用）
--- @return table 数组
function M.list_tool_names()
  local out = {}
  for server, cfg in pairs(state.servers) do
    for _, n in ipairs(cfg.toolnames or {}) do
      out[#out + 1] = n
    end
  end
  return out
end

--- 服务器是否 plan_safe（计划模式下可见）
--- @param server string
--- @return boolean
function M.plan_safe(server)
  local cfg = state.servers[server]
  return cfg and cfg.cfg.plan_safe == true
end

--- 预发刷新钩子：刷新 stale 服务器（由 chat_service 注册到 tool_loop）
--- @return Deferred resolve(boolean changed)
function M.pre_round()
  return M.refresh_stale()
end

--- 关闭所有服务器（插件关闭时）
function M.shutdown()
  if state.shutting_down then return end
  state.shutting_down = true
  for _, cfg in pairs(state.servers) do
    if cfg.client then
      pcall(cfg.client.close, cfg.client, {})
    end
  end
  state.servers = {}
  state.started = false
end

--- 重置（测试用）
function M.reset()
  M.shutdown()
  state.enabled = false
  state.started = false
  state.servers = {}
  state.shutting_down = false
end

M.state = state

return M
