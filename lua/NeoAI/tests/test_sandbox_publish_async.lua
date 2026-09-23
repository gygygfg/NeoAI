--- 异步发布 / 审批窗渲染上限 / 内存剥离 回归
--- @module NeoAI.tests.test_sandbox_publish_async
--- 覆盖：
--- 1) candidate.publish_async 两阶段（CAS 并行 + 写入并行）在顺序无关候选上正确；
--- 2) 任一 CAS 冲突时不产生任何写入（阶段一为只读）；
--- 3) 顺序敏感候选（git 对象）回落同步发布并保持「对象先于指针」；
--- 4) review.apply_async 端到端应用并落盘；
--- 5) 落盘后内存 item.files 剥离 content，content_for 可按需读取；
--- 6) 审批窗 build_lines 按 max_display_files 折叠并保留整单元审批映射。

local tests = require("NeoAI.tests")

--- 同步等待 Deferred 结果（测试专用）。
local function await(d, timeout)
  local done, val, err = false, nil, nil
  d:then_(function(v) val = v; done = true end, function(e) err = e; done = true end)
  vim.wait(timeout or 8000, function() return done end, 10)
  return val, err
end

local function sha(content)
  return "sha256:" .. vim.fn.sha256(content or "")
end

tests.suite("sandbox_publish_async", function(_, it)
  local function setup()
    local store = require("NeoAI.sandbox.store")
    local review = require("NeoAI.sandbox.review")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/reviews", "p")
    store.init(root)
    review.reset()
    return store, review
  end

  it("publish_async：顺序无关候选并行 CAS+写入，创建与修改均正确", function(t)
    local candidate = require("NeoAI.sandbox.candidate")
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p1 = dir .. "/a.txt"
    local p2 = dir .. "/b.txt"
    fs.write_file(p2, "old")
    local d = candidate.publish_async({
      candidate_digest = "sha256:asyncok",
      files = {
        { path = p1, action = "create", content = "one\n", mode = 420 },
        { path = p2, action = "modify", content = "new\n", before_hash = sha("old"), mode = 420 },
      },
    })
    local res = await(d)
    t.true_(res and res.ok, "异步发布应成功: " .. tostring(res and res.reason))
    t.eq("one\n", fs.read_file(p1), "新建文件内容应正确")
    t.eq("new\n", fs.read_file(p2), "修改文件内容应正确")
    t.eq("COMMITTED", res.state, "应返回已提交状态")
    vim.fn.delete(dir, "rf")
  end)

  it("publish_async：CAS 冲突时不产生任何写入（阶段一为只读）", function(t)
    local candidate = require("NeoAI.sandbox.candidate")
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p1 = dir .. "/first.txt"   -- 本应被创建
    local p2 = dir .. "/second.txt"  -- 已存在 → create 冲突
    fs.write_file(p2, "exists")
    local res = await(candidate.publish_async({
      candidate_digest = "sha256:asisconflict",
      files = {
        { path = p1, action = "create", content = "one\n", mode = 420 },
        { path = p2, action = "create", content = "two\n", mode = 420 },
      },
    }))
    t.true_(res and not res.ok, "应报告冲突")
    t.eq("CONFLICT", res.state, "应为 CONFLICT")
    t.eq(nil, vim.uv.fs_stat(p1), "冲突时不应部分写入其它文件")
    vim.fn.delete(dir, "rf")
  end)

  it("publish_async：git 原子组回落同步且保持对象先于指针", function(t)
    local candidate = require("NeoAI.sandbox.candidate")
    local dir = vim.fn.tempname()
    require("NeoAI.utils.fs").ensure_dir(dir .. "/.git/objects/ab")
    local cand = {
      candidate_digest = "sha256:gitasync",
      files = {
        { path = dir .. "/.git/index", action = "create", content = "idx", mode = 420 },
        { path = dir .. "/.git/objects/ab/cd", action = "create", content = "obj", mode = 420 },
      },
    }
    local writer = require("NeoAI.sandbox.writer")
    local order = {}
    local orig_apply = writer.apply
    writer.apply = function(action, path, content, opts)
      order[#order + 1] = path
      return { ok = true, state = writer.STATE.WRITTEN }
    end
    local res = await(candidate.publish_async(cand, {}))
    writer.apply = orig_apply
    t.true_(res and res.ok, "回落的同步发布应成功: " .. tostring(res and res.reason))
    t.true_(#order >= 2, "应有写入")
    t.matches("objects", order[1] or "", "对象应先写入")
    t.matches("index", order[#order] or "", "指针应后写入")
    vim.fn.delete(dir, "rf")
  end)

  it("review.apply_async：端到端应用并更新状态", function(t)
    local store, review = setup()
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/apply.txt"
    local cand = {
      candidate_digest = "sha256:reviewasync",
      files = { { path = p, action = "create", content = "hi\n", mode = 420 } },
      created_at = 1, effect = "fs_write",
    }
    store.write_candidate(cand)
    local item = review.enqueue(cand, { tool = "edit_file" })
    local res = await(review.apply_async(item.change_set_id, { auto_approve = true }))
    t.true_(res and res.ok, "异步应用应成功: " .. tostring(res and res.reason))
    t.eq("hi\n", fs.read_file(p), "文件应落盘")
    local after = review.get(item.change_set_id)
    t.eq(review.APPLY.APPLIED, after.apply_state, "条目应标记已应用")
    store.reset()
    review.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("内存剥离：落盘后 item.files 无 content，content_for 按需读取", function(t)
    local store, review = setup()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = dir .. "/lazy.txt"
    local cand = {
      candidate_digest = "sha256:lazy",
      files = { { path = p, action = "create", after_hash = "h", content = "lazy-content" } },
      created_at = 1,
    }
    store.write_candidate(cand)
    local item = review.enqueue(cand, { tool = "edit_file" })
    t.eq(nil, (item.files[1] or {}).content, "内存条目应已剥离 content")
    t.eq("lazy-content", review.content_for(item.change_set_id, p), "content_for 应按候选读取")
    t.eq("lazy-content", review.content_for(item.change_set_id, p), "LRU 二次读取应一致")
    store.reset()
    review.reset()
  end)

  it("终态淘汰：超过 terminal_cache_max 的已拒绝项从内存移除，get 回读磁盘", function(t)
    local store, review = setup()
    local config_store = require("NeoAI.kernel.config_store")
    local saved = config_store.get("tools.sandbox.review.terminal_cache_max")
    config_store.set("tools.sandbox.review.terminal_cache_max", 2)
    local ids = {}
    for i = 1, 5 do
      local cand = {
        candidate_digest = "sha256:term" .. i,
        files = { { path = "/tmp/term" .. i, action = "create", content = "x" } },
        created_at = i,
      }
      store.write_candidate(cand)
      local item = review.enqueue(cand, { tool = "edit_file" })
      ids[i] = item.change_set_id
    end
    for i = 1, 3 do review.reject(ids[i], "test") end
    -- 5 项中 3 项终态、2 项待审；终态上限 2 → 应淘汰 1 项（最早拒绝者）。
    t.eq(4, review._memory_count(), "超过上限的终态项应从内存淘汰")
    local back = review.get(ids[1])
    t.not_nil(back, "淘汰项应可从磁盘回读")
    t.eq(review.REVIEW.REJECTED, back.review_state, "回读状态应正确")
    config_store.set("tools.sandbox.review.terminal_cache_max", saved)
    store.reset()
    review.reset()
  end)

  it("审批窗：超过 max_display_files 折叠为汇总行且映射整单元审批", function(t)
    local sr = require("NeoAI.ui.components.sandbox_review")
    local config_store = require("NeoAI.kernel.config_store")
    local saved = config_store.get("tools.sandbox.review.max_display_files")
    config_store.set("tools.sandbox.review.max_display_files", 2)
    local files = {}
    for i = 1, 6 do files[i] = { path = "/tmp/cap/" .. i .. ".txt", action = "create" } end
    local data = sr.build_lines({ { change_set_id = "csCap", tool = "edit_file", files = files } })
    local rest_line, whole
    for ln, tgt in pairs(data.line_to_target) do
      if tgt.whole and tgt.change_set_id == "csCap" then whole = whole or ln end
    end
    for i, line in ipairs(data.lines) do
      if type(line) == "string" and line:find("其余 4 个文件", 1, true) then rest_line = i end
    end
    t.not_nil(rest_line, "应生成「其余 4 个文件」汇总行")
    t.not_nil(whole, "应存在整单元审批映射（头行/汇总行）")
    t.eq("csCap", data.line_to_target[rest_line].change_set_id, "汇总行应映射到整单元")
    t.true_(data.line_to_target[rest_line].whole == true, "汇总行应为整单元审批")
    config_store.set("tools.sandbox.review.max_display_files", saved)
  end)

  it("内容磁盘化：blobify 把内容移入 blob，候选不再内嵌，发布按 blob 写盘", function(t)
    local candidate = require("NeoAI.sandbox.candidate")
    local store = require("NeoAI.sandbox.store")
    local fs = require("NeoAI.utils.fs")
    local root = vim.fn.tempname()
    store.init(root)
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/blobbed.txt"
    local cand = {
      candidate_digest = "sha256:blobify1",
      files = { { path = p, action = "create", content = "payload\n", mode = 420, after_hash = sha("payload\n") } },
      created_at = 1,
    }
    candidate.blobify(cand)
    t.nil_(cand.files[1].content, "内容应从候选条目剥离")
    t.not_nil(cand.files[1].blob, "候选条目应记 blob")
    t.eq("payload\n", fs.read_file(cand.files[1].blob) or "", "blob 应含内容")
    local res = candidate.publish(cand)
    t.true_(res.ok, "按 blob 发布应成功: " .. tostring(res.reason))
    t.eq("payload\n", fs.read_file(p) or "", "真实文件内容应正确")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("内容磁盘化：blob 内 token 化内容发布时还原为真实密钥", function(t)
    local candidate = require("NeoAI.sandbox.candidate")
    local store = require("NeoAI.sandbox.store")
    local secret = require("NeoAI.sandbox.secret")
    local fs = require("NeoAI.utils.fs")
    secret.reset()
    store.init(vim.fn.tempname())
    local real = "sk-Ab3xY9pQ2mNv7Kd4Lw8Zr1Tg6Hs5"
    local text = "KEY=" .. real .. "\n"
    local tokenized = secret.tokenize(text)
    t.true_(not tostring(tokenized):find(real, 1, true), "token 化内容不应含真实密钥")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/secret.env"
    local cand = {
      candidate_digest = "sha256:blobsecret",
      files = { { path = p, action = "create", content = tokenized, mode = 420, after_hash = sha(tokenized) } },
      created_at = 1,
    }
    candidate.blobify(cand)
    local res = candidate.publish(cand)
    t.true_(res.ok, "发布应成功: " .. tostring(res.reason))
    local content = fs.read_file(p) or ""
    t.true_(content:find(real, 1, true) ~= nil, "真实文件应还原为原始密钥")
    t.false_(secret.has_token(content), "真实文件不应残留 token")
    secret.reset()
    store.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("内容磁盘化：blobify_async 内嵌内容回退路径写入 blob", function(t)
    local candidate = require("NeoAI.sandbox.candidate")
    local store = require("NeoAI.sandbox.store")
    local fs = require("NeoAI.utils.fs")
    store.init(vim.fn.tempname())
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/async.txt"
    local cand = {
      candidate_digest = "sha256:blobasync",
      files = { { path = p, action = "create", content = "async-payload", mode = 420, after_hash = sha("async-payload") } },
      created_at = 1,
    }
    local res = await(candidate.blobify_async(cand))
    t.not_nil(res, "blobify_async 应完成")
    t.nil_(cand.files[1].content, "内容应剥离")
    t.eq("async-payload", fs.read_file(cand.files[1].blob or "") or "", "blob 应含内容")
    store.reset()
    vim.fn.delete(dir, "rf")
  end)
end)
