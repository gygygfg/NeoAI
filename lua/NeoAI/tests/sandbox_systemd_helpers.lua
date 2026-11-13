--- 沙箱 systemctl 门面测试的共享辅助
--- @module 'NeoAI.tests.sandbox_systemd_helpers'
--- 供 `test_sandbox_systemd*.lua` 各分片复用。**非** `test_` 前缀：不会被测试加载器当作套件。
---
--- 拆背景：systemd 门面用例含真实定时器 / 服务重启等待，单文件串行会把整轮测试拖成长尾；
--- 按主题拆成多个套件后由并行运行器（heavy lane）同时执行。

local M = {}

--- 应用并恢复沙箱配置（临时覆盖→执行→恢复）
--- @param overrides table
--- @param fn function
function M.with_config(overrides, fn)
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

--- 写一个 unit 文件
--- @param dir string
--- @param name string
--- @param body string
--- @return string path
function M.write_unit(dir, name, body)
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(body)
  f:close()
  return path
end

--- 测试用沙箱配置（systemd 门面模式）
--- @param unit_roots table
--- @param extra table|nil
--- @return table
function M.systemd_config(unit_roots, extra)
  local base = {
    enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
    service = { enabled = true },
    systemd = { enabled = true, mode = "facade", unit_roots = unit_roots, max_deps = 32 },
  }
  for k, v in pairs(extra or {}) do base[k] = v end
  return base
end

--- 执行一个门面计划并等待 {stdout, stderr, code}。
--- @param sd table systemd 模块
--- @param plan table parse_command 结果
--- @param timeout number|nil
--- @return table
function M.run_plan(sd, plan, timeout)
  local res
  sd.handle(plan):then_(function(v) res = v end, function(e) res = { err = e } end)
  vim.wait(timeout or 3000, function() return res ~= nil end, 20)
  return res
end

return M
