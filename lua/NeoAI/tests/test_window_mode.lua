--- 窗口模式专项测试：float 输入浮窗 / split 尺寸收敛 / WindowMode 仅当前窗口生效
--- @module 'NeoAI.tests.test_window_mode'
local tests = require("NeoAI.tests")

tests.suite("window_mode", function(_, it)
  local config_store = require("NeoAI.kernel.config_store")

  --- 在指定屏幕尺寸下执行断言，结束后恢复原尺寸（headless 下 columns/lines 可写）。
  --- @param cols number
  --- @param lines number
  --- @param fn function
  local function with_screen(cols, lines, fn)
    local old_cols, old_lines = vim.o.columns, vim.o.lines
    pcall(function()
      vim.o.columns = cols
      vim.o.lines = lines
    end)
    local ok, err = pcall(fn)
    pcall(function()
      vim.o.columns = old_cols
      vim.o.lines = old_lines
    end)
    if not ok then error(err, 0) end
  end

  --- 保存/设置配置项，返回恢复函数。
  --- @param path string
  --- @param value any
  --- @return function
  local function set_cfg(path, value)
    local saved = config_store.get(path)
    config_store.set(path, value)
    return function() config_store.set(path, saved) end
  end

  --- 重置聊天视图与会话状态（各用例起点一致）。
  local function reset_chat()
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()
  end

  --- 浮动主窗口的完整几何（与 manager._open_float 同源，用于断言整体高度）。
  --- @param win number
  --- @return table|nil
  local function float_geometry(win)
    return require("NeoAI.ui.window.manager").get_float_geometry(win)
  end

  --- 取一个「普通（非浮窗）」窗口，用作焦点移出目标。
  --- @param exclude table<number, boolean>
  --- @return number|nil
  local function plain_win(exclude)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not exclude[w] and vim.api.nvim_win_get_config(w).relative == "" then
        return w
      end
    end
    return nil
  end

  it("float 模式：输入框是紧贴主浮窗下方的等宽独立浮窗", function(t)
    local restore_mode = set_cfg("ui.window_mode", "float")
    reset_chat()
    with_screen(120, 40, function()
      local chat_view = require("NeoAI.ui.window.chat_view")
      local opened = chat_view.open()
      local main_win = opened.win_id
      local input_win = chat_view._input_win_id()
      t.true_(input_win ~= nil and vim.api.nvim_win_is_valid(input_win), "应创建输入窗口")

      local icfg = vim.api.nvim_win_get_config(input_win)
      local mcfg = vim.api.nvim_win_get_config(main_win)
      t.true_(icfg.relative ~= "", "float 模式下输入框必须是浮窗（不是普通 split）")
      t.eq("minimal", mcfg.style, "主聊天窗应为浮窗")
      t.eq(vim.api.nvim_win_get_width(main_win), icfg.width, "输入浮窗宽度应等于主浮窗宽度")

      local mpos = vim.api.nvim_win_get_position(main_win)
      local ipos = vim.api.nvim_win_get_position(input_win)
      t.eq(mpos[2], ipos[2], "输入浮窗应与主浮窗左对齐")
      t.eq(mpos[1] + vim.api.nvim_win_get_height(main_win) + 2, ipos[1],
        "输入浮窗应紧贴主浮窗下边框之下")

      -- 主浮窗让位后，两者合计仍占原整体高度（两者各自还有上下各 1 行边框）。
      local geom = float_geometry(main_win)
      t.true_(geom ~= nil, "浮动窗口应登记几何")
      t.eq(geom.height,
        vim.api.nvim_win_get_height(main_win) + vim.api.nvim_win_get_height(input_win) + 2,
        "主浮窗 + 输入浮窗应合计占原整体高度")

      reset_chat()
    end)
    restore_mode()
  end)

  it("float 模式：输入框随内容增高，主浮窗同步让位；焦点回主窗收为 idle 高度", function(t)
    local restore_mode = set_cfg("ui.window_mode", "float")
    reset_chat()
    with_screen(120, 40, function()
      local chat_view = require("NeoAI.ui.window.chat_view")
      local opened = chat_view.open()
      local main_win = opened.win_id
      local input_win = chat_view._input_win_id()
      local ibuf = vim.api.nvim_win_get_buf(input_win)
      local geom = float_geometry(main_win)
      local main_h0 = vim.api.nvim_win_get_height(main_win)
      local input_h0 = vim.api.nvim_win_get_height(input_win)

      -- 输入 7 行（焦点在输入框，由 TextChanged 触发增高）
      vim.api.nvim_set_current_win(input_win)
      vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { "1", "2", "3", "4", "5", "6", "7" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = ibuf })
      t.eq(7, vim.api.nvim_win_get_height(input_win), "输入浮窗应随内容增高到 7 行")
      t.eq(main_h0 + input_h0 - 7, vim.api.nvim_win_get_height(main_win), "主浮窗应同步变矮")
      t.eq(geom.height, vim.api.nvim_win_get_height(main_win) + 7 + 2, "整体高度应保持不变")
      local ipos = vim.api.nvim_win_get_position(input_win)
      local mpos = vim.api.nvim_win_get_position(main_win)
      t.eq(mpos[1] + vim.api.nvim_win_get_height(main_win) + 2, ipos[1],
        "增高后输入浮窗仍应紧贴主浮窗下边框")

      -- 焦点回主窗口：输入框收为 idle 高度（1 行），主浮窗相应恢复
      vim.api.nvim_set_current_win(main_win)
      vim.wait(20)
      t.eq(1, vim.api.nvim_win_get_height(input_win), "焦点在主窗时输入浮窗应收起为 1 行")
      t.eq(geom.height, vim.api.nvim_win_get_height(main_win) + 1 + 2, "主浮窗应恢复高度")

      reset_chat()
    end)
    restore_mode()
  end)

  it("float 模式：焦点移出聊天界面收起输入浮窗并恢复主浮窗全高，回到聊天重建且不重复", function(t)
    local restore_mode = set_cfg("ui.window_mode", "float")
    reset_chat()
    with_screen(120, 40, function()
      local chat_view = require("NeoAI.ui.window.chat_view")
      local opened = chat_view.open()
      local main_win = opened.win_id
      local geom = float_geometry(main_win)
      local input_win = chat_view._input_win_id()
      t.true_(input_win ~= nil and vim.api.nvim_win_is_valid(input_win), "应创建输入浮窗")
      local ibuf = vim.api.nvim_win_get_buf(input_win)
      t.true_(vim.api.nvim_win_get_height(main_win) < geom.height, "主浮窗应为输入浮窗让出高度")

      -- 焦点移出聊天界面 → 收起输入浮窗 + 主浮窗恢复全高
      local other = plain_win({ [main_win] = true, [input_win] = true })
      t.true_(other ~= nil, "应存在其它普通窗口用于移出焦点")
      vim.api.nvim_set_current_win(other)
      vim.wait(50)
      local iw = chat_view._input_win_id()
      t.false_(iw ~= nil and vim.api.nvim_win_is_valid(iw), "焦点移出后输入浮窗应被收起")
      t.eq(geom.height, vim.api.nvim_win_get_height(main_win), "主浮窗应恢复全高")

      -- 回到聊天界面 → 重建输入浮窗（同一输入 buffer，只有一个窗口）
      vim.api.nvim_set_current_win(main_win)
      vim.wait(50)
      local iw2 = chat_view._input_win_id()
      t.true_(iw2 ~= nil and vim.api.nvim_win_is_valid(iw2), "回到聊天应重建输入浮窗")
      t.true_(vim.api.nvim_win_get_config(iw2).relative ~= "", "重建的输入框仍应是浮窗")
      local n = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == ibuf then n = n + 1 end
      end
      t.eq(1, n, "同一输入 buffer 只应有一个窗口（不得出现两个输入框）")

      reset_chat()
    end)
    restore_mode()
  end)

  it("split 模式：宽度按屏幕比例与原窗口保底收敛，默认最多占屏幕一半", function(t)
    local restore_mode = set_cfg("ui.window_mode", "split")

    -- 默认配置：max_ratio=0.5（最多占屏幕一半）、min_rest=20（原窗口保底）。
    local split_cfg = config_store.get("ui.split")
    t.eq(0.5, split_cfg.max_ratio, "默认 ui.split.max_ratio 应为 0.5")
    t.eq(20, split_cfg.min_rest, "默认 ui.split.min_rest 应为 20")

    local function check(cols, want_max)
      local chat_view = require("NeoAI.ui.window.chat_view")
      reset_chat()
      local opened = chat_view.open()
      local main_win = opened.win_id
      local width = vim.api.nvim_win_get_width(main_win)
      t.true_(width <= want_max, ("cols=%d 时 NeoAI 窗口宽 %d 应 <= %d"):format(cols, width, want_max))
      local other = plain_win({ [main_win] = true })
      t.true_(other ~= nil, ("cols=%d 时应保留原窗口"):format(cols))
      t.true_(vim.api.nvim_win_get_width(other) >= 20,
        ("cols=%d 时原窗口应至少保留 20 列，实际 %d"):format(cols, vim.api.nvim_win_get_width(other)))
      reset_chat()
      return width
    end

    -- 默认配置（未显式设置 ui.split）：size=80 但被 50% 上限收敛到屏幕一半。
    with_screen(120, 40, function()
      t.eq(60, check(120, 60), "默认配置下 cols=120 时应收敛到屏幕一半（60 列）")
    end)
    with_screen(80, 40, function()
      t.eq(40, check(80, 40), "cols=80 时应收敛到 50% 上限（40 列）")
    end)
    with_screen(60, 40, function()
      t.eq(30, check(60, 30), "cols=60 时应收敛到 50% 上限（30 列）")
    end)

    restore_mode()
  end)

  it("split 模式：top 方向按高度收敛（不再错误地设置宽度）", function(t)
    local restore_mode = set_cfg("ui.window_mode", "split")
    local restore_split = set_cfg("ui.split", { size = 80, direction = "top", max_ratio = 0.5, min_rest = 20 })
    reset_chat()
    with_screen(120, 40, function()
      local chat_view = require("NeoAI.ui.window.chat_view")
      local opened = chat_view.open()
      local main_win = opened.win_id
      local h = vim.api.nvim_win_get_height(main_win)
      local available = math.max(1, vim.o.lines - 1)
      local cap = math.min(math.floor(available * 0.5), available - 20 - 1)
      t.true_(h <= cap, ("top 方向高度 %d 应收敛到 <= %d"):format(h, cap))
      t.eq(vim.o.columns, vim.api.nvim_win_get_width(main_win), "top 方向不应改动窗口宽度")
      reset_chat()
    end)
    restore_split()
    restore_mode()
  end)

  it("WindowMode 切换只影响当前聊天窗口：不写配置、其它实例不变、新开窗口按配置", function(t)
    local restore_mode = set_cfg("ui.window_mode", "tab")
    reset_chat()
    with_screen(120, 40, function()
      local ui = require("NeoAI.ui")
      local chat_view = require("NeoAI.ui.window.chat_view")

      -- 实例 A（tab）
      local a = chat_view.open()
      local a_win, a_input = a.win_id, chat_view._input_win_id()
      t.eq("tab", chat_view.get_window_mode(), "A 应沿用配置的 tab 模式")

      -- 实例 B（新窗口，仍按配置 tab），成为当前实例
      local b = chat_view.open_new()
      local b_win = b.win_id
      t.eq("tab", ui.window_mode(), "当前窗口模式应为 tab")

      -- 切换当前窗口（B）到 float
      local mode, rebuilt = ui.set_window_mode("float")
      t.eq("float", mode, "应返回切换后的模式")
      t.true_(rebuilt, "空闲时应立即重建当前窗口")
      t.eq("tab", config_store.get("ui.window_mode"), "运行期切换不得写 ui.window_mode 配置")
      t.eq("float", chat_view.get_window_mode(), "B 应为 float")
      local b_input = chat_view._input_win_id()
      t.true_(b_input ~= nil and vim.api.nvim_win_is_valid(b_input), "B 重建后应有输入框")
      t.true_(vim.api.nvim_win_get_config(b_input).relative ~= "", "B 的输入框应是浮窗")
      t.false_(vim.api.nvim_win_is_valid(b_win), "B 的旧窗口应已被重建")

      -- 实例 A 不受影响：窗口仍在、仍是普通 split（不是浮窗）
      t.true_(vim.api.nvim_win_is_valid(a_win), "A 的窗口不应被重建")
      t.eq("", vim.api.nvim_win_get_config(a_win).relative, "A 仍应是普通 split 窗口")
      t.true_(a_input ~= nil and vim.api.nvim_win_is_valid(a_input), "A 的输入框应保持原样")
      t.eq("", vim.api.nvim_win_get_config(a_input).relative, "A 的输入框仍应是普通 split")

      -- 新开窗口（新会话）仍按配置：tab
      local c = chat_view.open_new()
      t.eq("tab", chat_view.get_window_mode(), "新开窗口不应继承切换后的 float 模式")
      t.eq("", vim.api.nvim_win_get_config(c.win_id).relative, "新开窗口应为 tab（普通标签页窗口）")

      reset_chat()
    end)
    restore_mode()
  end)

  it("Agent 运行中切换窗口模式：保留同一 Agent，当前回合不中断", function(t)
    local restore_mode = set_cfg("ui.window_mode", "tab")
    reset_chat()
    with_screen(120, 40, function()
      local ui = require("NeoAI.ui")
      local chat_view = require("NeoAI.ui.window.chat_view")
      local chat_service = require("NeoAI.services.chat_service")
      local runtime = require("NeoAI.core.agent.runtime")

      local opened = chat_view.open()
      local old_win = opened.win_id
      local agent = chat_service.get_agent_for_buffer(opened.buf)
      t.true_(agent ~= nil, "打开聊天窗口后应绑定 Agent")
      t.eq("", vim.api.nvim_win_get_config(old_win).relative, "起始应为 tab（普通窗口）")
      -- 模拟「正在生成」：重建若走旧的 detach_window 会 dispose 掉运行中的 Agent。
      agent.state = "generating"

      local mode, rebuilt = ui.set_window_mode("float")
      t.eq("float", mode, "应返回切换后的模式")
      t.true_(rebuilt, "Agent 运行中也应完成重建")
      t.eq("generating", agent.state, "切换不得改变 Agent 状态")
      t.true_(runtime.get(agent.id) == agent, "运行中的 Agent 不得被销毁或替换")
      t.eq("tab", config_store.get("ui.window_mode"), "运行期切换不得写 ui.window_mode 配置")

      local res = chat_view.open()
      local new_win = res.win_id
      t.true_(new_win ~= old_win, "应重建为新的主窗口")
      t.false_(vim.api.nvim_win_is_valid(old_win), "旧窗口应已关闭")
      t.true_(vim.api.nvim_win_get_config(new_win).relative ~= "", "新主窗口应为浮窗")
      local input_win = chat_view._input_win_id()
      t.true_(input_win ~= nil and vim.api.nvim_win_is_valid(input_win), "应重建输入框")
      t.true_(vim.api.nvim_win_get_config(input_win).relative ~= "", "float 模式下输入框应为浮窗")
      local bound = chat_service.get_agent_for_buffer(res.buf)
      t.true_(bound ~= nil and bound.id == agent.id, "新窗口应仍绑定同一 Agent")

      -- 运行中再切回 split：同样保留同一个 Agent。
      local mode2, rebuilt2 = ui.set_window_mode("split")
      t.eq("split", mode2, "应切回 split")
      t.true_(rebuilt2, "运行中切到 split 也应重建")
      t.true_(runtime.get(agent.id) == agent, "再次切换后 Agent 仍不得被销毁")
      t.eq("generating", agent.state, "再次切换后 Agent 状态不变")

      agent.state = "idle"
      reset_chat()
    end)
    restore_mode()
  end)

  it("WindowMode 无已打开窗口时只提示，不写配置", function(t)
    local restore_mode = set_cfg("ui.window_mode", "tab")
    reset_chat()
    local ui = require("NeoAI.ui")
    local mode, rebuilt = ui.set_window_mode("float")
    t.eq("tab", mode, "无窗口时应返回当前（配置）模式")
    t.false_(rebuilt, "无窗口时不应重建")
    t.eq("tab", config_store.get("ui.window_mode"), "不得写配置")
    restore_mode()
  end)
end)
