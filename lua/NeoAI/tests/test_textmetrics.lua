--- 纯 Lua 文本度量专项测试
--- @module NeoAI.tests.test_textmetrics
--- 与 vim.fn.strwidth / strchars / strcharpart 交叉校验（合法 UTF-8），
--- 并覆盖非法字节、折行/切片语义与工作线程内 load(source) 的等价性。

local tests = require("NeoAI.tests")

tests.suite("textmetrics", function(_, it)
  local tm = require("NeoAI.utils.textmetrics")

  -- 合法 UTF-8 样本：ASCII / CJK / 全角 / emoji / 制表框线 / 组合字符 / 混合
  local SAMPLES = {
    "",
    "abc",
    "中文",
    "中a文 mixed",
    "ＡＢＣ",
    "😀🎉",
    "✅ 正常",
    "┌──┬──┐",
    "│ 工具 │",
    "很长的内容",
    "e" .. string.char(0xCC, 0x81) .. "b",
    "The quick brown fox jumps over the lazy dog",
    "一段包含 English 与 12345 的混合文本。",
    "→ ← ↑ ↓ · … “引号”",
    "≤ 0.5B / Qwen3-Embedding-8B（必须 INT8/Q4）",
    "𠀀𠀁𠀂", -- CJK 扩展 B（4 字节）
  }

  it("strwidth 与 vim.fn.strwidth 一致", function(t)
    for _, s in ipairs(SAMPLES) do
      t.eq(vim.fn.strwidth(s), tm.strwidth(s), ("strwidth 不一致: %q"):format(s))
    end
  end)

  it("strchars 与 vim.fn.strchars 一致", function(t)
    for _, s in ipairs(SAMPLES) do
      t.eq(vim.fn.strchars(s), tm.strchars(s), ("strchars 不一致: %q"):format(s))
    end
  end)

  it("strcharpart 与 vim.fn.strcharpart 一致（合法 UTF-8）", function(t)
    for _, s in ipairs(SAMPLES) do
      local n = tm.strchars(s)
      for start = 0, n + 1 do
        for len = 0, n + 1 do
          local got = tm.strcharpart(s, start, len)
          local want = vim.fn.strcharpart(s, start, len)
          t.eq(want, got, ("strcharpart(%q, %d, %d) 不一致"):format(s, start, len))
        end
      end
      -- len 省略 = 到末尾
      for start = 0, n + 1 do
        t.eq(vim.fn.strcharpart(s, start), tm.strcharpart(s, start), ("strcharpart(%q, %d) 不一致"):format(s, start))
      end
      -- 负 start 归零并削减 len、负 len 视为空
      for start = -1, -3, -1 do
        for len = 0, 3 do
          t.eq(vim.fn.strcharpart(s, start, len), tm.strcharpart(s, start, len),
            ("strcharpart(%q, %d, %d) 负 start 不一致"):format(s, start, len))
        end
      end
      t.eq(vim.fn.strcharpart(s, 1, -1), tm.strcharpart(s, 1, -1), "负 len 应为空串")
    end
  end)

  it("非法 UTF-8 字节：宽度按 vim 计 4、字符计 1", function(t)
    -- 注：本模块对 overlong（0xC0/0xC1）与代理区按严格 UTF-8 判定为非法单字节；
    -- vim 对这类畸形序列有更宽松的解析，故只对「孤立非法字节 / 截断序列」交叉校验。
    local cases = {
      string.char(0x80),
      string.char(0xFF),
      string.char(0x80) .. "a" .. string.char(0xC3),
      string.char(0xE4, 0xB8), -- 截断的 3 字节序列
    }
    for _, s in ipairs(cases) do
      t.eq(vim.fn.strwidth(s), tm.strwidth(s), ("非法字节 strwidth 不一致: %q"):format(s))
      t.eq(vim.fn.strchars(s), tm.strchars(s), ("非法字节 strchars 不一致: %q"):format(s))
    end
    -- 严格语义：overlong 拆为两个非法单字节（各计 1 字符、宽 4）
    t.eq(2, tm.strchars(string.char(0xC0, 0xAF)), "overlong 应按非法单字节计 2 字符")
    t.eq(8, tm.strwidth(string.char(0xC0, 0xAF)), "overlong 应按非法单字节计宽 8")
  end)

  it("each_char 拼接结果等于原串且宽度之和等于 strwidth", function(t)
    for _, s in ipairs(SAMPLES) do
      local parts, w = {}, 0
      for ch, cw in tm.each_char(s) do
        parts[#parts + 1] = ch
        w = w + cw
      end
      t.eq(s, table.concat(parts), ("each_char 拼接不一致: %q"):format(s))
      t.eq(tm.strwidth(s), w, ("each_char 宽度和不一致: %q"):format(s))
    end
  end)

  it("split_lines 与 vim.split 一致", function(t)
    for _, s in ipairs({ "", "a", "a\nb", "a\n", "\n", "\n\n", "中\n文\n" }) do
      local got = tm.split_lines(s)
      local want = vim.split(s, "\n", { plain = true })
      t.eq(#want, #got, ("split_lines 行数不一致: %q"):format(s))
      for i = 1, #want do
        t.eq(want[i], got[i], ("split_lines 第 %d 行不一致: %q"):format(i, s))
      end
    end
  end)

  it("工作线程内 load(source) 与主线程结果一致", function(t)
    t.not_nil(tm.source, "source 应可读取（供工作线程 load）")
    local worker = assert(load(tm.source))()
    for _, s in ipairs(SAMPLES) do
      t.eq(tm.strwidth(s), worker.strwidth(s), ("worker strwidth 不一致: %q"):format(s))
      t.eq(tm.strchars(s), worker.strchars(s), ("worker strchars 不一致: %q"):format(s))
      t.eq(tm.strcharpart(s, 1, 2), worker.strcharpart(s, 1, 2), ("worker strcharpart 不一致: %q"):format(s))
    end
  end)
end)
