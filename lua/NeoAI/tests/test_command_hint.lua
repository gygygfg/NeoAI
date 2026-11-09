--- 命令提示（ui.command_hint）专项测试
--- @module 'NeoAI.tests.test_command_hint'
--- 覆盖：命令行匹配（空前缀 / 前缀过滤 / 非 NeoAI 命令）、提示行文本、
--- cmp 候选项三元组、安装/卸载无残留。
local tests = require("NeoAI.tests")

tests.suite("command_hint", function(_, it)
  local hint = require("NeoAI.ui.command_hint")
  local commands = require("NeoAI.plugins.builtin.commands")

  it("matched：`:NeoAI` 与 `NeoAI ` 视为空前缀，返回全部子命令", function(t)
    local items = hint.matched(":NeoAI")
    t.eq(#commands.SUBCOMMANDS, #items, "未输入空格时应返回全部子命令")
    for _, it2 in ipairs(items) do t.true_(it2.matched, "空前缀下全部匹配") end

    local spaced = hint.matched("NeoAI ")
    t.eq(#commands.SUBCOMMANDS, #spaced)
  end)

  it("matched：按前缀过滤，未匹配项 matched=false", function(t)
    local items = hint.matched(":NeoAI Sandbox")
    local matched, unmatched = 0, 0
    for _, it2 in ipairs(items) do
      if it2.matched then
        matched = matched + 1
        t.eq("Sandbox", it2.name:sub(1, 7), "匹配项应以 Sandbox 开头: " .. it2.name)
      else
        unmatched = unmatched + 1
      end
    end
    t.true_(matched > 0, "应有匹配项")
    t.true_(unmatched > 0, "应有不匹配项")
  end)

  it("matched：非 NeoAI 命令 / 已有第二个参数时返回空", function(t)
    t.eq(0, #hint.matched(":NeoAIOther"))
    t.eq(0, #hint.matched(":NeoAI Open extra"))
    t.eq(0, #hint.matched(""))
  end)

  it("hint_lines：形如「name — desc」，只含匹配项", function(t)
    local lines = hint.hint_lines(":NeoAI SandboxList")
    t.true_(#lines >= 1)
    t.eq("SandboxList — " .. commands.subcommand_descs().SandboxList, lines[1])

    local all = hint.hint_lines(":NeoAI ")
    t.eq(#commands.SUBCOMMANDS, #all, "空前缀应列出全部子命令")
  end)

  it("completion_items：含 label/detail/documentation", function(t)
    local items = hint.completion_items(":NeoAI Doct")
    t.eq(1, #items)
    t.eq("Doctor", items[1].label)
    t.true_(#items[1].detail > 0, "应有说明")
    t.true_(items[1].documentation:find("NeoAI Doctor", 1, true) ~= nil)
  end)

  it("install 返回清理函数，uninstall 后无残留自动命令", function(t)
    -- 先归零（commands 插件启动时可能已安装过），再在测试控制区间内计数
    hint.uninstall()
    local before = #vim.api.nvim_get_autocmds({ event = "CmdlineChanged" })
    local cleanup = hint.install()
    t.eq("function", type(cleanup))
    t.true_(hint.mode() ~= nil, "安装后应有提示形态（cmp 或 float）")
    cleanup()
    t.nil_(hint.mode(), "卸载后形态应为 nil")
    local after = #vim.api.nvim_get_autocmds({ event = "CmdlineChanged" })
    t.eq(before, after, "卸载后 CmdlineChanged 自动命令应恢复原状")
  end)

  it("安装幂等：重复 install 不重复注册", function(t)
    hint.uninstall()
    local c1 = hint.install()
    local c2 = hint.install()
    c1()
    c2()
    t.nil_(hint.mode())
    hint.reset()
  end)

  it("配置 enabled=false 时零副作用", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    hint.uninstall()
    local saved = vim.deepcopy(config_store.get_all() or {})
    config_store.set("ui.command_hint", { enabled = false })
    local before = #vim.api.nvim_get_autocmds({ event = "CmdlineChanged" })
    local cleanup = hint.install()
    t.nil_(hint.mode(), "关闭时不应选择提示形态")
    t.eq(before, #vim.api.nvim_get_autocmds({ event = "CmdlineChanged" }))
    cleanup()
    config_store.load(saved)
  end)
end)
