-- Neovim LSP 操作工具模块
-- 提供 LSP 核心操作：悬停文档、跳转定义、查找引用、重命名、格式化、诊断等
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
-- 仅在 Neovim >= 0.5 且 LSP 客户端可用时自动启用
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- 通用 LSP 服务检测与初始化（自适应所有配置，不硬编码）
-- ============================================================================

-- 缓存检测结果
local _lsp_init_done = false
local _mason_installed = nil
local _lsp_service_type = nil

-- 判断客户端是否为正式 LSP 服务（纯能力检测，不依赖硬编码名称）
-- 规则：仅支持 inlineCompletion 且无任何核心 LSP 能力的客户端视为非正式
-- 核心 LSP 能力：hover、definition、references、formatting、codeAction、completion、documentSymbol 等
local function is_formal_lsp_client(client)
  if not client then
    return false
  end
  local caps = client.server_capabilities
  -- 如果尚未初始化完成（caps 为 nil），暂时视为正式，后续会重新检查
  if not caps then
    return true
  end
  -- 检查是否有至少一项核心 LSP 能力
  local has_core = caps.hoverProvider
    or caps.definitionProvider
    or caps.referencesProvider
    or caps.documentFormattingProvider
    or caps.codeActionProvider
    or caps.completionProvider
    or caps.documentSymbolProvider
    or caps.workspaceSymbolProvider
    or caps.implementationProvider
    or caps.declarationProvider
    or caps.renameProvider
    or caps.typeDefinitionProvider
    or caps.signatureHelpProvider
  -- 如果没有任何核心能力，且仅支持 inlineCompletion，视为非正式服务
  if not has_core and caps.inlineCompletionProvider then
    return false
  end
  return true
end

-- 自动检测用户使用的 LSP 服务类型（不依赖特定路径）
local function detect_lsp_service_type()
  if _lsp_service_type then
    return _lsp_service_type
  end

  -- 1) 尝试检测用户自定义 LSP 配置模块
  local custom_modules = { "lsp", "lspconfig", "lsp_config", "lsp-config" }
  for _, mod_name in ipairs(custom_modules) do
    local ok, mod = pcall(require, mod_name)
    if ok and type(mod) == "table" then
      if mod.start_server_with_config or mod.setup or mod._server_configs then
        _lsp_service_type = "custom:" .. mod_name
        return _lsp_service_type
      end
    end
  end

  -- 2) 检测 nvim-lspconfig 插件
  local ok_lspconfig = pcall(require, "lspconfig.configs")
  if ok_lspconfig then
    _lsp_service_type = "lspconfig"
    return _lsp_service_type
  end

  -- 3) 检测 Mason
  local ok_mason = pcall(require, "mason-registry")
  if ok_mason then
    _lsp_service_type = "mason"
    return _lsp_service_type
  end

  -- 4) 检测 COC
  if vim.g.coc_service_initialized ~= nil then
    _lsp_service_type = "coc"
    return _lsp_service_type
  end

  -- 5) 回退：Neovim 内置 LSP API
  _lsp_service_type = "native"
  return _lsp_service_type
end

-- 获取 Mason 已安装的 LSP 服务器列表（通用方式）
local function get_mason_installed_servers()
  if _mason_installed then
    return _mason_installed
  end
  _mason_installed = {}

  local ok_reg, mason_registry = pcall(require, "mason-registry")
  if not ok_reg then
    return _mason_installed
  end

  -- 优先使用 get_all_installed_packages（Mason 较新版本）
  local ok_all, all_pkgs = pcall(mason_registry.get_all_installed_packages)
  if ok_all and type(all_pkgs) == "table" then
    for _, pkg in ipairs(all_pkgs) do
      local install_path = nil
      local ok_path, path = pcall(pkg.get_install_path, pkg)
      if ok_path then
        install_path = path
      end
      table.insert(_mason_installed, {
        mason_name = pkg.name,
        lsp_name = pkg.name,
        is_installed = true,
        install_path = install_path,
      })
    end
    return _mason_installed
  end

  -- 回退：通过常见 LSP 包名逐个检查
  local common_lsp_packages = {
    "lua-language-server",
    "pyright",
    "typescript-language-server",
    "html-lsp",
    "css-lsp",
    "json-lsp",
    "yaml-language-server",
    "bash-language-server",
    "clangd",
    "gopls",
    "rust-analyzer",
    "marksman",
    "solargraph",
    "intelephense",
    "jdtls",
    "vue-language-server",
    "svelte-language-server",
    "dockerfile-language-server",
    "vim-language-server",
    "texlab",
    "angular-language-server",
    "graphql-language-service-cli",
    "prisma-language-server",
    "tailwindcss-language-server",
  }
  for _, pkg_name in ipairs(common_lsp_packages) do
    local ok, pkg = pcall(mason_registry.get_package, pkg_name)
    if ok and pkg:is_installed() then
      local install_path = nil
      local ok_path, path = pcall(pkg.get_install_path, pkg)
      if ok_path then
        install_path = path
      end
      table.insert(_mason_installed, {
        mason_name = pkg_name,
        lsp_name = pkg_name,
        is_installed = true,
        install_path = install_path,
      })
    end
  end

  return _mason_installed
end

-- 获取当前活跃的正式 LSP 客户端列表
local function get_active_formal_clients()
  local all = vim.lsp.get_clients()
  local formal = {}
  for _, c in ipairs(all) do
    if is_formal_lsp_client(c) then
      table.insert(formal, c)
    end
  end
  return formal
end

-- 获取所有可用的正式 LSP 服务器名称
local function get_available_formal_servers()
  local servers = {}
  for _, info in ipairs(get_mason_installed_servers()) do
    servers[info.lsp_name] = true
  end
  for _, c in ipairs(get_active_formal_clients()) do
    servers[c.name] = true
  end
  local result = {}
  for n, _ in pairs(servers) do
    table.insert(result, n)
  end
  table.sort(result)
  return result
end

-- 判断是否为正式服务器名称
-- 注意：启动前无法通过名称判断，所有服务器都允许尝试启动
-- 非正式服务的过滤完全由 is_formal_lsp_client 在客户端 attach 后通过能力检测完成
local function is_formal_server_name(_name)
  return true
end

-- 通过 Mason 查找已安装服务器的启动命令
local function find_mason_server_cmd(config_name)
  local servers = get_mason_installed_servers()
  for _, info in ipairs(servers) do
    if info.lsp_name == config_name or info.mason_name == config_name then
      local install_path = info.install_path
      if install_path then
        local candidates = {
          install_path .. "/" .. config_name,
          install_path .. "/bin/" .. config_name,
          install_path .. "/" .. info.mason_name,
          install_path .. "/bin/" .. info.mason_name,
        }
        for _, candidate in ipairs(candidates) do
          if vim.fn.executable(candidate) == 1 then
            return { candidate }
          end
        end
      end
    end
  end
  return nil
end

-- 初始化检测（模块加载时自动执行）
local function ensure_lsp_init()
  if _lsp_init_done then
    return
  end
  _lsp_init_done = true
  detect_lsp_service_type()
  vim.schedule(function()
    get_mason_installed_servers()
  end)
end

ensure_lsp_init()

-- 延迟清理队列：暂存 get_lsp_clients 返回的 cleanup 函数
-- 在工具循环结束时统一执行，避免多次打开/关闭 LSP buffer
local _deferred_cleanups = {}

-- 监听 TOOL_LOOP_FINISHED 事件，在工具循环结束时统一清理延迟的 buffer
local _cleanup_augroup = vim.api.nvim_create_augroup("NeoAILspDeferredCleanup", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = _cleanup_augroup,
  pattern = "NeoAI:tool_loop_finished",
  callback = function()
    M.flush_deferred_cleanups()
  end,
})

-- 检查 LSP 是否可用
local lsp_available = false

-- 标记 Tree-sitter 解析器是否已检查/安装
local ts_parsers_checked = false

-- 常用文件类型对应的 Tree-sitter 解析器名称
local ft_to_ts_parser = {
  lua = "lua",
  python = "python",
  javascript = "javascript",
  typescript = "typescript",
  javascriptreact = "tsx",
  typescriptreact = "tsx",
  go = "go",
  rust = "rust",
  java = "java",
  c = "c",
  cpp = "cpp",
  ruby = "ruby",
  php = "php",
  json = "json",
  yaml = "yaml",
  markdown = "markdown",
  bash = "bash",
  sh = "bash",
  zsh = "bash",
  css = "css",
  html = "html",
  vue = "vue",
  svelte = "svelte",
  toml = "toml",
  sql = "sql",
  cmake = "cmake",
  dockerfile = "dockerfile",
  make = "make",
  query = "query",
  regex = "regex",
}

-- 自动安装 Tree-sitter 解析器（异步，非阻塞）
-- 在模块加载时自动触发，仅执行一次
local function ensure_ts_parsers()
  if ts_parsers_checked then
    return
  end
  ts_parsers_checked = true

  local ok_ts, ts = pcall(require, "vim.treesitter")
  if not ok_ts then
    return
  end

  -- 检查 nvim-treesitter 插件是否可用（提供 TSInstallSync 命令）
  local has_ts_install = pcall(function()
    return vim.fn.exists(":TSInstallSync") == 2
  end)

  if not has_ts_install then
    -- 使用 vim.treesitter.language.inspect 检查解析器是否真正安装
    -- 注意：get_lang 只返回语言名称，不检查解析器文件是否存在
    local ok_inspect, _ = pcall(ts.language.inspect, "lua")
    if ok_inspect then
      -- 至少有一个解析器可用，跳过安装
      return
    end

    -- 尝试使用内置的 :TSInstall 命令（如果 nvim-treesitter 已加载）
    local has_ts_install_cmd = pcall(function()
      return vim.fn.exists(":TSInstall") == 2
    end)
    if not has_ts_install_cmd then
      return
    end
  end

  -- 检查并安装缺失的解析器
  -- 使用 vim.schedule 异步执行，避免阻塞模块加载
  vim.schedule(function()
    local missing_parsers = {}
    for _, parser_name in pairs(ft_to_ts_parser) do
      -- 使用 inspect 检查解析器是否真正安装（而非 get_lang）
      local ok, _ = pcall(ts.language.inspect, parser_name)
      if not ok then
        missing_parsers[parser_name] = true
      end
    end

    if next(missing_parsers) then
      local parser_list = vim.fn.keys(missing_parsers)
      table.sort(parser_list)

      -- 使用 TSInstallSync 批量安装（同步，但只在首次加载时执行一次）
      pcall(vim.api.nvim_exec2, "TSInstallSync " .. table.concat(parser_list, " "), {})
    end
  end)
end

-- 使用 LSP documentSymbol 回退查找符号位置
-- 当 Tree-sitter 不可用时，通过 LSP 的 documentSymbol 请求定位符号
local function find_symbol_via_lsp(filepath, symbol_name, bufnr)
  -- 获取绝对路径
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  -- 如果没有提供 bufnr，通过文件路径获取
  if not bufnr or bufnr == -1 then
    bufnr = vim.fn.bufnr(abs_path)
  end
  if bufnr == -1 then
    return nil
  end

  -- 重试机制：最多尝试 3 次，每次等待 2 秒
  for attempt = 1, 3 do
    local ok, responses = pcall(vim.lsp.buf_request_sync, bufnr, "textDocument/documentSymbol", {
      textDocument = { uri = vim.uri_from_fname(abs_path) },
    }, 5000)

    if ok and responses then
      -- 检查是否有任何客户端返回了有效结果
      local has_result = false
      for _, response in pairs(responses) do
        if type(response) == "table" then
          -- buf_request_sync 返回 { [client_id] = { result = ..., err = ... } }
          local result = response.result
          if result ~= nil then
            has_result = true
            if type(result) == "table" and #result > 0 then
              -- 搜索符号
              local function search_symbols(symbols, depth)
                depth = depth or 0
                if depth > 20 then
                  return nil
                end
                for _, sym in ipairs(symbols) do
                  if sym.name == symbol_name then
                    local range = sym.selectionRange or sym.range
                    if range then
                      return range.start.line, range.start.character
                    end
                  end
                  if sym.children and #sym.children > 0 then
                    local r, c = search_symbols(sym.children, depth + 1)
                    if r then
                      return r, c
                    end
                  end
                end
                return nil
              end
              local r, c = search_symbols(result)
              if r then
                return r, c
              end
            end
          end
        end
      end
      -- 如果有客户端响应但没有找到符号，直接返回（不再重试）
      if has_result then
        return nil
      end
    end

    -- 等待后重试
    if attempt < 3 then
      vim.wait(2000, function()
        return false
      end, 50)
    end
  end

  return nil
end

-- LSP 符号类型名称映射（兼容 Neovim 0.12，该版本没有 vim.lsp.symbol_kind_name）
local symbol_kind_names = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

local function safe_symbol_kind_name(kind)
  if type(kind) ~= "number" then
    return tostring(kind or "Unknown")
  end
  -- 优先使用 Neovim 内置函数（如果存在）
  local ok, result = pcall(vim.lsp.symbol_kind_name, kind)
  if ok and result then
    return result
  end
  -- 回退到本地映射表
  return symbol_kind_names[kind] or ("Symbol_" .. kind)
end

local function check_lsp()
  if lsp_available then
    return true
  end
  local ok = pcall(require, "vim.lsp")
  if ok then
    lsp_available = true
    return true
  end
  return false
end

-- 读取文件内容（使用 vim.uv 异步 I/O 替代 io.open）
local function read_file_content(filepath)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local fd, open_err = vim.uv.fs_open(abs_path, "r", 438)
  if not fd then
    return nil, "无法读取文件: " .. (open_err or "未知错误")
  end
  local stat, stat_err = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil, "无法读取文件: " .. (stat_err or "无法获取文件信息")
  end
  local content, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not content then
    return nil, "无法读取文件: " .. (read_err or "未知错误")
  end
  return content, nil
end

-- 确保文件已加载到缓冲区，返回 bufnr 和清理函数
-- 如果文件之前不在缓冲区，加载后返回的 cleanup 会关闭它
-- 如果文件已在缓冲区，cleanup 为空操作
local function ensure_buf_loaded(filepath)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local bufnr = vim.fn.bufnr(abs_path)
  local was_loaded = true

  if bufnr == -1 then
    -- 文件不在缓冲区，加载它
    bufnr = vim.fn.bufadd(abs_path)
    vim.fn.bufload(bufnr)
    was_loaded = false
  end

  -- 返回清理函数：如果是我们加载的临时缓冲区，关闭它
  local function cleanup()
    if not was_loaded and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  return bufnr, cleanup, nil
end

-- 检查 LSP 客户端是否支持悬停（本模块所需的核心能力）
-- 大多数 LSP 操作（定义、引用、悬停、补全等）只需要 hoverProvider
-- 格式化能力单独在 lsp_format 工具中检查
--
-- 注意：如果 server_capabilities 为 nil，说明客户端尚未完成初始化。
-- 此时返回 true 以避免过滤掉刚启动的客户端，后续操作会等待初始化完成。
local function client_has_required_capabilities(client)
  local caps = client.server_capabilities
  if not caps then
    -- 客户端尚未初始化完成，暂时视为可用（后续会等待初始化）
    return true
  end
  -- 只需要悬停能力（hoverProvider），这是大多数 LSP 操作的基础
  local has_hover = caps.hoverProvider == true or (type(caps.hoverProvider) == "table")
  return has_hover
end

-- 从客户端列表中过滤出支持悬停能力的客户端
local function filter_qualified_clients(clients)
  if not clients then
    return {}
  end
  local qualified = {}
  for _, client in ipairs(clients) do
    if client_has_required_capabilities(client) then
      table.insert(qualified, client)
    end
  end
  return qualified
end

-- 等待 LSP 客户端通过 LspAttach 事件 attach 到缓冲区
-- 使用 vim.wait 处理事件循环，最多等待 timeout_ms 毫秒
-- 返回过滤后的客户端列表，或 nil
-- 如果提供了 expected_config，只返回与该配置名匹配的客户端
-- 注意：LspAttach 回调中会筛选客户端，只有支持悬停能力的客户端才触发 done=true
--
-- 重要：此函数不应在 vim.schedule 回调中调用，因为 vim.wait 会阻塞事件循环。
-- 如果需要在异步上下文中获取 LSP 客户端，请使用 get_lsp_clients_nonblocking。
local function wait_for_lsp_attach(bufnr, timeout_ms, expected_config)
  timeout_ms = timeout_ms or 5000
  local clients = nil
  local done = false

  -- 辅助函数：检查客户端是否与期望配置匹配
  local function client_matches(client)
    if not expected_config then
      return true
    end
    return client.name == expected_config
  end

  -- 先检查当前是否已有合格的客户端已 attach
  clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    -- 只返回与期望配置匹配的客户端
    local matched = {}
    for _, client in ipairs(clients) do
      if client_matches(client) then
        table.insert(matched, client)
      end
    end
    if #matched > 0 then
      -- 等待客户端初始化完成（最多 8 秒）
      -- 使用 vim.wait，能处理所有 Neovim 事件
      local init_ok = vim.wait(8000, function()
        for _, client in ipairs(matched) do
          if client.initialized and client.server_capabilities then
            return true
          end
        end
        return false
      end, 50)
      if init_ok then
        -- 再次过滤：只保留支持悬停能力的客户端
        local qualified = filter_qualified_clients(matched)
        if qualified and #qualified > 0 then
          return qualified
        end
        return matched
      end
      -- 初始化超时，继续等待 LspAttach 事件
    end
  end

  -- 创建一次性 autocmd 监听 LspAttach
  -- 在回调中筛选：只接受正式 LSP 客户端（排除 Copilot 等非正式服务）
  -- 这样可以避免 GitHub Copilot 等非正式客户端触发回调
  --
  -- 注意：LspAttach 触发时，client.server_capabilities 可能尚未初始化完成。
  -- 因此回调中不立即检查 capabilities，而是设置一个标志，
  -- 由 vim.wait 的条件函数轮询检查 server_capabilities。
  local augroup = vim.api.nvim_create_augroup("NeoAILspWait_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    buffer = bufnr,
    once = true,
    callback = function(args)
      -- 获取触发事件的客户端
      local client_id = args.data and args.data.client_id
      local client = client_id and vim.lsp.get_client_by_id(client_id)
      -- 只接受正式 LSP 客户端（排除 Copilot 等非正式服务）
      if client and is_formal_lsp_client(client) then
        done = true
      end
    end,
  })

  -- 等待事件或超时（使用 vim.wait，能处理所有 Neovim 事件）
  -- vim.wait 会在等待期间处理 autocmd、LSP 回调等所有事件
  vim.wait(timeout_ms, function()
    if not done then
      return false
    end
    -- 客户端已 attach，检查 server_capabilities 是否可用
    local attached = vim.lsp.get_clients({ bufnr = bufnr })
    for _, c in ipairs(attached) do
      if is_formal_lsp_client(c) and c.server_capabilities and client_has_required_capabilities(c) then
        return true
      end
    end
    return false
  end, 50)

  -- 清理 autocmd
  pcall(vim.api.nvim_del_augroup_by_id, augroup)

  -- 再次检查客户端
  clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    -- 只返回与期望配置匹配的客户端
    local matched = {}
    for _, client in ipairs(clients) do
      if client_matches(client) then
        table.insert(matched, client)
      end
    end
    if #matched > 0 then
      return matched
    end
  end

  -- 也检查全局客户端（只处理正式 LSP 服务）
  local all_clients = vim.lsp.get_clients()
  if all_clients and #all_clients > 0 then
    for _, client in ipairs(all_clients) do
      if is_formal_lsp_client(client) and client_has_required_capabilities(client) and client_matches(client) then
        local ok = pcall(vim.lsp.buf_attach_client, bufnr, client.id)
        if ok then
          -- 等待客户端 attach（使用 vim.wait）
          vim.wait(200, function()
            local attached = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
            return #attached > 0
          end, 20)
          clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
          if clients and #clients > 0 then
            -- 只返回与期望配置匹配的客户端
            local matched = {}
            for _, c in ipairs(clients) do
              if client_matches(c) then
                table.insert(matched, c)
              end
            end
            if #matched > 0 then
              return matched
            end
          end
        end
      end
    end
  end

  return nil
end

-- 异步非阻塞版本的 wait_for_lsp_attach
-- 使用 LspAttach 事件驱动 + 轮询定时器，不阻塞主线程
-- 回调模式：callback(clients, err, bufnr)
local function wait_for_lsp_attach_async(bufnr, callback, timeout_ms, expected_config)
  timeout_ms = timeout_ms or 8000

  -- 辅助函数：检查客户端是否与期望配置匹配
  local function client_matches(client)
    if not expected_config then
      return true
    end
    return client.name == expected_config
  end

  -- 先检查当前是否已有合格的客户端
  local clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    local matched = {}
    for _, client in ipairs(clients) do
      if is_formal_lsp_client(client) and client_matches(client) then
        table.insert(matched, client)
      end
    end
    if #matched > 0 then
      -- 使用轮询定时器等待初始化完成（不阻塞）
      local poll_timer = vim.uv.new_timer()
      local elapsed = 0
      poll_timer:start(50, 50, function()
        elapsed = elapsed + 50
        vim.schedule(function()
          if elapsed >= timeout_ms then
            poll_timer:stop()
            poll_timer:close()
            -- 超时，返回已匹配的客户端（即使未初始化完成）
            if callback then
              callback(matched, nil, bufnr)
            end
            return
          end
          for _, client in ipairs(matched) do
            if client.initialized and client.server_capabilities then
              poll_timer:stop()
              poll_timer:close()
              local qualified = filter_qualified_clients(matched)
              if callback then
                callback(qualified or matched, nil, bufnr)
              end
              return
            end
          end
        end)
      end)
      return
    end
  end

  -- 创建一次性 autocmd 监听 LspAttach
  local augroup = vim.api.nvim_create_augroup("NeoAILspWaitAsync_" .. bufnr, { clear = true })
  local attached = false
  local cleanup_done = false

  local function cleanup()
    if cleanup_done then
      return
    end
    cleanup_done = true
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end

  vim.api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    buffer = bufnr,
    once = true,
    callback = function(args)
      local client_id = args.data and args.data.client_id
      local client = client_id and vim.lsp.get_client_by_id(client_id)
      if client and is_formal_lsp_client(client) then
        attached = true
      end
    end,
  })

  -- 轮询检查客户端是否已 attach 并初始化
  local poll_timer = vim.uv.new_timer()
  local elapsed = 0
  poll_timer:start(100, 100, function()
    elapsed = elapsed + 100
    vim.schedule(function()
      if elapsed >= timeout_ms then
        poll_timer:stop()
        poll_timer:close()
        cleanup()
        -- 超时，最后检查一次
        local final_clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
        if final_clients and #final_clients > 0 then
          local matched = {}
          for _, c in ipairs(final_clients) do
            if is_formal_lsp_client(c) and client_matches(c) then
              table.insert(matched, c)
            end
          end
          if #matched > 0 then
            if callback then
              callback(matched, nil, bufnr)
            end
            return
          end
        end
        if callback then
          callback(nil, "LSP 客户端连接超时", bufnr)
        end
        return
      end

      if not attached then
        return
      end

      -- 客户端已 attach，检查 server_capabilities
      local attached_clients = vim.lsp.get_clients({ bufnr = bufnr })
      for _, c in ipairs(attached_clients) do
        if is_formal_lsp_client(c) and c.server_capabilities and client_has_required_capabilities(c) then
          poll_timer:stop()
          poll_timer:close()
          cleanup()
          if callback then
            callback({ c }, nil, bufnr)
          end
          return
        end
      end
    end)
  end)
end

-- 非阻塞版本的 get_lsp_clients
-- 不调用 vim.wait，直接检查当前已 attach 的客户端
-- 如果客户端尚未 attach，尝试通过 try_start_lsp 启动（不等待）
-- 适用于在 vim.schedule 回调中调用
-- 返回 clients, err, bufnr, cleanup
local function get_lsp_clients_nonblocking(filepath, defer_cleanup)
  local bufnr, cleanup, err = ensure_buf_loaded(filepath)
  if err then
    return nil, err, nil, nil
  end

  -- 获取文件类型和对应的 LSP 配置名
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local ft = vim.filetype.match({ filename = abs_path })
  local ft_to_lsp_config = {
    lua = "lua_ls",
    python = "pyright",
    javascript = "ts_ls",
    typescript = "ts_ls",
    javascriptreact = "ts_ls",
    typescriptreact = "ts_ls",
    go = "gopls",
    rust = "rust_analyzer",
    java = "jdtls",
    c = "clangd",
    cpp = "clangd",
    ruby = "solargraph",
    php = "intelephense",
    json = "jsonls",
    yaml = "yamlls",
    markdown = "marksman",
    bash = "bashls",
    sh = "bashls",
    zsh = "bashls",
    css = "cssls",
    html = "htmlls",
    vue = "volar",
    svelte = "svelte",
  }
  local expected_config = ft and ft_to_lsp_config[ft]

  -- 第一步：直接查找已 attach 到该缓冲区的客户端（只匹配正式 LSP 服务）
  local clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    local matched_clients = {}
    for _, client in ipairs(clients) do
      if is_formal_lsp_client(client) and (not expected_config or client.name == expected_config) then
        table.insert(matched_clients, client)
      end
    end
    if #matched_clients > 0 then
      if defer_cleanup and cleanup then
        table.insert(_deferred_cleanups, cleanup)
        return matched_clients, nil, bufnr, nil
      end
      return matched_clients, nil, bufnr, cleanup
    end
  end

  -- 第二步：尝试启动 LSP 服务器（不等待）
  if expected_config then
    local started = try_start_lsp(expected_config, bufnr)
    if started then
      -- 不等待，直接返回 nil，让调用方决定是否重试
      if cleanup then
        cleanup()
      end
      return nil, "LSP 客户端正在启动中，请稍后重试", nil, nil
    end
  end

  if cleanup then
    cleanup()
  end
  return nil, "文件 '" .. filepath .. "' 没有关联的 LSP 客户端（需要支持悬停功能）", nil, nil
end

-- 完全非阻塞的 get_lsp_clients 异步版本
-- 回调模式：callback(clients, err, bufnr, cleanup)
-- 不会阻塞主线程，适合在 vim.schedule 回调中调用
-- 流程：
--   1. 加载文件到缓冲区
--   2. 检查是否已有已 attach 的客户端
--   3. 如果没有，尝试启动 LSP 服务器
--   4. 等待客户端 attach（使用 wait_for_lsp_attach_async，不阻塞）
--   5. 通过回调返回结果
local function get_lsp_clients_async(filepath, callback, defer_cleanup)
  if not callback then
    return
  end

  local bufnr, cleanup, err = ensure_buf_loaded(filepath)
  if err then
    callback(nil, err, nil, nil)
    return
  end

  -- 获取文件类型和对应的 LSP 配置名
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local ft = vim.filetype.match({ filename = abs_path })
  local ft_to_lsp_config = {
    lua = "lua_ls",
    python = "pyright",
    javascript = "ts_ls",
    typescript = "ts_ls",
    javascriptreact = "ts_ls",
    typescriptreact = "ts_ls",
    go = "gopls",
    rust = "rust_analyzer",
    java = "jdtls",
    c = "clangd",
    cpp = "clangd",
    ruby = "solargraph",
    php = "intelephense",
    json = "jsonls",
    yaml = "yamlls",
    markdown = "marksman",
    bash = "bashls",
    sh = "bashls",
    zsh = "bashls",
    css = "cssls",
    html = "htmlls",
    vue = "volar",
    svelte = "svelte",
  }
  local expected_config = ft and ft_to_lsp_config[ft]

  -- 辅助函数：检查客户端是否与期望配置匹配
  local function client_matches(client)
    if not expected_config then
      return true
    end
    return client.name == expected_config
  end

  -- 第一步：直接查找已 attach 的客户端
  local clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    local matched = {}
    for _, client in ipairs(clients) do
      if is_formal_lsp_client(client) and client_matches(client) then
        table.insert(matched, client)
      end
    end
    if #matched > 0 then
      if defer_cleanup and cleanup then
        table.insert(_deferred_cleanups, cleanup)
        callback(matched, nil, bufnr, nil)
      else
        callback(matched, nil, bufnr, cleanup)
      end
      return
    end
  end

  -- 第二步：尝试启动 LSP 服务器
  if expected_config then
    local started = try_start_lsp(expected_config, bufnr)
    if started then
      -- 等待客户端 attach（非阻塞）
      wait_for_lsp_attach_async(bufnr, function(attached_clients, attach_err, _)
        if attached_clients then
          if defer_cleanup and cleanup then
            table.insert(_deferred_cleanups, cleanup)
            callback(attached_clients, nil, bufnr, nil)
          else
            callback(attached_clients, nil, bufnr, cleanup)
          end
        else
          if cleanup then
            cleanup()
          end
          callback(nil, attach_err or "LSP 客户端启动后连接失败", nil, nil)
        end
      end, 8000, expected_config)
      return
    end
  end

  -- 第三步：等待任何 LSP 客户端 attach（非阻塞）
  wait_for_lsp_attach_async(bufnr, function(attached_clients, attach_err, _)
    if attached_clients then
      if defer_cleanup and cleanup then
        table.insert(_deferred_cleanups, cleanup)
        callback(attached_clients, nil, bufnr, nil)
      else
        callback(attached_clients, nil, bufnr, cleanup)
      end
    else
      if cleanup then
        cleanup()
      end
      callback(nil, attach_err or "文件 '" .. filepath .. "' 没有关联的 LSP 客户端", nil, nil)
    end
  end, 5000, expected_config)
end

-- 获取文件对应的 LSP 客户端
-- 尝试多种方式启动 LSP 服务器（通用实现，自适应所有 LSP 配置）
-- 返回 true/false
local function try_start_lsp(config_name, bufnr)
  -- 跳过非正式服务器
  if not is_formal_server_name(config_name) then
    return false
  end

  ensure_lsp_init()

  -- 方式 1：尝试通过用户自定义 LSP 模块启动
  -- 遍历常见自定义模块名，看是否有启动能力
  local custom_modules = { "lsp", "lspconfig", "lsp_config", "lsp-config" }
  for _, mod_name in ipairs(custom_modules) do
    local ok, mod = pcall(require, mod_name)
    if ok and type(mod) == "table" then
      -- 方式 1a：start_server_with_config 方法
      if mod.start_server_with_config then
        local started = mod.start_server_with_config(config_name, bufnr)
        if started then
          return true
        end
      end
      -- 方式 1b：_server_configs 表（Neovim 0.12 内置 API 模式）
      if mod._server_configs and mod._server_configs[config_name] then
        local cfg = mod._server_configs[config_name]
        local ok_id, client_id = pcall(vim.lsp.start, cfg)
        if ok_id and client_id then
          pcall(vim.lsp.buf_attach_client, bufnr, client_id)
          return true
        end
      end
    end
  end

  -- 方式 2：vim.lsp.config 注册的配置（Neovim 0.12 内置）
  local configs_ok = pcall(function()
    if type(vim.lsp.config) == "table" then
      if vim.lsp.config.get then
        local c = vim.lsp.config.get(config_name)
        if c then
          return true
        end
      end
    end
    return false
  end)
  if configs_ok then
    local ok_id, client_id = pcall(vim.lsp.start, config_name)
    if ok_id and client_id then
      pcall(vim.lsp.buf_attach_client, bufnr, client_id)
      return true
    end
  end

  -- 方式 3：nvim-lspconfig 插件
  local lspconfig_ok, lspconfig = pcall(require, "lspconfig")
  if lspconfig_ok and lspconfig[config_name] then
    -- 尝试 launch（部分版本支持）
    local ok_launch, client_id = pcall(lspconfig[config_name].launch, lspconfig[config_name], bufnr)
    if ok_launch and client_id then
      return true
    end
    -- 尝试通过 manager 启动（较新版本）
    if lspconfig[config_name].manager then
      local ok_mgr = pcall(lspconfig[config_name].manager.try_add, bufnr)
      if ok_mgr then
        return true
      end
    end
  end

  -- 方式 4：Mason 已安装的服务器
  local mason_cmd = find_mason_server_cmd(config_name)
  if mason_cmd then
    local lsp_config = {
      name = config_name,
      cmd = mason_cmd,
      root_dir = vim.fn.getcwd(),
    }
    local ok_id, client_id = pcall(vim.lsp.start, lsp_config)
    if ok_id and client_id then
      pcall(vim.lsp.buf_attach_client, bufnr, client_id)
      return true
    end
  end

  -- 方式 5：直接启动（通过 config_name 推断可执行文件名）
  -- 生成多种可能的命令变体
  local cmd_variants = {}
  -- 特殊映射（常见 LSP 服务器的标准命令）
  local special_cmds = {
    lua_ls = { "lua-language-server" },
    pyright = { "pyright-langserver", "--stdio" },
    ts_ls = { "typescript-language-server", "--stdio" },
    html = { "vscode-html-language-server", "--stdio" },
    cssls = { "vscode-css-language-server", "--stdio" },
    jsonls = { "vscode-json-language-server", "--stdio" },
    yamlls = { "yaml-language-server", "--stdio" },
    bashls = { "bash-language-server", "start" },
    clangd = { "clangd" },
    gopls = { "gopls" },
    rust_analyzer = { "rust-analyzer" },
    marksman = { "marksman" },
    solargraph = { "solargraph", "stdio" },
    intelephense = { "intelephense", "--stdio" },
    jdtls = { "jdtls" },
    volar = { "vue-language-server", "--stdio" },
    svelte = { "svelte-language-server", "--stdio" },
    htmlls = { "vscode-html-language-server", "--stdio" },
  }
  if special_cmds[config_name] then
    table.insert(cmd_variants, special_cmds[config_name])
  end
  -- 通用推断
  local dashed = config_name:gsub("_", "-")
  table.insert(cmd_variants, { config_name })
  table.insert(cmd_variants, { dashed })
  table.insert(cmd_variants, { dashed .. "-language-server" })
  table.insert(cmd_variants, { dashed .. "-langserver", "--stdio" })
  table.insert(cmd_variants, { "vscode-" .. dashed .. "-language-server", "--stdio" })

  for _, cmd in ipairs(cmd_variants) do
    if cmd[1] and vim.fn.executable(cmd[1]) == 1 then
      local lsp_config = {
        name = config_name,
        cmd = cmd,
        root_dir = vim.fn.getcwd(),
      }
      local ok_id, client_id = pcall(vim.lsp.start, lsp_config)
      if ok_id and client_id then
        pcall(vim.lsp.buf_attach_client, bufnr, client_id)
        return true
      end
    end
  end

  return false
end

-- 获取文件对应的 LSP 客户端
-- 只返回同时支持格式化（formatting）和悬停（hover）的客户端
-- 如果文件没有关联的客户端，尝试通过多种方式启动
-- 返回 clients, err, bufnr, cleanup
-- 如果 defer_cleanup 为 true，cleanup 会延迟到工具循环结束时执行
--
-- 注意：此函数会调用 vim.wait（在 wait_for_lsp_attach 中），
-- 如果在 vim.schedule/vim.defer_fn 回调中调用会阻塞主进程。
-- 异步上下文中请使用 get_lsp_clients_nonblocking。
local function get_lsp_clients(filepath, defer_cleanup)
  local bufnr, cleanup, err = ensure_buf_loaded(filepath)
  if err then
    return nil, err, nil, nil
  end

  -- 获取文件类型和对应的 LSP 配置名
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local ft = vim.filetype.match({ filename = abs_path })
  local ft_to_lsp_config = {
    lua = "lua_ls",
    python = "pyright",
    javascript = "ts_ls",
    typescript = "ts_ls",
    javascriptreact = "ts_ls",
    typescriptreact = "ts_ls",
    go = "gopls",
    rust = "rust_analyzer",
    java = "jdtls",
    c = "clangd",
    cpp = "clangd",
    ruby = "solargraph",
    php = "intelephense",
    json = "jsonls",
    yaml = "yamlls",
    markdown = "marksman",
    bash = "bashls",
    sh = "bashls",
    zsh = "bashls",
    css = "cssls",
    html = "htmlls",
    vue = "volar",
    svelte = "svelte",
  }
  local expected_config = ft and ft_to_lsp_config[ft]

  -- 辅助函数：检查客户端是否与文件类型匹配
  local function client_matches_filetype(client)
    if not expected_config then
      return true -- 无法推断文件类型，接受任何客户端
    end
    -- 检查客户端名称是否与期望的配置名匹配
    return client.name == expected_config
  end

  -- 第一步：直接查找已 attach 到该缓冲区的客户端（只匹配正式 LSP 服务）
  local clients = filter_qualified_clients(vim.lsp.get_clients({ bufnr = bufnr }))
  if clients and #clients > 0 then
    -- 检查是否有与文件类型匹配的客户端
    local matched_clients = {}
    for _, client in ipairs(clients) do
      if is_formal_lsp_client(client) and client_matches_filetype(client) then
        table.insert(matched_clients, client)
      end
    end
    if #matched_clients > 0 then
      if defer_cleanup and cleanup then
        table.insert(_deferred_cleanups, cleanup)
        return matched_clients, nil, bufnr, nil
      end
      return matched_clients, nil, bufnr, cleanup
    end
  end

  -- 第二步：尝试通过文件类型推断并启动 LSP 服务器
  if expected_config then
    -- 尝试多种方式启动 LSP 服务器
    local started = try_start_lsp(expected_config, bufnr)
    if started then
      -- 启动后等待客户端 attach（使用 vim.wait，最多 8 秒）
      -- 注意：如果在 vim.schedule 回调中调用，会阻塞主进程
      local attached_clients = wait_for_lsp_attach(bufnr, 8000, expected_config)
      if attached_clients then
        if defer_cleanup and cleanup then
          table.insert(_deferred_cleanups, cleanup)
          return attached_clients, nil, bufnr, nil
        end
        return attached_clients, nil, bufnr, cleanup
      end
    end
  end

  -- 第三步：通过 LspAttach 事件等待 LSP 客户端 attach（最多 5 秒）
  local attached_clients = wait_for_lsp_attach(bufnr, 5000, expected_config)
  if attached_clients then
    if defer_cleanup and cleanup then
      table.insert(_deferred_cleanups, cleanup)
      return attached_clients, nil, bufnr, nil
    end
    return attached_clients, nil, bufnr, cleanup
  end

  if cleanup then
    cleanup()
  end
  return nil, "文件 '" .. filepath .. "' 没有关联的 LSP 客户端（需要支持悬停功能）", nil, nil
end

-- 使用 Tree-sitter 在文件中查找符号位置
-- 如果 Tree-sitter 不可用，回退到 LSP documentSymbol
-- 返回 { row, col } 或 nil
-- 如果提供了 bufnr，则优先使用它进行 LSP documentSymbol 回退查找
local function find_symbol_position(filepath, symbol_name, node_type, bufnr)
  -- 先尝试 Tree-sitter
  local ok_ts, ts = pcall(require, "vim.treesitter")
  if ok_ts then
    local content, err = read_file_content(filepath)
    if content then
      -- 推断语言
      local abs_path = vim.fn.fnamemodify(filepath, ":p")
      local ft = vim.filetype.match({ filename = abs_path })
      if ft then
        -- 使用 inspect 检查解析器是否真正安装
        local ok_inspect, _ = pcall(ts.language.inspect, ft)
        if not ok_inspect then
          -- 解析器未安装，跳过 Tree-sitter 查找，直接回退到 LSP
          return find_symbol_via_lsp(filepath, symbol_name, bufnr)
        end
        local ok_lang, lang = pcall(ts.language.get_lang, ft)
        if ok_lang and lang then
          local ok_parser, parser = pcall(ts.get_string_parser, content, lang)
          if ok_parser and parser then
            local ok_trees, trees = pcall(parser.parse, parser)
            if ok_trees and trees and #trees > 0 then
              local root = trees[1]:root()

              -- 需要跳过的节点类型（注释、字符串等，不包含有效符号）
              local skip_types = {
                comment = true,
                string = true,
                string_literal = true,
                line_comment = true,
                block_comment = true,
              }

              -- 递归遍历查找匹配的节点
              -- 跳过根节点（如 chunk、program），因为根节点包含整个文件内容
              local root_types = { chunk = true, program = true }

              -- 检查符号名是否包含 '.'（如 "M.setup"、"table.insert"）
              local symbol_parts = {}
              local is_dotted = false
              if symbol_name:find(".", 1, true) then
                is_dotted = true
                for part in symbol_name:gmatch("[^.]+") do
                  table.insert(symbol_parts, part)
                end
              end

              local function search_node(node, depth, max_depth)
                if not node or (max_depth and depth > max_depth) then
                  return nil
                end

                -- 跳过根节点类型，避免根节点包含整个文件内容导致返回 (0,0)
                if root_types[node:type()] then
                  -- 直接搜索子节点
                  for i = 0, node:named_child_count() - 1 do
                    local child = node:named_child(i)
                    local r, c = search_node(child, depth + 1, max_depth)
                    if r then
                      return r, c
                    end
                  end
                  return nil
                end

                -- 跳过注释和字符串节点
                if skip_types[node:type()] then
                  return nil
                end

                local text = vim.treesitter.get_node_text(node, content)
                local node_type_match = true
                if node_type and node:type() ~= node_type then
                  node_type_match = false
                end

                if node_type_match and text then
                  -- 策略一：精确匹配（text == symbol_name）
                  if text == symbol_name then
                    -- 查找子节点中精确匹配符号名的 identifier 节点
                    for i = 0, node:named_child_count() - 1 do
                      local child = node:named_child(i)
                      local child_text = vim.treesitter.get_node_text(child, content)
                      if child_text == symbol_name then
                        local sr, sc = child:range()
                        return sr, sc
                      end
                    end
                    local sr, sc = node:range()
                    return sr, sc
                  end

                  -- 策略二：子串匹配（text 包含 symbol_name）
                  if text:find(symbol_name, 1, true) then
                    -- 优先查找子节点中精确匹配符号名的 identifier 节点
                    for i = 0, node:named_child_count() - 1 do
                      local child = node:named_child(i)
                      local child_text = vim.treesitter.get_node_text(child, content)
                      if child_text == symbol_name then
                        local sr, sc = child:range()
                        return sr, sc
                      end
                    end
                    -- 如果没有找到精确匹配的子节点，返回当前节点的起始位置
                    local sr, sc = node:range()
                    return sr, sc
                  end

                  -- 策略三：带点符号名匹配（如 "M.setup" 匹配 field 节点 "M.setup"）
                  if is_dotted and text == symbol_parts[#symbol_parts] then
                    -- 当前节点文本等于最后一部分（如 "setup"），向上检查父节点链
                    -- 对于 field 节点如 "M.setup"，子节点是 "M" 和 "setup"
                    -- 我们直接检查当前节点的父节点是否包含完整的点号表达式
                    local parent = node:parent()
                    if parent then
                      local parent_text = vim.treesitter.get_node_text(parent, content)
                      if parent_text == symbol_name then
                        local sr, sc = node:range()
                        return sr, sc
                      end
                    end
                  end
                end

                -- 优先搜索命名子节点
                for i = 0, node:named_child_count() - 1 do
                  local child = node:named_child(i)
                  local r, c = search_node(child, depth + 1, max_depth)
                  if r then
                    return r, c
                  end
                end

                return nil
              end

              local row, col = search_node(root, 0, 50)
              if row then
                return row, col
              end
            end
          end
        end
      end
    end
  end

  -- Tree-sitter 不可用或未找到符号，回退到 LSP documentSymbol
  local row, col = find_symbol_via_lsp(filepath, symbol_name, bufnr)
  if row then
    return row, col
  end

  return nil, "未找到符号 '" .. symbol_name .. "' 在文件中的位置"
end

-- 执行 LSP 请求并等待结果
-- 使用 Neovim 0.12 的 buf_request_sync，单次请求，超时 5 秒
-- 如果第一次请求没有结果，重试一次
--
-- 注意：此函数会阻塞主线程（调用 vim.wait），
-- 请优先使用 lsp_request_async 进行非阻塞调用
local function lsp_request(bufnr, method, params)
  for attempt = 1, 2 do
    local ok, responses = pcall(vim.lsp.buf_request_sync, bufnr, method, params, 5000)
    if ok and responses then
      for _, response in pairs(responses) do
        if type(response) == "table" and response.result ~= nil then
          return response.result
        end
      end
    end
    -- 如果没有结果，等待后重试
    if attempt < 2 then
      vim.wait(1000, function()
        return false
      end, 50)
    end
  end
  return nil
end

-- LSP 请求的异步非阻塞版本
-- 使用 vim.lsp.buf_request（非阻塞）替代 buf_request_sync
-- 回调模式：callback(result, error_msg)
-- 不会阻塞主线程，适合在 vim.schedule 回调中调用
local function lsp_request_async(bufnr, method, params, callback)
  if not bufnr or not method then
    if callback then
      callback(nil, "无效的 LSP 请求参数")
    end
    return
  end

  local done = false
  local result_value = nil
  local error_value = nil
  local timer = vim.uv.new_timer()

  -- 使用 buf_request 非阻塞发送请求
  -- vim.lsp.buf_request 返回 request_id (number)，如果失败则抛出错误
  -- pcall 返回 (ok, request_id_or_error)
  local ok, result_or_err = pcall(vim.lsp.buf_request, bufnr, method, params, function(err, result, ctx)
    -- 这个回调在主线程中执行
    if done then
      return
    end
    done = true

    -- 取消超时定时器
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end

    if err then
      error_value = tostring(err)
      if callback then
        callback(nil, error_value)
      end
    elseif result == nil then
      error_value = "LSP 请求无响应"
      if callback then
        callback(nil, error_value)
      end
    else
      result_value = result
      if callback then
        callback(result, nil)
      end
    end
  end)

  if not ok then
    -- pcall 失败（buf_request 抛出错误）
    done = true
    if timer and not timer:is_closing() then
      timer:close()
    end
    if callback then
      callback(nil, "发送 LSP 请求失败: " .. tostring(result_or_err))
    end
    return
  end

  -- buf_request 成功，result_or_err 是 request_id
  -- 注意：即使没有客户端 attach，buf_request 也不会报错，只是不会调用回调
  -- 超时定时器会处理这种情况

  -- 设置超时保护（8秒）
  timer:start(8000, 0, function()
    vim.schedule(function()
      if done then
        return
      end
      done = true
      if not timer:is_closing() then
        timer:close()
      end
      if callback then
        callback(nil, "LSP 请求超时（8秒）: " .. method)
      end
    end)
  end)
end
-- ============================================================================
-- 工具 lsp_hover - 悬浮显示符号文档（回调模式）
-- ============================================================================

local function _lsp_hover(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位")
    end
    return
  end

  -- 使用 get_lsp_clients_async 非阻塞获取 LSP 客户端
  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    -- 使用 lsp_request_async 非阻塞发送 LSP 请求
    lsp_request_async(bufnr, "textDocument/hover", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result then
        if on_error then
          on_error(req_err or "未找到符号 '" .. args.symbol .. "' 的悬停信息")
        end
        return
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          contents = result.contents,
          range = result.range,
        })
      end
    end)
  end, true)
end

M.lsp_hover = define_tool({
  name = "lsp_hover",
  description = "获取文件中指定符号的 LSP 悬停信息（函数/变量说明文档），通过符号名称和可选的节点类型定位",
  func = _lsp_hover,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = { type = "object", description = "悬停信息，包含文档内容和位置范围" },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_definition - 跳转到定义（回调模式）
-- ============================================================================

local function _lsp_definition(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end
  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end
  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    lsp_request_async(bufnr, "textDocument/definition", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "未找到符号 '" .. args.symbol .. "' 的定义")
        end
        return
      end

      local locations = {}
      for _, loc in ipairs(result) do
        table.insert(locations, {
          uri = loc.uri or loc.targetUri,
          filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
          range = loc.range or loc.targetRange,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          locations = locations,
        })
      end
    end)
  end, true)
end

M.lsp_definition = define_tool({
  name = "lsp_definition",
  description = "获取文件中指定符号的定义位置，通过符号名称和可选的节点类型定位，返回定义所在的文件和位置范围",
  func = _lsp_definition,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = { type = "object", description = "定义位置信息列表" },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_references - 查找所有引用
-- ============================================================================

local function _lsp_references(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end
  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    local include_declaration = true
    if args.include_declaration ~= nil then
      include_declaration = args.include_declaration
    end

    lsp_request_async(bufnr, "textDocument/references", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
      context = { includeDeclaration = include_declaration },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "未找到符号 '" .. args.symbol .. "' 的引用")
        end
        return
      end

      local references = {}
      for _, ref in ipairs(result) do
        table.insert(references, {
          uri = ref.uri,
          filename = ref.filename or (ref.uri and vim.uri_to_fname(ref.uri)),
          range = ref.range,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          reference_count = #references,
          references = references,
        })
      end
    end)
  end, true)
end

M.lsp_references = define_tool({
  name = "lsp_references",
  description = "获取文件中指定符号的所有引用位置，通过符号名称和可选的节点类型定位，返回引用列表",
  func = _lsp_references,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
      include_declaration = {
        type = "boolean",
        description = "是否包含声明位置（可选，默认 true）",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "引用位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_implementation - 查看实现位置
-- ============================================================================

local function _lsp_implementation(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end
  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    lsp_request_async(bufnr, "textDocument/implementation", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "未找到符号 '" .. args.symbol .. "' 的实现")
        end
        return
      end

      local locations = {}
      for _, loc in ipairs(result) do
        table.insert(locations, {
          uri = loc.uri,
          filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
          range = loc.range,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          locations = locations,
        })
      end
    end)
  end, true)
end

M.lsp_implementation = define_tool({
  name = "lsp_implementation",
  description = "获取文件中指定符号的实现位置，通过符号名称和可选的节点类型定位，返回实现所在的文件和位置范围",
  func = _lsp_implementation,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "实现位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_declaration - 查看声明位置
-- ============================================================================

local function _lsp_declaration(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end
  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    lsp_request_async(bufnr, "textDocument/declaration", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "未找到符号 '" .. args.symbol .. "' 的声明")
        end
        return
      end

      local locations = {}
      for _, loc in ipairs(result) do
        table.insert(locations, {
          uri = loc.uri,
          filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
          range = loc.range,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          locations = locations,
        })
      end
    end)
  end, true)
end

M.lsp_declaration = define_tool({
  name = "lsp_declaration",
  description = "获取文件中指定符号的声明位置，通过符号名称和可选的节点类型定位，返回声明所在的文件和位置范围",
  func = _lsp_declaration,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名、变量名" },
      node_type = {
        type = "string",
        description = "节点类型过滤（可选），如 'function_definition'、'identifier'",
      },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "声明位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})
-- ============================================================================
-- 工具 lsp_document_symbols - 获取文档符号列表
-- ============================================================================

local function _lsp_document_symbols(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    lsp_request_async(bufnr, "textDocument/documentSymbol", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "未找到文档符号")
        end
        return
      end

      local function flatten_symbols(symbols, depth)
        depth = depth or 0
        local flat = {}
        for _, sym in ipairs(symbols) do
          local entry = {
            name = sym.name,
            kind = sym.kind,
            kind_name = safe_symbol_kind_name(sym.kind),
            range = sym.range,
            selection_range = sym.selectionRange,
            detail = sym.detail,
            depth = depth,
          }
          table.insert(flat, entry)
          if sym.children and #sym.children > 0 then
            local children = flatten_symbols(sym.children, depth + 1)
            for _, child in ipairs(children) do
              table.insert(flat, child)
            end
          end
        end
        return flat
      end

      local symbols = flatten_symbols(result)

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol_count = #symbols,
          symbols = symbols,
        })
      end
    end)
  end, true)
end

M.lsp_document_symbols = define_tool({
  name = "lsp_document_symbols",
  description = "获取文件中所有符号（变量、函数、类等）的列表，返回符号名称、类型和位置范围",
  func = _lsp_document_symbols,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "文档符号列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_workspace_symbols - 搜索工作区符号
-- ============================================================================

local function _lsp_workspace_symbols(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.query then
    if on_error then
      on_error("需要 query（查询字符串）参数")
    end
    return
  end

  if not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数来定位 LSP 客户端")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err or not clients then
      if on_error then
        on_error(err or "无法获取 LSP 客户端")
      end
      return
    end

    -- 对每个客户端发送 workspace/symbol 请求
    local all_symbols = {}
    local pending = 0
    local completed = 0
    local has_error = false

    for _, client in ipairs(clients) do
      if client.server_capabilities and client.server_capabilities.workspaceSymbolProvider then
        pending = pending + 1
        local client_id = client.id
        lsp_request_async(bufnr, "workspace/symbol", { query = args.query }, function(result, req_err)
          completed = completed + 1
          if has_error then
            return
          end

          if req_err then
            has_error = true
            if cleanup then
              cleanup()
            end
            if on_error then
              on_error(req_err)
            end
            return
          end

          if result and #result > 0 then
            for _, sym in ipairs(result) do
              table.insert(all_symbols, {
                name = sym.name,
                kind = sym.kind,
                kind_name = safe_symbol_kind_name(sym.kind),
                location = sym.location,
                container_name = sym.containerName,
              })
            end
          end

          if completed >= pending then
            if cleanup then
              cleanup()
            end
            if #all_symbols == 0 then
              if on_error then
                on_error("未找到匹配工作区符号: " .. args.query)
              end
            elseif on_success then
              on_success({
                query = args.query,
                symbol_count = #all_symbols,
                symbols = all_symbols,
              })
            end
          end
        end)
      end
    end

    if pending == 0 then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("没有客户端支持工作区符号搜索")
      end
    end
  end, true)
end

M.lsp_workspace_symbols = define_tool({
  name = "lsp_workspace_symbols",
  description = "在工作区中搜索符号（函数、类、变量等），返回匹配的符号列表及其位置",
  func = _lsp_workspace_symbols,
  async = true,
  parameters = {
    type = "object",
    properties = {
      query = { type = "string", description = "符号名称查询字符串，支持模糊匹配" },
      filepath = { type = "string", description = "文件路径，用于定位 LSP 客户端" },
    },
    required = { "query", "filepath" },
  },
  returns = {
    type = "object",
    description = "工作区符号搜索结果",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_code_action - 获取代码修复建议
-- ============================================================================

local function _lsp_code_action(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    -- 通过符号名称定位
    local row, col
    if args.symbol then
      row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
        end
        return
      end
    else
      row = 0
      col = 0
    end

    -- 获取该位置的诊断信息（用于 code action context）
    local diagnostics = {}
    if args.include_diagnostics ~= false then
      diagnostics = vim.diagnostic.get(bufnr, { lnum = row })
    end

    lsp_request_async(bufnr, "textDocument/codeAction", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      range = {
        start = { line = row, character = col },
        ["end"] = { line = row, character = col + 1 },
      },
      context = {
        diagnostics = diagnostics,
        only = args.only,
      },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "未找到该位置的代码操作")
        end
        return
      end

      local actions = {}
      for _, action in ipairs(result) do
        table.insert(actions, {
          title = action.title,
          kind = action.kind,
          is_preferred = action.isPreferred,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          action_count = #actions,
          actions = actions,
        })
      end
    end)
  end, true)
end

M.lsp_code_action = define_tool({
  name = "lsp_code_action",
  description = "获取文件中指定符号位置的 LSP 代码操作建议（如自动修复、重构等），通过符号名称定位，返回操作标题和类型列表。注意：通常仅在文件有诊断信息（错误/警告）的位置才会有代码操作建议，无诊断的位置可能返回空结果。",
  func = _lsp_code_action,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称（可选），不指定则从文件开头查找" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
      only = {
        type = "array",
        items = { type = "string" },
        description = "仅返回指定类型的代码操作（可选），如 'refactor.extract.function'",
      },
      include_diagnostics = {
        type = "boolean",
        description = "是否包含诊断信息作为上下文（可选，默认 true）",
      },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "代码操作建议列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_rename - 重命名符号
-- ============================================================================

local function _lsp_rename(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  if not args.new_name then
    if on_error then
      on_error("需要 new_name（新名称）参数")
    end
    return
  end
  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位要重命名的符号")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    lsp_request_async(bufnr, "textDocument/rename", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
      newName = args.new_name,
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err then
        if on_error then
          on_error(req_err)
        end
        return
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          new_name = args.new_name,
          changes = result and result.changes,
        })
      end
    end)
  end, true)
end

M.lsp_rename = define_tool({
  name = "lsp_rename",
  description = "重命名文件中指定符号，通过符号名称定位，返回重命名影响的所有文件变更",
  func = _lsp_rename,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "要重命名的符号名称" },
      new_name = { type = "string", description = "新名称" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
    },
    required = { "filepath", "symbol", "new_name" },
  },
  returns = {
    type = "object",
    description = "重命名结果，包含所有受影响的文件变更",
  },
  category = "lsp",
  permissions = { write = true },
})

-- ============================================================================
-- 工具 lsp_format - 格式化代码
-- ============================================================================

local function _lsp_format(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err or not clients then
      if on_error then
        on_error(err or "无法获取 LSP 客户端")
      end
      return
    end

    -- 单独检查客户端是否支持格式化能力
    local has_format_client = false
    for _, client in ipairs(clients) do
      local caps = client.server_capabilities
      if caps then
        local has_format = caps.documentFormattingProvider == true or (type(caps.documentFormattingProvider) == "table")
        if has_format then
          has_format_client = true
          break
        end
      end
    end
    if not has_format_client then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("LSP 客户端不支持文档格式化（documentFormattingProvider）")
      end
      return
    end

    local options = {}
    if args.tab_size then
      options.tabSize = args.tab_size
    end
    if args.insert_spaces ~= nil then
      options.insertSpaces = args.insert_spaces
    end

    lsp_request_async(bufnr, "textDocument/formatting", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      options = options,
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "格式化失败或无变更")
        end
        return
      end

      -- 读取格式化后的内容
      local content, _ = read_file_content(args.filepath)

      if on_success then
        on_success({
          filepath = args.filepath,
          formatted = true,
          content = content,
        })
      end
    end)
  end, true)
end

M.lsp_format = define_tool({
  name = "lsp_format",
  description = "使用 LSP 格式化指定文件中的代码，支持设置缩进大小和空格/制表符偏好",
  func = _lsp_format,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      tab_size = { type = "number", description = "缩进大小（可选）" },
      insert_spaces = { type = "boolean", description = "是否使用空格缩进（可选）" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "格式化结果，包含格式化后的文件内容",
  },
  category = "lsp",
  permissions = { write = true },
})
-- ============================================================================
-- 工具 lsp_diagnostics - 获取诊断信息
-- ============================================================================

local function _lsp_diagnostics(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  if not args or not args.filepath then
    return { error = "需要 filepath（文件路径）参数" }
  end

  local bufnr, cleanup, err = ensure_buf_loaded(args.filepath)
  if err then
    return { filepath = args.filepath, error = err }
  end

  local diagnostics = vim.diagnostic.get(bufnr, {
    severity = args.severity and { min = args.severity },
  })

  if cleanup then
    cleanup()
  end

  if not diagnostics or #diagnostics == 0 then
    return { filepath = args.filepath, diagnostic_count = 0, diagnostics = {} }
  end

  local results = {}
  for _, d in ipairs(diagnostics) do
    table.insert(results, {
      severity = d.severity,
      message = d.message,
      source = d.source,
      code = d.code,
      lnum = d.lnum,
      col = d.col,
      end_lnum = d.end_lnum,
      end_col = d.end_col,
    })
  end

  return {
    filepath = args.filepath,
    diagnostic_count = #results,
    diagnostics = results,
  }
end

M.lsp_diagnostics = define_tool({
  name = "lsp_diagnostics",
  description = "获取文件中所有 LSP 诊断信息（错误、警告、提示等），支持按严重程度过滤",
  func = _lsp_diagnostics,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      severity = {
        type = "number",
        description = "最低严重程度过滤（可选）：1=错误, 2=警告, 3=信息, 4=提示",
      },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "诊断信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_client_info - 获取 LSP 客户端信息
-- ============================================================================

-- 判断 LSP 客户端是否功能完整（至少支持一项核心语义功能）
-- 排除仅支持 inline_completion 的客户端（如 GitHub Copilot）
local function is_client_functionally_complete(client)
  local caps = client.server_capabilities
  if not caps then
    return false
  end
  -- 核心语义功能列表：只要支持其中任意一项就认为是功能完整的客户端
  local core_capabilities = {
    caps.hoverProvider,
    caps.definitionProvider,
    caps.referencesProvider,
    caps.documentFormattingProvider,
    caps.codeActionProvider,
    caps.completionProvider,
    caps.signatureHelpProvider,
    caps.documentSymbolProvider,
    caps.workspaceSymbolProvider,
    caps.implementationProvider,
    caps.declarationProvider,
    caps.typeDefinitionProvider,
    caps.renameProvider,
  }
  for _, cap in ipairs(core_capabilities) do
    if cap == true or type(cap) == "table" then
      return true
    end
  end
  return false
end

local function _lsp_client_info(args)
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  -- 收集要查询的文件路径列表
  local filepaths = {}
  if args and args.filepath then
    table.insert(filepaths, args.filepath)
  end
  if args and args.filepaths then
    if type(args.filepaths) == "table" then
      for _, fp in ipairs(args.filepaths) do
        table.insert(filepaths, fp)
      end
    end
  end

  if #filepaths == 0 then
    return { error = "需要 filepath（文件路径）或 filepaths（文件路径列表）参数" }
  end

  local file_results = {}
  for _, filepath in ipairs(filepaths) do
    local abs_path = vim.fn.fnamemodify(filepath, ":p")
    -- 使用 ensure_buf_loaded 自动加载文件到缓冲区
    local bufnr, cleanup, load_err = ensure_buf_loaded(filepath)
    local file_entry = {
      filepath = filepath,
      clients = {},
    }

    if load_err then
      file_entry.error = "文件加载失败: " .. load_err
    else
      local clients = vim.lsp.get_clients({ bufnr = bufnr })
      if not clients or #clients == 0 then
        file_entry.error = "该文件没有关联的 LSP 客户端"
      else
        local filtered_count = 0
        for _, client in ipairs(clients) do
          if not is_client_functionally_complete(client) then
            filtered_count = filtered_count + 1
          else
            table.insert(file_entry.clients, {
              name = client.name,
              id = client.id,
              root_dir = client.config and client.config.root_dir,
              capabilities = client.server_capabilities and {
                hover_provider = client.server_capabilities.hoverProvider,
                definition_provider = client.server_capabilities.definitionProvider,
                references_provider = client.server_capabilities.referencesProvider,
                rename_provider = client.server_capabilities.renameProvider,
                document_formatting_provider = client.server_capabilities.documentFormattingProvider,
                code_action_provider = client.server_capabilities.codeActionProvider,
                completion_provider = client.server_capabilities.completionProvider,
                signature_help_provider = client.server_capabilities.signatureHelpProvider,
                document_symbol_provider = client.server_capabilities.documentSymbolProvider,
                workspace_symbol_provider = client.server_capabilities.workspaceSymbolProvider,
                implementation_provider = client.server_capabilities.implementationProvider,
                declaration_provider = client.server_capabilities.declarationProvider,
                inline_completion = client.server_capabilities.inlineCompletionProvider,
                document_color = client.server_capabilities.colorProvider,
                semantic_tokens = client.server_capabilities.semanticTokensProvider,
              },
            })
          end
        end
        file_entry.filtered_count = filtered_count
      end
    end

    table.insert(file_results, file_entry)

    -- 清理临时加载的缓冲区
    if cleanup then
      cleanup()
    end
  end

  return {
    file_count = #file_results,
    files = file_results,
  }
end

M.lsp_client_info = define_tool({
  name = "lsp_client_info",
  description = "获取指定文件或文件列表的 LSP 客户端信息，包括名称、根目录、支持的能力列表。必须提供 filepath（单个文件）或 filepaths（文件列表）参数。",
  func = _lsp_client_info,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径（与 filepaths 二选一）" },
      filepaths = {
        type = "array",
        items = { type = "string" },
        description = "文件路径列表（与 filepath 二选一）",
      },
    },
  },
  returns = {
    type = "object",
    description = "每个文件对应的 LSP 客户端信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_signature_help - 获取签名帮助
-- ============================================================================

local function _lsp_signature_help(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end
  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    lsp_request_async(bufnr, "textDocument/signatureHelp", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result then
        if on_error then
          on_error(req_err or "未找到符号 '" .. args.symbol .. "' 的签名帮助")
        end
        return
      end

      local signatures = {}
      for _, sig in ipairs(result.signatures or {}) do
        local params = {}
        for _, param in ipairs(sig.parameters or {}) do
          table.insert(params, {
            label = param.label,
            documentation = param.documentation,
          })
        end
        table.insert(signatures, {
          label = sig.label,
          documentation = sig.documentation,
          parameters = params,
          active_parameter = sig.activeParameter,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          active_signature = result.activeSignature,
          active_parameter = result.activeParameter,
          signatures = signatures,
        })
      end
    end)
  end, true)
end

M.lsp_signature_help = define_tool({
  name = "lsp_signature_help",
  description = "获取文件中指定符号的 LSP 签名帮助信息（函数参数提示），通过符号名称定位，返回参数列表和文档。注意：符号名必须在函数调用位置（如 `foo(` 或 `obj.method(`），而非定义位置（如 `function foo()`），否则 LSP 无法返回签名信息。",
  func = _lsp_signature_help,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如函数名" },
      node_type = { type = "string", description = "节点类型过滤（可选），如 'call_expression'" },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "签名帮助信息",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_completion - 获取补全建议
-- ============================================================================

local function _lsp_completion(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col
    if args.symbol then
      row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
        end
        return
      end
    else
      row = 0
      col = 0
    end

    lsp_request_async(bufnr, "textDocument/completion", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
      context = {
        triggerKind = args.trigger_kind or 1,
        triggerCharacter = args.trigger_character,
      },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or not result.items or #result.items == 0 then
        if on_error then
          on_error(req_err or "未找到该位置的补全建议")
        end
        return
      end

      local items = {}
      for _, item in ipairs(result.items) do
        table.insert(items, {
          label = item.label,
          kind = item.kind,
          detail = item.detail,
          documentation = item.documentation,
          insert_text = item.insertText,
          insert_text_format = item.insertTextFormat,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          position = { row = row, col = col },
          is_incomplete = result.isIncomplete,
          item_count = #items,
          items = items,
        })
      end
    end)
  end, true)
end

M.lsp_completion = define_tool({
  name = "lsp_completion",
  description = "获取文件中指定符号位置的 LSP 补全建议列表，通过符号名称定位，返回补全项标签、类型、文档和插入文本",
  func = _lsp_completion,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称（可选），用于定位补全触发位置" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
      trigger_kind = {
        type = "number",
        description = "触发类型（可选）：1=手动触发, 2=触发字符, 3=不完整补全",
      },
      trigger_character = { type = "string", description = "触发字符（可选），如 '.'" },
    },
    required = { "filepath" },
  },
  returns = {
    type = "object",
    description = "补全建议列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- ============================================================================
-- 工具 lsp_type_definition - 获取类型定义
-- ============================================================================

local function _lsp_type_definition(args, on_success, on_error)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  if not args or not args.filepath then
    if on_error then
      on_error("需要 filepath（文件路径）参数")
    end
    return
  end
  if not args.symbol then
    if on_error then
      on_error("需要 symbol（符号名称）参数来定位")
    end
    return
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local row, col = find_symbol_position(args.filepath, args.symbol, args.node_type, bufnr)
    if not row then
      if cleanup then
        cleanup()
      end
      if on_error then
        on_error("未找到符号 '" .. args.symbol .. "' 在文件中的位置")
      end
      return
    end

    lsp_request_async(bufnr, "textDocument/typeDefinition", {
      textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      position = { line = row, character = col },
    }, function(result, req_err)
      if cleanup then
        cleanup()
      end

      if req_err or not result or (type(result) == "table" and #result == 0) then
        if on_error then
          on_error(req_err or "未找到符号 '" .. args.symbol .. "' 的类型定义")
        end
        return
      end

      local locations = {}
      for _, loc in ipairs(result) do
        table.insert(locations, {
          uri = loc.uri,
          filename = loc.filename or (loc.uri and vim.uri_to_fname(loc.uri)),
          range = loc.range,
        })
      end

      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          locations = locations,
        })
      end
    end)
  end, true)
end

M.lsp_type_definition = define_tool({
  name = "lsp_type_definition",
  description = "获取文件中指定符号的类型定义位置，通过符号名称和可选的节点类型定位，返回类型定义所在的文件和位置范围。注意：仅适用于有静态类型系统的语言（如 TypeScript、Java、Go），Lua、Python、JavaScript 等动态类型语言通常无法提供类型定义信息。",
  func = _lsp_type_definition,
  async = true,
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "文件路径" },
      symbol = { type = "string", description = "符号名称，如变量名、函数名" },
      node_type = { type = "string", description = "节点类型过滤（可选）" },
    },
    required = { "filepath", "symbol" },
  },
  returns = {
    type = "object",
    description = "类型定义位置信息列表",
  },
  category = "lsp",
  permissions = { read = true },
})

-- 刷新延迟清理队列：执行所有暂存的 cleanup 函数并清空队列
-- 在工具循环结束时自动调用，也可由外部手动调用
function M.flush_deferred_cleanups()
  for i = #_deferred_cleanups, 1, -1 do
    local cleanup = _deferred_cleanups[i]
    if cleanup then
      pcall(cleanup)
    end
  end
  _deferred_cleanups = {}
end

-- ============================================================================
-- 工具 lsp_service_info - 获取 LSP 服务信息
-- ============================================================================

local function _lsp_service_info()
  if not check_lsp() then
    return { error = "LSP 不可用" }
  end

  ensure_lsp_init()

  local mason_servers = get_mason_installed_servers()
  local mason_names = {}
  for _, info in ipairs(mason_servers) do
    table.insert(mason_names, info.mason_name)
  end

  local active = get_active_formal_clients()
  local active_info = {}
  for _, c in ipairs(active) do
    table.insert(active_info, {
      name = c.name,
      id = c.id,
      initialized = c.initialized == true,
      has_capabilities = c.server_capabilities ~= nil,
    })
  end

  local available = get_available_formal_servers()

  return {
    service_type = _lsp_service_type or "unknown",
    mason_installed = mason_names,
    active_formal_clients = active_info,
    available_formal_servers = available,
  }
end

M.lsp_service_info = define_tool({
  name = "lsp_service_info",
  description = "获取当前 Neovim 的 LSP 服务信息，包括检测到的服务类型、Mason 已安装的服务器列表、当前活跃的正式 LSP 客户端列表",
  func = _lsp_service_info,
  parameters = {
    type = "object",
    properties = {},
  },
  returns = {
    type = "object",
    description = "LSP 服务信息",
  },
  category = "lsp",
  permissions = { read = true },
})

-- 导出初始化信息供外部使用
function M.get_lsp_init_info()
  ensure_lsp_init()
  return {
    service_type = _lsp_service_type,
    mason_installed_servers = get_mason_installed_servers(),
    available_formal_servers = get_available_formal_servers(),
  }
end

-- 导出 is_formal_lsp_client 供其他模块使用
function M.is_formal_lsp_client(client)
  return is_formal_lsp_client(client)
end

-- 模块加载时自动触发 Tree-sitter 解析器安装
ensure_ts_parsers()

-- get_tools() - 返回所有工具列表供注册
function M.get_tools()
  if not check_lsp() then
    return {}
  end

  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

return M
