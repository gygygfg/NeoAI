--- 密钥判定的「来源」语义：AI 自己生成的值自动放行；工具取到的真密钥才保护
--- @module 'NeoAI.tests.test_secret_provenance'
--- 覆盖：
---   1. 误报收敛：`data-key="statusColor"` / `obj.key = "Value"` 等复合名赋值不再登记为密钥；
---   2. AI 生成：首次出现在工具参数（`origin="ai"`）的高熵值不假化、不登记、不弹窗；
---   3. 端上取到：工具结果（默认 origin）里的真密钥仍登记，上下文守卫仍能命中；
---   4. 告警窗文本单行化：命令/密钥值含换行不再让 `nvim_buf_set_lines` 报错。

local tests = require("NeoAI.tests")

tests.suite("secret_provenance", function(_, it)
  local secret = require("NeoAI.sandbox.secret.secret")

  it("误报收敛：复合名赋值（data-key / obj.key）不登记为原始密钥", function(t)
    secret.reset()
    local sample = 'const colorEl = $(\'[data-key="statusColor"]\');\n'
      .. 'const el = row.dataset.key = "statusColor";\n'
      .. 'data_key="statusColor"\n'
    local out = secret.tokenize(sample, { entropy = false })
    t.eq(sample, out, "普通标识符不应被假化")
    t.eq(nil, secret.find_real_secret("statusColor"), "普通标识符不应登记为原始密钥")
    t.eq(0, #secret.detect_named("data-key=\"statusColor\""), "不应命中具名规则")
  end)

  it("误报收敛：仍能识别真实凭据形态（数字/Base64/随机纯字母）", function(t)
    secret.reset()
    local cases = {
      'api_key = "aB3dE9fG2hJ4kL6m"',
      'password = "Sup3rS3cretValue"',
      'client_secret: "xK9pQ2mN7vR4tW8z"',
    }
    for _, text in ipairs(cases) do
      local out, used = secret.tokenize(text, { entropy = false })
      t.true_(#used > 0, "应识别并假化: " .. text)
      t.true_(out ~= text, "应发生替换: " .. text)
      t.eq(text, (secret.detokenize(out)), "应可无损还原: " .. text)
    end
    secret.reset()
  end)

  it("AI 生成的值：首次出现在工具参数即放行（不假化/不登记/上下文守卫不命中）", function(t)
    secret.reset()
    local generated = "xK9pQ2mN7vR4tW8z" -- 模型自己编的口令
    local text = 'DB_PASSWORD = "' .. generated .. '"'
    local out, used = secret.tokenize(text, { entropy = false, origin = "ai" })
    t.eq(text, out, "AI 生成的值应原样保留（不被假化）")
    t.eq(0, #used, "不应生成 token")
    t.true_(secret.is_ai_generated(generated), "应登记为 AI 生成")
    t.eq(nil, secret.find_real_secret(generated), "不应作为真密钥命中")
    -- 上下文守卫：即便之后原样出现在 AI 上下文中，也不弹窗/不终止。
    t.eq(nil, secret.context_leak({ role = "assistant", content = generated }), "上下文守卫不应命中")
    t.eq(nil, secret.context_leak_from({ { role = "assistant", content = "使用 " .. generated } }, 1),
      "增量守卫不应命中")
    secret.reset()
  end)

  it("工具取到的真密钥：仍登记并触发上下文守卫（AI 生成豁免不削弱保护）", function(t)
    secret.reset()
    local real = "xK9pQ2mN7vR4tW8z" -- 从命令输出中取到的真密钥
    local out, used = secret.tokenize("API_KEY=" .. real, { entropy = false })
    t.true_(#used > 0, "工具结果中的真密钥应被假化")
    t.true_(out ~= "API_KEY=" .. real, "应发生替换")
    t.true_(secret.has_token(out), "应含假密钥 token")
    t.eq(real, secret.find_real_secret("x " .. real), "应登记为真密钥")
    t.not_nil(secret.context_leak({ role = "tool", content = real }), "上下文守卫应命中真密钥")
    -- 同一值后续出现在 AI 参数里：仍按真密钥处理（保守优先）。
    local args_out, args_used = secret.tokenize('OTHER_KEY = "' .. real .. '"', { entropy = false, origin = "ai" })
    t.true_(#args_used > 0, "已知真密钥出现在 AI 参数时仍应假化")
    t.true_(args_out ~= 'OTHER_KEY = "' .. real .. '"', "应发生替换")
    secret.reset()
  end)

  it("告警窗文本单行化：命令/密钥含换行不破坏 nvim_buf_set_lines 输入", function(t)
    local ui = require("NeoAI.ui.components.secret_alert")
    local lines = ui._text({
      kind = "tool",
      tool = "run_command",
      command = "line1\nline2\r\nline3",
      secret = "abc\ndef",
      fake = "xyz\nuvw",
    })
    for i, line in ipairs(lines) do
      t.true_(type(line) == "string", "行应为字符串: " .. tostring(i))
      t.eq(nil, line:find("[\r\n]"), "行不得含换行: " .. line)
    end
    t.true_(table.concat(lines, "\n"):find("line1 line2 line3", 1, true) ~= nil, "命令应被压成单行")
  end)

  it("执行器：出向工具参数按 origin=ai 处理（AI 生成值不登记为真密钥）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local sandbox = require("NeoAI.sandbox")
    local saved = config_store.get_all()
    config_store.load({ tools = { approval = { mode = "auto_allow" }, sandbox = {
      mode = "dry_run", review = { enabled = true },
    } } })
    pcall(sandbox.reset)
    secret.reset()
    local generated = "xK9pQ2mN7vR4tW8z"
    local captured
    local orig = secret.tokenize_args
    secret.tokenize_args = function(args, opts)
      if type(opts) == "table" and opts.origin == "ai" then captured = opts end
      return orig(args, opts)
    end
    local done = false
    require("NeoAI.tools").execute("edit_file", {
      file_path = vim.fn.tempname() .. "_gen_secret.txt",
      mode = "write",
      content = 'DB_PASSWORD = "' .. generated .. '"\n',
      description = "t",
    }, {}):then_(function() done = true end, function() done = true end)
    vim.wait(10000, function() return done end)
    secret.tokenize_args = orig
    config_store.load(saved)
    t.eq("ai", captured and captured.origin, "执行器应以 origin=ai 处理出向参数")
    t.true_(secret.is_ai_generated(generated), "AI 生成值应登记为 ai_generated")
    t.eq(nil, secret.find_real_secret(generated), "AI 生成值不应登记为真密钥（不弹窗）")
    secret.reset()
  end)
end)
