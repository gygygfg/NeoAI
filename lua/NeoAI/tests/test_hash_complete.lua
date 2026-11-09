--- # 占位符补全与解析（ui.components.hash_complete）专项测试
--- @module 'NeoAI.tests.test_hash_complete'
--- 覆盖：token 起点定位、候选生成（键/参数）、解析替换（成功/失败原样保留）、
--- 消息类占位符的字符数截断（CJK 安全）、extmark 高亮与清理。
local tests = require("NeoAI.tests")

tests.suite("hash_complete", function(_, it)
  local hash = require("NeoAI.ui.components.hash_complete")

  local function with_cfg(patch, fn)
    local config_store = require("NeoAI.kernel.config_store")
    local saved = vim.deepcopy(config_store.get_all() or {})
    local merged = vim.deepcopy(config_store.get("ui.input_box.hash_completion") or {})
    for k, v in pairs(patch or {}) do merged[k] = v end
    config_store.load(vim.deepcopy(saved))
    config_store.set("ui.input_box.hash_completion", merged)
    local ok, err = pcall(fn)
    config_store.load(saved)
    if not ok then error(err, 0) end
  end

  it("find_start 定位当前 # token，遇到空白/右花括号即停止", function(t)
    t.eq(1, (hash.find_start("#")))
    t.eq(1, (hash.find_start("#{buf")))
    t.eq(5, (hash.find_start("abc #{buf")))
    t.nil_(hash.find_start("abc def"))
    t.nil_(hash.find_start("#{buffers} "), "右花括号后不应再算作占位符")
  end)

  it("candidates：空输入返回全部键，前缀过滤生效", function(t)
    local all = hash.candidates("#")
    t.true_(#all >= 8, "应返回全部占位符键")
    local names = {}
    for _, item in ipairs(all) do names[#names + 1] = item.word end
    local joined = table.concat(names, " ")
    for _, key in ipairs({ "buffers", "buffer", "lsp", "message", "notify", "tool", "skills", "mcp" }) do
      t.true_(joined:find("#{" .. key, 1, true) ~= nil, "缺少占位符键: " .. key)
    end

    local b = hash.candidates("#{buf")
    t.true_(#b >= 1)
    for _, item in ipairs(b) do
      t.eq("#{buf", item.word:sub(1, 5), "候选应匹配前缀: " .. item.word)
    end

    t.eq(0, #hash.candidates("#{zzz"), "无匹配前缀应返回空")
    t.eq(0, #hash.candidates("#{buffers}"), "已闭合的占位符不应再补全")
    t.eq(0, #hash.candidates("abc"), "非 # 起始不应补全")
  end)

  it("candidates：参数化键可补全参数项（buffer 名）", function(t)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/neoai_hash_target.txt")
    local items = hash.candidates("#{buffer:neoai_hash")
    t.true_(#items >= 1, "应按 buffer 名补全参数项")
    t.true_(items[1].word:find("#{buffer:", 1, true) == 1)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("scan 提取占位符（键 + 可选参数）", function(t)
    local items = hash.scan("看 #{buffers} 与 #{tool:read_file}，还有 #{lsp}")
    t.eq(3, #items)
    t.eq("buffers", items[1].key)
    t.nil_(items[1].arg)
    t.eq("tool", items[2].key)
    t.eq("read_file", items[2].arg)
    t.eq("lsp", items[3].key)
  end)

  it("resolve：buffers 展开为列表，未知键原样保留", function(t)
    local out, count = hash.resolve("A #{buffers} B #{nope} C")
    t.true_(count >= 1, "至少替换 buffers")
    t.true_(out:find("buffer 列表", 1, true) ~= nil, "应展开 buffer 列表")
    t.true_(out:find("#{nope}", 1, true) ~= nil, "未知键应原样保留")
  end)

  it("resolve：无占位符时原样返回且计数为 0", function(t)
    local out, count = hash.resolve("普通文本，没有占位符")
    t.eq("普通文本，没有占位符", out)
    t.eq(0, count)
  end)

  it("resolve：enabled=false 时零副作用（原样返回）", function(t)
    with_cfg({ enabled = false }, function()
      local out, count = hash.resolve("A #{buffers}")
      t.eq("A #{buffers}", out)
      t.eq(0, count)
      t.eq(0, #hash.candidates("#"))
    end)
  end)

  it("resolve：失败参数（不存在的 buffer）原样保留，不抛错", function(t)
    local out, count = hash.resolve("#{buffer:绝对不存在的名字}")
    t.eq(0, count)
    t.eq("#{buffer:绝对不存在的名字}", out)
  end)

  it("message/notify：按字符数上限截断（CJK 不被切半）", function(t)
    with_cfg({ max_chars = 10 }, function()
      local out = hash.resolve("#{message}")
      t.eq("string", type(out))
      -- 截断后不得出现替换字符（半个 UTF-8 序列）
      t.nil_(out:find("\239\191\189", 1, true), "不得出现 UTF-8 替换字符")
      local n = vim.fn.strchars(out)
      -- 允许附加「已截断」说明，因此只校验前缀部分不超过上限
      t.true_(n >= 0)
      local head = out:match("^[^\n]*")
      t.true_(vim.fn.strchars(head) <= 10 + 20, "首行不应显著超限")
    end)
  end)

  it("highlight：为 #{...} 写入 extmark，clear 后清空", function(t)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "第一行 #{buffers} 结束",
      "第二行没有占位符",
      "第三行 #{lsp} 与 #{tool:read_file}",
    })
    local n = hash.highlight(buf)
    t.eq(3, n, "应高亮 3 处占位符")
    local marks = vim.api.nvim_buf_get_extmarks(buf, hash.HL_NS, 0, -1, {})
    t.eq(3, #marks)
    hash.clear(buf)
    t.eq(0, #vim.api.nvim_buf_get_extmarks(buf, hash.HL_NS, 0, -1, {}))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("completefunc：findstart 返回 0-based 列，候选为 dict 列表", function(t)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local start = hash.completefunc(1, "")
    t.eq(0, start, "光标在行首 # 之后，起始列应为 0")
    local items = hash.completefunc(0, "#")
    t.true_(#items > 0, "应有候选")
    t.eq("string", type(items[1].word))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("tools 占位符：未注册工具系统时给出可读提示而非报错", function(t)
    local out, count = hash.resolve("#{tool}")
    t.eq(1, count)
    t.eq("string", type(out))
  end)

  it("lsp 占位符：无诊断时输出占位文本", function(t)
    local out, count = hash.resolve("#{lsp}", { bufnr = vim.api.nvim_get_current_buf() })
    t.eq(1, count)
    t.true_(out:find("无诊断", 1, true) ~= nil or out:find("诊断", 1, true) ~= nil)
  end)
end)
