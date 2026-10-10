--- 命名空间文件桥（file_bridge）回归
--- @module NeoAI.tests.test_sandbox_namespace
--- 覆盖：常驻实例运行后，`file_bridge` 的读/写/存在/stat/建目录/删除/列目录均在沙箱 mount
--- 命名空间内执行——**写入落在 overlay 暂存层（真实工作区零改动）**，读取为 overlay 合并视图
--- （未暂存则读真实 lower）。仅在 bwrap + 常驻实例可用时运行。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  if merged.tools.sandbox.ephemeral_roots == nil then
    merged.tools.sandbox.ephemeral_roots = {}
  end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

local function resident_sandbox_config(extra)
  local base = {
    enabled = true, fail_closed = true, mode = "dry_run",
    ephemeral_roots = {}, resident = { enabled = true }, inproc_namespace = true,
  }
  for k, v in pairs(extra or {}) do base[k] = v end
  return base
end

tests.suite("sandbox_namespace", function(_, it)
  it("file_bridge：命名空间内写入落在 overlay（真实盘零改动），读取为合并视图", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.execution.resident")
    if not resident.available() then return end
    local fs = require("NeoAI.utils.fs")
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = resident_sandbox_config() },
    }, function()
      require("NeoAI.sandbox").reset()
      local tools = require("NeoAI.tools")
      -- 用工作区内子目录（非 /tmp —— 沙箱 /tmp 为会话私有，宿主文件不可见）。
      local base = fs.canonical(vim.uv.cwd()) .. "/.neoai_ns_test"
      vim.fn.delete(base, "rf")
      fs.ensure_dir(base)
      local target = base .. "/f.txt"
      fs.write_file(target, "REAL-ORIGINAL")

      -- 起常驻实例（执行一条无关命令）。
      local done = false
      tools.execute("run_command", { command = "true", description = "t" }, {})
        :then_(function() done = true end, function() done = true end)
      vim.wait(20000, function() return done end, 50)
      t.not_nil(resident.active(), "应存在常驻实例")

      local bridge = require("NeoAI.sandbox.execution.file_bridge")
      t.true_(bridge.available(), "命名空间桥应可用")

      -- 读穿透：未暂存的真实文件应可读。
      t.eq("REAL-ORIGINAL", bridge.read(target), "未暂存文件应读穿透真实内容")
      t.eq(true, bridge.exists(target), "存在判定为真")
      local st = bridge.stat(target)
      t.not_nil(st, "stat 应返回")
      t.eq("file", st and st.type, "应为文件")

      -- 命名空间写：overlay 视图更新，真实盘不变。
      local ok = bridge.write(target, "SANDBOXED-VIEW")
      t.true_(ok, "命名空间写应成功")
      t.eq("SANDBOXED-VIEW", bridge.read(target), "overlay 视图应看到新内容")
      t.eq("REAL-ORIGINAL", fs.read_file(target), "真实盘不得改动（写入落在 overlay 暂存层）")

      -- 建目录 / 列目录 / 删除（均命名空间内）。
      local sub = base .. "/sub"
      t.true_(bridge.mkdir(sub), "mkdir 应成功")
      t.eq("directory", (bridge.stat(sub) or {}).type, "子目录应为目录")
      local names = bridge.list(base) or {}
      local seen = {}
      for _, n in ipairs(names) do seen[n] = true end
      t.true_(seen["f.txt"], "列目录应含 f.txt")
      t.true_(seen["sub"], "列目录应含 sub")
      t.true_(bridge.write(sub .. "/g.txt", "G"), "写子文件应成功")
      t.eq("G", bridge.read(sub .. "/g.txt"), "应读回子文件")
      t.true_(bridge.unlink(sub), "删除目录树应成功")
      t.eq(false, bridge.exists(sub), "删除后应不存在")
      -- 真实盘上 sub 从未创建（overlay-only）。
      t.false_(fs.exists(sub), "真实盘不应出现 overlay 新建的目录")

      resident.stop({ timeout_ms = 5000 })
      vim.fn.delete(base, "rf")
    end)
  end)

  it("file_bridge：常驻实例未运行时不可用且不静默降级", function(t)
    local resident = require("NeoAI.sandbox.execution.resident")
    resident.stop({ timeout_ms = 2000 })
    local bridge = require("NeoAI.sandbox.execution.file_bridge")
    t.false_(bridge.available(), "无实例时桥应不可用")
    local content, err = bridge.read("/etc/hostname")
    t.nil_(content, "无实例时读取应返回 nil（调用方回退宿主 I/O）")
    t.not_nil(err, "应给出错误原因")
  end)

  it("overlay 权威：进程内 edit_file 写 overlay（真实盘零改动），read_file 见新内容", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.execution.resident")
    if not resident.available() then return end
    local fs = require("NeoAI.utils.fs")
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = resident_sandbox_config() },
    }, function()
      require("NeoAI.sandbox").reset()
      local tools = require("NeoAI.tools")
      local review = require("NeoAI.sandbox.review.review")
      review.reset()
      local base = fs.canonical(vim.uv.cwd()) .. "/.neoai_ns_edit"
      vim.fn.delete(base, "rf")
      fs.ensure_dir(base)
      local target = base .. "/e.txt"
      fs.write_file(target, "ORIGINAL\n")

      -- 首个文件操作应主动建立常驻实例（无需先跑命令）。
      t.eq(nil, resident.active(), "初始不应存在常驻实例")

      -- 经工具编辑（overlay 权威：写命名空间 overlay）。
      local ed_done, ed_err = false, nil
      tools.execute("edit_file", {
        file_path = target, description = "t", mode = "write", content = "CHANGED\n",
      }, {}):then_(function() ed_done = true end, function(e) ed_err = e; ed_done = true end)
      vim.wait(20000, function() return ed_done end, 50)
      t.eq(nil, ed_err, "edit_file 不应报错: " .. tostring(ed_err and (ed_err.message or ed_err)))
      t.not_nil(resident.active(), "首个文件操作应建立常驻实例")

      -- 真实盘零改动（写入落在 overlay 暂存层）。
      t.eq("ORIGINAL\n", fs.read_file(target), "真实盘不得改动（overlay 权威）")

      -- 待审候选已产生。
      local pend = review.list({ review_state = "PENDING" })
      t.true_(#pend > 0, "应产生待审候选")

      -- read_file 经暂存缓存看到新内容（缓存由 overlay 镜像）。
      local rd, rd_done = nil, false
      tools.execute("read_file", { file_path = target, description = "t" }, {}):then_(
        function(v) rd = v; rd_done = true end, function() rd_done = true end)
      vim.wait(20000, function() return rd_done end, 50)
      t.true_(tostring(rd):find("CHANGED", 1, true) ~= nil, "read_file 应看到 overlay 新内容")

      local bridge = require("NeoAI.sandbox.execution.file_bridge")
      -- create_directory：overlay 建目录，真实盘不出现。
      local nd = base .. "/newdir"
      local cd_done = false
      tools.execute("create_directory", { file_path = nd, description = "t" }, {})
        :then_(function() cd_done = true end, function() cd_done = true end)
      vim.wait(20000, function() return cd_done end, 50)
      t.false_(fs.exists(nd), "真实盘不应出现 overlay 新建目录")
      t.eq(true, bridge.exists(nd), "overlay 视图应见到新建目录")
      local fe_done, fe_val = false, nil
      tools.execute("file_exists", { file_path = nd, description = "t" }, {}):then_(
        function(v) fe_val = v; fe_done = true end, function() fe_done = true end)
      vim.wait(20000, function() return fe_done end, 50)
      t.eq("true", tostring(fe_val), "file_exists 应反映 overlay 新建目录")

      -- delete_file：overlay 删除，真实盘仍在。
      local del_done = false
      tools.execute("delete_file", { file_path = target, description = "t" }, {})
        :then_(function() del_done = true end, function() del_done = true end)
      vim.wait(20000, function() return del_done end, 50)
      t.eq("ORIGINAL\n", fs.read_file(target), "overlay 删除不应改真实盘")
      t.eq(false, bridge.exists(target), "overlay 视图应已删除")

      resident.stop({ timeout_ms = 5000 })
      review.reset()
      vim.fn.delete(base, "rf")
    end)
  end)
end)
