--- 沙箱暂存/门禁正确性专项测试
--- @module NeoAI.tests.test_sandbox_staging
--- 覆盖：目录条目不算实质暂存；has_staged_under/outside；overlay_gate 按根覆盖判定；
--- T2 无关暂存不误拒；整机根 overlay 目录与 /root 可写根不冲突；
--- 复合命令中的 systemctl 注入维护脚本桩。

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

tests.suite("sandbox_staging", function(_, it)
  it("目录条目不算实质暂存，文件条目才算", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    sandbox.reset()
    candidate.begin_session()
    -- 仅新建目录：不构成实质改动（否则空目录会让 has_staged 永为真）。
    candidate.merge_candidate({ files = { { path = dir, action = "mkdir", mode = 493 } } })
    t.false_(candidate.has_staged(), "仅目录条目不应视为未发布改动")
    -- 新建文件：构成实质改动。
    candidate.merge_candidate({
      files = { { path = dir .. "/f.txt", action = "create", content = "x\n" } },
    })
    t.true_(candidate.has_staged(), "新建文件应视为未发布改动")
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("has_staged_under / has_staged_outside 按根筛选", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local dir = vim.fn.tempname()
    local other = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.ensure_dir(other)
    sandbox.reset()
    candidate.begin_session()
    candidate.merge_candidate({
      files = { { path = dir .. "/f.txt", action = "create", content = "x\n" } },
    })
    t.true_(candidate.has_staged_under({ dir }), "dir 内的暂存应命中 has_staged_under")
    t.false_(candidate.has_staged_under({ other }), "other 内无暂存")
    t.false_(candidate.has_staged_outside({ dir }), "暂存被 dir 覆盖，outside 应为假")
    t.true_(candidate.has_staged_outside({ other }), "暂存在 other 之外，outside 应为真")
    sandbox.reset()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(other, "rf")
  end)

  it("overlay_gate：混合 overlay/bind 时按根覆盖判定（未覆盖的暂存仍拒绝）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local wrapper = require("NeoAI.sandbox.wrapper")
    local dir = vim.fn.tempname()
    local other = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.ensure_dir(other)
    with_config({ tools = { sandbox = { overlay_fail_closed = false } } }, function()
      sandbox.reset()
      candidate.begin_session()
      candidate.merge_candidate({
        files = { { path = dir .. "/f.txt", action = "create", content = "x\n" } },
      })
      -- dir 是 overlay 可覆盖根：放行。
      local ok1 = wrapper.overlay_gate({ { root = dir, mode = "overlay" } }, {})
      t.true_(ok1, "暂存在 overlay 根内应放行")
      -- other 是 overlay 根、dir 是 bind：dir 内暂存未被覆盖 → 必须拒绝。
      local ok2, err2 = wrapper.overlay_gate(
        { { root = other, mode = "overlay" }, { root = dir, mode = "bind" } }, {})
      t.false_(ok2, "未覆盖根的暂存应拒绝")
      t.matches("SANDBOX_STAGING_UNCOVERED", tostring(err2))
    end)
    sandbox.reset()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(other, "rf")
  end)

  it("overlay_gate：T2 仅 cwd 内暂存阻塞，无关暂存不误拒", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local wrapper = require("NeoAI.sandbox.wrapper")
    local dir = vim.fn.tempname()
    local other = vim.fn.tempname()
    fs.ensure_dir(dir)
    fs.ensure_dir(other)
    sandbox.reset()
    candidate.begin_session()
    candidate.merge_candidate({
      files = { { path = dir .. "/f.txt", action = "create", content = "x\n" } },
    })
    -- T2 无 overlay、cwd=dir：cwd 内暂存不可见 → 拒绝。
    local ok1 = wrapper.overlay_gate({}, { userns = true, cwd = dir })
    t.false_(ok1, "T2 且 cwd 内有暂存应拒绝")
    -- T2 cwd=other：暂存在 cwd 之外，不在其工作集内 → 放行（此前会被全局 has_staged 误拒）。
    local ok2, err2 = wrapper.overlay_gate({}, { userns = true, cwd = other })
    t.true_(ok2, "T2 无关暂存不应拒绝: " .. tostring(err2))
    sandbox.reset()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(other, "rf")
  end)

  it("overlay 子目录编码：整机根与 /root 可写根不冲突", function(t)
    local fs = require("NeoAI.utils.fs")
    local wrapper = require("NeoAI.sandbox.wrapper")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    with_config({ tools = { sandbox = { read_all = false, process_roots = {} } } }, function()
      local specs = wrapper.build_overlay_specs(dir, dir .. "/base", { "/root" })
      local root_upper
      for _, s in ipairs(specs) do
        if s.root == "/root" then root_upper = s.upper end
      end
      t.not_nil(root_upper, "应包含 /root 可写根规格")
      t.matches("/r_root/", tostring(root_upper), "/root 应编码为 r_root，不与整机根 base/root 冲突")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("复合命令中的 systemctl：分类标记并注入维护脚本桩", function(t)
    local privilege = require("NeoAI.sandbox.privilege")
    local spec = { effect = "process" }
    with_config({ tools = { sandbox = { systemd = { maintscript_stubs = true } } } }, function()
      local req = privilege.classify("run_command", { command = "echo hi && systemctl status foo" }, spec, {})
      t.true_(req.systemd_compound == true, "复合 systemctl 应标记 systemd_compound")
      local res = privilege.resolve(req.tier, req)
      t.true_(res.ok, "resolve 应成功")
      t.true_(res.privileges.systemctl_shim == true, "复合 systemctl 应注入 systemctl shim（不注入 policy-rc.d）")
      t.false_(res.privileges.maintscript_stubs == true, "复合 systemctl 不应注入完整维护脚本桩")

      local req2 = privilege.classify("run_command", { command = "echo hi" }, spec, {})
      t.false_(req2.systemd_compound == true, "普通命令不应标记 systemd_compound")
    end)
  end)

  it("稳定临时根基目录：resident/一次性/子进程共用同一 /tmp 源", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local fs = require("NeoAI.utils.fs")
    local base = runtime.stable_tmp_base()
    t.eq("string", type(base), "stable_tmp_base 应返回字符串")
    t.eq(base, runtime.stable_tmp_base(), "稳定基目录应可重复且一致")
    if runtime.backend() ~= "bwrap" then return end
    local cwd = vim.fn.tempname()
    fs.ensure_dir(cwd)
    local prefix = runtime.process_prefix({
      cwd = cwd, overlays = {}, privileges = { network = false },
      session_tmp_dir = base, tmpfs_base = base,
    })
    t.not_nil(prefix, "应能构造前缀")
    local joined = table.concat(prefix, " ")
    t.matches(base, joined, "前缀应引用稳定基目录")
    t.matches("/tmp_tmp/", joined, "应把稳定基目录下的子目录绑定到 /tmp")
    vim.fn.delete(cwd, "rf")
  end)
end)
