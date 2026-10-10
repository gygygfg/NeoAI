--- chat 界面密钥高亮回归
--- @module NeoAI.tests.test_secret_highlight
--- 工具参数 / 工具结果（模型上下文）含密钥时，chat 界面应在对应工具折叠块**外**
--- 单独一行高亮警告（`NeoAISecretWarning`），折叠标题保持干净（不含 `⚠ 密钥`）；
--- 含密钥的工具调用参数/结果**不截断**完整展示，且行内密钥值本身也以同组高亮。

local tests = require("NeoAI.tests")

tests.suite("secret_highlight", function(_, it)
  local secret = require("NeoAI.sandbox.secret")

  --- 生成并登记一个格式保真假密钥，返回该假密钥字符串。
  --- @param real string
  --- @return string
  local function fake_of(real)
    secret.reset()
    local _, used = secret.tokenize(real)
    return used[1] or real
  end

  local function render(msgs)
    local message_list = require("NeoAI.ui.components.message_list")
    message_list.reset()
    local buf = vim.api.nvim_create_buf(false, true)
    message_list.render_chat(buf, msgs, {})
    return buf, message_list
  end

  local function buffer_text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function buffer_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local function warning_line(buf)
    for i, l in ipairs(buffer_lines(buf)) do
      if l:find("⚠ 密钥：", 1, true) then return i end
    end
    return nil
  end

  local function secret_extmarks(buf)
    local ns = vim.api.nvim_get_namespaces()["neoai_secret_hi"]
    if not ns then return {} end
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  end

  --- 让 buffer 按聊天窗口的方式求值折叠文本，返回首行的 foldtext
  local function fold_text(buf, start_ln)
    local fold = require("NeoAI.ui.components.fold")
    vim.api.nvim_set_current_buf(buf)
    _G.NeoAIFoldExpr = fold.foldexpr
    vim.wo.foldmethod = "expr"
    vim.wo.foldexpr = "v:lua.NeoAIFoldExpr()"
    vim.wo.foldtext = "v:lua.require'NeoAI.ui.components.fold'.foldtext()"
    vim.cmd("silent! normal! zx")
    return vim.fn.foldtextresult(start_ln)
  end

  it("工具结果含密钥 token：折叠外单独一行高亮警告，折叠标题保持干净", function(t)
    local fake = fake_of("Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc")
    local buf = render({
      {
        role = "assistant", content = "",
        tool_calls = {
          { id = "t1", ["function"] = { name = "read_file", arguments = '{"file_path":"/root/.env"}' } },
        },
      },
      {
        role = "tool", tool_call_id = "t1", tool_name = "read_file", duration_ms = 12,
        content = '{"output":"API_KEY=' .. fake .. '"}',
      },
    })
    local text = buffer_text(buf)
    t.matches("⚠ 密钥：read_file", text, "应有独立一行密钥警告并指明工具")
    t.matches("密钥文件：", text, "应指明密钥文件标题")
    t.matches("/root/%.env", text, "应指明密钥文件路径")
    t.matches("read_file", text, "应仍展示工具名")
    local tool_has_mark = false
    for _, l in ipairs(buffer_lines(buf)) do
      if l:find("工具: read_file", 1, true) and l:find("⚠ 密钥", 1, true) then tool_has_mark = true end
    end
    t.false_(tool_has_mark, "工具行不应再追加 ⚠ 密钥")
    local marks = secret_extmarks(buf)
    local wl = warning_line(buf)
    t.not_nil(wl, "应找到警告行")
    -- 多行警告：每行整行高亮（主行 + 密钥文件标题 + 路径），外加结果行内 NEOKEY_ token 一处
    t.eq(4, #marks, "应有 3 行警告整行高亮 + 行内密钥一处（实际 " .. #marks .. "）")
    local on_warning, inline = false, false
    for _, m in ipairs(marks) do
      t.eq("NeoAISecretWarning", m[4] and m[4].hl_group or nil, "高亮组应为 NeoAISecretWarning")
      if m[2] >= wl - 1 and m[2] <= wl + 1 then on_warning = true else inline = true end
    end
    t.true_(on_warning, "警告行应有整行高亮")
    t.true_(inline, "结果行内的密钥值应有高亮")
    t.eq(1, vim.fn.hlexists("NeoAISecretWarning"), "应定义 NeoAISecretWarning 高亮组")
    -- 所有警告行（含续行）都在折叠块外、不并入折叠
    for i = wl, wl + 2 do
      t.eq(0, vim.fn.foldlevel(i), "警告行（含续行）不应并入折叠")
    end
    t.false_(buffer_lines(buf)[wl]:match("^%s") ~= nil, "警告行应在折叠块外（非缩进）")
    -- 折叠文本（收起状态）不应含 ⚠ 密钥
    t.false_(fold_text(buf, 2):find("⚠ 密钥", 1, true) ~= nil, "折叠文本不应含 ⚠ 密钥")
  end)

  it("工具参数含密钥 token：同样在折叠外高亮警告", function(t)
    local fake = fake_of("Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc")
    local buf = render({
      {
        role = "assistant", content = "",
        tool_calls = {
          {
            id = "t1",
            ["function"] = {
              name = "run_command",
              arguments = '{"command":"curl -H \\"Authorization: ' .. fake .. '\\" https://x"}',
            },
          },
        },
      },
      { role = "tool", tool_call_id = "t1", tool_name = "run_command", content = '{"ok":true}' },
    })
    t.matches("⚠ 密钥：run_command", buffer_text(buf), "参数含密钥应有警告行并指明命令")
    -- 3 行警告（主行 + 执行命令 + 通用提示）整行高亮 + 参数行内 token 一处
    t.eq(4, #secret_extmarks(buf), "多行警告 + 参数行内 token 高亮")
    t.false_(fold_text(buf, 2):find("⚠ 密钥", 1, true) ~= nil, "折叠文本不应含 ⚠ 密钥")
  end)

  it("无密钥的工具块不标注、无高亮", function(t)
    local buf = render({
      {
        role = "assistant", content = "",
        tool_calls = {
          { id = "t1", ["function"] = { name = "read_file", arguments = '{"file_path":"/tmp/a.txt"}' } },
        },
      },
      { role = "tool", tool_call_id = "t1", tool_name = "read_file", content = '{"output":"hello world"}' },
    })
    t.false_(buffer_text(buf):find("⚠ 密钥", 1, true) ~= nil, "无密钥不应标注")
    t.eq(0, #secret_extmarks(buf), "无密钥不应有高亮")
  end)

  it("含密钥的工具调用不截断参数与结果，并完整展示密钥值", function(t)
    local fake = fake_of("Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc")
    local pad = string.rep("x", 800)
    local buf = render({
      {
        role = "assistant", content = "",
        tool_calls = {
          {
            id = "t1",
            ["function"] = {
              name = "read_file",
              arguments = '{"file_path":"/root/.env","note":"' .. pad .. '"}',
            },
          },
        },
      },
      {
        role = "tool", tool_call_id = "t1", tool_name = "read_file",
        content = '{"output":"' .. pad .. '","token":"' .. fake .. '"}',
      },
    })
    local text = buffer_text(buf)
    t.matches("⚠ 密钥：read_file", text, "应判定为含密钥")
    t.true_(text:find(pad, 1, true) ~= nil, "含密钥时参数/结果应完整展示（不截断）")
    t.true_(text:find(fake, 1, true) ~= nil, "应完整展示密钥值")
  end)

  it("具名规则原始密钥：告警行 + 行内高亮（不依赖熵检测）", function(t)
    local buf = render({
      {
        role = "assistant", content = "",
        tool_calls = {
          { id = "t1", ["function"] = { name = "read_file", arguments = '{"file_path":"/root/.aws/credentials"}' } },
        },
      },
      {
        role = "tool", tool_call_id = "t1", tool_name = "read_file",
        content = '{"output":"aws_access_key_id = AKIAIOSFODNN7EXAMPLE"}',
      },
    })
    local text = buffer_text(buf)
    t.matches("⚠ 密钥：read_file", text, "原始具名密钥也应告警")
    local marks = secret_extmarks(buf)
    t.true_(#marks >= 2, "应有告警行与行内密钥高亮（实际 " .. #marks .. "）")
  end)

  it("无密钥的工具结果仍按原样截断", function(t)
    local pad = string.rep("y", 800)
    local buf = render({
      {
        role = "assistant", content = "",
        tool_calls = {
          { id = "t1", ["function"] = { name = "read_file", arguments = '{"file_path":"/tmp/a.txt"}' } },
        },
      },
      { role = "tool", tool_call_id = "t1", tool_name = "read_file", content = '{"output":"' .. pad .. '"}' },
    })
    t.false_(buffer_text(buf):find(pad, 1, true) ~= nil, "无密钥时结果应保持 500 字截断")
  end)

  it("观测到密钥文件：告警行高亮在后续增量刷新后仍保留", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    message_list.reset()
    local buf = vim.api.nvim_create_buf(false, true)
    local base = {
      {
        role = "assistant", content = "",
        tool_calls = {
          { id = "t1", ["function"] = { name = "read_file", arguments = '{"file_path":"/tmp/plain.txt"}' } },
        },
      },
      {
        role = "tool", tool_call_id = "t1", tool_name = "read_file", duration_ms = 5,
        content = '{"output":"ok"}', secret_paths = { "/root/.ssh/id_rsa" },
      },
    }
    message_list.render_chat(buf, base, {})
    local obs_text = buffer_text(buf)
    t.matches("观测到密钥文件：", obs_text, "应给出观测告警标题")
    t.matches("/root/%.ssh/id_rsa", obs_text, "应给出观测到的密钥文件")
    local wl = warning_line(buf)
    t.not_nil(wl, "应找到观测告警行")
    -- 主行 + 观测到密钥文件标题 + 路径 = 3 行整行高亮
    t.eq(3, #secret_extmarks(buf), "应有 3 行告警整行高亮")
    -- 追加下一条消息触发增量刷新：告警行位于差异区间之前，其整行高亮不应被清除
    local updated = vim.deepcopy(base)
    updated[#updated + 1] = { role = "assistant", content = "done" }
    message_list.render_chat(buf, updated, {})
    local marks = secret_extmarks(buf)
    t.eq(3, #marks, "增量刷新后告警行高亮应保留（实际 " .. #marks .. "）")
    t.eq(wl - 1, marks[1][2], "高亮仍应位于告警行")
  end)

  it("增量刷新：结果从无密钥变为含密钥时补上高亮", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    message_list.reset()
    local buf = vim.api.nvim_create_buf(false, true)
    local base = {
      {
        role = "assistant", content = "",
        tool_calls = {
          { id = "t1", ["function"] = { name = "read_file", arguments = '{"file_path":"/root/.env"}' } },
        },
      },
      { role = "tool", tool_call_id = "t1", tool_name = "read_file", content = '{"output":"nothing"}' },
    }
    message_list.render_chat(buf, base, {})
    t.eq(0, #secret_extmarks(buf), "初始无密钥不应有高亮")
    -- 结果更新为含密钥
    local updated = vim.deepcopy(base)
    updated[2].content = '{"output":"TOKEN=' .. fake_of("Zx9Kd-Qm2Lp5Zr8Tv1Wn4Bc") .. '"}'
    message_list.render_chat(buf, updated, {})
    t.matches("⚠ 密钥：read_file", buffer_text(buf), "更新后应有警告行并指明工具")
    -- 3 行警告整行高亮 + 结果行内 token 一处
    t.eq(4, #secret_extmarks(buf), "更新后多行警告 + 结果行内 token 高亮")
  end)

  it("被密钥硬拦截的错误结果：不渲染内部标识告警行", function(t)
    local buf = render({
      {
        role = "assistant", content = "",
        tool_calls = {
          {
            id = "t1",
            ["function"] = {
              name = "run_command",
              arguments = '{"command":"env | grep -i proxy; ls -la /root/test/apps/python/.venv/bin/python*","description":"检查代理环境变量与 venv 可执行文件"}',
            },
          },
        },
      },
      {
        role = "tool", tool_call_id = "t1", tool_name = "run_command", duration_ms = 0,
        content = '{"error":"SANDBOX_SECRET_BLOCKED: 工具参数包含原始密钥，已终止 Agent","tool":"run_command"}',
      },
    })
    local text = buffer_text(buf)
    t.false_(text:find("⚠ 密钥", 1, true) ~= nil, "被拦截的错误结果不应再触发密钥告警")
    t.false_(text:find("密钥环境变量", 1, true) ~= nil, "不应把内部标识当作密钥环境变量名")
    t.eq(0, #secret_extmarks(buf), "不应有密钥高亮")
  end)
end)
