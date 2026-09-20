--- 待审队列内存缓存回归
--- @module NeoAI.tests.test_review_cache
--- 验证待审队列水合后不再反复读盘：此前 `review.list` 每次调用都
--- `store.list_reviews()`（scandir + 逐文件 JSON 解码），待审堆积到数百/上千时，
--- `supersede_by_paths`（每次工具调用）与状态栏 `pending_summary`（每次重绘多次）
--- 会退化为 O(n²) 磁盘扫描，占满主线程。

local tests = require("NeoAI.tests")

tests.suite("review_cache", function(_, it)
  local function setup()
    local store = require("NeoAI.sandbox.store")
    local review = require("NeoAI.sandbox.review")
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
    local candidate = require("NeoAI.sandbox.candidate")
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
end)
