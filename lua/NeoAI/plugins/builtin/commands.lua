--- 命令插件
--- @module NeoAI.plugins.builtin.commands
--- 注册全部 NeoAI 用户命令；卸载时删除。业务调用一律经 kernel.services.use 获取服务。

local services = require("NeoAI.kernel.services")

local M = {}

-- 本插件注册的命令名（卸载时删除）
local COMMANDS = {
  "NeoAIOpen", "NeoAIChat", "NeoAITree", "NeoAIClose", "NeoAIKeymaps",
  "NeoAIStatusline", "NeoAITest", "NeoAIChatStatus", "NeoAICycleDisplay",
  "NeoAIReloadDisplay", "NeoAIPlan", "NeoAIAuto", "NeoAIReloadAll",
  "NeoAIApprovePlan", "NeoAISandboxCommit", "NeoAISandboxDiscard",
  "NeoAISandboxList", "NeoAISandboxShow", "NeoAISandboxCaps", "NeoAISandboxDiag",
  "NeoAISandboxReview", "NeoAISandboxApprove", "NeoAISandboxReject",
  "NeoAISandboxApply", "NeoAISandboxApplyAll",
  "NeoAISandboxGrant", "NeoAISandboxRevoke", "NeoAISandboxPrune", "NeoAISandboxMetrics",
  "NeoAISandboxPublish", "NeoAISandboxReplay", "NeoAISandboxAudit", "NeoAISandboxAutoApprove",
}

-- ========== 私有函数 ==========

--- 懒获取服务（缺失时返回 nil，由调用方降级）
--- @param name string
--- @return any
local function _svc(name)
  return services.use(name)
end

--- 注册一个用户命令（force 覆盖同名）
--- @param name string
--- @param fn function
--- @param opts table
local function _cmd(name, fn, opts)
  opts = opts or {}
  opts.desc = opts.desc or ("NeoAI: " .. name)
  opts.force = true
  vim.api.nvim_create_user_command(name, fn, opts)
end

-- ========== 公开 API ==========

--- 注册命令
--- @return function 清理函数
function M.start()
  _cmd("NeoAIOpen", function()
    local ui = _svc("services.ui")
    if ui then ui.open_default() end
  end, { desc = "打开 NeoAI 默认界面" })

  _cmd("NeoAIChat", function()
    local ui = _svc("services.ui")
    if ui then ui.open_chat() end
  end, { desc = "打开 NeoAI 聊天界面" })

  _cmd("NeoAITree", function()
    local ui = _svc("services.ui")
    if ui then ui.open_tree() end
  end, { desc = "打开 NeoAI 会话树界面" })

  _cmd("NeoAIClose", function()
    local ui = _svc("services.ui")
    if ui then ui.close_all() end
  end, { desc = "关闭所有 NeoAI 窗口" })

  _cmd("NeoAIKeymaps", function()
    local ui = _svc("services.ui")
    if ui then ui.show_keymaps() end
  end, { desc = "显示 NeoAI 当前键位配置" })

  _cmd("NeoAIStatusline", function()
    local status = _svc("services.status")
    if not status then return end
    local text = status.component()
    if text == "" then
      vim.notify("[NeoAI] (无激活 Agent)", vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] " .. text:gsub("%%%%", "%"), vim.log.levels.INFO)
    end
  end, { desc = "预览 NeoAI lualine 状态栏组件内容" })

  _cmd("NeoAITest", function(opts)
    local ok, tests = pcall(require, "NeoAI.tests")
    if not ok then
      vim.notify("[NeoAI] 测试模块加载失败: " .. tostring(tests), vim.log.levels.ERROR)
      return
    end
    local args = opts.args or ""
    local names = {}
    for arg in args:gmatch("%S+") do
      table.insert(names, arg)
    end
    local results = tests.run_all(unpack(names))
    vim.notify(string.format("测试结果: %d 通过, %d 失败", results.passed, results.failed), vim.log.levels.INFO)
    if #results.errors > 0 then
      vim.notify("失败测试:\n  " .. table.concat(results.errors, "\n  "), vim.log.levels.WARN)
    end
  end, { nargs = "*", desc = "运行 NeoAI 测试" })

  _cmd("NeoAIChatStatus", function()
    local ui = _svc("services.ui")
    if ui then ui.chat_status() end
  end, { desc = "显示 NeoAI 聊天窗口状态" })

  _cmd("NeoAICycleDisplay", function()
    local ui = _svc("services.ui")
    local chat_view = ui and ui.get_chat_view()
    if not chat_view then return end
    local plugin = chat_view.cycle_display()
    if plugin then
      vim.notify("[NeoAI] 显示模式已切换: " .. (plugin.label or plugin.name), vim.log.levels.INFO)
    end
  end, { desc = "循环切换聊天显示模式（对话/轨迹）" })

  _cmd("NeoAIReloadDisplay", function(opts)
    local ui = _svc("services.ui")
    local chat_view = ui and ui.get_chat_view()
    if not chat_view then return end
    local name = (opts.args or ""):match("%S+") or nil
    local plugin = chat_view.reload_display(name)
    if plugin then
      vim.notify("[NeoAI] 显示模式插件已热重载: " .. (plugin.label or plugin.name), vim.log.levels.INFO)
    end
  end, { nargs = "?", desc = "热重载显示模式插件（缺省重载当前模式）" })

  _cmd("NeoAIPlan", function()
    local chat_service = _svc("services.chat_service")
    if not chat_service then return end
    local active = chat_service.toggle_plan_mode()
    local ui = _svc("services.ui")
    if ui then ui.get_chat_view().refresh() end
    if active == nil then
      vim.notify("[NeoAI] 无当前 Agent，无法切换计划模式", vim.log.levels.WARN)
    else
      local suffix = chat_service.has_pending_mode() and "（将在本轮生成结束后生效）" or ""
      vim.notify("[NeoAI] 计划模式已" .. (active and "开启" or "关闭") .. suffix, vim.log.levels.INFO)
    end
  end, { desc = "切换计划模式" })

  _cmd("NeoAIAuto", function()
    local chat_service = _svc("services.chat_service")
    if not chat_service then return end
    local active = chat_service.toggle_auto_mode()
    local suffix = chat_service.has_pending_mode() and "（将在本轮生成结束后生效）" or ""
    vim.notify("[NeoAI] AUTO 模式（自动允许所有工具调用）已" .. (active and "开启" or "关闭") .. suffix, vim.log.levels.INFO)
  end, { desc = "切换AUTO模式（自动允许所有工具调用）" })

  _cmd("NeoAIReloadAll", function()
    local reload_all = require("NeoAI.tools.builtin.reload_all")
    local res = reload_all._precheck()
    if not res.ok then
      vim.notify("[NeoAI] 热重载预检失败，已取消：\n" .. tostring(res.message), vim.log.levels.ERROR)
      return
    end
    local ok, err = reload_all._perform_reload()
    if ok then
      vim.notify("[NeoAI] 插件已热重载完成", vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 插件热重载失败（已尽力回滚）：" .. tostring(err), vim.log.levels.ERROR)
    end
  end, { desc = "热重载整个 NeoAI 插件（先隔离子进程预检，失败则取消）" })

  _cmd("NeoAISandboxCommit", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then
      vim.notify("[NeoAI] 沙箱服务不可用", vim.log.levels.ERROR)
      return
    end
    local digest = (opts.args or ""):match("%S+")
    if not digest then
      local list = sandbox.list()
      if #list == 0 then
        vim.notify("[NeoAI] 无待处理候选", vim.log.levels.INFO)
      else
        vim.notify("[NeoAI] 请指定候选摘要（:NeoAISandboxList 查看）", vim.log.levels.WARN)
      end
      return
    end
    local res = sandbox.commit(digest)
    if res.ok then
      vim.notify(("[NeoAI] 候选已发布: %s（%d 项）"):format(digest, res.receipt and res.receipt.file_count or 0), vim.log.levels.INFO)
    else
      vim.notify(("[NeoAI] 发布失败(%s): %s"):format(tostring(res.state), tostring(res.reason)), vim.log.levels.ERROR)
    end
  end, { nargs = "?", desc = "应用沙箱候选到真实工作区（CAS 发布）" })

  _cmd("NeoAISandboxDiscard", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local digest = (opts.args or ""):match("%S+")
    if not digest then
      vim.notify("[NeoAI] 请指定候选摘要", vim.log.levels.WARN)
      return
    end
    if sandbox.discard(digest) then
      vim.notify("[NeoAI] 候选已丢弃: " .. digest, vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 候选不存在: " .. digest, vim.log.levels.WARN)
    end
  end, { nargs = "?", desc = "丢弃沙箱候选" })

  _cmd("NeoAISandboxList", function()
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local list = sandbox.list()
    if #list == 0 then
      vim.notify("[NeoAI] 无待处理候选", vim.log.levels.INFO)
      return
    end
    local lines = {}
    for _, c in ipairs(list) do
      lines[#lines + 1] = string.format("%s  %d 项  %s", c.candidate_digest, #(c.files or {}), c.effect or "")
    end
    vim.notify("[NeoAI] 待处理候选:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "列出沙箱待处理候选" })

  _cmd("NeoAISandboxShow", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local digest = (opts.args or ""):match("%S+")
    if not digest then return end
    local cand = sandbox.show(digest)
    if not cand then
      vim.notify("[NeoAI] 候选不存在: " .. digest, vim.log.levels.WARN)
      return
    end
    local lines = {}
    for _, f in ipairs(cand.files or {}) do
      lines[#lines + 1] = string.format("%-8s %s", f.action, f.path)
    end
    vim.notify("[NeoAI] " .. digest .. "\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { nargs = "?", desc = "查看沙箱候选清单" })

  _cmd("NeoAISandboxCaps", function()
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local caps = sandbox.probe()
    local parts = {}
    for _, k in ipairs({ "bwrap", "unshare", "userns", "cgroup2", "overlayfs", "seccomp", "cgroup", "seccomp_filter" }) do
      parts[#parts + 1] = k .. "=" .. tostring(caps[k])
    end
    -- 权限档位与受控 docker 可用性
    local pcfg = require("NeoAI.kernel.config_store").get("tools.sandbox.privilege") or {}
    local dcfg = require("NeoAI.kernel.config_store").get("tools.sandbox.docker") or {}
    local dstat = "off"
    if dcfg.mode == "controlled" then
      dstat = (type(dcfg.socket) == "string" and vim.uv.fs_stat(dcfg.socket) ~= nil) and "ready" or "socket-missing"
    elseif dcfg.mode == "host" then
      dstat = "host"
    end
    parts[#parts + 1] = "privilege=" .. tostring(pcfg.enabled ~= false)
    parts[#parts + 1] = "max_tier=" .. tostring(pcfg.max_tier or 0)
    parts[#parts + 1] = "docker=" .. tostring(dcfg.mode or "?") .. "(" .. dstat .. ")"
    -- overlay 可用性诊断：不可用时给出原因（默认 fail-closed 会拒绝 process 工具）
    local runtime = require("NeoAI.sandbox.runtime")
    local diag = runtime.overlay_diagnosis(vim.fn.getcwd())
    parts[#parts + 1] = "overlay=" .. (diag.available and "ready"
      or ("unavailable(" .. tostring(diag.reason) .. ")"))
    local scfg = require("NeoAI.kernel.config_store").get("tools.sandbox") or {}
    parts[#parts + 1] = "overlay_fail_closed=" .. tostring(scfg.overlay_fail_closed ~= false)
    vim.notify("[NeoAI] 沙箱能力: " .. table.concat(parts, " "), vim.log.levels.INFO)
  end, { desc = "显示沙箱运行时能力探测结果" })

  --- 137 / OOM 归因：采集宿主/容器 cgroup 限制、负载与已解析沙箱限制
  _cmd("NeoAISandboxDiag", function()
    local ok, diag = pcall(require, "NeoAI.sandbox.diag")
    if not ok or type(diag.sandbox_limits) ~= "function" then
      vim.notify("[NeoAI] 诊断模块不可用", vim.log.levels.WARN)
      return
    end
    local info = diag.sandbox_limits()
    local lines = {}
    for _, k in ipairs({
      "pid1", "systemd", "nproc", "loadavg", "mem_total_kb",
      "root_memory_max", "root_memory_events", "root_pids_max", "root_pids_events",
      "neoai_cpu_max", "neoai_memory_max", "resolved_limits",
    }) do
      local v = info[k]
      if type(v) == "table" then v = vim.inspect(v):gsub("%s+", " ") end
      lines[#lines + 1] = string.format("%s=%s", k, tostring(v))
    end
    vim.notify("[NeoAI] 沙箱诊断:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "显示沙箱资源域/负载诊断（137/OOM 归因）" })

  --- 异步审批：列出待审修改（按路径级别高亮），选择应用
  _cmd("NeoAISandboxReview", function()
    require("NeoAI.ui.components.sandbox_review").open()
  end, { desc = "列出并应用待审的沙箱修改（按路径级别高亮）" })

  _cmd("NeoAISandboxApprove", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local id = (opts.args or ""):match("%S+")
    if not id then
      vim.notify("[NeoAI] 请指定变更单元 id（:NeoAISandboxReview 查看）", vim.log.levels.WARN)
      return
    end
    if sandbox.approve(id) then
      vim.notify("[NeoAI] 已批准（尚未应用）: " .. id, vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 变更单元不存在: " .. id, vim.log.levels.WARN)
    end
  end, { nargs = "?", desc = "批准沙箱变更单元（不应用）" })

  _cmd("NeoAISandboxReject", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local id = (opts.args or ""):match("%S+")
    if not id then
      vim.notify("[NeoAI] 请指定变更单元 id", vim.log.levels.WARN)
      return
    end
    if sandbox.reject(id) then
      vim.notify("[NeoAI] 已拒绝并丢弃: " .. id, vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 变更单元不存在: " .. id, vim.log.levels.WARN)
    end
  end, { nargs = "?", desc = "拒绝沙箱变更单元并丢弃候选" })

  _cmd("NeoAISandboxApply", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local parts = {}
    for arg in (opts.args or ""):gmatch("%S+") do parts[#parts + 1] = arg end
    local id = parts[1]
    if not id then
      vim.notify("[NeoAI] 用法: :NeoAISandboxApply <change_set_id> [file...]（:NeoAISandboxReview 查看）", vim.log.levels.WARN)
      return
    end
    local apply_opts = { auto_approve = true }
    if #parts > 1 then
      local files = {}
      for i = 2, #parts do files[#files + 1] = parts[i] end
      apply_opts.files = files
    end
    local res = sandbox.apply(id, apply_opts)
    if res.ok then
      vim.notify("[NeoAI] 已应用: " .. id, vim.log.levels.INFO)
    else
      vim.notify(("[NeoAI] 应用失败(%s): %s"):format(tostring(res.state), tostring(res.reason)), vim.log.levels.ERROR)
    end
  end, { nargs = "*", desc = "批准并应用沙箱变更单元（可指定文件子集：:NeoAISandboxApply <id> [file...]）" })

  _cmd("NeoAISandboxApplyAll", function()
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local res = sandbox.apply_all({ only_approved = false })
    vim.notify(("[NeoAI] 批量应用完成：成功 %d，失败 %d"):format(res.applied, res.failed), vim.log.levels.INFO)
  end, { desc = "应用全部待审沙箱变更单元" })

  _cmd("NeoAISandboxGrant", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local args = {}
    for a in (opts.args or ""):gmatch("%S+") do args[#args + 1] = a end
    local path = args[1] or vim.fn.getcwd()
    local ttl = tonumber(args[2])
    local g = sandbox.create_grant({
      scope = { paths = { path } },
      operations = { "fs_write" },
      budget = { max_files = tonumber(args[3]) or nil },
      ttl_sec = ttl,
      created_by = "user",
    })
    vim.notify(("[NeoAI] 已创建任务授权 %s：范围=%s ttl=%s"):format(g.grant_id, path, tostring(ttl)), vim.log.levels.INFO)
  end, { nargs = "*", desc = "创建窄范围任务授权（:NeoAISandboxGrant [path] [ttl_sec] [max_files]）" })

  _cmd("NeoAISandboxRevoke", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local id = (opts.args or ""):match("%S+")
    if not id then
      local lines = {}
      for _, g in ipairs(sandbox.list_grants()) do
        lines[#lines + 1] = string.format("%s  %s", g.grant_id, table.concat(g.scope.paths or {}, ","))
      end
      vim.notify("[NeoAI] 请指定 grant_id：\n" .. table.concat(lines, "\n"), vim.log.levels.WARN)
      return
    end
    if sandbox.revoke_grant(id) then
      vim.notify("[NeoAI] 已撤销授权: " .. id, vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 授权不存在: " .. id, vim.log.levels.WARN)
    end
  end, { nargs = "?", desc = "撤销任务授权（无参数列出全部）" })

  _cmd("NeoAISandboxPrune", function()
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local res = sandbox.prune()
    vim.notify(("[NeoAI] 已清理：变更单元 %d，候选 %d"):format(res.removed_reviews, res.removed_candidates), vim.log.levels.INFO)
  end, { desc = "按保留期清理过期候选与变更单元" })

  _cmd("NeoAISandboxMetrics", function()
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local m = sandbox.metrics()
    vim.notify(("[NeoAI] 沙箱指标：候选=%d 待审=%d 已应用=%d 已拒绝=%d 冲突=%d")
      :format(m.candidates, m.pending, m.applied, m.rejected, m.conflicts), vim.log.levels.INFO)
  end, { desc = "显示沙箱运行指标" })

  --- 行为审计与风险评估（监视 AI 的读取/调用行为）
  _cmd("NeoAISandboxAudit", function()
    local ok, audit = pcall(require, "NeoAI.sandbox.audit")
    if not ok then return end
    vim.notify("[NeoAI] " .. audit.summary(), vim.log.levels.INFO)
  end, { desc = "显示沙箱行为审计与风险评估摘要" })

  --- 会话级自动审批（默认关闭）：开启后 L0/L1 风险自动应用，包/密钥仍需确认
  _cmd("NeoAISandboxAutoApprove", function(opts)
    local review = require("NeoAI.sandbox.review")
    local arg = (opts.args or ""):match("%S+")
    if arg == "on" or arg == "true" then
      review.set_session_auto(true)
    elseif arg == "off" or arg == "false" then
      review.set_session_auto(false)
    elseif arg ~= nil and arg ~= "status" then
      vim.notify("[NeoAI] 用法: :NeoAISandboxAutoApprove [on|off|status]", vim.log.levels.WARN)
      return
    end
    local state = review.session_auto() and "开启" or "关闭"
    vim.notify(("[NeoAI] 新会话自动审批：%s（L2+ 与包/密钥仍会进入待审）"):format(state), vim.log.levels.INFO)
  end, { nargs = "?", desc = "设置 AI 新会话自动审批（默认关闭）" })

  _cmd("NeoAISandboxPublish", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local ids = {}
    for a in (opts.args or ""):gmatch("%S+") do ids[#ids + 1] = a end
    if #ids == 0 then
      vim.notify("[NeoAI] 用法: :NeoAISandboxPublish <change_set_id> [id...]", vim.log.levels.WARN)
      return
    end
    local set = sandbox.prepare_publication_set(ids)
    if set.state ~= "READY" then
      vim.notify(("[NeoAI] 组合发布集合不可用(%s)：missing=%s conflicts=%d")
        :format(set.state, table.concat(set.missing or {}, ","), #(set.conflicts or {})), vim.log.levels.ERROR)
      return
    end
    local res = sandbox.apply_set(set)
    if res.ok then
      vim.notify(("[NeoAI] 组合发布成功：%d 个变更单元"):format(#set.members), vim.log.levels.INFO)
    else
      vim.notify(("[NeoAI] 组合发布失败(%s): %s"):format(tostring(res.state), tostring(res.reason)), vim.log.levels.ERROR)
    end
  end, { nargs = "*", desc = "组合发布多个变更单元（含依赖闭包与 CAS）" })

  _cmd("NeoAISandboxReplay", function(opts)
    local sandbox = _svc("services.sandbox")
    if not sandbox then return end
    local id = (opts.args or ""):match("%S+")
    if not id then
      vim.notify("[NeoAI] 用法: :NeoAISandboxReplay <evidence_id>", vim.log.levels.WARN)
      return
    end
    local res = sandbox.replay(id)
    if not res.ok then
      vim.notify("[NeoAI] 回放失败: " .. tostring(res.reason), vim.log.levels.ERROR)
      return
    end
    vim.notify(("[NeoAI] 回放 %s：same=%s expected=%s actual=%s%s")
      :format(id, tostring(res.same), tostring(res.expected.decision), tostring(res.actual.decision),
        res.version_mismatch and "（策略版本不一致）" or ""), vim.log.levels.INFO)
  end, { nargs = "?", desc = "回放一条已记录的策略裁决" })

  _cmd("NeoAIApprovePlan", function()
    local chat_service = _svc("services.chat_service")
    if not chat_service then return end
    local function report(result)
      if result and result.approved then
        vim.notify(("[NeoAI] 计划已确认，已转入 CHAT 模式，任务清单 %d 项"):format(result.todo_count or 0), vim.log.levels.INFO)
      else
        vim.notify("[NeoAI] 确认计划失败: " .. tostring(result and result.error or "未知错误"), vim.log.levels.WARN)
      end
    end
    local result = chat_service.approve_plan()
    if result and result.then_ then
      result:then_(report, function(err)
        vim.notify("[NeoAI] 确认计划失败: " .. tostring(err and err.message or err), vim.log.levels.WARN)
      end)
    else
      report(result)
    end
  end, { desc = "确认计划并转入 CHAT 执行" })

  return function()
    for _, name in ipairs(COMMANDS) do
      pcall(vim.api.nvim_del_user_command, name)
    end
  end
end

return M
