--- 模型选择器测试
--- @module NeoAI.tests.test_model_picker

local tests = require("NeoAI.tests")
local config_store = require("NeoAI.kernel.config_store")

-- 基础提供商表：把默认提供商全部设为无 api_key（去掉环境变量注入的 key），
-- 再叠加测试传入的提供商，保证测试确定性。
local function _base_providers(overrides)
  local default_providers = require("NeoAI.default_config").get_default_config().ai.providers
  local providers = {}
  for name in pairs(default_providers) do
    providers[name] = { api_key = "", models_override = {} }
  end
  for name, p in pairs(overrides or {}) do
    providers[name] = p
  end
  return providers
end

tests.suite("model_picker", function(_, it)
  it("build_lines 过滤无 api_key 提供商并按提供商分组", function(t)
    config_store.load({
      ai = {
        default_provider = "alpha",
        providers = _base_providers({
          alpha = { api_type = "openai", base_url = "http://x", api_key = "kA", models_override = { "A1", "A2" } },
          beta = { api_type = "openai", base_url = "http://x", api_key = "", models_override = { "B1" } },
          gamma = { api_type = "openai", base_url = "http://x", api_key = "kB", models_override = { "G1", "G2", "G3" } },
        }),
      },
    })
    local picker = require("NeoAI.ui.components.model_picker")
    local data = picker.build_lines({
      {
        provider = "alpha",
        models = { { id = "A1" }, { id = "A2" } },
      },
      {
        provider = "beta",
        models = { { id = "B1" } },
      },
      {
        provider = "gamma",
        models = { { id = "G1" }, { id = "G2" }, { id = "G3" } },
      },
    })
    t.deep_eq({ "alpha", "  A1", "  A2", "gamma", "  G1", "  G2", "  G3" }, data.lines,
      "应只显示有 api_key 的提供商，且按提供商分组（模型用 2 格缩进）")
    t.eq(2, data.first_model_line, "第一个模型应为第 2 行")
    t.deep_eq({ "alpha", "gamma" }, data.providers, "providers 应只含 alpha/gamma")
    t.deep_eq({ provider = "gamma", id = "G2" }, data.line_to_model[6],
      "第 6 行应是 gamma 的 G2")
  end)

  it("无 api_key 提供商不展示；按提供商可折叠；回车在模型行选择正确", function(t)
    config_store.load({
      ai = {
        default_provider = "alpha",
        default_model = "auto",
        providers = _base_providers({
          alpha = { api_type = "openai", base_url = "http://x", api_key = "kA", models_override = { "A1", "A2" } },
          beta = { api_type = "openai", base_url = "http://x", api_key = "", models_override = { "B1" } },
          gamma = { api_type = "openai", base_url = "http://x", api_key = "kB", models_override = { "G1", "G2", "G3" } },
        }),
        model_refresh = { on_startup = false },
      },
    })
    local picker = require("NeoAI.ui.components.model_picker")
    picker.reset()

    local selected = nil
    picker.open(function(model_id, provider)
      selected = { model = model_id, provider = provider }
    end)

    local buf = picker.get_buf()
    t.not_nil(buf, "打开选择器应创建 buffer")
    -- 等待异步模型列表加载完成（起始占位行会被替换，行数 > 1）
    local loaded = vim.wait(3000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 1
    end)
    t.true_(loaded, "模型列表应加载完成")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    t.deep_eq({ "alpha", "  A1", "  A2", "gamma", "  G1", "  G2", "  G3" }, lines,
      "默认提供商（无 api_key）与 beta 不应展示")

    -- 按提供商折叠开启（expr），默认展开
    local win = 0
    t.eq("expr", vim.wo[win].foldmethod, "应按提供商使用 expr 折叠")
    t.eq(-1, vim.fn.foldclosed(1), "默认应展开 alpha 组")
    t.eq(1, vim.fn.foldlevel(2), "alpha 模型行应在折叠内")

    local function cr_map()
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == "<CR>" then return m end
      end
      return nil
    end
    local cr = cr_map()
    t.not_nil(cr, "应注册回车映射")

    -- 在头行回车：切换折叠（alpha 组关闭又打开）
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    cr.callback()
    t.eq(1, vim.fn.foldclosed(1), "头行回车应折叠 alpha 组")
    t.true_(vim.fn.foldtextresult(1):find("alpha", 1, true) ~= nil, "折叠文本应显示提供商名")
    cr.callback()
    t.eq(-1, vim.fn.foldclosed(1), "头行回车应再次展开 alpha 组")

    -- 在模型行回车：选择正确模型（gamma 的 G1 在第 5 行）
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    cr.callback()
    t.not_nil(selected, "回车应触发选择")
    t.eq("G1", selected.model, "应选中 gamma 的 G1")
    t.eq("gamma", selected.provider, "应返回提供商 gamma")
  end)

  it("所有提供商都无 api_key 时展示提示", function(t)
    config_store.load({
      ai = {
        default_provider = "alpha",
        providers = _base_providers({
          alpha = { api_type = "openai", base_url = "http://x", api_key = "", models_override = { "A1" } },
        }),
        model_refresh = { on_startup = false },
      },
    })
    local picker = require("NeoAI.ui.components.model_picker")
    picker.reset()
    local selected = nil
    picker.open(function(model_id, provider)
      selected = { model = model_id, provider = provider }
    end)
    local buf = picker.get_buf()
    local loaded = vim.wait(3000, function()
      local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return #l > 0 and l[1] ~= "加载模型列表..."
    end)
    t.true_(loaded, "应完成加载")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    t.eq(1, #lines, "应只有一行提示")
    t.true_(lines[1]:find("api_key", 1, true) ~= nil, "提示应包含 api_key")
    t.nil_(selected, "无模型时回车不应选择")
  end)
end)
