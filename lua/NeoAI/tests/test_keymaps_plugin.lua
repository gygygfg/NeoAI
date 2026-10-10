--- 键位插件（plugins.builtin.keymaps）与 ui.keymap 专项测试
--- @module 'NeoAI.tests.test_keymaps_plugin'
local tests = require("NeoAI.tests")
local config_store = require("NeoAI.kernel.config_store")
local services = require("NeoAI.kernel.services")

tests.suite("keymaps_plugin", function(_, it)
  local keymaps = require("NeoAI.plugins.builtin.keymaps")
  local ui_keymap = require("NeoAI.ui.keymap")

  local function count_maps(mode, desc)
    local n = 0
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if m.desc == desc then n = n + 1 end
    end
    return n
  end

  it("插件 start 注册全局键位且 cleanup 删除", function(t)
    local saved = config_store.get("keymaps.global")
    config_store.set("keymaps.global", { open_chat = { key = "<Leader>nt", desc = "NeoAI plugin-testkey" } })
    local cleanup = keymaps.start()
    t.eq(1, count_maps("n", "NeoAI plugin-testkey"), "应注册全局键位")
    cleanup()
    t.eq(0, count_maps("n", "NeoAI plugin-testkey"), "清理应删除键位")
    config_store.set("keymaps.global", saved)
  end)

  it("run(action) 经 ui 服务分发，缺失时降级 nil", function(t)
    local saved = services.use("services.ui")
    services.revoke("services.ui")
    t.nil_(keymaps.run("open_chat"), "ui 缺失应返回 nil")
    local calls = {}
    services.provide("services.ui", {
      open_chat = function() calls[#calls + 1] = "chat" end,
      open_tree = function() calls[#calls + 1] = "tree" end,
      close_all = function() calls[#calls + 1] = "close" end,
      has_windows = function() return false end,
    })
    keymaps.run("open_chat")
    keymaps.run("open_tree")
    keymaps.run("close_all")
    keymaps.run("toggle_ui") -- has_windows=false → open_tree
    t.deep_eq({ "chat", "tree", "close", "tree" }, calls)
    if saved then services.provide("services.ui", saved) else services.revoke("services.ui") end
  end)

  it("ui.keymap.register_context 注册 buffer 键位并可卸载", function(t)
    local saved = config_store.get("keymaps.tree")
    config_store.set("keymaps.tree", { quit = { key = "q", desc = "NeoAI tree-quit" } })
    local buf = vim.api.nvim_create_buf(false, true)
    ui_keymap.reset()
    ui_keymap.register_context("tree", { quit = function() end }, buf)
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.desc == "NeoAI tree-quit" then found = true end
    end
    t.true_(found, "应注册 buffer 键位")
    ui_keymap.unregister("tree")
    found = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.desc == "NeoAI tree-quit" then found = true end
    end
    t.false_(found, "unregister 应删除 buffer 键位")
    vim.api.nvim_buf_delete(buf, { force = true })
    config_store.set("keymaps.tree", saved)
  end)

  it("ui.keymap 双模式：insert/normal 各自注册", function(t)
    local saved = config_store.get("keymaps.chat")
    config_store.set("keymaps.chat", {
      send = { insert = { key = "<C-s>" }, normal = { key = "<CR>" } },
    })
    local buf = vim.api.nvim_create_buf(false, true)
    ui_keymap.reset()
    ui_keymap.register_context("chat", { send = function() end }, buf)
    local function has(mode)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if m.desc == "NeoAI send" then return true end
      end
      return false
    end
    t.true_(has("i"), "insert 模式应注册")
    t.true_(has("n"), "normal 模式应注册")
    vim.api.nvim_buf_delete(buf, { force = true })
    config_store.set("keymaps.chat", saved)
  end)

  it("ui.keymap.show_keymaps 打开浮窗", function(t)
    local function win_title(w)
      local cfg = vim.api.nvim_win_get_config(w)
      local title = cfg.title
      if type(title) == "string" then return title end
      if type(title) == "table" then
        local parts = {}
        for _, chunk in ipairs(title) do
          if type(chunk) == "string" then parts[#parts + 1] = chunk
          elseif type(chunk) == "table" then parts[#parts + 1] = tostring(chunk[1] or "") end
        end
        return table.concat(parts)
      end
      return nil
    end
    ui_keymap.show_keymaps()
    local opened = false
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if win_title(w) == "NeoAI 键位配置" then
        opened = true
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    t.true_(opened, "应打开键位浮窗")
  end)
end)
