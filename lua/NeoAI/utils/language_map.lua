--- 语言 / 扩展名 / 工具映射表 (统一入口)
--- 所有扩展名/文件类型 → 解析器/LSP/格式化工具的映射都集中在这里
--- 供 neovim_tree, neovim_lsp, file_tools 等模块复用

local M = {}

M.ext_to_lang = {
  py = "python", lua = "lua", js = "javascript", ts = "typescript",
  jsx = "tsx", tsx = "tsx", go = "go", rs = "rust", java = "java",
  c = "c", cpp = "cpp", rb = "ruby", php = "php", json = "json",
  yaml = "yaml", yml = "yaml", md = "markdown", sh = "bash",
  bash = "bash", zsh = "bash", css = "css", html = "html", htm = "html",
  vue = "vue", svelte = "svelte", toml = "toml", sql = "sql",
  cmake = "cmake", dockerfile = "dockerfile", make = "make",
  query = "query", regex = "regex",
}

M.ext_to_parser = {
  [".lua"] = "lua", [".py"] = "python", [".js"] = "javascript",
  [".ts"] = "typescript", [".jsx"] = "tsx", [".tsx"] = "tsx",
  [".go"] = "go", [".rs"] = "rust", [".java"] = "java", [".c"] = "c",
  [".cpp"] = "cpp", [".h"] = "c", [".hpp"] = "cpp", [".rb"] = "ruby",
  [".php"] = "php", [".json"] = "json", [".yaml"] = "yaml",
  [".yml"] = "yaml", [".md"] = "markdown", [".sh"] = "bash",
  [".bash"] = "bash", [".zsh"] = "bash", [".css"] = "css",
  [".html"] = "html", [".htm"] = "html", [".vue"] = "vue",
  [".svelte"] = "svelte", [".toml"] = "toml", [".sql"] = "sql",
  [".cmake"] = "cmake", [".mk"] = "make", [".query"] = "query",
  [".regex"] = "regex",
}

M.ft_to_parser = {
  lua = "lua", python = "python", javascript = "javascript",
  typescript = "typescript", javascriptreact = "tsx",
  typescriptreact = "tsx", go = "go", rust = "rust", java = "java",
  c = "c", cpp = "cpp", ruby = "ruby", php = "php", json = "json",
  yaml = "yaml", markdown = "markdown", bash = "bash", sh = "bash",
  zsh = "bash", css = "css", html = "html", vue = "vue",
  svelte = "svelte", toml = "toml", sql = "sql", cmake = "cmake",
  dockerfile = "dockerfile", make = "make", query = "query", regex = "regex",
}

M.ft_to_lsp_config = {
  lua = "lua_ls", python = "pyright", javascript = "ts_ls",
  typescript = "ts_ls", javascriptreact = "ts_ls", typescriptreact = "ts_ls",
  go = "gopls", rust = "rust_analyzer", java = "jdtls", c = "clangd",
  cpp = "clangd", ruby = "solargraph", php = "intelephense",
  json = "jsonls", yaml = "yamlls", markdown = "marksman",
  bash = "bashls", sh = "bashls", zsh = "bashls", css = "cssls",
  html = "htmlls", vue = "volar", svelte = "svelte",
}

M.lsp_commands = {
  lua_ls = { "lua-language-server" },
  pyright = { "pyright-langserver", "--stdio" },
  ts_ls = { "typescript-language-server", "--stdio" },
  html = { "vscode-html-language-server", "--stdio" },
  cssls = { "vscode-css-language-server", "--stdio" },
  jsonls = { "vscode-json-language-server", "--stdio" },
  yamlls = { "yaml-language-server", "--stdio" },
  bashls = { "bash-language-server", "start" },
  clangd = { "clangd" }, gopls = { "gopls" },
  rust_analyzer = { "rust-analyzer" }, marksman = { "marksman" },
  solargraph = { "solargraph", "stdio" },
  intelephense = { "intelephense", "--stdio" },
  jdtls = { "jdtls" }, volar = { "vue-language-server", "--stdio" },
  svelte = { "svelte-language-server", "--stdio" },
  htmlls = { "vscode-html-language-server", "--stdio" },
}

M.mason_executables = {
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

M.external_formatters = {
  python = {
    { cmd = "ruff", args = { "format", "--quiet" }, name = "ruff" },
    { cmd = "black", args = { "--quiet" }, name = "black" },
    { cmd = "autopep8", args = { "--in-place" }, name = "autopep8" },
    { cmd = "yapf", args = { "--in-place" }, name = "yapf" },
  },
  lua = { { cmd = "stylua", args = {}, name = "stylua" } },
  javascript = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  typescript = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  javascriptreact = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  typescriptreact = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  json = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  yaml = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  markdown = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  css = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  html = { { cmd = "prettier", args = { "--write" }, name = "prettier" } },
  go = { { cmd = "gofmt", args = { "-w" }, name = "gofmt" } },
  rust = { { cmd = "rustfmt", args = {}, name = "rustfmt" } },
  sh = { { cmd = "shfmt", args = { "-w" }, name = "shfmt" } },
  bash = { { cmd = "shfmt", args = { "-w" }, name = "shfmt" } },
}

function M.lang_from_ext(ext)
  ext = ext:match("^%.?(.+)$")
  return M.ext_to_lang[ext]
end

function M.parser_from_ext(ext)
  local dotted = ext:find("^%.") and ext or "." .. ext
  return M.ext_to_parser[dotted]
end

function M.parser_from_ft(ft)
  return M.ft_to_parser[ft]
end

function M.lsp_config_from_ft(ft)
  return M.ft_to_lsp_config[ft]
end

function M.lsp_cmd(config_name)
  return M.lsp_commands[config_name]
end

function M.mason_executable(mason_name)
  return M.mason_executables[mason_name]
end

function M.formatters_for_ft(ft)
  return M.external_formatters[ft]
end

return M
