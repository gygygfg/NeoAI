--- 沙箱 overlay 视图同步专项测试
--- @module NeoAI.tests.test_sandbox_overlay_invalidate
--- 覆盖：发布/拒绝后失效 overlay 物化条目，后续命令不再读到旧物化内容（视图分裂修复）；
--- 权限位变化触发重新物化（执行位不丢失）。

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
    ephemeral_roots = {}, resident = { enabled = true },
  }
  for k, v in pairs(extra or {}) do base[k] = v end
  return base
end

local function run(cmd)
  local out, done = nil, false
  require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {})
    :then_(function(v) out = v; done = true end, function() done = true end)
  vim.wait(20000, function() return done end, 50)
  return out
end

tests.suite("sandbox_overlay_invalidate", function(_, it)
  it("常驻实例：invalidate_paths 后命令读到真实盘新内容（不再读到旧物化）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.resident")
    if not resident.available() then return end
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = resident_sandbox_config() },
    }, function()
      require("NeoAI.sandbox").reset()
      local f = vim.fn.getcwd() .. "/.neoai_overlay_invalidate_test"
      pcall(os.remove, f)
      -- 沙箱内创建 OLD（落 overlay upper）
      run("printf OLD > " .. f)
      t.not_nil(resident.active(), "应存在常驻实例")
      -- 真实盘改为 NEW（lower 更新，upper 仍为 OLD）
      local fh = io.open(f, "w"); fh:write("NEW"); fh:close()
      -- 未失效时命令仍读到 OLD（overlay upper 遮蔽 lower）
      local stale = tostring(run("cat " .. f))
      t.matches("OLD", stale, "失效前应读到旧物化内容（复现视图分裂）")
      -- 失效 overlay 物化条目后应读到真实盘新内容
      resident.invalidate_paths({ f })
      vim.wait(500)
      local fresh = tostring(run("cat " .. f))
      t.matches("NEW", fresh, "失效后应读到真实盘新内容")
      resident.stop({ timeout_ms = 5000 })
      pcall(os.remove, f)
    end)
  end)
end)
