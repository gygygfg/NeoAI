--- 工具输出限流（tools.builtin.output_guard）+ 沙箱 /tmp 落盘回读专项测试
--- @module NeoAI.tests.test_output_guard
--- 覆盖：小输出原样；超限头+尾+标记；有/无沙箱映射（落盘 vs 降级）；enabled=false；
--- 多字节安全；read_file 经访客路径回读落盘文件。
local tests = require("NeoAI.tests")

tests.suite("output_guard", function(_, it, before_each)
  local og, guest_fs, config_store, stringx

  before_each(function()
    og = require("NeoAI.tools.builtin.output_guard")
    guest_fs = require("NeoAI.sandbox.guest_fs")
    config_store = require("NeoAI.kernel.config_store")
    stringx = require("NeoAI.utils.stringx")
    guest_fs.clear()
  end)

  -- 注册一个临时目录为访客 /tmp（模拟沙箱 bind），返回宿主目录。
  local function mount_tmp()
    local host = vim.fn.tempname() .. "-og"
    vim.fn.mkdir(host, "p")
    guest_fs.set_root("/tmp", host)
    return host
  end

  -- 直接调用 read_file 工具（异步等待）。
  local function invoke_read(args)
    local file_ops = require("NeoAI.tools.builtin.file_ops")
    local tools = {}
    for _, tl in ipairs(file_ops.get_tools()) do tools[tl.name] = tl end
    local result, err, done = nil, nil, false
    tools.read_file.func(args, function(v)
      result, done = v, true
    end, function(e)
      err, done = e, true
    end)
    if not done then vim.wait(15000, function() return done end, 10) end
    return result, err
  end

  it("小输出原样返回", function(t)
    local s = string.rep("a", 100)
    t.eq(s, og.cap(s, { tool = "t" }))
  end)

  it("超限：头+尾+截断标记；无沙箱映射时明确提示未落盘", function(t)
    local big = string.rep("x", 50000)
    local out = og.cap(big, { tool = "t" })
    t.ok(#out < #big, "应被截断")
    t.matches("输出过长已截断", out)
    t.matches("未落盘", out, "无沙箱映射时应提示未落盘")
  end)

  it("超限：有沙箱映射时落盘，原文可回读且一致", function(t)
    mount_tmp()
    local big = string.rep("x", 50000)
    local out = og.cap(big, { tool = "git_log" })
    local p = out:match("/tmp/neoai%-out/[%w_%-%.]+%.log")
    t.not_nil(p, "应给出落盘路径")
    local host = guest_fs.to_host(p)
    t.eq(1, vim.fn.filereadable(host), "落盘文件应存在")
    t.eq(big, table.concat(vim.fn.readfile(host), "\n"), "落盘内容应等于原文")
  end)

  it("enabled=false 时不限流", function(t)
    local saved = config_store.get("tools.output_guard.enabled")
    config_store.set("tools.output_guard.enabled", false)
    local ok, err = pcall(function()
      local big = string.rep("x", 50000)
      t.eq(big, og.cap(big, { tool = "t" }))
    end)
    config_store.set("tools.output_guard.enabled", saved)
    if not ok then error(err, 0) end
  end)

  it("多字节安全：截断结果仍是合法 UTF-8", function(t)
    local big = string.rep("中", 30000)
    local out = og.cap(big, { tool = "t" })
    t.true_(stringx.is_valid_utf8(out), "截断结果应为合法 UTF-8")
    t.ok(vim.fn.strchars(out) < 30000, "字符数应减少")
  end)

  it("头+尾配置非法时自动钳制（不会越截越长）", function(t)
    local big = string.rep("x", 30000)
    -- head+tail 远超 max_chars：应被钳制到收缩后的长度。
    local out = og.cap(big, { tool = "t", max_chars = 1000, head_chars = 5000, tail_chars = 5000 })
    t.ok(#out < 2000, "应收缩到接近 max_chars")
    t.matches("输出过长已截断", out)
  end)

  it("read_file：无解析器大文件返回头+尾并给出落盘路径", function(t)
    mount_tmp()
    -- 造一个多行大文件（内容 > 20000 字符，.log 无 tree-sitter parser）
    local lines = {}
    for i = 1, 5000 do
      lines[i] = string.format("line %04d %s", i, string.rep("z", 20))
    end
    local content = table.concat(lines, "\n")
    local p = guest_fs.tmp_host("/tmp") .. "/seed.log"
    local f = assert(io.open(p, "w"))
    f:write(content)
    f:close()
    -- 以访客路径交给 read_file（模拟工具读取沙箱内文件）
    local r, err = invoke_read({ file_path = "/tmp/seed.log" })
    t.nil_(err, "read_file 不应报错")
    t.matches("文件较大", r)
    t.matches("/tmp/neoai%-out/[%w_%-%.]+%.log", r, "应给出落盘路径")
  end)

  it("read_file：按处理落盘路径的 start_line/end_line 可回读", function(t)
    mount_tmp()
    local lines = {}
    for i = 1, 5000 do
      lines[i] = string.format("line %04d %s", i, string.rep("z", 20))
    end
    local content = table.concat(lines, "\n")
    local out = og.cap(content, { tool = "read_file", label = "doc" })
    local p = out:match("/tmp/neoai%-out/[%w_%-%.]+%.log")
    t.not_nil(p, "应落盘")
    local r, err = invoke_read({ file_path = p, start_line = 1, end_line = 5 })
    t.nil_(err)
    t.matches("line 0001", r)
    t.matches("line 0005", r)
  end)

  it("read_file：大 start_line/end_line 切片同样受限流", function(t)
    mount_tmp()
    local lines = {}
    for i = 1, 5000 do
      lines[i] = string.format("line %04d %s", i, string.rep("z", 20))
    end
    local content = table.concat(lines, "\n")
    local p = guest_fs.tmp_host("/tmp") .. "/slice.log"
    local f = assert(io.open(p, "w"))
    f:write(content)
    f:close()
    local r, err = invoke_read({ file_path = "/tmp/slice.log", start_line = 1, end_line = 5000 })
    t.nil_(err)
    t.matches("输出过长已截断", r, "整文件切片应被限流")
  end)
end)
