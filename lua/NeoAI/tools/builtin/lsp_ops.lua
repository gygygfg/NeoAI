--- LSP 操作工具
--- @module NeoAI.tools.builtin.lsp_ops
--- 通过 Neovim 内置 LSP（vim.lsp）提供代码分析工具。

local helpers = require("NeoAI.tools.builtin.tool_helpers")
local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有函数 ==========

--- 通过文件路径获取 buffer；未打开时后台加载
--- @param filepath string
--- @return number|nil bufnr
local function _bufnr(filepath)
  local bufnr = helpers.ensure_buffer(filepath)
  if bufnr then
    -- 磁盘直写工具（edit_file 等）只改磁盘不改已加载 buffer，导致内存与磁盘不一致；
    -- 这里把磁盘最新内容同步进 buffer，避免 LSP 基于过期内容（读错位置 / 重命名写回旧内容）。
    helpers.sync_buffer_from_disk(bufnr)
    -- 沙箱激活且该文件有暂存副本时，用暂存内容覆盖**后台加载**的 buffer，使 LSP 客户端
    -- 的 didOpen 文本与沙箱命名空间内的磁盘视图一致（与文件工具共享同一暂存视图）。
    -- 用户已打开的 buffer 不受影响（sync_buffer_from_sandbox 仅作用于后台 buffer）。
    if filepath and filepath ~= "" then
      helpers.sync_buffer_from_sandbox(bufnr, filepath)
    end
  end
  return bufnr
end

--- 获取文件或当前 buffer 的 LSP 客户端
--- @param filepath string|nil
--- @return table|nil client
local function _client_for(filepath)
  local bufnr = _bufnr(filepath)
  if not bufnr then
    return nil
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return nil
  end
  return clients[1]
end

--- 找一个支持指定方法的 LSP 客户端（优先 AI 沙箱克隆，回退编辑器客户端）
--- @param method string
--- @param bufnr number|nil
--- @return table|nil
local function _client_supporting(method, bufnr)
  local ok, sandbox = pcall(require, "NeoAI.sandbox.lsp")
  if ok and sandbox then
    local ok2, clone = pcall(sandbox.client_supporting, method, bufnr)
    if ok2 and clone then
      return clone
    end
  end
  local clients = bufnr and vim.lsp.get_clients({ bufnr = bufnr }) or vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if client:supports_method(method, bufnr) then
      return client
    end
  end
  return nil
end

--- 请求 + 等待结果的包装
--- LSP 服务器可能对请求永不响应（后台加载的 buffer、服务器内部卡住等），
--- buf_request 本身无超时，若一直等待会让工具循环挂到 executor 超时（默认 30s）
--- 才报"工具执行超时"，并拖累同一轮并行执行的所有工具（async.all 等最慢的）。
--- 这里加请求级超时：超时即拒绝，工具快速失败并给出明确错误。
--- @param method string
--- @param params table
--- @param target number|table bufnr 或 LSP 客户端（client:request）
--- @return Deferred
local function _request(method, params, target)
  -- 优先走 AI 专用沙箱 LSP 克隆（独立进程，读暂存内容，诊断不外溢）。
  -- 未启用 / overlay 不可用 / 无克隆时回退到编辑器客户端（原行为）。
  if type(target) == "number" then
    local ok, sandbox = pcall(require, "NeoAI.sandbox.lsp")
    if ok and sandbox then
      local ok2, clone = pcall(sandbox.client_supporting, method, target)
      if ok2 and clone then
        target = clone
      end
    end
  end

  local d = async.Deferred.new()
  local called = false
  local timeout_ms = config_store.get("tools.lsp.timeout_ms") or 10000

  local timer
  local function _settle(ok_, value)
    if called then
      return
    end
    called = true
    if timer and timer:is_active() then
      pcall(timer.stop, timer)
    end
    if ok_ then
      d:resolve(value)
    else
      d:reject(value)
    end
  end

  -- 请求级超时兜底：服务器无响应时按时拒绝，而不是永久挂起
  timer = vim.uv.new_timer()
  timer:start(timeout_ms, 0, function()
    vim.schedule(function()
      _settle(false, { kind = "lsp", message = ("LSP 请求超时 (%dms): %s"):format(timeout_ms, method) })
    end)
  end)

  local handler = function(err_resp, result)
    if err_resp and err_resp.code then
      _settle(false, { kind = "lsp", code = err_resp.code, message = err_resp.message })
    else
      _settle(true, result)
    end
  end

  if type(target) == "number" then
    -- 第 5 参 on_unsupported 置空：不支持的方法由下方空映射分支给出准确错误，
    -- 避免 Neovim 再弹一条 "method not supported" 的 notify 噪音。
    local ok, id = pcall(vim.lsp.buf_request, target, method, params, handler, function() end)
    if not ok then
      _settle(false, { kind = "lsp", message = tostring(id) })
    elseif type(id) == "table" and not next(id) then
      -- buf_request 返回空的客户端映射且回调永不触发。可能是无客户端，也可能有
      -- 客户端但不支持该请求（Neovim 0.12 对不支持的方法直接返回 {}）。
      -- 区分两者给出准确错误，避免误导为"无 LSP 客户端"。
      local clients = vim.lsp.get_clients({ bufnr = target })
      if #clients == 0 then
        _settle(
          false,
          { kind = "lsp", message = "无 LSP 客户端（文件可能在后台加载，客户端未附加）" }
        )
      else
        _settle(false, { kind = "lsp", message = ("当前 LSP 客户端不支持请求: %s"):format(method) })
      end
    elseif id == 0 then
      -- 旧版 API：返回 0 表示无客户端
      _settle(
        false,
        { kind = "lsp", message = "无 LSP 客户端（文件可能在后台加载，客户端未附加）" }
      )
    end
  else
    local ok, err = pcall(function()
      target:request(method, params, handler)
    end)
    if not ok then
      _settle(false, { kind = "lsp", message = tostring(err) })
    end
  end
  return d
end

--- 位置参数规范化
--- @param args table
--- @return number bufnr, number line, number col
local function _position(args)
  local bufnr = _bufnr(args.filepath)
  if not bufnr then
    return nil
  end
  local line = (args.line or 0) - 1 -- LSP 为 0-based
  local col = args.col or 0
  return bufnr, math.max(0, line), math.max(0, col)
end

--- 取位置结果的 uri 与 range，兼容 Location 与 LocationLink 两种格式。
--- 服务器（如 lua-language-server）对 typeDefinition/implementation 返回
--- LocationLink（targetUri/targetRange，无 uri/range），直接取 loc.uri 为 nil。
--- @param loc table
--- @return string uri, table range
local function _location_fields(loc)
  if loc.targetUri then -- LocationLink
    return loc.targetUri, loc.targetRange
  end
  return loc.uri, loc.range -- Location
end

--- 安全包装异步处理器：处理器抛异常时转 on_error，而不是被 then_ 派生的
--- Deferred 吞掉（工具忽略返回值 → 永不回调 → 挂到 executor 超时）。
--- 同时避免 pcall 返回的第二个值（字符串数量等）意外泄漏。
--- @param d Deferred
--- @param process function(result) -> string
--- @param on_success function
--- @param on_error function
local function _safe_then(d, process, on_success, on_error)
  d:then_(function(result)
    local ok, out = pcall(process, result)
    if ok then
      on_success(out)
    else
      on_error("LSP 结果处理失败: " .. tostring(out))
    end
  end, function(e)
    on_error(e.message)
  end)
end

--- 触发一次 didChange（内容不变）让已附加的 LSP 服务器重新 lint。
--- push 模型服务器只在收到 didChange 后重新发布诊断，读缓存会拿到陈旧结果；
--- 这里重设相同内容：Neovim 的 LSP sync 随之发送 didChange。不改内容、不产生撤销项、
--- 不残留 modified 标记（`undolevels=-1` 期间写入，事后恢复）。
--- @param bufnr number
--- @return boolean
local function _touch_buffer(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].modifiable then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local was_modified = vim.bo[bufnr].modified
  local undolevels = vim.bo[bufnr].undolevels
  local ok = pcall(function()
    vim.bo[bufnr].undolevels = -1
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end)
  pcall(function()
    vim.bo[bufnr].undolevels = undolevels
  end)
  if not was_modified then
    pcall(function()
      vim.bo[bufnr].modified = false
    end)
  end
  return ok
end

--- 等待服务器针对该 buffer 重新发布诊断（`textDocument/publishDiagnostics`），
--- 超时（`tools.lsp.timeout_ms`）后仍返回当前缓存。等待期间不阻塞主线程。
--- @param bufnr number
--- @param cb function
local function _await_publish(bufnr, cb)
  local done = false
  local timer, au
  local function finish()
    if done then
      return
    end
    done = true
    if timer then
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
    end
    if au then
      pcall(vim.api.nvim_del_autocmd, au)
    end
    -- 诊断缓存由 publishDiagnostics 处理器写入；LspNotify 可能早于处理器，延后一个 tick 再读。
    vim.schedule(cb)
  end
  au = vim.api.nvim_create_autocmd("LspNotify", {
    buffer = bufnr,
    callback = function(opts)
      local data = opts and opts.data
      if data and data.method == "textDocument/publishDiagnostics" then
        finish()
      end
    end,
  })
  local timeout_ms = config_store.get("tools.lsp.timeout_ms") or 10000
  timer = vim.uv.new_timer()
  timer:start(timeout_ms, 0, function()
    vim.schedule(finish)
  end)
end

--- 等待 LSP 客户端就绪：后台加载 buffer / 服务器启动或重启期间客户端可能尚未附加，
--- 立即报「无 LSP 客户端」会让诊断工具在服务端就绪前误失败。这里先立即尝试一次，
--- 未就绪则监听 `LspAttach` 并周期性重试 `attempt`，直到其返回 true 或超时。
--- `attempt()` 负责在就绪时完成后续处理并返回 true（幂等：就绪后不再重复调用）。
--- 超时后调用 `on_timeout()`，由调用方决定报错或降级。等待期间不阻塞主线程。
--- @param bufnr number
--- @param attempt function() -> boolean 就绪并已处理时返回 true
--- @param on_timeout function()
local function _await_client(bufnr, attempt, on_timeout)
  if attempt() then
    return
  end
  local done = false
  local timer, au
  local function finish(timeout)
    if done then
      return
    end
    done = true
    if timer then
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
    end
    if au then
      pcall(vim.api.nvim_del_autocmd, au)
    end
    if timeout then
      on_timeout()
    end
  end
  au = vim.api.nvim_create_autocmd("LspAttach", {
    buffer = bufnr,
    callback = function()
      if not done and attempt() then
        finish(false)
      end
    end,
  })
  local timeout_ms = config_store.get("tools.lsp.attach_timeout_ms") or 3000
  local deadline = vim.uv.now() + timeout_ms
  timer = vim.uv.new_timer()
  timer:start(100, 100, function()
    vim.schedule(function()
      if done then
        return
      end
      if attempt() then
        finish(false)
      elseif vim.uv.now() >= deadline then
        finish(true)
      end
    end)
  end)
end

-- ========== 工具定义 ==========

local lsp_tools = {}

--- 悬停信息
lsp_tools.lsp_hover = helpers.define_tool(
  "lsp_hover",
  "获取光标位置悬停信息。filepath/line/col 可选（默认当前）。",
  {
    type = "object",
    properties = {
      filepath = { type = "string" },
      line = { type = "integer" },
      col = { type = "integer" },
    },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    _safe_then(
      _request(
        "textDocument/hover",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } },
        bufnr
      ),
      function(result)
        if result and result.contents then
          local out = {}
          local contents = result.contents
          if type(contents) == "string" then
            out[1] = contents
          elseif type(contents) == "table" and contents.value then
            out[1] = contents.value
          elseif type(contents) == "table" then
            for _, c in ipairs(contents) do
              out[#out + 1] = type(c) == "table" and (c.value or "") or tostring(c)
            end
          end
          return table.concat(out, "\n")
        end
        return "无悬停信息"
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 定义
lsp_tools.lsp_definition = helpers.define_tool(
  "lsp_definition",
  "获取符号定义位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    _safe_then(
      _request(
        "textDocument/definition",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } },
        bufnr
      ),
      function(locations)
        if not locations or #locations == 0 then
          return "未找到定义"
        end
        local out = {}
        for _, loc in ipairs(locations) do
          local uri, range = _location_fields(loc)
          out[#out + 1] = string.format(
            "%s:%d:%d",
            vim.uri_to_fname(uri),
            (range and range.start.line or 0) + 1,
            range and range.start.character or 0
          )
        end
        return table.concat(out, "\n")
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 引用
lsp_tools.lsp_references = helpers.define_tool(
  "lsp_references",
  "查找符号引用位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    -- context 为 LSP 必填字段（ReferenceParams），缺失时部分服务器（如 lua-language-server
    -- provider.lua 会访问 params.context.includeDeclaration）直接内部异常。
    _safe_then(
      _request(
        "textDocument/references",
        {
          textDocument = { uri = vim.uri_from_bufnr(bufnr) },
          position = { line = line, character = col },
          context = { includeDeclaration = true },
        },
        bufnr
      ),
      function(locations)
        if not locations or #locations == 0 then
          return "未找到引用"
        end
        local out = {}
        for _, loc in ipairs(locations) do
          local uri, range = _location_fields(loc)
          out[#out + 1] = string.format(
            "%s:%d:%d",
            vim.uri_to_fname(uri),
            (range and range.start.line or 0) + 1,
            range and range.start.character or 0
          )
        end
        return table.concat(out, "\n")
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 文档符号
lsp_tools.lsp_document_symbols = helpers.define_tool(
  "lsp_document_symbols",
  "获取文档内符号列表。filepath 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr = _bufnr(args.filepath)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    _safe_then(
      _request("textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, bufnr),
      function(symbols)
        if not symbols or #symbols == 0 then
          return "无符号"
        end
        local out = {}
        local function walk(sym, depth)
          local name = sym.name or ""
          local kind = vim.lsp.protocol.SymbolKind[sym.kind] or tostring(sym.kind)
          out[#out + 1] = string.rep("  ", depth) .. name .. " (" .. kind .. ")"
          for _, child in ipairs(sym.children or {}) do
            walk(child, depth + 1)
          end
        end
        for _, sym in ipairs(symbols) do
          walk(sym, 0)
        end
        return table.concat(out, "\n")
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 工作区符号
lsp_tools.lsp_workspace_symbols = helpers.define_tool(
  "lsp_workspace_symbols",
  "搜索工作区符号。query 必填。",
  {
    type = "object",
    properties = { query = { type = "string" } },
    required = { "query" },
  },
  function(args, on_success, on_error)
    -- workspace/symbol 是工作区级请求，不应依赖当前 buffer（headless/聊天 buffer 可能
    -- 没有可用的客户端）。在所有客户端里挑一个支持该方法的，避免误报"无 LSP 客户端"。
    local client = _client_supporting("workspace/symbol")
    if not client then
      on_error("无支持 workspace/symbol 的 LSP 客户端")
      return
    end
    _safe_then(_request("workspace/symbol", { query = args.query }, client), function(symbols)
      if not symbols or #symbols == 0 then
        return "无匹配符号"
      end
      local out = {}
      for _, sym in ipairs(symbols) do
        local uri = sym.location and (sym.location.uri or sym.location.targetUri)
        out[#out + 1] = (sym.name or "") .. "  " .. (uri and vim.uri_to_fname(uri) or "")
      end
      return table.concat(out, "\n")
    end, on_success, on_error)
  end,
  { category = "lsp" }
)

--- 诊断信息
lsp_tools.lsp_diagnostics = helpers.define_tool("lsp_diagnostics", "重新获取文件诊断信息。", {
  type = "object",
  properties = { filepath = { type = "string" } },
  required = {},
}, function(args, on_success, on_error)
  local bufnr = _bufnr(args.filepath)
  if not bufnr then
    on_error("无法找到文件 buffer")
    return
  end
  local uri = vim.uri_from_bufnr(bufnr)

  -- 每次调用都重新获取：
  -- 1) pull 客户端（textDocument/diagnostic，优先 AI 沙箱克隆）：直接请求最新诊断；
  -- 2) 仅 push 客户端：强制触发一次 didChange 让服务器重新 lint，等其发布后再读缓存，
  --    避免返回陈旧的 `vim.diagnostic.get` 缓存。
  local function _format(diagnostics)
    if not diagnostics or #diagnostics == 0 then
      on_success("无诊断信息")
      return
    end
    local out = {}
    for _, diag in ipairs(diagnostics) do
      local sev = vim.diagnostic.severity[diag.severity] or "?"
      out[#out + 1] = string.format("%s:%d %s: %s", args.filepath or "(当前)", diag.lnum + 1, sev, diag.message)
    end
    on_success(table.concat(out, "\n"))
  end

  local function _pull(client)
    _request("textDocument/diagnostic", { textDocument = { uri = uri } }, client):then_(function(result)
      local items = type(result) == "table" and result.items or nil
      if items then
        _format(vim.tbl_map(function(d)
          local r = d.range or { start = { line = 0, character = 0 } }
          return { lnum = r.start.line, severity = d.severity, message = d.message }
        end, items))
      else
        _format(vim.diagnostic.get(bufnr))
      end
    end, function()
      _format(vim.diagnostic.get(bufnr))
    end)
  end

  local function _push()
    _touch_buffer(bufnr)
    _await_publish(bufnr, function()
      _format(vim.diagnostic.get(bufnr))
    end)
  end

  -- 就绪后立即处理并返回 true；无客户端时返回 false（由 _await_client 继续等待）。
  local function _run()
    local client = _client_supporting("textDocument/diagnostic", bufnr)
    if client then
      _pull(client)
      return true
    end
    if #vim.lsp.get_clients({ bufnr = bufnr }) > 0 then
      _push()
      return true
    end
    return false
  end

  if _run() then
    return
  end
  -- 服务器可能正在启动/重启，客户端尚未附加：等待其就绪后再取诊断，而不是立即报错。
  _await_client(bufnr, _run, function()
    on_error("无 LSP 客户端（文件可能在后台加载，客户端未附加）")
  end)
end, { category = "lsp" })

--- 客户端信息
lsp_tools.lsp_client_info = helpers.define_tool("lsp_client_info", "获取 LSP 客户端信息。filepath 可选。", {
  type = "object",
  properties = { filepath = { type = "string" } },
  required = {},
}, function(args, on_success)
  local bufnr = _bufnr(args.filepath)
  local clients = vim.lsp.get_clients()
  local out = {}
  for _, c in ipairs(clients) do
    out[#out + 1] = string.format(
      "%s (%s)%s",
      c.name,
      c.root_dir or "",
      (bufnr and vim.lsp.get_client_by_id(c.id) and " [active]" or "")
    )
  end
  on_success(#out > 0 and table.concat(out, "\n") or "无 LSP 客户端")
end, { category = "lsp" })

--- 代码操作
lsp_tools.lsp_code_action = helpers.define_tool(
  "lsp_code_action",
  "获取代码操作建议。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    local range = { start = { line = line, character = col }, ["end"] = { line = line, character = col + 1 } }
    _safe_then(
      _request(
        "textDocument/codeAction",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, range = range, context = { diagnostics = {} } },
        bufnr
      ),
      function(actions)
        if not actions or #actions == 0 then
          return "无代码操作"
        end
        local out = {}
        for _, a in ipairs(actions) do
          out[#out + 1] = (a.title or a.kind or "action")
        end
        return table.concat(out, "\n")
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 重命名
lsp_tools.lsp_rename = helpers.define_tool("lsp_rename", "重命名符号。filepath/line/col/new_name 必填。", {
  type = "object",
  properties = {
    filepath = { type = "string" },
    line = { type = "integer" },
    col = { type = "integer" },
    new_name = { type = "string" },
  },
  required = { "new_name" },
}, function(args, on_success, on_error)
  local bufnr, line, col = _position(args)
  if not bufnr then
    on_error("无法找到文件 buffer")
    return
  end
  _safe_then(
    _request(
      "textDocument/rename",
      {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = line, character = col },
        newName = args.new_name,
      },
      bufnr
    ),
    function(edit)
      if not edit or not edit.changes then
        return "无重命名编辑"
      end
      local changed = 0
      for uri, changes in pairs(edit.changes) do
        local b = helpers.ensure_buffer(vim.uri_to_fname(uri))
        if not b then
          error("重命名失败：无法加载文件 " .. vim.uri_to_fname(uri))
        end
        -- 目标文件可能因磁盘直写工具（edit_file 等）而陈旧：先同步再应用编辑，
        -- 否则基于过期内容写回会把磁盘新内容覆盖成旧内容（改名错位）。
        helpers.sync_buffer_from_disk(b)
        for _, ch in ipairs(changes) do
          pcall(
            vim.api.nvim_buf_set_text,
            b,
            ch.range.start.line,
            ch.range.start.character,
            ch.range["end"].line,
            ch.range["end"].character,
            vim.split(ch.newText, "\n", { plain = true })
          )
        end
        helpers.mark_edited(b) -- 显式编辑：允许回写（只读加载/同步不标记、不回写）
        local saved, err = helpers.persist_buffer(b)
        if not saved then
          error("重命名失败：无法保存文件 " .. vim.uri_to_fname(uri) .. " (" .. tostring(err) .. ")")
        end
        changed = changed + 1
      end
      return ("重命名完成（%d 个文件）"):format(changed)
    end,
    on_success,
    on_error
  )
end, { category = "lsp", approval = { auto_allow = false } })

--- 格式化
lsp_tools.lsp_format = helpers.define_tool("lsp_format", "格式化文档。filepath 可选。", {
  type = "object",
  properties = { filepath = { type = "string" } },
  required = {},
}, function(args, on_success, on_error)
  local bufnr = _bufnr(args.filepath)
  if not bufnr then
    on_error("无法找到文件 buffer")
    return
  end
  _safe_then(
    _request(
      "textDocument/formatting",
      { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, options = { tabSize = 2, insertSpaces = true } },
      bufnr
    ),
    function(edits)
      if edits and #edits > 0 then
        for _, e in ipairs(edits) do
          pcall(
            vim.api.nvim_buf_set_text,
            bufnr,
            e.range.start.line,
            e.range.start.character,
            e.range["end"].line,
            e.range["end"].character,
            vim.split(e.newText, "\n", { plain = true })
          )
        end
        helpers.mark_edited(bufnr) -- 显式编辑：允许回写（只读加载路径不标记、不回写）
        local saved, err = helpers.persist_buffer(bufnr)
        if not saved then
          error("格式化失败：无法保存文件（" .. tostring(err) .. "）")
        end
        return "格式化完成"
      end
      return "无需格式化"
    end,
    on_success,
    on_error
  )
end, { category = "lsp", approval = { auto_allow = false } })

--- 签名帮助
lsp_tools.lsp_signature_help = helpers.define_tool(
  "lsp_signature_help",
  "获取函数签名。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    _safe_then(
      _request(
        "textDocument/signatureHelp",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } },
        bufnr
      ),
      function(result)
        if result and result.signatures and #result.signatures > 0 then
          local out = {}
          for _, s in ipairs(result.signatures) do
            out[#out + 1] = s.label or ""
          end
          return table.concat(out, "\n")
        end
        return "无签名信息"
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 补全
lsp_tools.lsp_completion = helpers.define_tool("lsp_completion", "获取补全建议。filepath/line/col 可选。", {
  type = "object",
  properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
  required = {},
}, function(args, on_success, on_error)
  local bufnr, line, col = _position(args)
  if not bufnr then
    on_error("无法找到文件 buffer")
    return
  end
  _safe_then(
    _request(
      "textDocument/completion",
      { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } },
      bufnr
    ),
    function(result)
      local items = result and (result.items or result) or {}
      local out = {}
      for _, item in ipairs(items) do
        out[#out + 1] = item.label or ""
      end
      return #out > 0 and table.concat(out, "\n") or "无补全建议"
    end,
    on_success,
    on_error
  )
end, { category = "lsp" })

--- 类型定义
lsp_tools.lsp_type_definition = helpers.define_tool(
  "lsp_type_definition",
  "获取符号类型定义。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    _safe_then(
      _request(
        "textDocument/typeDefinition",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } },
        bufnr
      ),
      function(locations)
        if not locations or #locations == 0 then
          return "未找到类型定义"
        end
        local out = {}
        for _, loc in ipairs(locations) do
          local uri, range = _location_fields(loc)
          out[#out + 1] = string.format(
            "%s:%d:%d",
            vim.uri_to_fname(uri),
            (range and range.start.line or 0) + 1,
            range and range.start.character or 0
          )
        end
        return table.concat(out, "\n")
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 声明
lsp_tools.lsp_declaration = helpers.define_tool(
  "lsp_declaration",
  "获取符号声明位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    _safe_then(
      _request(
        "textDocument/declaration",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } },
        bufnr
      ),
      function(locations)
        if not locations or #locations == 0 then
          return "未找到声明"
        end
        local out = {}
        for _, loc in ipairs(locations) do
          local uri, range = _location_fields(loc)
          out[#out + 1] = string.format(
            "%s:%d:%d",
            vim.uri_to_fname(uri),
            (range and range.start.line or 0) + 1,
            range and range.start.character or 0
          )
        end
        return table.concat(out, "\n")
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 实现
lsp_tools.lsp_implementation = helpers.define_tool(
  "lsp_implementation",
  "获取符号实现位置。filepath/line/col 可选。",
  {
    type = "object",
    properties = { filepath = { type = "string" }, line = { type = "integer" }, col = { type = "integer" } },
    required = {},
  },
  function(args, on_success, on_error)
    local bufnr, line, col = _position(args)
    if not bufnr then
      on_error("无法找到文件 buffer")
      return
    end
    _safe_then(
      _request(
        "textDocument/implementation",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = line, character = col } },
        bufnr
      ),
      function(locations)
        if not locations or #locations == 0 then
          return "未找到实现"
        end
        local out = {}
        for _, loc in ipairs(locations) do
          local uri, range = _location_fields(loc)
          out[#out + 1] = string.format(
            "%s:%d:%d",
            vim.uri_to_fname(uri),
            (range and range.start.line or 0) + 1,
            range and range.start.character or 0
          )
        end
        return table.concat(out, "\n")
      end,
      on_success,
      on_error
    )
  end,
  { category = "lsp" }
)

--- 服务信息
lsp_tools.lsp_service_info = helpers.define_tool(
  "lsp_service_info",
  "获取 LSP 服务信息（客户端、根目录）。",
  {
    type = "object",
    properties = {},
    required = {},
  },
  function(args, on_success)
    local clients = vim.lsp.get_clients()
    local out = {}
    for _, c in ipairs(clients) do
      out[#out + 1] = string.format("%s  root=%s  name=%s", c.id, c.root_dir or "-", c.name)
    end
    on_success(#out > 0 and table.concat(out, "\n") or "无 LSP 客户端")
  end,
  { category = "lsp" }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(lsp_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
