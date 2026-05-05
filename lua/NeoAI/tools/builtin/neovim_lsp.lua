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
-- 返回完整的命令数组（包含参数），或 nil
local function find_mason_server_cmd(config_name)
  local servers = get_mason_installed_servers()
  for _, info in ipairs(servers) do
    if info.lsp_name == config_name or info.mason_name == config_name then
      local install_path = info.install_path
      if install_path then
        -- 先检查 bin 目录下的常见可执行文件
        local bin_dir = install_path .. "/bin/"
        local mason_name = info.mason_name
        -- Mason 包名到实际可执行文件名的映射
        local executable_map = {
          pyright = { "pyright-langserver", "--stdio" },
          ["typescript-language-server"] = { "typescript-language-server", "--stdio" },
          ["html-lsp"] = { "vscode-html-language-server", "--stdio" },
          ["css-lsp"] = { "vscode-css-language-server", "--stdio" },
          ["json-lsp"] = { "vscode-json-language-server", "--stdio" },
          ["yaml-language-server"] = { "yaml-language-server", "--stdio" },
          ["bash-language-server"] = { "bash-language-server", "start" },
          ["lua-language-server"] = { "lua-language-server" },
          ["rust-analyzer"] = { "rust-analyzer" },
        }
        -- 优先使用映射表
        local mapped = executable_map[mason_name] or executable_map[config_name]
        if mapped then
          local full_cmd = {}
          for _, part in ipairs(mapped) do
            if part == full_cmd[1] or #full_cmd == 0 then
              table.insert(full_cmd, bin_dir .. part)
            else
              table.insert(full_cmd, part)
            end
          end
          if vim.fn.executable(full_cmd[1]) == 1 then
            return full_cmd
          end
          -- 也检查不带 bin/ 前缀的路径
          local alt_cmd = {}
          for _, part in ipairs(mapped) do
            if #alt_cmd == 0 then
              table.insert(alt_cmd, install_path .. "/" .. part)
            else
              table.insert(alt_cmd, part)
            end
          end
          if vim.fn.executable(alt_cmd[1]) == 1 then
            return alt_cmd
          end
        end

        -- 通用回退：尝试 bin 目录下各种可能的可执行文件名
        local candidate_names = {
          config_name,
          mason_name,
          config_name:gsub("_", "-"),
          mason_name:gsub("_", "-"),
          config_name .. "-language-server",
          mason_name .. "-language-server",
          config_name:gsub("_", "-") .. "-language-server",
          "vscode-" .. config_name:gsub("_", "-") .. "-language-server",
        }
        for _, name in ipairs(candidate_names) do
          local candidate = bin_dir .. name
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

-- lsp_request_async 的前向声明（实际定义在文件后面）
-- 使用模块级变量避免闭包捕获问题
local _lsp_request_async

-- 使用 LSP documentSymbol 回退查找符号位置（异步回调模式）
-- 当 Tree-sitter 不可用时，通过 LSP 的 documentSymbol 请求定位符号
-- 回调模式：callback(row, col, err)
local function find_symbol_via_lsp_async(filepath, symbol_name, bufnr, callback)
  -- 获取绝对路径
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  -- 如果没有提供 bufnr，通过文件路径获取
  if not bufnr or bufnr == -1 then
    bufnr = vim.fn.bufnr(abs_path)
  end
  if bufnr == -1 then
    if callback then
      callback(nil, nil, "文件未加载到缓冲区")
    end
    return
  end

  local attempt_count = 0
  local max_attempts = 3

  local function do_request()
    attempt_count = attempt_count + 1

    _lsp_request_async(bufnr, "textDocument/documentSymbol", {
      textDocument = { uri = vim.uri_from_fname(abs_path) },
    }, function(result, req_err)
      if req_err then
        if attempt_count < max_attempts then
          -- 重试前等待 1 秒
          vim.defer_fn(do_request, 1000)
          return
        end
        if callback then
          callback(nil, nil, req_err)
        end
        return
      end

      if result and type(result) == "table" and #result > 0 then
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
          if callback then
            callback(r, c, nil)
          end
          return
        end
      end

      -- 有结果但未找到符号，或结果为空
      if attempt_count < max_attempts then
        -- 空结果可能是 LSP 尚未完成索引，重试
        vim.defer_fn(do_request, 1000)
        return
      end

      if callback then
        callback(nil, nil, nil)
      end
    end)
  end

  do_request()
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
      local timer_closed = false

      local function safe_close_timer()
        if timer_closed then
          return
        end
        timer_closed = true
        if poll_timer then
          pcall(poll_timer.stop, poll_timer)
          pcall(poll_timer.close, poll_timer)
        end
      end

      if poll_timer then
        poll_timer:start(50, 50, function()
          elapsed = elapsed + 50
          vim.schedule(function()
            if timer_closed then
              return
            end

            if elapsed >= timeout_ms then
              safe_close_timer()
              -- 超时，返回已匹配的客户端（即使未初始化完成）
              if callback then
                callback(matched, nil, bufnr)
              end
              return
            end
            for _, client in ipairs(matched) do
              if client.initialized and client.server_capabilities then
                safe_close_timer()
                local qualified = filter_qualified_clients(matched)
                if callback then
                  callback(qualified or matched, nil, bufnr)
                end
                return
              end
            end
          end)
        end)
      end -- if poll_timer
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
      -- 只接受正式 LSP 客户端，且客户端名称与期望配置匹配（如果提供了 expected_config）
      if client and is_formal_lsp_client(client) and client_matches(client) then
        attached = true
      end
    end,
  })

  -- 轮询检查客户端是否已 attach 并初始化
  local poll_timer = vim.uv.new_timer()
  local elapsed = 0
  local timer_closed = false

  local function safe_close_timer()
    if timer_closed then
      return
    end
    timer_closed = true
    if poll_timer then
      pcall(poll_timer.stop, poll_timer)
      pcall(poll_timer.close, poll_timer)
    end
  end

  if poll_timer then
    poll_timer:start(100, 100, function()
      elapsed = elapsed + 100
      vim.schedule(function()
        if timer_closed then
          return
        end

        if elapsed >= timeout_ms then
          safe_close_timer()
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

        -- 即使 LspAttach 事件已错过（attached 为 false），
        -- 也应直接检查已 attach 的客户端，避免依赖事件驱动
        local attached_clients = vim.lsp.get_clients({ bufnr = bufnr })
        for _, c in ipairs(attached_clients) do
          if is_formal_lsp_client(c) and c.server_capabilities and client_has_required_capabilities(c) then
            safe_close_timer()
            cleanup()
            if callback then
              callback({ c }, nil, bufnr)
            end
            return
          end
        end

        -- 如果 LspAttach 事件尚未触发，继续等待
        if not attached then
          return
        end
      end)
    end)
  end -- if poll_timer
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
  -- 注意：vim.lsp.start(config_name) 在 Neovim 0.12 中可能返回 true, nil
  -- （启动成功但 client_id 为 nil），此时需要验证客户端是否真的启动了
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
    if ok_id then
      if client_id then
        pcall(vim.lsp.buf_attach_client, bufnr, client_id)
        return true
      end
      -- vim.lsp.start 返回 true 但 client_id 为 nil
      -- 需要验证客户端是否真的启动了：检查是否有新客户端出现
      -- 等待一小段时间让客户端完成初始化
      local before_count = #vim.lsp.get_clients()
      vim.wait(2000, function()
        return #vim.lsp.get_clients() > before_count
      end, 100)
      local after_clients = vim.lsp.get_clients()
      if #after_clients > before_count then
        -- 有新客户端出现，尝试 attach
        for _, c in ipairs(after_clients) do
          if c.name == config_name or not pcall(function() return before_count >= #vim.lsp.get_clients() end) then
            pcall(vim.lsp.buf_attach_client, bufnr, c.id)
          end
        end
        return true
      end
      -- 没有新客户端出现，启动失败
      return false
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
      callback(nil, attach_err or ("文件 '" .. filepath .. "' 没有关联的 LSP 客户端"), nil, nil)
    end
  end, 5000, expected_config)
end

-- 获取文件对应的 LSP 客户端
-- 只返回同时支持格式化（formatting）和悬停（hover）的客户端
-- 如果文件没有关联的客户端，尝试通过多种方式启动
-- 返回 clients, err, bufnr, cleanup
-- 使用 Tree-sitter 在文件中查找符号位置（异步回调模式）
-- 如果 Tree-sitter 不可用，回退到 LSP documentSymbol
-- 回调模式：callback(row, col, err)
-- 如果提供了 bufnr，则优先使用它进行 LSP documentSymbol 回退查找
--
-- 搜索策略（按优先级）：
--   1. 精确匹配 identifier 节点（最精确）
--   2. 精确匹配任意节点（次精确）
--   3. 子串匹配 identifier 节点（避免误匹配如 "__main__" 匹配 "main"）
--   4. 带点符号名匹配（如 "M.setup"）
--   5. LSP documentSymbol 回退
local function find_symbol_position_async(filepath, symbol_name, node_type, bufnr, callback)
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
          find_symbol_via_lsp_async(filepath, symbol_name, bufnr, callback)
          return
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
              -- 跳过根节点（如 chunk、program、module），因为根节点包含整个文件内容
              local root_types = { chunk = true, program = true, module = true }

              -- 检查符号名是否包含 '.'（如 "M.setup"、"table.insert"）
              local symbol_parts = {}
              local is_dotted = false
              if symbol_name:find(".", 1, true) then
                is_dotted = true
                for part in symbol_name:gmatch("[^.]+") do
                  table.insert(symbol_parts, part)
                end
              end

              -- 存储最佳匹配结果（优先选择 identifier 节点）
              local best_match = nil

              local function search_node(node, depth, max_depth)
                if not node or (max_depth and depth > max_depth) then
                  return
                end

                -- 跳过根节点类型
                if root_types[node:type()] then
                  for i = 0, node:named_child_count() - 1 do
                    search_node(node:named_child(i), depth + 1, max_depth)
                  end
                  return
                end

                -- 跳过注释和字符串节点
                if skip_types[node:type()] then
                  return
                end

                local text = vim.treesitter.get_node_text(node, content)
                local node_type_match = true
                if node_type and node:type() ~= node_type then
                  node_type_match = false
                end

                if node_type_match and text then
                  local node_is_identifier = node:type() == "identifier"

                  -- 策略一：精确匹配 identifier 节点（最精确）
                  if node_is_identifier and text == symbol_name then
                    local sr, sc = node:range()
                    best_match = { row = sr, col = sc, priority = 1 }
                    return
                  end

                  -- 策略二：精确匹配任意节点
                  if text == symbol_name then
                    -- 查找子节点中精确匹配的 identifier
                    for i = 0, node:named_child_count() - 1 do
                      local child = node:named_child(i)
                      local child_text = vim.treesitter.get_node_text(child, content)
                      if child:type() == "identifier" and child_text == symbol_name then
                        local sr, sc = child:range()
                        best_match = { row = sr, col = sc, priority = 1 }
                        return
                      end
                    end
                    -- 没有 identifier 子节点，使用当前节点
                    if not best_match or best_match.priority > 2 then
                      local sr, sc = node:range()
                      best_match = { row = sr, col = sc, priority = 2 }
                    end
                    return
                  end

                  -- 策略三：子串匹配 identifier 节点（避免误匹配如 "__main__" 匹配 "main"）
                  if node_is_identifier and text:find(symbol_name, 1, true) then
                    if not best_match or best_match.priority > 3 then
                      local sr, sc = node:range()
                      best_match = { row = sr, col = sc, priority = 3 }
                    end
                    return
                  end

                  -- 策略四：子串匹配任意节点（仅在没有 identifier 匹配时使用）
                  if text:find(symbol_name, 1, true) then
                    -- 优先查找子节点中精确匹配的 identifier
                    for i = 0, node:named_child_count() - 1 do
                      local child = node:named_child(i)
                      local child_text = vim.treesitter.get_node_text(child, content)
                      if child:type() == "identifier" and child_text == symbol_name then
                        local sr, sc = child:range()
                        if not best_match or best_match.priority > 3 then
                          best_match = { row = sr, col = sc, priority = 3 }
                        end
                        return
                      end
                    end
                    -- 没有 identifier 子节点，使用当前节点（低优先级）
                    if not best_match or best_match.priority > 4 then
                      local sr, sc = node:range()
                      best_match = { row = sr, col = sc, priority = 4 }
                    end
                    return
                  end

                  -- 策略五：带点符号名匹配（如 "M.setup" 匹配 field 节点 "M.setup"）
                  if is_dotted and text == symbol_parts[#symbol_parts] then
                    local parent = node:parent()
                    if parent then
                      local parent_text = vim.treesitter.get_node_text(parent, content)
                      if parent_text == symbol_name then
                        local sr, sc = node:range()
                        if not best_match or best_match.priority > 3 then
                          best_match = { row = sr, col = sc, priority = 3 }
                        end
                        return
                      end
                    end
                  end
                end

                -- 递归搜索子节点
                for i = 0, node:named_child_count() - 1 do
                  search_node(node:named_child(i), depth + 1, max_depth)
                  if best_match and best_match.priority == 1 then
                    -- 已找到最高优先级匹配，提前终止
                    return
                  end
                end
              end

              search_node(root, 0, 50)

              if best_match then
                if callback then
                  callback(best_match.row, best_match.col, nil)
                end
                return
              end
            end
          end
        end
      end
    end
  end

  -- Tree-sitter 不可用或未找到符号，回退到 LSP documentSymbol
  find_symbol_via_lsp_async(filepath, symbol_name, bufnr, callback)
end

-- 执行 LSP 请求并等待结果
-- 使用 Neovim 0.12 的 buf_request_sync，单次请求，超时 5 秒
-- 如果第一次请求没有结果，重试一次
-- LSP 请求的异步非阻塞版本
-- 使用 vim.lsp.buf_request（非阻塞）替代 buf_request_sync
-- 回调模式：callback(result, error_msg)
-- 不会阻塞主线程，适合在 vim.schedule 回调中调用
-- 注意：LSP 协议中，某些请求（如 hover）在没有信息时返回 nil 是正常行为
-- 超时（回调未被调用）才表示客户端未就绪，此时会返回错误信息
--
-- 多客户端处理：当有多个 LSP 客户端时，等待所有客户端响应，
-- 优先返回非空结果（有内容的），如果都为空则返回第一个结果
--
-- 并发安全：每个请求使用独立的 request_id 标识，避免多个同时请求的回调混淆
-- 使用 vim.lsp.buf_request 返回的 request_id 来区分不同请求的回调
--
-- LSP 方法名到对应能力字段的映射
-- 用于在发送请求前检查客户端是否支持该方法，避免不必要的超时等待
local method_to_capability = {
  ["textDocument/declaration"] = "declarationProvider",
  ["textDocument/definition"] = "definitionProvider",
  ["textDocument/typeDefinition"] = "typeDefinitionProvider",
  ["textDocument/implementation"] = "implementationProvider",
  ["textDocument/references"] = "referencesProvider",
  ["textDocument/hover"] = "hoverProvider",
  ["textDocument/documentSymbol"] = "documentSymbolProvider",
  ["textDocument/formatting"] = "documentFormattingProvider",
  ["textDocument/codeAction"] = "codeActionProvider",
  ["textDocument/rename"] = "renameProvider",
  ["textDocument/signatureHelp"] = "signatureHelpProvider",
  ["textDocument/completion"] = "completionProvider",
  ["workspace/symbol"] = "workspaceSymbolProvider",
}

local _request_counter = 0
local _pending_requests = {} -- 存储挂起的请求：request_id -> { done, timer, responses, callback, defer_timer }

local function lsp_request_async(bufnr, method, params, callback)
  if not bufnr or not method then
    if callback then
      callback(nil, "无效的 LSP 请求参数")
    end
    return
  end

  -- 检查客户端是否支持该 LSP 方法
  -- 如果不支持，立即返回错误，避免等待 15 秒超时
  -- 如果客户端的 server_capabilities 为 nil（尚未初始化），
  -- 则异步等待其初始化完成后再检查
  local cap_field = method_to_capability[method]
  if cap_field then
    local clients = vim.lsp.get_clients({ bufnr = bufnr })

    -- 检查是否有客户端尚未初始化（server_capabilities 为 nil）
    local has_uninitialized = false
    for _, client in ipairs(clients) do
      if not client.server_capabilities then
        has_uninitialized = true
        break
      end
    end

    -- 如果有未初始化的客户端，异步等待其初始化完成
    -- 初始化完成后重新调用自身（递归），继续执行后续逻辑
    if has_uninitialized then
      local wait_timer = vim.uv.new_timer()
      local elapsed = 0
      local timer_closed = false

      local function safe_close_timer()
        if timer_closed then
          return
        end
        timer_closed = true
        if wait_timer then
          pcall(wait_timer.stop, wait_timer)
          pcall(wait_timer.close, wait_timer)
        end
      end

      if wait_timer then
        wait_timer:start(100, 100, function()
          elapsed = elapsed + 100
          vim.schedule(function()
            if timer_closed then
              return
            end

            -- 检查所有客户端是否都已初始化
            local all_initialized = true
            for _, client in ipairs(clients) do
              if not client.server_capabilities then
                all_initialized = false
                break
              end
            end

            if all_initialized or elapsed >= 5000 then
              safe_close_timer()
              -- 初始化完成（或超时），重新调用自身继续执行
              -- 此时能力检查会基于已初始化的 capabilities 进行
              lsp_request_async(bufnr, method, params, callback)
            end
          end)
        end)
      end
      return
    end

    local any_supported = false
    for _, client in ipairs(clients) do
      local caps = client.server_capabilities
      if caps then
        local cap_value = caps[cap_field]
        if cap_value == true or type(cap_value) == "table" then
          any_supported = true
          break
        end
      end
    end
    if not any_supported then
      if callback then
        if #clients == 0 then
          callback(nil, string.format('没有 LSP 客户端连接到缓冲区，无法发送请求 "%s"', method))
        elseif method == "textDocument/formatting" then
          local client_names = {}
          for _, c in ipairs(clients) do
            table.insert(client_names, c.name)
          end
          callback(nil, string.format(
            "LSP 方法 'textDocument/formatting' 不被任何已连接的服务器支持。\\n" ..
            "已连接客户端: %s\\n" ..
            "提示: 当前 LSP 服务器不提供格式化功能。Pyright 是类型检查器，" ..
            "不支持格式化。请安装 ruff、black 或 autopep8 等格式化工具。",
            table.concat(client_names, ", ")
          ))
        else
          callback(nil, string.format('LSP 方法 "%s" 不被任何已连接的服务器支持', method))
        end
      end
      return
    end
  end

  -- 生成唯一请求 ID
  _request_counter = _request_counter + 1
  local req_id = _request_counter

  -- 请求状态
  local state = {
    done = false,
    timer = vim.uv.new_timer(),
    responses = {},
    callback = callback,
    defer_timer = nil,
  }
  _pending_requests[req_id] = state

  -- 安全清理函数
  local function safe_cleanup()
    if state.done then
      return
    end
    state.done = true
    if state.timer and not state.timer:is_closing() then
      state.timer:stop()
      state.timer:close()
    end
    if state.defer_timer then
      state.defer_timer:stop()
      state.defer_timer:close()
      state.defer_timer = nil
    end
    _pending_requests[req_id] = nil
  end

  -- 使用 buf_request 非阻塞发送请求
  -- 注意：vim.lsp.buf_request 返回的 request_id 可以用于取消请求
  local ok, result_or_err = pcall(vim.lsp.buf_request, bufnr, method, params, function(err, result, ctx)
    -- 使用 vim.schedule 确保回调在主事件循环中执行
    vim.schedule(function()
      if state.done then
        return
      end

      -- 收集响应
      table.insert(state.responses, { err = err, result = result, ctx = ctx })

      -- 如果有非空结果，立即返回
      if not err and result ~= nil then
        if type(result) ~= "table" or #result > 0 then
          local cb = state.callback
          safe_cleanup()
          if cb then
            cb(result, nil)
          end
          return
        end
      end

      -- 等待所有客户端响应后再决定
      -- 第一个响应到达后，启动短等待让其他客户端有机会响应
      if #state.responses == 1 then
        if state.defer_timer then
          state.defer_timer:stop()
          state.defer_timer:close()
        end
        state.defer_timer = vim.uv.new_timer()
        state.defer_timer:start(500, 0, function()
          vim.schedule(function()
            if state.done then
              return
            end
            local cb = state.callback
            safe_cleanup()
            -- 在所有响应中找非空结果
            for _, r in ipairs(state.responses) do
              if not r.err and r.result ~= nil then
                if cb then
                  cb(r.result, nil)
                end
                return
              end
            end
            -- 都为空，返回第一个结果
            if #state.responses > 0 then
              if cb then
                cb(state.responses[1].result, state.responses[1].err)
              end
            else
              if cb then
                cb(nil, "所有 LSP 客户端返回空")
              end
            end
          end)
        end)
      end
    end)
  end)

  if not ok then
    local cb = state.callback
    safe_cleanup()
    if cb then
      cb(nil, "发送 LSP 请求失败: " .. tostring(result_or_err))
    end
    return
  end

  -- 设置超时保护（15秒，给多客户端更多时间）
  state.timer:start(15000, 0, function()
    vim.schedule(function()
      if state.done then
        return
      end
      local cb = state.callback
      safe_cleanup()
      -- 超时时，在所有已收到的响应中找非空结果
      for _, r in ipairs(state.responses) do
        if not r.err and r.result ~= nil then
          if cb then
            cb(r.result, nil)
          end
          return
        end
      end
      if #state.responses > 0 then
        if cb then
          cb(state.responses[1].result, state.responses[1].err)
        end
      else
        if cb then
          cb(nil, "LSP 请求超时（15秒）: " .. method)
        end
      end
    end)
  end)
end

-- 赋值给前向声明变量，供 find_symbol_via_lsp_async 等函数使用
_lsp_request_async = lsp_request_async

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

    find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              position = { row = row, col = col },
              contents = nil,
              found = false,
            })
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
            found = true,
          })
        end
      end)
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
  approval = { behavior = "auto_approve" },
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

    find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result or (type(result) == "table" and #result == 0) then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              position = { row = row, col = col },
              locations = {},
              found = false,
            })
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
  approval = { behavior = "auto_approve" },
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

    find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result or (type(result) == "table" and #result == 0) then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              position = { row = row, col = col },
              reference_count = 0,
              references = {},
              found = false,
            })
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
  approval = { behavior = "auto_approve" },
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

    find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result or (type(result) == "table" and #result == 0) then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              position = { row = row, col = col },
              locations = {},
              found = false,
            })
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
  approval = { behavior = "auto_approve" },
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

    find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result or (type(result) == "table" and #result == 0) then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              position = { row = row, col = col },
              locations = {},
              found = false,
            })
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
  approval = { behavior = "auto_approve" },
})
-- ============================================================================
-- 工具 lsp_document_symbols - 获取文档符号列表
-- ============================================================================

local function _lsp_document_symbols(args, on_success, on_error, on_progress)
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

  if on_progress then
    on_progress("加载文件到缓冲区", "executing", 0)
  end

  get_lsp_clients_async(args.filepath, function(clients, err, bufnr, cleanup)
    if err then
      if on_progress then
        on_progress("加载文件到缓冲区", "error", 0, err)
      end
      if on_error then
        on_error(err)
      end
      return
    end

    if on_progress then
      on_progress("加载文件到缓冲区", "completed", 0)
      on_progress("获取LSP文档符号", "executing", 0)
    end
    if err then
      if on_error then
        on_error(err)
      end
      return
    end

    local retry_count = 0
    local max_retries = 1
    local request_active = false

    -- 使用 Tree-sitter 直接解析文件结构作为 LSP documentSymbol 的替代
    -- 当 LSP 返回空结果时，用 Tree-sitter 获取符号列表
    -- 不依赖 neovim_tree 模块，直接使用 vim.treesitter API
    local function get_symbols_via_treesitter(filepath, callback)
      local ok_ts, ts = pcall(require, "vim.treesitter")
      if not ok_ts then
        if callback then
          callback(nil)
        end
        return
      end

      -- 读取文件内容
      local abs_path = vim.fn.fnamemodify(filepath, ":p")
      local fd, open_err = vim.uv.fs_open(abs_path, "r", 438)
      if not fd then
        if callback then
          callback(nil)
        end
        return
      end
      local stat, _ = vim.uv.fs_fstat(fd)
      if not stat then
        vim.uv.fs_close(fd)
        if callback then
          callback(nil)
        end
        return
      end
      local content, _ = vim.uv.fs_read(fd, stat.size, 0)
      vim.uv.fs_close(fd)
      if not content then
        if callback then
          callback(nil)
        end
        return
      end

      -- 推断语言
      local ext = vim.fn.fnamemodify(abs_path, ":e"):lower()
      local ext_to_lang = {
        py = "python",
        lua = "lua",
        js = "javascript",
        ts = "typescript",
        jsx = "tsx",
        tsx = "tsx",
        go = "go",
        rs = "rust",
        java = "java",
        c = "c",
        cpp = "cpp",
        rb = "ruby",
        php = "php",
        json = "json",
        yaml = "yaml",
        yml = "yaml",
        md = "markdown",
        sh = "bash",
        bash = "bash",
        css = "css",
        html = "html",
        vue = "vue",
        svelte = "svelte",
        toml = "toml",
        sql = "sql",
      }
      local lang = ext_to_lang[ext]
      if not lang then
        if callback then
          callback(nil)
        end
        return
      end

      -- 检查解析器是否可用
      local ok_inspect, _ = pcall(ts.language.inspect, lang)
      if not ok_inspect then
        if callback then
          callback(nil)
        end
        return
      end

      -- 解析
      local ok_parser, parser = pcall(ts.get_string_parser, content, lang)
      if not ok_parser or not parser then
        if callback then
          callback(nil)
        end
        return
      end
      local ok_trees, trees = pcall(parser.parse, parser)
      if not ok_trees or not trees or #trees == 0 then
        if callback then
          callback(nil)
        end
        return
      end

      local root = trees[1]:root()

      -- 递归遍历节点，提取结构信息
      local symbols = {}
      local seen = {}

      -- Python 的节点类型
      local structure_types = {
        class_definition = 5, -- Class
        function_definition = 12, -- Function
      }

      -- 需要跳过的节点类型（注释、字符串等，不包含有效符号）
      local skip_types = {
        comment = true,
        string = true,
        string_literal = true,
        line_comment = true,
        block_comment = true,
      }

      local function traverse(node, depth)
        if not node or depth > 6 then
          return
        end

        local node_type = node:type()

        -- 跳过注释和字符串节点（及其子节点）
        if skip_types[node_type] then
          return
        end

        local kind = structure_types[node_type]

        if kind then
          local text = vim.treesitter.get_node_text(node, content)
          local name = text:match("^[^\n]+") or text

          -- 提取名称
          if node_type == "function_definition" then
            local fn = text:match("def%s+([%w_]+)")
            if fn then
              name = fn
            end
          elseif node_type == "class_definition" then
            local cls = text:match("class%s+([%w_]+)")
            if cls then
              name = cls
            end
          end

          -- 只保留能提取到有效名称的符号
          if name and name ~= "" then
            local sr, sc, er, ec = node:range()
            local key = node_type .. ":" .. name .. ":" .. sr
            if not seen[key] then
              seen[key] = true
              table.insert(symbols, {
                name = name,
                kind = kind,
                kind_name = safe_symbol_kind_name(kind),
                range = {
                  start = { line = sr, character = sc },
                  ["end"] = { line = er, character = ec },
                },
                depth = depth,
              })
            end
          end
        end

        for i = 0, node:named_child_count() - 1 do
          traverse(node:named_child(i), depth + 1)
        end
      end

      traverse(root, 0)

      if callback then
        callback(symbols)
      end
    end

    local function do_document_symbol_request()
      if request_active then
        return
      end
      request_active = true
      retry_count = retry_count + 1

      if on_progress then
        on_progress("获取LSP文档符号", "executing", 0)
      end

      lsp_request_async(bufnr, "textDocument/documentSymbol", {
        textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
      }, function(result, req_err)
        if req_err then
          if on_progress then
            on_progress("获取LSP文档符号", "error", 0, req_err)
          end
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(req_err)
          end
          return
        end

        -- LSP 返回空结果时，使用 Tree-sitter 作为 fallback
        if (not result or (type(result) == "table" and #result == 0)) and retry_count < max_retries then
          if on_progress then
            on_progress("获取LSP文档符号", "executing", 0, "LSP 返回空，尝试 Tree-sitter")
          end
          -- 异步尝试 Tree-sitter
          get_symbols_via_treesitter(args.filepath, function(ts_symbols)
            if ts_symbols and #ts_symbols > 0 then
              if on_progress then
                on_progress("获取LSP文档符号", "completed", 0, "使用 Tree-sitter")
              end
              if cleanup then
                cleanup()
              end
              if on_success then
                on_success({
                  filepath = args.filepath,
                  symbol_count = #ts_symbols,
                  symbols = ts_symbols,
                  _source = "treesitter",
                  _note = "LSP 未返回符号，使用 Tree-sitter 语法分析结果。",
                })
              end
              return
            end

            -- Tree-sitter 也失败，重试 LSP
            request_active = false
            vim.defer_fn(do_document_symbol_request, 2000)
          end)
          return
        end

        if cleanup then
          cleanup()
        end

        if not result or (type(result) == "table" and #result == 0) then
          -- 最终 fallback：尝试 Tree-sitter
          if on_progress then
            on_progress("获取LSP文档符号", "executing", 0, "LSP 无结果，尝试 Tree-sitter")
          end
          get_symbols_via_treesitter(args.filepath, function(ts_symbols)
            if ts_symbols and #ts_symbols > 0 then
              if on_progress then
                on_progress("获取LSP文档符号", "completed", 0, "使用 Tree-sitter")
              end
              if on_success then
                on_success({
                  filepath = args.filepath,
                  symbol_count = #ts_symbols,
                  symbols = ts_symbols,
                  _source = "treesitter",
                  _note = "LSP 未返回符号，使用 Tree-sitter 语法分析结果。",
                })
              end
            else
              if on_progress then
                on_progress("获取LSP文档符号", "completed", 0, "未找到符号")
              end
              if on_success then
                on_success({
                  filepath = args.filepath,
                  symbol_count = 0,
                  symbols = {},
                  _note = "LSP 和 Tree-sitter 均未找到符号。",
                })
              end
            end
          end)
          return
        end

        if on_progress then
          on_progress("获取LSP文档符号", "completed", 0)
        end

        -- 处理符号结果
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
    end

    -- 启动首次请求
    do_document_symbol_request()
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
  approval = { behavior = "auto_approve" },
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
  approval = { behavior = "auto_approve" },
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

    -- 辅助函数：发送 codeAction 请求
    local function send_code_action_request(row, col)
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result or (type(result) == "table" and #result == 0) then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              action_count = 0,
              actions = {},
            })
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
    end

    -- 通过符号名称定位
    if args.symbol then
      find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end

        send_code_action_request(row, col)
      end)
    else
      send_code_action_request(0, 0)
    end
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
  approval = { behavior = "auto_approve" },
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

    find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
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

        if not result then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              new_name = args.new_name,
              changes = nil,
              found = false,
            })
          end
          return
        end

        if on_success then
          on_success({
            filepath = args.filepath,
            symbol = args.symbol,
            new_name = args.new_name,
            changes = result.changes,
            found = true,
          })
        end
      end)
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

-- 外部格式化工具配置（文件类型 -> { 命令, 参数 } 列表）
-- 当 LSP 不支持格式化时，尝试使用这些外部工具
local external_formatters = {
  python = {
    { cmd = "ruff", args = { "format", "--quiet" }, name = "ruff" },
    { cmd = "black", args = { "--quiet" }, name = "black" },
    { cmd = "autopep8", args = { "--in-place" }, name = "autopep8" },
    { cmd = "yapf", args = { "--in-place" }, name = "yapf" },
  },
  lua = {
    { cmd = "stylua", args = {}, name = "stylua" },
  },
  javascript = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  typescript = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  javascriptreact = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  typescriptreact = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  json = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  yaml = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  markdown = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  css = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  html = {
    { cmd = "prettier", args = { "--write" }, name = "prettier" },
  },
  go = {
    { cmd = "gofmt", args = { "-w" }, name = "gofmt" },
  },
  rust = {
    { cmd = "rustfmt", args = {}, name = "rustfmt" },
  },
  sh = {
    { cmd = "shfmt", args = { "-w" }, name = "shfmt" },
  },
  bash = {
    { cmd = "shfmt", args = { "-w" }, name = "shfmt" },
  },
}

-- 尝试使用外部格式化工具格式化文件
-- 返回 true 表示成功，false 表示无可用工具
local function try_external_formatter(filepath, ft)
  local formatters = external_formatters[ft]
  if not formatters then
    return false, nil
  end

  local abs_path = vim.fn.fnamemodify(filepath, ":p")

  for _, formatter in ipairs(formatters) do
    if vim.fn.executable(formatter.cmd) == 1 then
      local cmd_args = vim.deepcopy(formatter.args)
      table.insert(cmd_args, abs_path)

      -- 使用 systemlist 获取退出码：返回 { exit_code, output }
      -- vim.fn.system 在 Neovim 中返回 (output, exit_code)
      local ok, result_or_err = pcall(vim.fn.system, cmd_args)
      if ok then
        -- 检查 vim.v.shell_error 来判断命令是否成功
        if vim.v.shell_error == 0 then
          return true, formatter.name
        end
      end
    end
  end

  return false, nil
end

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
    -- 注意：get_lsp_clients_async 返回的客户端只保证支持 hover，不一定支持 formatting
    -- 所以需要在这里单独检查
    local has_format_client = false
    local format_client = nil
    for _, client in ipairs(clients) do
      local caps = client.server_capabilities
      if caps then
        local has_format = caps.documentFormattingProvider == true or (type(caps.documentFormattingProvider) == "table")
        if has_format then
          has_format_client = true
          format_client = client
          break
        end
      end
    end
    if not has_format_client then
      -- 如果当前客户端不支持格式化，尝试查找其他已 attach 但未被 get_lsp_clients_async 返回的客户端
      -- （因为 get_lsp_clients_async 只返回支持 hover 的客户端）
      local all_clients = vim.lsp.get_clients({ bufnr = bufnr })
      for _, client in ipairs(all_clients) do
        local caps = client.server_capabilities
        if caps then
          local has_format = caps.documentFormattingProvider == true
            or (type(caps.documentFormattingProvider) == "table")
          if has_format then
            has_format_client = true
            format_client = client
            break
          end
        end
      end
    end
    if not has_format_client then
      -- LSP 不支持格式化，尝试回退到外部格式化工具
      local abs_path = vim.fn.fnamemodify(args.filepath, ":p")
      local ft = vim.filetype.match({ filename = abs_path })

      local ok, tool_name = try_external_formatter(args.filepath, ft)
      if ok then
        if cleanup then
          cleanup()
        end
        local content, _ = read_file_content(args.filepath)
        if on_success then
          on_success({
            filepath = args.filepath,
            formatted = true,
            content = content,
            _source = "external:" .. tool_name,
            _note = string.format("使用外部工具 '%s' 格式化成功（LSP 不支持格式化）", tool_name),
          })
        end
        return
      end

      -- 外部工具也不可用，提供详细的错误信息
      if cleanup then
        cleanup()
      end
      if on_error then
        local attached_names = {}
        for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
          table.insert(attached_names, c.name)
        end
        local client_list = #attached_names > 0 and table.concat(attached_names, ", ") or "无"

        -- 列出可用的外部格式化工具
        local available_tools = {}
        local formatters = external_formatters[ft]
        if formatters then
          for _, f in ipairs(formatters) do
            local installed = vim.fn.executable(f.cmd) == 1
            table.insert(available_tools, string.format("  %s %s [%s]",
              installed and "✓" or "✗", f.name, installed and "已安装" or "未安装"))
          end
        end
        local tool_list = #available_tools > 0 and table.concat(available_tools, "\\n") or "  （该文件类型无可配置的外部格式化工具）"

        local msg = string.format(
          "LSP 客户端不支持文档格式化（documentFormattingProvider）。\\n" ..
          "文件类型: %s\\n" ..
          "已连接的 LSP 客户端: %s\\n\\n" ..
          "外部格式化工具状态：\\n%s\\n\\n" ..
          "建议：\\n" ..
          "  1. 安装上述标记为 ✗ 的工具（如 pip install ruff）\\n" ..
          "  2. 或使用支持格式化的 LSP 服务器（如 ruff 替代 pyright）",
          ft or "未知",
          client_list,
          tool_list
        )
        on_error(msg)
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

      if req_err then
        if on_error then
          on_error(req_err)
        end
        return
      end

      if not result or (type(result) == "table" and #result == 0) then
        if on_success then
          on_success({
            filepath = args.filepath,
            formatted = false,
            content = nil,
          })
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
  approval = { behavior = "auto_approve" },
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

local function _lsp_client_info(args, on_success, on_error, on_progress)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
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
    if on_error then
      on_error("需要 filepath（文件路径）或 filepaths（文件路径列表）参数")
    end
    return
  end

  local file_results = {}
  local current_index = 0
  local total_files = #filepaths
  local stopped = false

  -- 检查是否已请求停止
  local function is_stopped()
    if stopped then
      return true
    end
    local orc_ok, tool_orc = pcall(require, "NeoAI.core.ai.tool_orchestrator")
    if orc_ok and tool_orc.is_stop_requested() then
      stopped = true
      return true
    end
    return false
  end

  -- 递归处理每个文件
  local function process_next_file()
    if is_stopped() then
      -- 停止请求，返回已收集的结果
      if on_success then
        on_success({
          file_count = #file_results,
          files = file_results,
          _stopped = true,
          _note = "工具调用已停止，返回部分结果",
        })
      end
      return
    end

    current_index = current_index + 1
    if current_index > total_files then
      -- 所有文件处理完毕
      if on_success then
        on_success({
          file_count = #file_results,
          files = file_results,
        })
      end
      return
    end

    local filepath = filepaths[current_index]
    local abs_path = vim.fn.fnamemodify(filepath, ":p")

    -- 子步骤1：保证文件在缓冲区
    if on_progress then
      on_progress(string.format("保证文件在buffer (%d/%d)", current_index, total_files), "executing", 0)
    end

    local bufnr, cleanup, load_err = ensure_buf_loaded(filepath)
    local file_entry = {
      filepath = filepath,
      clients = {},
    }

    if load_err then
      file_entry.error = "文件加载失败: " .. load_err
      table.insert(file_results, file_entry)
      if on_progress then
        on_progress(string.format("保证文件在buffer (%d/%d)", current_index, total_files), "error", 0, load_err)
      end
      process_next_file()
      return
    end

    if on_progress then
      on_progress(string.format("保证文件在buffer (%d/%d)", current_index, total_files), "completed", 0)
    end

    -- 子步骤2：等待 LSP 服务加载
    if on_progress then
      on_progress(string.format("等待LSP服务加载 (%d/%d)", current_index, total_files), "executing", 0)
    end

    -- 获取文件类型并推断期望的 LSP 配置名
    local ft = vim.filetype.match({ filename = abs_path })
    local ft_to_lsp_config = {
      lua = "lua_ls",
      python = "pyright",
      javascript = "ts_ls",
      typescript = "ts_ls",
      javascriptreact = "tsx",
      typescriptreact = "tsx",
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

    -- 使用异步非阻塞版本等待 LSP attach
    wait_for_lsp_attach_async(bufnr, function(clients, attach_err, _)
      if not clients or #clients == 0 then
        file_entry.error = attach_err or "该文件没有关联的 LSP 客户端"
        if on_progress then
          on_progress(
            string.format("等待LSP服务加载 (%d/%d)", current_index, total_files),
            "error",
            0,
            file_entry.error
          )
        end
      else
        if on_progress then
          on_progress(string.format("等待LSP服务加载 (%d/%d)", current_index, total_files), "completed", 0)
        end

        -- 子步骤3：获取 LSP 服务信息
        if on_progress then
          on_progress(string.format("获取LSP服务信息 (%d/%d)", current_index, total_files), "executing", 0)
        end

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

        if on_progress then
          on_progress(string.format("获取LSP服务信息 (%d/%d)", current_index, total_files), "completed", 0)
        end
      end

      table.insert(file_results, file_entry)

      -- 清理临时加载的缓冲区
      if cleanup then
        cleanup()
      end

      -- 处理下一个文件
      process_next_file()
    end, 30000, expected_config)
  end

  -- 开始处理第一个文件
  process_next_file()
end

M.lsp_client_info = define_tool({
  name = "lsp_client_info",
  description = "获取指定文件或文件列表的 LSP 客户端信息，包括名称、根目录、支持的能力列表。必须提供 filepath（单个文件）或 filepaths（文件列表）参数。",
  func = _lsp_client_info,
  async = true,
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
  approval = { behavior = "auto_approve" },
})

-- send_signature_request 前向声明（实际定义在文件后面）
local _send_signature_request

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

    -- signatureHelp 需要在函数调用位置（如 `foo(` 或 `obj.method(`）而非定义位置
    -- 因此我们使用 Tree-sitter 查找函数调用表达式（call_expression）的位置
    -- 如果用户指定了 node_type，优先使用；否则默认查找 call_expression
    local search_node_type = args.node_type or "call_expression"

    -- 读取文件内容，使用 Tree-sitter 查找函数调用位置
    local content, read_err = read_file_content(args.filepath)
    if not content then
      -- 无法读取文件，回退到 LSP documentSymbol 查找
      find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end
        -- 使用找到的位置 + 1 列，模拟在函数名后的位置
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
      end)
      return
    end

    -- 使用 Tree-sitter 查找函数调用位置
    local ok_ts, ts = pcall(require, "vim.treesitter")
    if not ok_ts then
      -- Tree-sitter 不可用，回退到 LSP documentSymbol
      find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
      end)
      return
    end

    -- 推断语言
    local abs_path = vim.fn.fnamemodify(args.filepath, ":p")
    local ft = vim.filetype.match({ filename = abs_path })
    if not ft then
      -- 无法推断语言，回退
      find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
      end)
      return
    end

    -- 检查解析器是否可用
    local ok_inspect, _ = pcall(ts.language.inspect, ft)
    if not ok_inspect then
      -- 解析器未安装，回退到 LSP documentSymbol
      find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
      end)
      return
    end

    local ok_lang, lang = pcall(ts.language.get_lang, ft)
    if not ok_lang or not lang then
      find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
      end)
      return
    end

    local ok_parser, parser = pcall(ts.get_string_parser, content, lang)
    if not ok_parser or not parser then
      find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
      end)
      return
    end

    local ok_trees, trees = pcall(parser.parse, parser)
    if not ok_trees or not trees or #trees == 0 then
      find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
      end)
      return
    end

    local root = trees[1]:root()
    local best_match = nil

    -- 递归查找函数调用节点
    local function search_call_node(node, depth, max_depth)
      if not node or (max_depth and depth > max_depth) then
        return
      end

      local node_type = node:type()

      -- 查找 call_expression 或类似的函数调用节点
      if
        node_type == "call_expression"
        or node_type == "call"
        or node_type == "function_call"
        or node_type == "method_call"
        or node_type == search_node_type
      then
        local text = vim.treesitter.get_node_text(node, content) or ""
        -- 检查调用表达式是否包含目标符号名
        -- 例如: `foo(args)` 或 `obj.method(args)`
        local call_start = text:find(args.symbol, 1, true)
        if call_start then
          -- 找到匹配的调用表达式，使用调用位置（左括号前）
          local sr, sc, er, ec = node:range()
          -- 查找左括号位置：在调用表达式中，左括号通常在函数名之后
          -- 对于 `foo(args)`，位置在 `foo` 之后
          -- 使用函数名长度来确定位置
          local name_end_col = sc + #args.symbol
          best_match = { row = sr, col = name_end_col }
          return
        end
      end

      -- 递归搜索子节点
      for i = 0, node:named_child_count() - 1 do
        search_call_node(node:named_child(i), depth + 1, max_depth)
        if best_match then
          return
        end
      end
    end

    search_call_node(root, 0, 50)

    if best_match then
      -- 找到函数调用位置，发送 signatureHelp 请求
      _send_signature_request(bufnr, args, cleanup, on_success, on_error, best_match.row, best_match.col)
    else
      -- Tree-sitter 未找到调用位置（可能在定义位置查找而非调用位置）
      -- 回退策略：在整个文件中搜索包含 `symbol(` 的文本行，
      -- 这些行很可能是函数调用位置（如 `processor = JupyterProcessor(args.notebook)`）
      -- 而不是定义位置（如 `class JupyterProcessor:` 或 `def __init__(self)`）
      local fallback_row, fallback_col = nil, nil
      local lines = vim.split(content, "\n")
      for line_idx, line_text in ipairs(lines) do
        -- 查找包含 `symbol(` 的行（函数调用模式）
        local call_start = line_text:find(args.symbol .. "%s*%(")
        if call_start then
          -- 跳过定义位置（class/def 关键字开头的行）
          local trimmed = line_text:match("^%s*(.-)%s*$")
          if not trimmed:match("^class%s") and not trimmed:match("^def%s") and not trimmed:match("^function%s") then
            fallback_row = line_idx - 1  -- 0-based
            fallback_col = call_start - 1 + #args.symbol  -- 0-based，定位到函数名末尾
            break
          end
        end
      end

      if fallback_row then
        -- 通过文本搜索找到调用位置
        _send_signature_request(bufnr, args, cleanup, on_success, on_error, fallback_row, fallback_col)
      else
        -- 最终回退：尝试在整个文件中搜索所有 call_expression 节点
        -- 使用更宽松的匹配策略
        local function search_all_calls(node, depth, max_depth)
          if not node or (max_depth and depth > max_depth) then
            return
          end
          local node_type = node:type()
          if node_type == "call_expression" or node_type == "call" or node_type == "function_call" or node_type == "method_call" then
            local text = vim.treesitter.get_node_text(node, content) or ""
            -- 使用更宽松的子串匹配
            if text:find(args.symbol, 1, true) then
              local sr, sc = node:range()
              -- 检查是否在调用位置（左括号前）
              local paren_pos = text:find("%(")
              if paren_pos then
                local name_end = sc + paren_pos - 1
                if not best_match then
                  best_match = { row = sr, col = name_end }
                end
                return
              end
            end
          end
          for i = 0, node:named_child_count() - 1 do
            search_all_calls(node:named_child(i), depth + 1, max_depth)
            if best_match then
              return
            end
          end
        end

        search_all_calls(root, 0, 50)

        if best_match then
          _send_signature_request(bufnr, args, cleanup, on_success, on_error, best_match.row, best_match.col)
        else
          -- 完全回退：使用 LSP documentSymbol 查找定义位置
          -- 注意：定义位置不是调用位置，LSP 可能无法返回签名信息
          find_symbol_via_lsp_async(args.filepath, args.symbol, bufnr, function(row, col, find_err)
            if not row then
              if cleanup then
                cleanup()
              end
              if on_error then
                on_error(
                  find_err
                    or (
                      "未找到符号 '"
                      .. args.symbol
                      .. "' 在文件中的调用位置。注意：signatureHelp 需要在函数调用位置（如 `foo(` 或 `obj.method(`）而非定义位置。"
                    )
                )
              end
              return
            end
            -- 使用找到的定义位置 + 1 列，尝试发送请求
            _send_signature_request(bufnr, args, cleanup, on_success, on_error, row, col + 1)
          end)
        end
      end
    end
  end, true)
end

-- 发送 signatureHelp 请求的辅助函数
_send_signature_request = function(bufnr, args, cleanup, on_success, on_error, row, col)
  lsp_request_async(bufnr, "textDocument/signatureHelp", {
    textDocument = { uri = vim.uri_from_fname(vim.fn.fnamemodify(args.filepath, ":p")) },
    position = { line = row, character = col },
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

    if not result then
      if on_success then
        on_success({
          filepath = args.filepath,
          symbol = args.symbol,
          position = { row = row, col = col },
          signatures = {},
          found = false,
        })
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
  approval = { behavior = "auto_approve" },
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

    -- 辅助函数：发送 completion 请求
    local function send_completion_request(row, col)
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result or not result.items or #result.items == 0 then
          if on_success then
            on_success({
              filepath = args.filepath,
              position = { row = row, col = col },
              is_incomplete = false,
              item_count = 0,
              items = {},
            })
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
    end

    -- 通过符号名称定位
    if args.symbol then
      find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
        if not row then
          if cleanup then
            cleanup()
          end
          if on_error then
            on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
          end
          return
        end

        send_completion_request(row, col)
      end)
    else
      send_completion_request(0, 0)
    end
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
  approval = { behavior = "auto_approve" },
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

    find_symbol_position_async(args.filepath, args.symbol, args.node_type, bufnr, function(row, col, find_err)
      if not row then
        if cleanup then
          cleanup()
        end
        if on_error then
          on_error(find_err or ("未找到符号 '" .. args.symbol .. "' 在文件中的位置"))
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

        if req_err then
          if on_error then
            on_error(req_err)
          end
          return
        end

        if not result or (type(result) == "table" and #result == 0) then
          if on_success then
            on_success({
              filepath = args.filepath,
              symbol = args.symbol,
              position = { row = row, col = col },
              locations = {},
              found = false,
            })
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
    end)
  end, true)
end

M.lsp_type_definition = define_tool({
  name = "lsp_type_definition",
  description = "获取文件中指定符号的类型定义位置，通过符号名称和可选的节点类型定位，返回类型定义所在的文件和位置范围",
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
  approval = { behavior = "auto_approve" },
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

local function _lsp_service_info(args, on_success, on_error, on_progress)
  if not check_lsp() then
    if on_error then
      on_error("LSP 不可用")
    end
    return
  end

  -- 使用 vim.schedule 异步执行，避免阻塞
  vim.schedule(function()
    if on_progress then
      on_progress("检测LSP服务类型", "executing", 0)
    end

    ensure_lsp_init()

    if on_progress then
      on_progress("检测LSP服务类型", "completed", 0)
      on_progress("获取Mason已安装服务器", "executing", 0)
    end

    local mason_servers = get_mason_installed_servers()
    local mason_names = {}
    for _, info in ipairs(mason_servers) do
      table.insert(mason_names, info.mason_name)
    end

    if on_progress then
      on_progress("获取Mason已安装服务器", "completed", 0)
      on_progress("获取活跃LSP客户端", "executing", 0)
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

    if on_progress then
      on_progress("获取活跃LSP客户端", "completed", 0)
      on_progress("汇总可用服务器列表", "executing", 0)
    end

    local available = get_available_formal_servers()

    if on_progress then
      on_progress("汇总可用服务器列表", "completed", 0)
    end

    if on_success then
      on_success({
        service_type = _lsp_service_type or "unknown",
        mason_installed = mason_names,
        available_formal_servers = available,
      })
    end
  end)
end

M.lsp_service_info = define_tool({
  name = "lsp_service_info",
  description = "获取当前 Neovim 的 LSP 服务信息，包括检测到的服务类型、Mason 已安装的服务器列表、当前活跃的正式 LSP 客户端列表",
  func = _lsp_service_info,
  async = true,
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
  approval = { behavior = "auto_approve" },
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
