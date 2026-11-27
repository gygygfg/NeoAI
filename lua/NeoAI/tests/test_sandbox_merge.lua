--- 三方合并发布回归
--- @module 'NeoAI.tests.test_sandbox_merge'
--- 覆盖发布阶段的三方合并（base/ours/theirs）：
--- 1) 无外部改动 → 直写候选（快路径）；
--- 2) 外部改动非重叠 → 合并写盘，保留外部改动；
--- 3) 外部改动重叠且结果不同 → MERGE_CONFLICT，真实文件零改动；
--- 4) 外部内容已是候选结果 → 幂等跳过；
--- 5) 无 base_blob 的候选仍走严格 CAS；
--- 6) 同步与异步发布语义一致。

local tests = require("NeoAI.tests")

local function await(d, timeout)
  local done, val, err = false, nil, nil
  d:then_(function(v) val = v; done = true end, function(e) err = e; done = true end)
  vim.wait(timeout or 8000, function() return done end, 10)
  return val, err
end

local function sha(content)
  return "sha256:" .. vim.fn.sha256(content or "")
end

tests.suite("sandbox_merge", function(_, it)
  local function setup()
    local store = require("NeoAI.sandbox.state.store")
    local fs = require("NeoAI.utils.fs")
    store.init(vim.fn.tempname())
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    return store, fs, dir
  end

  --- 构造一个 modify 候选（含 base_blob）。
  local function build_modify(fs, dir, name, base, ours)
    local base_file = dir .. "/.base_" .. name
    fs.write_file(base_file, base)
    return {
      candidate_digest = "sha256:merge_" .. name,
      files = {
        {
          path = dir .. "/" .. name,
          action = "modify",
          base_exists = true,
          base_type = "file",
          base_blob = base_file,
          before_hash = sha(base),
          after_hash = sha(ours),
          content = ours,
          mode = 420,
        },
      },
      created_at = 1,
      effect = "fs_write",
    }
  end

  it("无外部改动：直写候选内容", function(t)
    local store, fs, dir = setup()
    local base = "a\nb\nc\n"
    local ours = "a\nB\nc\n"
    local p = dir .. "/plain.txt"
    fs.write_file(p, base)
    local cand = build_modify(fs, dir, "plain.txt", base, ours)
    local res = require("NeoAI.sandbox.execution.candidate").publish(cand)
    t.true_(res.ok, "应成功: " .. tostring(res.reason))
    t.eq(ours, fs.read_file(p), "应写入候选内容")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("外部非重叠改动：合并写盘并保留外部改动（同步）", function(t)
    local store, fs, dir = setup()
    local base = "a\nb\nc\n"
    local ours = "a\nB\nc\n"     -- 改第 2 行
    local theirs = "a\nb\nC\n"   -- 外部改第 3 行
    local p = dir .. "/m1.txt"
    fs.write_file(p, theirs)     -- 外部已改动
    local cand = build_modify(fs, dir, "m1.txt", base, ours)
    local res = require("NeoAI.sandbox.execution.candidate").publish(cand)
    t.true_(res.ok, "应成功: " .. tostring(res.reason))
    t.eq("a\nB\nC\n", fs.read_file(p), "应合并双方改动")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("外部重叠冲突：MERGE_CONFLICT 且真实文件零改动（同步）", function(t)
    local store, fs, dir = setup()
    local base = "a\nb\nc\n"
    local ours = "a\nX\nc\n"
    local theirs = "a\nY\nc\n"
    local p = dir .. "/c1.txt"
    fs.write_file(p, theirs)
    local cand = build_modify(fs, dir, "c1.txt", base, ours)
    local res = require("NeoAI.sandbox.execution.candidate").publish(cand)
    t.false_(res.ok, "应冲突")
    t.eq("CONFLICT", res.state)
    t.matches("^MERGE_CONFLICT", res.reason or "", "应为合并冲突")
    t.eq(theirs, fs.read_file(p), "冲突时真实文件不得改动")
    t.not_nil(res.conflicts and res.conflicts[1], "应带冲突详情")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("外部内容已是候选结果：幂等跳过", function(t)
    local store, fs, dir = setup()
    local base = "a\nb\nc\n"
    local ours = "a\nB\nc\n"
    local p = dir .. "/idem.txt"
    fs.write_file(p, ours)
    local cand = build_modify(fs, dir, "idem.txt", base, ours)
    local res = require("NeoAI.sandbox.execution.candidate").publish(cand)
    t.true_(res.ok, "幂等应成功: " .. tostring(res.reason))
    t.eq(ours, fs.read_file(p), "内容应保持候选结果")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("幂等按内容判定：after_hash 为 stat 签名/缺失时也不写盘、不报合并冲突", function(t)
    local store, fs, dir = setup()
    local base = "a\nb\nc\n"
    local ours = "a\nB\nc\n"
    local p = dir .. "/idem_sig.txt"
    fs.write_file(p, ours) -- 同一改动已由另一单元落盘
    local writer = require("NeoAI.sandbox.execution.writer")
    for _, after in ipairs({ "sig:1:2:6", nil }) do
      local apply_calls = 0
      local orig_apply = writer.apply
      writer.apply = function(...)
        apply_calls = apply_calls + 1
        return orig_apply(...)
      end
      local cand = build_modify(fs, dir, "idem_sig.txt", base, ours)
      cand.files[1].after_hash = after
      local ok, res = pcall(require("NeoAI.sandbox.execution.candidate").publish, cand)
      writer.apply = orig_apply
      t.true_(ok, "发布不应报错: " .. tostring(res))
      t.true_(res.ok, ("after_hash=%s 时内容已落盘应幂等成功: %s"):format(
        tostring(after), tostring(res.reason)))
      t.eq(0, apply_calls, "内容已是候选结果时不应再走写入")
      t.eq(ours, fs.read_file(p), "真实内容不得改动")
    end
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("无 base_blob：仍走严格 CAS（基线变了即冲突）", function(t)
    local store, fs, dir = setup()
    local base = "a\nb\nc\n"
    local ours = "a\nB\nc\n"
    local p = dir .. "/nocap.txt"
    fs.write_file(p, "a\nZ\nc\n") -- 外部改动
    local cand = {
      candidate_digest = "sha256:merge_nocap",
      files = {
        {
          path = p, action = "modify", base_exists = true, base_type = "file",
          before_hash = sha(base), after_hash = sha(ours), content = ours, mode = 420,
        },
      },
      created_at = 1, effect = "fs_write",
    }
    local res = require("NeoAI.sandbox.execution.candidate").publish(cand)
    t.false_(res.ok, "无基线捕获应拒绝")
    t.eq("CONFLICT", res.state)
    t.eq("a\nZ\nc\n", fs.read_file(p), "真实文件不得改动")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("异步发布：外部非重叠改动合并写盘", function(t)
    local store, fs, dir = setup()
    local base = "l1\nl2\nl3\nl4\nl5\n"
    local ours = "l1\nL2\nl3\nl4\nl5\n"
    local theirs = "l1\nl2\nl3\nL4\nl5\n"
    local p = dir .. "/am.txt"
    fs.write_file(p, theirs)
    local cand = build_modify(fs, dir, "am.txt", base, ours)
    local res = await(require("NeoAI.sandbox.execution.candidate").publish_async(cand))
    t.true_(res and res.ok, "异步应成功: " .. tostring(res and res.reason))
    t.eq("l1\nL2\nl3\nL4\nl5\n", fs.read_file(p), "异步应合并双方改动")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("异步发布：外部重叠冲突且零写入", function(t)
    local store, fs, dir = setup()
    local base = "a\nb\nc\n"
    local ours = "a\nX\nc\n"
    local theirs = "a\nY\nc\n"
    local p = dir .. "/ac.txt"
    fs.write_file(p, theirs)
    local cand = build_modify(fs, dir, "ac.txt", base, ours)
    local res = assert(await(require("NeoAI.sandbox.execution.candidate").publish_async(cand)))
    t.true_(res and not res.ok, "异步应冲突")
    t.eq("CONFLICT", res.state)
    t.matches("^MERGE_CONFLICT", res.reason or "", "应为合并冲突")
    t.eq(theirs, fs.read_file(p), "冲突时真实文件不得改动")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("配置关闭（merge=false）：回退严格 CAS", function(t)
    local store, fs, dir = setup()
    local config_store = require("NeoAI.kernel.config_store")
    local saved = config_store.get("tools.sandbox.review.merge")
    config_store.set("tools.sandbox.review.merge", false)
    local base = "a\nb\nc\n"
    local ours = "a\nB\nc\n"
    local theirs = "a\nb\nC\n"
    local p = dir .. "/off.txt"
    fs.write_file(p, theirs)
    local cand = build_modify(fs, dir, "off.txt", base, ours)
    local res = require("NeoAI.sandbox.execution.candidate").publish(cand)
    t.false_(res.ok, "关闭合并后基线变化应拒绝")
    t.eq("CONFLICT", res.state)
    t.eq(theirs, fs.read_file(p), "真实文件不得改动")
    config_store.set("tools.sandbox.review.merge", saved)
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("合并保留密钥：base/ours 为 token，落盘为真实内容", function(t)
    local store, fs, dir = setup()
    local secret = require("NeoAI.sandbox.secret.secret")
    secret.reset()
    local real1 = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local base_real = "A=1\nKEY=" .. real1 .. "\nC=3\n"
    local ours_real = "A=1\nKEY=" .. real1 .. "\nC=30\n"
    local theirs_real = "A=10\nKEY=" .. real1 .. "\nC=3\n"
    local base_tok = secret.tokenize(base_real)
    local ours_tok = secret.tokenize(ours_real)
    local base_file = dir .. "/.base_secret"
    fs.write_file(base_file, base_tok)
    local p = dir .. "/sec.txt"
    fs.write_file(p, theirs_real)
    local cand = {
      candidate_digest = "sha256:merge_secret",
      files = {
        {
          path = p, action = "modify", base_exists = true, base_type = "file",
          base_blob = base_file, before_hash = sha(base_real), after_hash = sha(ours_real),
          content = ours_tok, mode = 420,
        },
      },
      created_at = 1, effect = "fs_write",
    }
    local res = require("NeoAI.sandbox.execution.candidate").publish(cand)
    t.true_(res.ok, "应成功: " .. tostring(res.reason))
    local got = assert(fs.read_file(p))
    t.true_(got:find(real1, 1, true) ~= nil, "落盘应含真实密钥")
    t.false_(secret.has_token(got), "落盘不应残留 token")
    t.true_(got:find("A=10\n", 1, true) ~= nil, "应保留外部改动 A=10")
    t.true_(got:find("C=30\n", 1, true) ~= nil, "应保留我方改动 C=30")
    secret.reset()
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("异步冻结：空文件基线也捕获 base（空内容不是读取失败）", function(t)
    local store = require("NeoAI.sandbox.state.store")
    local fs = require("NeoAI.utils.fs")
    local config_store = require("NeoAI.kernel.config_store")
    local store_root = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(store_root)
    store.init(store_root)
    local prev_ws = config_store.get("tools.sandbox.workspace_root")
    config_store.set("tools.sandbox.workspace_root", store_root .. "/sb")
    -- 三方合并基线内容需要「内容内联」模式才捕获（默认 inline_candidate_bytes=0 时
    -- 基线内容不读进内存，发布退回 CAS 冲突提示）。本用例专门验证 base blob 捕获。
    local prev_inline = config_store.get("tools.sandbox.inline_candidate_bytes")
    config_store.set("tools.sandbox.inline_candidate_bytes", 8 * 1024 * 1024)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    sandbox.reset()
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/empty.txt"
    fs.write_file(p, "") -- 冻结时基线是空文件
    local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
    candidate.begin(a, assert(store.root()))
    local staged = candidate.stage_path(a.attempt_id, p)
    t.not_nil(staged, "应有暂存路径")
    fs.write_file(staged, "new\n")
    local cand = t.await(candidate.finish_async(a.attempt_id), 20000)
    t.not_nil(cand, "应冻结出候选")
    local entry = cand and cand.files and cand.files[1]
    t.not_nil(entry, "应有文件条目")
    t.eq("modify", entry and entry.action, "应判定为 modify")
    -- 空基线必须落成 merge base：否则发布阶段只能静默回退 CAS（BASELINE_CHANGED），
    -- 外部一并改动时无冲突详情可交给 AI 重做。
    t.not_nil(entry and entry.base_blob, "空文件基线也应捕获 merge base")
    t.eq("", entry and (entry.base_blob and fs.read_file(entry.base_blob) or nil) or nil,
      "base blob 内容应为空串")
    candidate.cleanup(a.attempt_id)
    config_store.set("tools.sandbox.workspace_root", prev_ws)
    config_store.set("tools.sandbox.inline_candidate_bytes", prev_inline)
    sandbox.reset()
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("默认（不内联）：候选只带元数据 + blob，不捕获 merge base（回退 CAS）", function(t)
    local store = require("NeoAI.sandbox.state.store")
    local fs = require("NeoAI.utils.fs")
    local config_store = require("NeoAI.kernel.config_store")
    local store_root = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(store_root)
    store.init(store_root)
    local prev_ws = config_store.get("tools.sandbox.workspace_root")
    local prev_inline = config_store.get("tools.sandbox.inline_candidate_bytes")
    config_store.set("tools.sandbox.workspace_root", store_root .. "/sb")
    config_store.set("tools.sandbox.inline_candidate_bytes", 0)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    sandbox.reset()
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/f.txt"
    fs.write_file(p, "old\n")
    local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
    candidate.begin(a, assert(store.root()))
    local staged = candidate.stage_path(a.attempt_id, p)
    t.not_nil(staged, "应有暂存路径")
    fs.write_file(staged, "new\n")
    local cand = t.await(candidate.finish_async(a.attempt_id), 20000)
    t.not_nil(cand, "应冻结出候选")
    local entry = cand and cand.files and cand.files[1]
    t.not_nil(entry, "应有文件条目")
    t.eq("modify", entry and entry.action)
    t.nil_(entry and entry.content, "内容不得内联进内存")
    t.not_nil(entry and entry.blob, "内容应磁盘化为 blob")
    t.eq("new\n", entry and entry.blob and (fs.read_file(entry.blob) or "") or "",
      "blob 应为视图内容（同盘复制）")
    t.nil_(entry and entry.base_blob, "不内联模式不捕获 base blob（发布回退 CAS 冲突提示）")
    candidate.cleanup(a.attempt_id)
    config_store.set("tools.sandbox.workspace_root", prev_ws)
    config_store.set("tools.sandbox.inline_candidate_bytes", prev_inline)
    sandbox.reset()
    store.reset()
    vim.fn.delete(dir, "rf")
  end)
end)
