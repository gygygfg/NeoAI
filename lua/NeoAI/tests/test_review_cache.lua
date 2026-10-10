--- 待审队列内存缓存回归
--- @module 'NeoAI.tests.test_review_cache'
--- 验证待审队列水合后不再反复读盘：此前 `review.list` 每次调用都
--- `store.list_reviews()`（scandir + 逐文件 JSON 解码），待审堆积到数百/上千时，
--- `supersede_by_paths`（每次工具调用）与状态栏 `pending_summary`（每次重绘多次）
--- 会退化为 O(n²) 磁盘扫描，占满主线程。

local tests = require("NeoAI.tests")

tests.suite("review_cache", function(_, it)
  ---@return table<string, any>, table<string, any>
  local function setup()
    local store = require("NeoAI.sandbox.state.store")
    local review = require("NeoAI.sandbox.review.review")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/reviews", "p")
    store.init(root)
    review.reset()
    return store, review
  end

  it("list/pending_summary 水合后不再读盘，且计数正确", function(t)
    local store, review = setup()
    for i = 1, 30 do
      review.enqueue({
        candidate_digest = "sha256:c" .. i,
        files = { { path = "/tmp/f" .. i, action = "modify" } },
        created_at = i,
      }, { tool = "edit_file" })
    end
    -- 触发一次水合（此后以内存为准）
    t.eq(30, review.pending_count())

    local orig = store.list_reviews
    local calls = 0
    store.list_reviews = function(...)
      calls = calls + 1
      return orig(...)
    end
    review.pending_summary()
    review.list({ review_state = review.REVIEW.PENDING })
    review.supersede_by_paths({ "/tmp/f1" }, nil)
    store.list_reviews = orig
    t.eq(0, calls, "水合后 list/pending_summary/supersede 不应再读盘")
    t.eq(29, review.pending_count(), "supersede 后待审应减 1")

    store.reset()
    review.reset()
  end)

  it("pending_summary 按文件计数并报告最高级别", function(t)
    local store, review = setup()
    review.enqueue({
      candidate_digest = "sha256:a",
      files = { { path = "/a" }, { path = "/b" } },
      created_at = 1,
    }, { tool = "x", risk_level = 2 })
    review.enqueue({
      candidate_digest = "sha256:b",
      files = { { path = "/c" } },
      created_at = 2,
    }, { tool = "x", risk_level = 3 })
    local sum = review.pending_summary()
    t.eq(3, sum.count, "应按文件总数计数")
    t.eq(3, sum.max_level, "应报告最高风险级别")
    store.reset()
    review.reset()
  end)

  it("pending_summary 缓存：变更后自动失效（计数不陈旧）", function(t)
    local store, review = setup()
    review.enqueue({
      candidate_digest = "sha256:c1",
      files = { { path = "/tmp/f1" } },
      created_at = 1,
    }, { tool = "x" })
    t.eq(1, review.pending_summary().count, "初始待审计数")
    -- 再次读取命中缓存
    t.eq(1, review.pending_summary().count)
    -- 新增待审项：写盘应失效缓存，下一次读取须反映新计数
    review.enqueue({
      candidate_digest = "sha256:c2",
      files = { { path = "/tmp/f2" } },
      created_at = 2,
    }, { tool = "x" })
    t.eq(2, review.pending_summary().count, "新增后计数应更新（缓存失效）")
    -- 取代一项：也应失效缓存
    review.supersede_by_paths({ "/tmp/f1" }, nil)
    t.eq(1, review.pending_summary().count, "取代后计数应更新（缓存失效）")
    store.reset()
    review.reset()
  end)

  it("重新水合：reset 后从磁盘恢复历史待审项", function(t)
    local store, review = setup()
    store.write_review({
      change_set_id = "cs_hist",
      review_state = "PENDING",
      apply_state = "NOT_REQUESTED",
      files = { { path = "/tmp/hist" } },
      created_at = 1,
    })
    -- reset 后首次访问应从磁盘水合出历史项
    review.reset()
    t.eq(1, review.pending_count(), "应从磁盘恢复历史待审项")
    store.reset()
    review.reset()
  end)

  it("supersede 大量待审项：批量删除不逐项全表扫描（避免 O(n²)）", function(t)
    local store, review = setup()
    local paths = {}
    for i = 1, 200 do
      paths[i] = "/tmp/f" .. i
      review.enqueue({
        candidate_digest = "sha256:d" .. i,
        files = { { path = "/tmp/f" .. i } },
        created_at = i,
      }, { tool = "edit_file" })
    end
    review.pending_summary()
    local before = review._ref_scans()
    local n = review.supersede_by_paths(paths, nil)
    t.eq(200, n, "应取代全部待审项")
    t.eq(0, review.pending_count(), "取代后待审应清空")
    t.eq(before, review._ref_scans(), "批量取代不应触发逐项全表扫描")
    store.reset()
    review.reset()
  end)

  it("apply_all 大量项：候选删除批量对账，不逐项全表扫描（避免 O(n²)）", function(t)
    local store, review = setup()
    ---@type table<string, any>
    local candidate = require("NeoAI.sandbox.execution.candidate")
    for i = 1, 100 do
      store.write_candidate({
        candidate_digest = "sha256:e" .. i,
        files = { { path = "/tmp/apply" .. i, action = "modify", content = "x",
          after_hash = "sha256:x", before_hash = "sha256:b" } },
        created_at = i,
      })
      review.enqueue({
        candidate_digest = "sha256:e" .. i,
        files = { { path = "/tmp/apply" .. i, action = "modify" } },
        created_at = i,
      }, { tool = "edit_file" })
    end
    -- 隔离发布：只验证删除对账的扫描次数，不落真实文件。
    local orig_publish, orig_receipt = candidate.publish, store.write_receipt
    candidate.publish = function() return { ok = true, receipt = { operation_id = "op" } } end
    store.write_receipt = function() return true end
    local before = review._ref_scans()
    local res = review.apply_all()
    candidate.publish, store.write_receipt = orig_publish, orig_receipt
    t.eq(100, res.applied, "应全部应用")
    t.eq(0, res.failed, "不应有失败")
    t.eq(before, review._ref_scans(), "批量应用不应逐项全表扫描引用")
    store.reset()
    review.reset()
  end)

  it("begin_batch/end_batch：逐项应用候选删除一次对账，不逐项全表扫描", function(t)
    local store, review = setup()
    ---@type table<string, any>
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local ids = {}
    for i = 1, 100 do
      store.write_candidate({
        candidate_digest = "sha256:g" .. i,
        files = { { path = "/tmp/batch" .. i, action = "modify", content = "x",
          after_hash = "sha256:x", before_hash = "sha256:b" } },
        created_at = i,
      })
      local item = review.enqueue({
        candidate_digest = "sha256:g" .. i,
        files = { { path = "/tmp/batch" .. i, action = "modify" } },
        created_at = i,
      }, { tool = "edit_file" })
      ids[i] = item.change_set_id
    end
    -- 隔离发布：只验证删除对账的扫描次数，不落真实文件。
    local orig_publish, orig_receipt = candidate.publish, store.write_receipt
    candidate.publish = function() return { ok = true, receipt = { operation_id = "op" } } end
    store.write_receipt = function() return true end
    local before = review._ref_scans()
    local ctx = review.begin_batch()
    for i = 1, 100 do
      review.apply(ids[i], { auto_approve = true, batch = ctx })
    end
    review.end_batch(ctx)
    candidate.publish, store.write_receipt = orig_publish, orig_receipt
    t.eq(before, review._ref_scans(), "批量会话不应逐项全表扫描引用")
    t.eq(0, review.pending_count(), "全部应用后待审应清空")
    store.reset()
    review.reset()
  end)

  it("部分取代：包安装单元不因单个 .pyc 改动被整单元丢弃（保留 .py/dist-info）", function(t)
    local store, review = setup()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/dashscope/__pycache__", "p")
    vim.fn.mkdir(dir .. "/dashscope-1.27.6.dist-info", "p")
    local p_py = dir .. "/dashscope/__init__.py"
    local p_meta = dir .. "/dashscope-1.27.6.dist-info/METADATA"
    local p_pyc = dir .. "/dashscope/__pycache__/__init__.cpython-311.pyc"
    local candA = {
      candidate_digest = "sha256:pkgA",
      files = {
        { path = p_py, action = "create", after_hash = "hp", content = "x" },
        { path = p_meta, action = "create", after_hash = "hm", content = "m" },
        { path = p_pyc, action = "create", after_hash = "hc", content = "c" },
      },
      created_at = 1,
    }
    store.write_candidate(candA)
    local A = review.enqueue(candA, { tool = "run_command", package = true, package_key = "pip:dashscope" })
    local candB = {
      candidate_digest = "sha256:pkgB",
      files = { { path = p_pyc, action = "modify", after_hash = "hc2", content = "c2" } },
      created_at = 2,
    }
    store.write_candidate(candB)
    local B = review.enqueue(candB, { tool = "run_command", package = true, package_key = "pip:*" })
    t.true_(A ~= nil and B ~= nil, "两个变更单元都应入队")
    -- 后续命令只改动 .pyc：只应登记该路径为「被取代」，其余文件保留待审
    review.supersede_by_paths({ p_pyc }, B.change_set_id)
    local A2 = review.get(A.change_set_id)
    t.eq(review.REVIEW.PENDING, A2.review_state, "包安装单元应保持待审（不被整单元取代）")
    t.true_(A2.superseded_paths and A2.superseded_paths[p_pyc], "应登记被取代的 .pyc")
    t.eq(A.candidate_digest, A2.candidate_digest, "部分取代不应重编码整候选（保持摘要不变）")
    t.not_nil(store.read_candidate(A2.candidate_digest), "候选保持有效（未重编码整单元）")
    -- 目标包文件（.py/dist-info）未被取代
    t.true_(not (A2.superseded_paths and (A2.superseded_paths[p_py] or A2.superseded_paths[p_meta])),
      "不应取代 .py/dist-info")
    -- B 仍为待审（持有被取代的 .pyc）
    t.eq(review.REVIEW.PENDING, review.get(B.change_set_id).review_state, "新单元应保持待审")
    -- 待审计数应扣除被取代路径：A 剩 2 + B 的 1 = 3
    t.eq(3, review.pending_summary().count, "待审计数应扣除被取代路径")
    -- 应用 A 时不得写入被取代的 .pyc（该路径归新单元），但必须写入 .py/dist-info
    ---@type table<string, any>
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local orig_pub, orig_receipt = candidate.publish, store.write_receipt
    local published
    candidate.publish = function(c)
      published = {}
      for _, f in ipairs(c.files) do published[f.path] = true end
      return { ok = true, state = "COMMITTED", receipt = { operation_id = "op_pkg" } }
    end
    store.write_receipt = function() return true end
    local res = review.apply(A.change_set_id, { auto_approve = true })
    candidate.publish, store.write_receipt = orig_pub, orig_receipt
    t.true_(res.ok, "应用应成功: " .. tostring(res and res.reason))
    t.true_(published and published[p_py], "应写入 __init__.py")
    t.true_(published and published[p_meta], "应写入 dist-info")
    t.true_(published and not published[p_pyc], "不应写入被取代的 .pyc")
    store.reset()
    review.reset()
  end)

  it("取代：git 原子组整组取代（不可拆分）", function(t)
    local store, review = setup()
    local dir = vim.fn.tempname()
    local cand = {
      candidate_digest = "sha256:gitA",
      files = {
        { path = dir .. "/.git/objects/ab/cd", action = "create", after_hash = "o", content = "o" },
        { path = dir .. "/.git/index", action = "modify", after_hash = "i", content = "i" },
        { path = dir .. "/work.txt", action = "modify", after_hash = "w", content = "w" },
      },
      created_at = 1,
    }
    store.write_candidate(cand)
    local item = review.enqueue(cand, { tool = "git_add" })
    t.eq("git", item.atomic_group, "应标记 git 原子组")
    review.supersede_by_paths({ dir .. "/work.txt" }, nil)
    local after = review.get(item.change_set_id)
    t.eq(review.REVIEW.SUPERSEDED, after.review_state, "git 原子组应整组取代，不逐文件拆分")
    store.reset()
    review.reset()
  end)

  it("应用兜底：候选文件外部丢失但曾落盘时，从暂存副本重建并应用", function(t)
    local store, review = setup()
    ---@type table<string, any>
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = dir .. "/f.txt"
    local cand = {
      candidate_digest = "sha256:lost",
      files = { { path = p, action = "create", after_hash = "h", content = "hi" } },
      created_at = 1, effect = "fs_write",
    }
    -- 生产路径：候选先并入暂存层（暂存副本保存内容），再冻结候选、入待审。
    candidate.reset()
    candidate.ensure_dirs(store.root())
    candidate.begin_session()
    candidate.merge_candidate(cand)
    store.write_candidate(cand)
    local item = review.enqueue(cand, { tool = "edit_file" })
    t.true_(store.was_written("sha256:lost"), "应记录候选曾写入")
    -- 外部删除候选文件（不经 discard_candidate，模拟实例存储被清理）
    vim.fn.delete(store.root() .. "/candidates/sha256_lost.json")
    t.nil_(store.read_candidate("sha256:lost"), "候选文件应已丢失")
    local orig = candidate.publish
    local published
    candidate.publish = function(c) published = c; return { ok = true, receipt = { operation_id = "op" } } end
    local res = review.apply(item.change_set_id, { auto_approve = true })
    candidate.publish = orig
    t.true_(res and res.ok, "应从暂存副本重建候选并应用: " .. tostring(res and res.reason))
    t.not_nil(published, "应调用 publish")
    t.eq("hi", ((published.files or {})[1] or {}).content, "重建内容应来自暂存副本")
    candidate.reset()
    store.reset()
    review.reset()
  end)

  it("拒绝保留可恢复副本，restore 往返重建候选并回到待审", function(t)
    local store, review = setup()
    local digest = "sha256:rj1"
    local cand = { candidate_digest = digest,
      files = { { path = "/tmp/rj.txt", action = "modify", content = "hi", after_hash = "h" } } }
    store.write_candidate(cand)
    local item = review.enqueue(cand, { tool = "edit_file" })
    review.reject(item.change_set_id, "USER")
    local after_reject = review.get(item.change_set_id)
    t.eq(review.REVIEW.REJECTED, after_reject.review_state, "拒绝后应为 REJECTED")
    t.eq(true, after_reject.rejected_copy, "应标记可恢复（副本已保存）")
    t.not_nil(store.read_rejected_copy(item.change_set_id, digest), "副本应存在")
    t.nil_(store.read_candidate(digest), "候选原件应被删除（副本是唯一来源）")
    t.eq(1, #review.list_rejected(), "list_rejected 应含 1 项")
    t.eq(item.change_set_id, review.list_rejected()[1].change_set_id, "已拒绝列表应含该项")

    local res = review.restore(item.change_set_id)
    t.true_(res.ok, "恢复应成功: " .. tostring(res and res.reason))
    local after = review.get(item.change_set_id)
    t.eq(review.REVIEW.PENDING, after.review_state, "恢复后应为待审")
    t.eq(nil, after.rejected_copy, "恢复后应清除可恢复标记")
    t.not_nil(store.read_candidate(digest), "恢复后候选应重建")
    t.nil_(store.read_rejected_copy(item.change_set_id, digest), "恢复后副本应删除")
    t.eq(0, #review.list_rejected(), "恢复后不再出现在已拒绝列表")
    store.reset()
    review.reset()
  end)

  it("已拒绝项超过 rejected_max 时回收最旧副本并移出内存", function(t)
    local store, review = setup()
    local config_store = require("NeoAI.kernel.config_store")
    local prev = config_store.get("tools.sandbox.review.rejected_max")
    config_store.set("tools.sandbox.review.rejected_max", 2)
    local ids = {}
    for i = 1, 3 do
      local digest = "sha256:ev" .. i
      local cand = { candidate_digest = digest,
        files = { { path = "/tmp/ev" .. i, action = "modify", content = "c" .. i, after_hash = "h" } } }
      store.write_candidate(cand)
      local item = review.enqueue(cand, { tool = "x" })
      ids[i] = item.change_set_id
    end
    review.reject(ids[1], "r")
    review.reject(ids[2], "r")
    review.reject(ids[3], "r")
    t.eq(2, #review.list_rejected(), "超限应只保留 2 个已拒绝项")
    t.nil_(store.read_rejected_copy(ids[1], "sha256:ev1"), "最旧项副本应被删除")
    local found_old = false
    for _, entry in ipairs(review.list_rejected()) do
      if entry.change_set_id == ids[1] then found_old = true end
    end
    t.true_(not found_old, "最旧项不应出现在已拒绝列表")
    -- 较新的两项仍可恢复
    t.not_nil(store.read_rejected_copy(ids[3], "sha256:ev3"), "最新项副本应保留")
    config_store.set("tools.sandbox.review.rejected_max", prev)
    store.reset()
    review.reset()
  end)

  it("[REPRO] 选择性应用多项后：已应用项全部保留 + 剩余文件回队待审", function(t)
    local store, review = setup()
    ---@type table<string, any>
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local base = vim.fn.tempname()
    vim.fn.mkdir(base, "p")
    local function mk(digest, files)
      local cand = { candidate_digest = digest, files = files, created_at = 1 }
      store.write_candidate(cand)
      return cand
    end
    local A = mk("sha256:bsA", {
      { path = base .. "/a.txt", action = "modify", content = "a", after_hash = "ha" },
      { path = "/etc/neoai_sysA", action = "modify", content = "s", after_hash = "hs" },
    })
    local B = mk("sha256:bsB", {
      { path = base .. "/b.txt", action = "modify", content = "b", after_hash = "hb" },
    })
    local C = mk("sha256:bsC", {
      { path = "/etc/neoai_sysC", action = "modify", content = "c", after_hash = "hc" },
    })
    local ia = review.enqueue(A, { tool = "edit_file" })
    local ib = review.enqueue(B, { tool = "edit_file" })
    local _ = review.enqueue(C, { tool = "edit_file" })
    local orig = candidate.publish
    candidate.publish = function()
      return { ok = true, state = "COMMITTED", receipt = { operation_id = "op_repro" } }
    end
    review.apply(ia.change_set_id, { auto_approve = true, files = { base .. "/a.txt" } })
    review.apply(ib.change_set_id, { auto_approve = true, files = { base .. "/b.txt" } })
    candidate.publish = orig
    local applied, pending = 0, 0
    for _, entry in ipairs(review.list()) do
      if entry.apply_state == review.APPLY.APPLIED then applied = applied + 1 end
      if entry.review_state == review.REVIEW.PENDING then pending = pending + 1 end
    end
    t.eq(2, applied, "应有 2 个已应用项（A、B）")
    t.eq(2, pending, "应剩 2 个待审项（C + A 回队的非工作区文件）")
    store.reset()
    review.reset()
  end)
end)
