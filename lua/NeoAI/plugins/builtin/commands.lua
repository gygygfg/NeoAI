--- 命令插件
--- @module 'NeoAI.plugins.builtin.commands'
--- 注册单一用户命令 `:NeoAI`，子命令以空格分隔（`:NeoAI Open`、`:NeoAI SandboxList`）。
--- Neovim 用户命令名不允许包含 `.` / `_` / `-`（`:NeoAI.Open` 会报 Invalid command name），
--- 因此不提供字面点号语法；命令名补全只会出现 `NeoAI`，输入空格后再补全子命令。
--- 业务调用一律经 kernel.services.use 获取服务；卸载时删除命令（副作用可卸载）。

local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有函数 ==========

--- 懒获取服务（缺失时返回 nil，由调用方降级）
--- @param name string
--- @return any
local function _svc(name)
  return services.use(name)
end

--- 取子命令的第一个位置参数
--- @param sub_opts table
--- @return string|nil
local function _first_arg(sub_opts)
  local fargs = (sub_opts and sub_opts.fargs) or {}
  return fargs[1]
end

-- ========== 子命令表 ==========
-- 顺序即补全与文档的展示顺序。phase1=true 的子命令在「阶段 1（UI/chat/status）」
-- 就绪后即可执行；其余需全量启动（工具/沙箱/skills/mcp 等后台服务）完成后再执行。
-- handler 统一签名 function(sub_opts)，sub_opts 含 args（剩余参数原文拼接）、fargs、
-- bang、mods、count、range/line1/line2。
local SUBCOMMANDS = {
  {
    name = "Open",
    phase1 = true,
    desc = "打开 NeoAI 默认界面",
    handler = function()
      local ui = _svc("services.ui")
      if ui then ui.open_default() end
    end,
  },
  {
    name = "Chat",
    phase1 = true,
    desc = "打开 NeoAI 聊天界面（新标签页/新会话）",
    handler = function()
      local ui = _svc("services.ui")
      -- 每次显式打开都在**新标签页**开一个独立聊天实例（唯一 buffer 名；旧实例保留继续运行）。
      if ui then ui.open_chat({ new_window = true }) end
    end,
  },
  {
    name = "Tree",
    phase1 = true,
    desc = "打开 NeoAI 会话树界面",
    handler = function()
      local ui = _svc("services.ui")
      if ui then ui.open_tree() end
    end,
  },
  {
    name = "Close",
    phase1 = true,
    desc = "关闭所有 NeoAI 窗口",
    handler = function()
      local ui = _svc("services.ui")
      if ui then ui.close_all() end
    end,
  },
  {
    name = "Keymaps",
    phase1 = true,
    desc = "显示 NeoAI 当前键位配置",
    handler = function()
      local ui = _svc("services.ui")
      if ui then ui.show_keymaps() end
    end,
  },
  {
    name = "Statusline",
    phase1 = true,
    desc = "预览 NeoAI lualine 状态栏组件内容",
    handler = function()
      local status = _svc("services.status")
      if not status then return end
      local text = status.component()
      if text == "" then
        vim.notify("[NeoAI] (无激活 Agent)", vim.log.levels.INFO)
      else
        vim.notify("[NeoAI] " .. text:gsub("%%%%", "%"), vim.log.levels.INFO)
      end
    end,
  },
  {
    name = "Test",
    phase1 = true,
    desc = "并行运行 NeoAI 测试（指定套件名则顺序执行）",
    handler = function(sub_opts)
      local ok, tests = pcall(require, "NeoAI.tests")
      if not ok then
        vim.notify("[NeoAI] 测试模块加载失败: " .. tostring(tests), vim.log.levels.ERROR)
        return
      end
      local args = sub_opts.args or ""
      local names = {}
      for arg in args:gmatch("%S+") do
        table.insert(names, arg)
      end
      -- 隔离子进程运行：套件会改写 registry/plugins/sandbox 等全局状态，且运行器无 after_each
      -- 恢复；在当前进程内跑会清空线上工具集（导致后续请求缺失 run_command 等），因此一律
      -- 用全新 headless nvim 执行，绝不触碰当前进程。
      if #names > 0 then
        -- 指定套件：单进程顺序执行，便于定位单个套件。
        vim.notify("[NeoAI] 已在隔离子进程启动测试（顺序）…", vim.log.levels.INFO)
        tests.run_isolated(names, {
          on_done = function(res)
            if res.passed + res.failed > 0 then
              vim.notify(
                string.format("[NeoAI] 测试结果（隔离子进程）: %d 通过, %d 失败", res.passed, res.failed),
                res.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
            else
              vim.notify(
                "[NeoAI] 测试子进程异常退出（code=" .. tostring(res.exit_code) .. "）\n" .. res.output:sub(1, 2000),
                vim.log.levels.ERROR)
            end
            if #res.errors > 0 then
              vim.notify("失败测试:\n  " .. table.concat(res.errors, "\n  "), vim.log.levels.WARN)
            end
          end,
        })
        return
      end
      -- 空参数：并行全量运行（多 worker 隔离子进程），交互式等待不阻塞。
      local ok_p, parallel = pcall(require, "NeoAI.tests.parallel")
      if not ok_p then
        vim.notify("[NeoAI] 并行测试模块加载失败: " .. tostring(parallel), vim.log.levels.ERROR)
        return
      end
      vim.notify("[NeoAI] 已并行启动全量测试…", vim.log.levels.INFO)
      parallel.run({
        wait = false,
        on_done = function(res)
          vim.notify(
            string.format("[NeoAI] 并行测试结果: %d 通过, %d 失败（%.1fs, %d worker）",
              res.passed, res.failed, res.elapsed_ms / 1000, res.workers),
            res.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
          if #res.errors > 0 then
            vim.notify("失败测试:\n  " .. table.concat(res.errors, "\n  "), vim.log.levels.WARN)
          end
        end,
      })
    end,
  },
  {
    name = "ChatStatus",
    phase1 = true,
    desc = "显示 NeoAI 聊天窗口状态",
    handler = function()
      local ui = _svc("services.ui")
      if ui then ui.chat_status() end
    end,
  },
  {
    name = "CycleDisplay",
    phase1 = true,
    desc = "循环切换聊天显示模式（对话/轨迹）",
    handler = function()
      local ui = _svc("services.ui")
      local chat_view = ui and ui.get_chat_view()
      if not chat_view then return end
      local plugin = chat_view.cycle_display()
      if plugin then
        vim.notify("[NeoAI] 显示模式已切换: " .. (plugin.label or plugin.name), vim.log.levels.INFO)
      end
    end,
  },
  {
    name = "WindowMode",
    phase1 = true,
    desc = "切换窗口模式（tab/float/split；缺省显示当前模式）",
    handler = function(sub_opts)
      local ui = _svc("services.ui")
      if not ui then return end
      local mode = _first_arg(sub_opts)
      if mode == nil or mode == "" then
        vim.notify(("[NeoAI] 当前窗口模式: %s（可选: tab / float / split）"):format(ui.window_mode()),
          vim.log.levels.INFO)
        return
      end
      -- 切换并立即重建已打开窗口；Agent 正在运行时仅更新配置（避免打断当前回合）。
      ui.set_window_mode(mode)
    end,
  },
  {
    name = "ReloadDisplay",
    phase1 = true,
    desc = "热重载显示模式插件（缺省重载当前模式）",
    handler = function(sub_opts)
      local ui = _svc("services.ui")
      local chat_view = ui and ui.get_chat_view()
      if not chat_view then return end
      local name = _first_arg(sub_opts)
      local plugin = chat_view.reload_display(name)
      if plugin then
        vim.notify("[NeoAI] 显示模式插件已热重载: " .. (plugin.label or plugin.name), vim.log.levels.INFO)
      end
    end,
  },
  {
    name = "Compact",
    phase1 = true,
    desc = "手动压缩当前会话上下文（忽略压力阈值，保留最近一轮）",
    handler = function()
      local chat_service = _svc("services.chat_service")
      if not chat_service then return end
      local agent = chat_service.get_current_agent()
      if not agent then
        vim.notify("[NeoAI] 无当前 Agent，无法压缩上下文", vim.log.levels.WARN)
        return
      end
      if agent._compacting or agent._compaction_pending then
        vim.notify("[NeoAI] 上下文压缩正在进行，请稍候", vim.log.levels.INFO)
        return
      end
      -- 压缩会在轮次边界替换较早历史的请求视图；生成/工具执行中强行压缩会与消息写入竞态。
      if agent.state == "generating" or agent.state == "tool_running" then
        vim.notify("[NeoAI] Agent 正在运行，请等本轮结束后再手动压缩", vim.log.levels.WARN)
        return
      end
      local compactor = require("NeoAI.core.session.compactor")
      vim.notify("[NeoAI] 开始手动压缩上下文…", vim.log.levels.INFO)
      local d = compactor.compact_now(agent)
      local function done(ok)
        local status = _svc("services.status")
        if status and status.refresh then status.refresh() end
        local ui = _svc("services.ui")
        local view = ui and ui.get_chat_view()
        if view then view.refresh() end
        if ok then
          vim.notify("[NeoAI] 上下文压缩完成（较早历史已替换为检查点）", vim.log.levels.INFO)
        else
          vim.notify("[NeoAI] 可折叠的上下文过少，未执行压缩", vim.log.levels.WARN)
        end
      end
      if d and d.then_ then
        d:then_(done, function(err)
          vim.notify("[NeoAI] 上下文压缩失败: " .. tostring(err and err.message or err), vim.log.levels.ERROR)
        end)
      end
    end,
  },
  {
    name = "Plan",
    phase1 = true,
    desc = "切换计划模式",
    handler = function()
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
    end,
  },
  {
    name = "Privileged",
    phase1 = true,
    desc = "切换高权限模式（网络仅记录、直连 docker/podman、不遮蔽 SSH 密钥）",
    handler = function()
      local chat_service = _svc("services.chat_service")
      if not chat_service then return end
      local active, reason = chat_service.toggle_privileged_mode()
      local ui = _svc("services.ui")
      local view = ui and ui.get_chat_view()
      if view then view.refresh() end
      if active == nil then
        local text = reason == "PRIVILEGED_MODE_DISABLED"
          and "高权限模式未启用（设置 tools.privileged_mode.enabled = true）"
          or reason == "PRIVILEGED_MODE_REQUIRES_ASYNC"
          and "高权限模式仅支持异步审批（tools.approval.mode = \"async\"）"
          or reason == "NO_AGENT"
          and "无当前 Agent，无法切换高权限模式"
          or tostring(reason or "未知原因")
        vim.notify("[NeoAI] 无法切换高权限模式：" .. text, vim.log.levels.WARN)
      else
        local suffix = chat_service.pending_mode_hint and chat_service.pending_mode_hint() or ""
        vim.notify("[NeoAI] 高权限模式已" .. (active and "开启" or "关闭") .. suffix,
          active and vim.log.levels.WARN or vim.log.levels.INFO)
      end
    end,
  },
  {
    name = "ApprovePlan",
    phase1 = true,
    desc = "确认计划并转入 CHAT 执行",
    handler = function()
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
    end,
  },
  {
    name = "ReloadAll",
    desc = "热重载整个 NeoAI 插件（先隔离子进程预检，失败则取消）",
    handler = function()
      local reload_all = require("NeoAI.plugins.reload")
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
    end,
  },
  {
    name = "SandboxCommit",
    desc = "应用沙箱候选到真实工作区（CAS 发布）",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then
        vim.notify("[NeoAI] 沙箱服务不可用", vim.log.levels.ERROR)
        return
      end
      local digest = _first_arg(sub_opts)
      if not digest then
        local list = sandbox.list()
        if #list == 0 then
          vim.notify("[NeoAI] 无待处理候选", vim.log.levels.INFO)
        else
          vim.notify("[NeoAI] 请指定候选摘要（:NeoAI SandboxList 查看）", vim.log.levels.WARN)
        end
        return
      end
      local res = sandbox.commit(digest)
      if res.ok then
        vim.notify(("[NeoAI] 候选已发布: %s（%d 项）"):format(digest, res.receipt and res.receipt.file_count or 0), vim.log.levels.INFO)
      else
        vim.notify(("[NeoAI] 发布失败(%s): %s"):format(tostring(res.state), tostring(res.reason)), vim.log.levels.ERROR)
      end
    end,
  },
  {
    name = "SandboxDiscard",
    desc = "丢弃沙箱候选",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local digest = _first_arg(sub_opts)
      if not digest then
        vim.notify("[NeoAI] 请指定候选摘要", vim.log.levels.WARN)
        return
      end
      if sandbox.discard(digest) then
        vim.notify("[NeoAI] 候选已丢弃: " .. digest, vim.log.levels.INFO)
      else
        vim.notify("[NeoAI] 候选不存在: " .. digest, vim.log.levels.WARN)
      end
    end,
  },
  {
    name = "SandboxList",
    desc = "列出沙箱待处理候选",
    handler = function()
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
    end,
  },
  {
    name = "SandboxShow",
    desc = "查看沙箱候选清单",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local digest = _first_arg(sub_opts)
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
    end,
  },
  {
    name = "SandboxCaps",
    desc = "显示沙箱运行时能力探测结果",
    handler = function()
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local caps = sandbox.probe()
      local parts = {}
      for _, k in ipairs({ "bwrap", "bwrap_version", "unshare", "userns", "cgroup2", "overlayfs", "seccomp", "cgroup", "seccomp_filter" }) do
        parts[#parts + 1] = k .. "=" .. tostring(caps[k])
      end
      -- 权限档位与容器门面（只走 podman；宿主 docker daemon 永不连接）
      local pcfg = require("NeoAI.kernel.config_store").get("tools.sandbox.privilege") or {}
      local ccfg = require("NeoAI.kernel.config_store").get("tools.sandbox.container") or {}
      local podman_ok = vim.fn.executable("podman") == 1
      local cstat = not (ccfg.enabled ~= false) and "off"
        or (podman_ok and "podman-ready" or "podman-missing")
      parts[#parts + 1] = "privilege=" .. tostring(pcfg.enabled ~= false)
      parts[#parts + 1] = "max_tier=" .. tostring(pcfg.max_tier or 0)
      parts[#parts + 1] = "container=" .. tostring(cstat)
      -- overlay 可用性诊断：不可用时给出原因（默认 fail-closed 会拒绝 process 工具）
      local diag = sandbox.overlay_diagnosis(vim.fn.getcwd())
      parts[#parts + 1] = "overlay=" .. (diag.available and "ready"
        or ("unavailable(" .. tostring(diag.reason) .. ")"))
      -- seccomp 施加方式（bwrap|unshare|none）与第 2 层行为兜底可用性（诊断降级落到哪一层）
      pcall(function()
        local runtime = require("NeoAI.sandbox.execution.runtime")
        parts[#parts + 1] = "seccomp_mode=" .. tostring(runtime.seccomp_mode())
        local obs = require("NeoAI.sandbox.observe.observer")
        parts[#parts + 1] = "backstop=" .. (obs.backstop_available() and "ebpf" or "none")
      end)
      -- 资源压力等级与**观测**是否被降级。注意上面的 seccomp_mode/backstop 属安全强制层，
      -- 绝不随资源压力降级；这里只反映「观测探针是否值得启动」这类性能取舍。
      local pressure_line = ""
      pcall(function()
        local pressure = require("NeoAI.kernel.pressure")
        parts[#parts + 1] = "pressure=" .. tostring(pressure.level())
        local obs_ok, obs_reason = require("NeoAI.sandbox.observe.observer").observation_allowed()
        parts[#parts + 1] = "observe=" .. (obs_ok and "on" or ("off(" .. tostring(obs_reason) .. ")"))
        local degs = pressure.degradations()
        pressure_line = #degs > 0
          and ("\n资源压力降级: " .. table.concat(degs, "；"))
          or "\n资源压力降级: 无（全速运行）"
      end)
      vim.notify("[NeoAI] 沙箱能力: " .. table.concat(parts, " ") .. pressure_line, vim.log.levels.INFO)
    end,
  },
  {
    name = "SandboxDiag",
    desc = "显示沙箱资源域/负载/资源压力诊断（137/OOM/卡顿归因）",
    handler = function()
      local ok, diag = pcall(require, "NeoAI.sandbox.observe.diag")
      if not ok or type(diag.sandbox_limits) ~= "function" then
        vim.notify("[NeoAI] 诊断模块不可用", vim.log.levels.WARN)
        return
      end
      local info = diag.sandbox_limits()
      local lines = {}
      for _, k in ipairs({
        "pid1", "systemd", "nproc", "loadavg", "mem_total_kb",
        "root_memory_max", "root_memory_events", "root_pids_max", "root_pids_events",
        "neoai_cpu_max", "neoai_memory_max", "cgroup_controllers", "resolved_limits",
        "pressure", "pressure_sandbox_memory_cap", "pressure_degradations",
      }) do
        local v = info[k]
        if type(v) == "table" then v = vim.inspect(v):gsub("%s+", " ") end
        lines[#lines + 1] = string.format("%s=%s", k, tostring(v))
      end
      -- 人类可读汇总（等级 + 已生效降级），避免用户自行解读上面的原始字节数
      pcall(function()
        local pressure = require("NeoAI.kernel.pressure")
        lines[#lines + 1] = "压力描述: " .. pressure.describe()
      end)
      vim.notify("[NeoAI] 沙箱诊断:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
    end,
  },
  {
    name = "SandboxReview",
    desc = "列出并应用待审的沙箱修改（按路径级别高亮）",
    handler = function()
      local ui = _svc("services.ui")
      if ui and ui.open_sandbox_review then ui.open_sandbox_review() end
    end,
  },
  {
    name = "SandboxApprove",
    desc = "批准沙箱变更单元（不应用）",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local id = _first_arg(sub_opts)
      if not id then
        vim.notify("[NeoAI] 请指定变更单元 id（:NeoAI SandboxReview 查看）", vim.log.levels.WARN)
        return
      end
      if sandbox.approve(id) then
        vim.notify("[NeoAI] 已批准（尚未应用）: " .. id, vim.log.levels.INFO)
      else
        vim.notify("[NeoAI] 变更单元不存在: " .. id, vim.log.levels.WARN)
      end
    end,
  },
  {
    name = "SandboxReject",
    desc = "拒绝沙箱变更单元并丢弃候选",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local id = _first_arg(sub_opts)
      if not id then
        vim.notify("[NeoAI] 请指定变更单元 id", vim.log.levels.WARN)
        return
      end
      if sandbox.reject(id) then
        vim.notify("[NeoAI] 已拒绝并丢弃: " .. id, vim.log.levels.INFO)
      else
        vim.notify("[NeoAI] 变更单元不存在: " .. id, vim.log.levels.WARN)
      end
    end,
  },
  {
    name = "SandboxApply",
    desc = "批准并应用沙箱变更单元（可指定文件子集：:NeoAI SandboxApply <id> [file...]）",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local parts = {}
      for arg in (sub_opts.args or ""):gmatch("%S+") do parts[#parts + 1] = arg end
      local id = parts[1]
      if not id then
        vim.notify("[NeoAI] 用法: :NeoAI SandboxApply <change_set_id> [file...]（:NeoAI SandboxReview 查看）", vim.log.levels.WARN)
        return
      end
      local apply_opts = { auto_approve = true }
      if #parts > 1 then
        local files = {}
        for i = 2, #parts do files[#files + 1] = parts[i] end
        apply_opts.files = files
      end
      local function report(res)
        if res and res.ok then
          vim.notify("[NeoAI] 已应用: " .. id, vim.log.levels.INFO)
        else
          vim.notify(("[NeoAI] 应用失败(%s): %s"):format(tostring(res and res.state), tostring(res and res.reason)),
            vim.log.levels.ERROR)
        end
      end
      if sandbox.apply_async then
        local p = sandbox.apply_async(id, apply_opts)
        if p and type(p.then_) == "function" then
          p:then_(report, function(e)
            report({ ok = false, state = "FAILED", reason = tostring(e and (e.message or e) or e) })
          end)
          return
        end
      end
      report(sandbox.apply(id, apply_opts))
    end,
  },
  {
    name = "SandboxApplyAll",
    desc = "应用全部待审沙箱变更单元",
    handler = function()
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local function report(res)
        vim.notify(("[NeoAI] 批量应用完成：成功 %d，失败 %d"):format(res.applied, res.failed),
          vim.log.levels.INFO)
      end
      if sandbox.apply_all_async then
        local p = sandbox.apply_all_async({ only_approved = false })
        if p and type(p.then_) == "function" then
          p:then_(report, function(e)
            vim.notify("[NeoAI] 批量应用失败: " .. tostring(e and (e.message or e) or e),
              vim.log.levels.ERROR)
          end)
          return
        end
      end
      report(sandbox.apply_all({ only_approved = false }))
    end,
  },
  {
    name = "SandboxGrant",
    desc = "创建窄范围任务授权（:NeoAI SandboxGrant [path] [ttl_sec] [max_files]）",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local args = (sub_opts and sub_opts.fargs) or {}
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
    end,
  },
  {
    name = "SandboxRevoke",
    desc = "撤销任务授权（无参数列出全部）",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local id = _first_arg(sub_opts)
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
    end,
  },
  {
    name = "SandboxPrune",
    desc = "按保留期清理过期候选与变更单元",
    handler = function()
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local res = sandbox.prune()
      vim.notify(("[NeoAI] 已清理：变更单元 %d，候选 %d"):format(res.removed_reviews, res.removed_candidates), vim.log.levels.INFO)
    end,
  },
  {
    name = "SandboxMetrics",
    desc = "显示沙箱运行指标",
    handler = function()
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local m = sandbox.metrics()
      vim.notify(("[NeoAI] 沙箱指标：候选=%d 待审=%d 已应用=%d 已拒绝=%d 冲突=%d")
        :format(m.candidates, m.pending, m.applied, m.rejected, m.conflicts), vim.log.levels.INFO)
    end,
  },
  {
    name = "SandboxAudit",
    desc = "显示沙箱行为审计与风险评估摘要（network = 查看网络访问记录）",
    handler = function(sub_opts)
      local kind = _first_arg(sub_opts)
      if kind == "network" then
        local ok, hp = pcall(require, "NeoAI.sandbox.net.host_proxy")
        if not ok then return end
        -- 高权限模式另有一份不会被 host_proxy.summary drain 的环形记录；优先读取它。
        local recs = {}
        local okp, sp = pcall(require, "NeoAI.sandbox.privileged")
        if okp and type(sp.records) == "function" then recs = sp.records(50) end
        if #recs == 0 then recs = hp.recent(50) end
        if #recs == 0 then
          vim.notify("[NeoAI] 暂无网络访问记录", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, r in ipairs(recs) do
          local at = os.date("%H:%M:%S", tonumber(r.at) or os.time())
          lines[#lines + 1] = ("%s  %-10s %s:%s -> %s"):format(
            at, tostring(r.proto or "?"), tostring(r.host or "?"), tostring(r.port or "?"),
            tostring(r.decision or "?"))
        end
        vim.notify("[NeoAI] 最近网络访问记录：\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
        return
      end
      local ok, audit = pcall(require, "NeoAI.sandbox.observe.audit")
      if not ok then return end
      vim.notify("[NeoAI] " .. audit.summary(), vim.log.levels.INFO)
    end,
  },
  {
    name = "SandboxAutoApprove",
    desc = "设置 AI 新会话自动审批（默认关闭）",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local arg = _first_arg(sub_opts)
      if arg == "on" or arg == "true" then
        sandbox.set_session_auto(true)
      elseif arg == "off" or arg == "false" then
        sandbox.set_session_auto(false)
      elseif arg ~= nil and arg ~= "status" then
        vim.notify("[NeoAI] 用法: :NeoAI SandboxAutoApprove [on|off|status]", vim.log.levels.WARN)
        return
      end
      local state = sandbox.session_auto() and "开启" or "关闭"
      vim.notify(("[NeoAI] 新会话自动审批：%s（L2+ 与包/密钥仍会进入待审）"):format(state), vim.log.levels.INFO)
    end,
  },
  {
    name = "SandboxPublish",
    desc = "组合发布多个变更单元（含依赖闭包与 CAS）",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local ids = {}
      for a in (sub_opts.args or ""):gmatch("%S+") do ids[#ids + 1] = a end
      if #ids == 0 then
        vim.notify("[NeoAI] 用法: :NeoAI SandboxPublish <change_set_id> [id...]", vim.log.levels.WARN)
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
    end,
  },
  {
    name = "SandboxReplay",
    desc = "回放一条已记录的策略裁决",
    handler = function(sub_opts)
      local sandbox = _svc("services.sandbox")
      if not sandbox then return end
      local id = _first_arg(sub_opts)
      if not id then
        vim.notify("[NeoAI] 用法: :NeoAI SandboxReplay <evidence_id>", vim.log.levels.WARN)
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
    end,
  },
  {
    name = "HerderStatus",
    desc = "显示 Herder 集成状态",
    handler = function()
      local install = _svc("services.herder_install")
      local herder = _svc("services.herder")
      if not install or not herder then
        vim.notify("[NeoAI] Herder 服务未加载", vim.log.levels.WARN)
        return
      end
      local st = install.status()
      local lines = {
        ("Herder 环境: %s"):format(st.herdr_env and "是" or "否（非 Herder 环境，集成 no-op）"),
        ("当前 pane: %s"):format(tostring(st.pane_id)),
        ("上报状态: %s"):format(st.reporting and "进行中" or "未接管（无活跃 agent 或未启用）"),
        ("上报标识: source=%s agent=%s display_agent=%s"):format(
          tostring(st.source), tostring(st.agent), tostring(st.display_agent)),
        ("配置文件: %s%s"):format(st.config_path, st.config_exists and "" or "（不存在）"),
        ("展示增强片段: %s"):format(st.installed and "已安装" or "未安装"),
      }
      vim.notify("[NeoAI] Herder 集成状态：\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
    end,
  },
  {
    name = "HerderConfig",
    desc = "查看/安装/卸载 Herder 展示增强配置片段",
    handler = function(sub_opts)
      local install = _svc("services.herder_install")
      if not install then
        vim.notify("[NeoAI] Herder 安装服务未加载", vim.log.levels.WARN)
        return
      end
      local sub = _first_arg(sub_opts)
      if sub == nil or sub == "show" then
        vim.notify("[NeoAI] 推荐 Herdr 配置片段（:NeoAI HerderConfig install 写入）：\n" .. install.snippet(), vim.log.levels.INFO)
        return
      end
      if sub == "install" then
        local res = install.install()
        if res.ok then
          vim.notify(("[NeoAI] Herder 配置片段：%s（%s）"):format(res.changed and "已写入" or "已存在，跳过", res.path), vim.log.levels.INFO)
        else
          vim.notify("[NeoAI] 写入失败（已回滚）: " .. tostring(res.error), vim.log.levels.ERROR)
        end
        return
      end
      if sub == "uninstall" then
        local res = install.uninstall()
        if res.ok then
          vim.notify(("[NeoAI] Herder 配置片段：%s（%s）"):format(res.changed and "已移除" or "未安装，跳过", res.path), vim.log.levels.INFO)
        else
          vim.notify("[NeoAI] 移除失败（已回滚）: " .. tostring(res.error), vim.log.levels.ERROR)
        end
        return
      end
      vim.notify("[NeoAI] 用法: :NeoAI HerderConfig [show|install|uninstall]", vim.log.levels.WARN)
    end,
  },
  {
    name = "Doctor",
    desc = "NeoAI 环境诊断（等同 :checkhealth NeoAI 的摘要）",
    handler = function()
      require("NeoAI.health").doctor()
    end,
  },
}

-- ========== 私有函数（依赖子命令表） ==========

--- 按名称查子命令（大小写不敏感）
--- @param name string|nil
--- @return table|nil
local function _find(name)
  if type(name) ~= "string" or name == "" then return nil end
  local lower = name:lower()
  for _, spec in ipairs(SUBCOMMANDS) do
    if spec.name:lower() == lower then return spec end
  end
  return nil
end

--- 全部子命令名（声明顺序）
--- @return table 数组
local function _names()
  local out = {}
  for _, spec in ipairs(SUBCOMMANDS) do out[#out + 1] = spec.name end
  return out
end

--- 打印用法与可用子命令
--- @param unknown string|nil 未识别的子命令名
local function _notify_usage(unknown)
  local head = unknown and ("[NeoAI] 未知子命令: " .. tostring(unknown)) or "[NeoAI] 缺少子命令"
  vim.notify(
    head .. "\n用法: :NeoAI <子命令> [参数]\n可用子命令: " .. table.concat(_names(), " "),
    vim.log.levels.WARN)
end

--- 由聚合命令的 user_command 回调重建子命令参数表
--- 保留 bang/mods/count/range 语义，args 取「子命令名之后的剩余参数」原文拼接。
--- @param opts table user_command 回调参数
--- @return table sub_opts
local function _sub_opts(opts)
  local fargs = opts.fargs or {}
  local rest = {}
  for i = 2, #fargs do rest[#rest + 1] = fargs[i] end
  return {
    name = fargs[1],
    args = table.concat(rest, " "),
    fargs = rest,
    bang = opts.bang,
    mods = opts.mods,
    smods = opts.smods,
    count = opts.count,
    range = opts.range,
    line1 = opts.line1,
    line2 = opts.line2,
  }
end

-- ========== 公开 API ==========

--- 全部子命令定义（诊断/测试用；不要在外部修改）
M.SUBCOMMANDS = SUBCOMMANDS

--- 本插件注册的唯一命令名
M.COMMAND = "NeoAI"

--- 子命令名数组（声明顺序）
M.NAMES = _names()

--- 子命令名 → 说明 映射（供命令提示浮窗 / cmp 源展示，避免外部再解析表结构）
--- @return table<string, string>
function M.subcommand_descs()
  local out = {}
  for _, spec in ipairs(SUBCOMMANDS) do out[spec.name] = spec.desc end
  return out
end

--- 判断子命令是否阶段 1 即可执行（懒加载占位与文档共用单一来源）
--- @param name string|nil
--- @return boolean
function M.is_phase1(name)
  local spec = _find(name)
  return spec ~= nil and spec.phase1 == true
end

--- 命令名/子命令补全（complete=customlist 回调）
--- customlist 返回值不会被 Vim 二次过滤，因此这里必须自行按 ArgLead 做前缀过滤。
--- 只在补全**第一个参数**（即子命令）时返回候选；已在输入后续参数时返回空表。
--- @param arglead string 当前正在补全的词
--- @param cmdline string 当前完整命令行
--- @param cursorpos number 光标位置（1-based 字节下标）
--- @return table 纯字符串候选数组
function M.complete(arglead, cmdline, cursorpos)
  arglead = arglead or ""
  local line = cmdline or ""
  local pos = tonumber(cursorpos) or #line
  if pos > 0 and pos <= #line then line = line:sub(1, pos) end
  -- 去掉前导空白与 `:`
  line = line:gsub("^%s*:?", "")
  -- 去掉命令名本身；rest 为命令名之后的内容
  local rest = line:match("^%S+%s(.*)$") or ""
  -- arglead 之前若已有其他 token，说明正在补全第二个及以后的参数 → 不补全子命令
  local before = #rest >= #arglead and rest:sub(1, #rest - #arglead) or rest
  if before:find("%S") then
    -- 唯一支持参数补全的子命令：WindowMode 补 tab / float / split。
    local first = line:match("^%S+%s+(%S+)")
    if first and first:lower() == "windowmode" then
      local lead = arglead:lower()
      local out = {}
      for _, m in ipairs({ "tab", "float", "split" }) do
        if lead == "" or m:sub(1, #lead) == lead then out[#out + 1] = m end
      end
      return out
    end
    return {}
  end
  local lead = arglead:lower()
  local out = {}
  for _, spec in ipairs(SUBCOMMANDS) do
    if lead == "" or spec.name:lower():sub(1, #lead) == lead then
      out[#out + 1] = spec.name
    end
  end
  return out
end

--- 分发一次 `:NeoAI <子命令> ...` 调用
--- @param opts table user_command 回调参数
--- @return boolean 是否成功分发
function M.dispatch(opts)
  local fargs = (opts and opts.fargs) or {}
  local name = fargs[1]
  if not name or name == "" then
    _notify_usage()
    return false
  end
  local spec = _find(name)
  if not spec then
    _notify_usage(name)
    return false
  end
  local ok, err = pcall(spec.handler, _sub_opts(opts))
  if not ok then
    vim.notify("[NeoAI] 子命令执行失败: " .. spec.name .. "\n" .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- 注册 `:NeoAI` 命令
--- @return function 清理函数
function M.start()
  vim.api.nvim_create_user_command(M.COMMAND, function(opts)
    M.dispatch(opts)
  end, {
    nargs = "*",
    complete = function(arglead, cmdline, cursorpos)
      return M.complete(arglead, cmdline, cursorpos)
    end,
    force = true,
    desc = "NeoAI 命令集合（用法：:NeoAI <子命令>）",
  })

  -- 命令提示（子命令说明浮窗 / cmp 源）：仅内置 API，缺失依赖时自动降级
  local hint_cleanup = nil
  local ok_hint, hint = pcall(require, "NeoAI.ui.command_hint")
  if ok_hint and hint and type(hint.install) == "function" then
    local ok_install, cleanup = pcall(hint.install)
    if ok_install and type(cleanup) == "function" then hint_cleanup = cleanup end
  end

  return function()
    if hint_cleanup then pcall(hint_cleanup) end
    pcall(vim.api.nvim_del_user_command, M.COMMAND)
  end
end

return M
