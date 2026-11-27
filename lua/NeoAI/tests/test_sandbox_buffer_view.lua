--- 未保存 buffer → 沙箱视图基线（save-all）回归
--- @module 'NeoAI.tests.test_sandbox_buffer_view'
--- 覆盖：基线登记、无 AI 增量不产生候选、AI 改动产生候选、新建未保存文件不被误捕获、
--- 保存后清除种子、pending_content 只暴露真实 AI 增量。
local tests = require("NeoAI.tests")

local function with_store(fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(saved or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  merged.tools.sandbox.workspace_root = vim.fn.tempname() .. "/sb"
  merged.tools.sandbox.postprocess = "sync"
  merged.tools.sandbox.observe = { enabled = false }
  merged.tools.sandbox.single_view = true
  merged.ui = merged.ui or {}
  merged.ui.pending_diff = { enabled = true, max_bytes = 1024 * 1024, virtual_added_lines = 5 }
  config_store.load(merged)
  local sandbox = require("NeoAI.sandbox")
  sandbox.reset()
  local ok, err = pcall(fn)
  sandbox.reset()
  config_store.load(saved)
  if not ok then error(err, 0) end
end

local function hash(s)
  return "sha256:" .. vim.fn.sha256(s)
end

local function new_attempt(candidate)
  local control = require("NeoAI.sandbox.execution.control")
  local store = require("NeoAI.sandbox.state.store")
  local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
  candidate.begin(a, assert(store.root()))
  return a
end

tests.suite("sandbox_buffer_view", function(_, it)
  it("seed_buffer 登记 save-all 基线，pending_content 不暴露纯 buffer 内容", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_store(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/a.txt"
      fs.write_file(p, "a\nb\n")
      local content = "a\nB\n"
      local ok, reason = candidate.seed_buffer(p, content, { tick = 1, disk_hash = hash("a\nb\n") })
      t.true_(ok, "seed 应成功")
      t.eq("seeded", reason)
      local info = candidate.buffer_seed_info(p)
      t.true_(info and info.seeded, "应登记 buffer 种子")
      t.false_(info.delta, "没有任何 AI 改动时不应有 delta")
      t.nil_(candidate.pending_content(p), "纯 buffer 内容不应显示为待审 diff")
      t.eq("a\nB\n", fs.read_file(info.staged) or "", "视图应写入 buffer 内容")
      t.eq("a\nb\n", fs.read_file(p) or "", "真实盘不应改动")
    end)
  end)

  it("AI 改动在基线上时 pending_content 返回增量，并产生候选", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_store(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/a.txt"
      fs.write_file(p, "a\nb\n")
      local seed = "a\nB\n"
      candidate.seed_buffer(p, seed, { tick = 1, disk_hash = hash("a\nb\n") })
      local info = candidate.buffer_seed_info(p)
      fs.write_file(info.staged, "a\nB2\nc\n")
      local pending = candidate.pending_content(p)
      t.not_nil(pending, "AI 改动后应有待审内容")
      t.eq("a\nB2\nc\n", pending.content)

      local a = new_attempt(candidate)
      candidate.mapping(a.attempt_id)[p] = {
        real = p, staged = info.staged, base_exists = true, base_type = "file",
        base_hash = hash("a\nb\n"), view_base_hash = hash(seed), buffer_seeded = true,
        mode = 420, base_mode = 420,
      }
      local cand = candidate.finish(a.attempt_id)
      t.eq(1, #cand.files, "AI 改动应产生候选")
      t.eq("modify", cand.files[1].action)
      -- 候选内容不驻留内存（inline_candidate_bytes 默认 0）：正文落在同盘 blob，
      -- 候选条目只带元数据，按需读取。
      t.nil_(cand.files[1].content, "候选不应把文件内容内联进内存")
      t.not_nil(cand.files[1].blob, "候选应记 blob")
      t.eq("a\nB2\nc\n", fs.read_file(cand.files[1].blob or "") or "", "blob 应含视图内容")
      candidate.cleanup(a.attempt_id)
    end)
  end)

  it("基线未被改动时不产生候选（含新建未保存文件）", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_store(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/a.txt"
      fs.write_file(p, "a\nb\n")
      local seed = "a\nB\n"
      candidate.seed_buffer(p, seed, { tick = 1, disk_hash = hash("a\nb\n") })
      local info = candidate.buffer_seed_info(p)
      local a = new_attempt(candidate)
      candidate.mapping(a.attempt_id)[p] = {
        real = p, staged = info.staged, base_exists = true, base_type = "file",
        base_hash = hash("a\nb\n"), view_base_hash = hash(seed), buffer_seeded = true,
        mode = 420, base_mode = 420,
      }
      local cand = candidate.finish(a.attempt_id)
      t.eq(0, #cand.files, "只有 save-all 基线时不应产生候选")
      candidate.cleanup(a.attempt_id)

      local np = dir .. "/new.lua"
      local nseed = "print('x')\n"
      candidate.seed_buffer(np, nseed, { tick = 2 })
      local ninfo = candidate.buffer_seed_info(np)
      local a2 = new_attempt(candidate)
      candidate.mapping(a2.attempt_id)[np] = {
        real = np, staged = ninfo.staged, base_exists = false, base_type = nil,
        base_hash = nil, view_base_hash = hash(nseed), buffer_seeded = true, mode = 420,
      }
      local cand2 = candidate.finish(a2.attempt_id)
      t.eq(0, #cand2.files, "新建未保存文件的基线不应被捕获为 create 候选")
      candidate.cleanup(a2.attempt_id)
    end)
  end)

  it("保存到基线后清除种子；保存了不同内容则保留冲突标记", function(t)
    local fs = require("NeoAI.utils.fs")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_store(function()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local p = dir .. "/a.txt"
      fs.write_file(p, "a\nb\n")
      local seed = "a\nB\n"
      candidate.seed_buffer(p, seed, { tick = 1, disk_hash = hash("a\nb\n") })
      local info = candidate.buffer_seed_info(p)
      -- AI 改动叠在基线上
      fs.write_file(info.staged, "a\nB2\n")
      -- 用户保存了「不同内容」：保留旧 CAS 基线并标记冲突
      candidate.on_buffer_saved(p, hash("a\nB3\n"))
      local after = candidate.buffer_seed_info(p)
      t.true_(after and after.buffer_conflict, "保存了与基线不同的内容应标记冲突")
      -- 用户把 buffer 保存回基线：CAS 基线前移，AI 候选仍有效
      candidate.on_buffer_saved(p, hash(seed))
      local after2 = candidate.buffer_seed_info(p)
      t.true_(after2 and after2.delta, "AI 改动应保留")
      t.false_(after2.buffer_conflict, "基线一致时冲突应清除")
      -- 没有 AI 改动时保存：种子被清除（用新路径，避免上一段 AI delta 阻止覆盖）
      local p2 = dir .. "/b.txt"
      fs.write_file(p2, "x\ny\n")
      local seed2 = "x\nY\n"
      candidate.seed_buffer(p2, seed2, { tick = 3, disk_hash = hash("x\ny\n") })
      candidate.on_buffer_saved(p2, hash(seed2))
      t.nil_(candidate.buffer_seed_info(p2), "保存后纯 buffer 种子应清除")
    end)
  end)

  it("buffer_view.sync 在 overlay 不可用/禁用时安全跳过", function(t)
    local bv = require("NeoAI.sandbox.execution.buffer_view")
    with_store(function()
      local ok, info = pcall(bv.sync)
      t.true_(ok, "sync 不应抛错")
      t.eq("table", type(info))
    end)
  end)
end)
