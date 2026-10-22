--- 无强制层时审批模式必须退回同步事前审批
--- @module 'NeoAI.tests.test_sandbox_no_isolation_prompt'
--- 覆盖：
--- 1. 无命名空间隔离后端时，`approval_mode` 被强制为 `prompt`（`async` 不成立）；
--- 2. 无任何动态强制层（无 seccomp 且无 eBPF backstop）时同样强制 `prompt`；
--- 3. 用户显式 `strict` 不被降级为 `prompt`（更严者保留）；
--- 4. 沙箱整体关闭（用户显式直跑）时不干预审批模式。
---
--- 存在意义：撤掉字符静态判定后，无强制层的机器上不存在任何自动拒绝能力。此时若仍用
--- `async`（先执行、事后确认），事故已经发生；唯一诚实的处置是退回**同步事前人工审批**，
--- 并如实告知「本机无强制层」，而不是用文本匹配假装有边界（核心不变量 6）。

local tests = require("NeoAI.tests")

local function with_cfg(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(saved)
  for path, value in pairs(overrides or {}) do
    local node = merged
    local parts = vim.split(path, ".", { plain = true })
    for i = 1, #parts - 1 do
      if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
      node = node[parts[i]]
    end
    node[parts[#parts]] = value
  end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("sandbox_no_isolation_prompt", function(_, it)
  it("无隔离后端：async 被强制退回 prompt", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local isolated = runtime.isolation_available()
    with_cfg({ ["tools.sandbox.enabled"] = true }, function()
      local executor = require("NeoAI.tools.executor")
      local r = executor.effective_approval_mode("async")
      if isolated then
        t.eq("async", r.mode, "有隔离后端时不应改写 async")
        t.eq(false, r.no_isolation, "有隔离后端时 no_isolation 应为 false")
      else
        t.eq("prompt", r.mode, "无隔离后端时 async 必须退回 prompt")
        t.eq(true, r.no_isolation, "应识别为无隔离后端")
      end
    end)
  end)

  it("无动态强制层：async 同样被强制退回 prompt，并如实标记", function(t)
    with_cfg({
      ["tools.sandbox.enabled"] = true,
      ["tools.sandbox.seccomp.enabled"] = false,
      ["tools.sandbox.seccomp.backstop"] = "off",
    }, function()
      local executor = require("NeoAI.tools.executor")
      local r = executor.effective_approval_mode("async")
      t.eq(true, r.no_enforcement, "seccomp 关闭且兜底关闭时应识别为无强制层")
      t.eq("prompt", r.mode, "无强制层时 async 必须退回 prompt")
    end)
  end)

  it("用户显式 strict 不被降级（更严者保留）", function(t)
    with_cfg({
      ["tools.sandbox.enabled"] = true,
      ["tools.sandbox.seccomp.enabled"] = false,
      ["tools.sandbox.seccomp.backstop"] = "off",
    }, function()
      local executor = require("NeoAI.tools.executor")
      local r = executor.effective_approval_mode("strict")
      t.eq("strict", r.mode, "strict 更严，不得被降级为 prompt")
      t.eq(true, r.no_enforcement, "但仍应如实标记无强制层")
    end)
  end)

  it("用户显式 auto_allow 在无强制层时不被降级（配置即人决策）", function(t)
    with_cfg({
      ["tools.sandbox.enabled"] = true,
      ["tools.sandbox.seccomp.enabled"] = false,
      ["tools.sandbox.seccomp.backstop"] = "off",
    }, function()
      local executor = require("NeoAI.tools.executor")
      local r = executor.effective_approval_mode("auto_allow")
      t.eq("auto_allow", r.mode, "只有 async 不成立；显式 auto_allow 保留并留下 no_enforcement 标记")
    end)
  end)

  it("沙箱整体关闭时不干预审批模式（用户显式选择直跑）", function(t)
    with_cfg({ ["tools.sandbox.enabled"] = false }, function()
      local executor = require("NeoAI.tools.executor")
      local r = executor.effective_approval_mode("async")
      t.eq("async", r.mode, "沙箱关闭时不改写审批模式")
      t.eq(false, r.no_enforcement, "沙箱关闭时不属强制层判定范围")
      t.eq(false, r.no_isolation, "沙箱关闭时不属隔离判定范围")
    end)
  end)

  it("执行路径确实采用该判定（接线校验）", function(t)
    -- 工具注册状态依赖插件启动顺序，直接 execute 在部分 worker 上不可用（工具表未构建），
    -- 故这里校验「执行路径入口确实调用了 effective_approval_mode 并把结果写回 ctx」，
    -- 行为本身由上面几条用 effective_approval_mode 直接覆盖。
    local src = table.concat(vim.fn.readfile("lua/NeoAI/tools/executor.lua"), "\n")
    t.ok(src:find("M.effective_approval_mode(mode)", 1, true) ~= nil,
      "执行路径应调用 effective_approval_mode")
    t.ok(src:find("ctx.approval_mode = mode", 1, true) ~= nil,
      "应把判定结果写回 ctx.approval_mode")
    t.ok(src:find("ctx.sandbox_no_enforcement = true", 1, true) ~= nil,
      "应如实标记 sandbox_no_enforcement")
  end)
end)
