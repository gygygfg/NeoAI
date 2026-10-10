--- 三方合并（merge3）单元测试
--- @module 'NeoAI.tests.test_merge3'
--- 覆盖 diff3 语义：单侧改动取该侧、同区间同结果去重、同区间异结果冲突、
--- 非重叠改动合并、空文件、删除/插入/追加、大文件回退（too_large）。

local tests = require("NeoAI.tests")

tests.suite("merge3", function(_, it)
  it("单侧改动 / 幂等 / 相同改动", function(t)
    local m3 = require("NeoAI.utils.merge3")
    local r = m3.merge("a\nb\nc\n", "a\nB\nc\n", "a\nb\nc\n")
    t.true_(r.ok, "对方未改：应取我方")
    t.eq("a\nB\nc\n", r.merged)

    r = m3.merge("a\nb\nc\n", "a\nb\nc\n", "a\nb\nC\n")
    t.true_(r.ok, "我方未改：应取对方")
    t.eq("a\nb\nC\n", r.merged)

    r = m3.merge("a\nb\nc\n", "a\nX\nc\n", "a\nX\nc\n")
    t.true_(r.ok, "双方改同一内容：应去重")
    t.eq("a\nX\nc\n", r.merged)
  end)

  it("非重叠改动合并", function(t)
    local m3 = require("NeoAI.utils.merge3")
    local r = m3.merge("l1\nl2\nl3\nl4\nl5\n", "l1\nL2\nl3\nl4\nl5\n", "l1\nl2\nl3\nL4\nl5\n")
    t.true_(r.ok, "不同行改动应干净合并")
    t.eq("l1\nL2\nl3\nL4\nl5\n", r.merged)

    -- 替换一行 + 末尾追加：不重叠
    r = m3.merge("a\nb\nc\nd\n", "a\nb\nX\nd\n", "a\nb\nc\nd\ne\n")
    t.true_(r.ok)
    t.eq("a\nb\nX\nd\ne\n", r.merged)
  end)

  it("同区间异结果冲突", function(t)
    local m3 = require("NeoAI.utils.merge3")
    local r = m3.merge("a\nb\nc\n", "a\nX\nc\n", "a\nY\nc\n")
    t.false_(r.ok, "同行不同内容应冲突")
    t.true_(r.conflict)

    -- 同点插入冲突
    r = m3.merge("a\nb\nc\n", "a\nX\nb\nc\n", "a\nY\nb\nc\n")
    t.true_(r.conflict, "同点插入不同内容应冲突")

    -- 双方在末尾追加不同内容
    r = m3.merge("a\nb\nc\n", "a\nb\nc\nd\n", "a\nb\nc\ne\n")
    t.true_(r.conflict, "末尾不同追加应冲突")

    -- 一方删除、另一方修改同一行
    r = m3.merge("a\nb\nc\n", "a\nc\n", "a\nB\nc\n")
    t.true_(r.conflict, "删除与修改同一行应冲突")
  end)

  it("删除 / 插入 / 空文件", function(t)
    local m3 = require("NeoAI.utils.merge3")
    -- 我方删 b，对方末尾加 e
    local r = m3.merge("a\nb\nc\nd\n", "a\nc\nd\n", "a\nb\nc\nd\ne\n")
    t.true_(r.ok)
    t.eq("a\nc\nd\ne\n", r.merged)

    -- base 为空、双方新建相同内容
    r = m3.merge("", "x\n", "x\n")
    t.true_(r.ok)
    t.eq("x\n", r.merged)

    -- base 为空、双方新建不同内容
    r = m3.merge("", "x\n", "y\n")
    t.true_(r.conflict, "空 base 下不同新建应冲突")

    -- 无尾换行
    r = m3.merge("a\nb", "a\nB", "a\nb")
    t.true_(r.ok)
    t.eq("a\nB", r.merged)
  end)

  it("splitlines 往返无损", function(t)
    local m3 = require("NeoAI.utils.merge3")
    for _, s in ipairs({ "", "a", "a\n", "a\nb", "a\nb\n", "\n", "\n\n", "a\n\nb\n" }) do
      t.eq(s, table.concat(m3._splitlines(s)), "splitlines 往返应无损: " .. vim.inspect(s))
    end
  end)

  it("超大文件回退 too_large", function(t)
    local m3 = require("NeoAI.utils.merge3")
    local big = {}
    for i = 1, m3.MAX_LINES + 1 do big[i] = "l" .. i .. "\n" end
    local base = table.concat(big)
    local r = m3.merge(base, base .. "x\n", base .. "y\n")
    t.false_(r.ok)
    t.true_(r.too_large, "超行数上限应回退 too_large")
  end)
end)
