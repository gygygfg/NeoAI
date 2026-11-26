--- 受保护资源的后果文案
--- @module 'NeoAI.sandbox.review.consequence'
--- 审批界面与待审条目共用的「后果告知」文案。每个条目固定五段：
---   title / ability（拿到什么能力）/ scope（影响范围）/ persistence（持续多久）/
---   suggestion（建议）。
---
--- 为什么集中在这里：同一个风险（读 SSH 私钥）可能来自遮蔽目录审批、密钥告警、
--- 待审条目标注等多个入口；各写一套文案会让用户看到互相矛盾的说法，也会让审计证据
--- 无法按 id 回放。**模板可被 `tools.sandbox.protected.consequences` 覆盖**，但 id 稳定。
---
--- 文案只描述事实，不替用户做决定；也不提供「永久允许」——放行范围只有「仅本次」与
--- 「本会话」两种，落地都可在会话内撤销。

local M = {}

-- ========== 私有常量 ==========

--- 内置后果表（id 与 `sandbox/protected/registry.lua` 一致）
--- @type table<string, table>
local CATALOG = {
  ssh_private_key = {
    title = "SSH 私钥",
    ability = "AI 可复制该私钥，并以你的身份登录任意接受该密钥的主机；也能解密受它保护的数据",
    scope = "~/.ssh 下的私钥与同目录配置（config / known_hosts / agent socket）",
    persistence = "放行后本会话内持续有效；仅选「仅本次」时只对本次调用生效",
    suggestion = "只拉代码时改用 git 工具；确需放行时选「仅本次」",
  },
  ssh_service = {
    title = "本机 SSH 服务与 agent",
    ability = "可连接 ssh-agent 借用已加载的私钥签名（不需要知道密钥本身），也可操作本机 sshd",
    scope = "/run/sshd、ssh-agent / gpg-agent 套接字、/tmp/ssh-*",
    persistence = "放行后本会话内持续有效；仅选「仅本次」时只对本次调用生效",
    suggestion = "非排障场景不要放行 agent socket",
  },
  credential_store = {
    title = "云端 / 版本控制凭据",
    ability = "AI 可用该凭据访问你的云账号、代码托管或包仓库（范围取决于令牌权限）",
    scope = "~/.aws、~/.gnupg、~/.kube、~/.netrc、git-credentials、gh / gcloud 配置",
    persistence = "放行后本会话内持续有效；仅选「仅本次」时只对本次调用生效",
    suggestion = "优先使用最小权限、可撤销的短期令牌",
  },
  system_account_db = {
    title = "宿主账户数据库",
    ability = "可读取全部账户口令哈希（可离线爆破），并可读取提权配置",
    scope = "/etc/shadow、/etc/gshadow、/etc/sudoers、/etc/passwd、/etc/group",
    persistence = "放行后本会话内持续有效；仅选「仅本次」时只对本次调用生效",
    suggestion = "账户修复类操作建议在独立会话中手动完成",
  },
  container_socket = {
    title = "容器运行时 socket",
    ability = "等同宿主 root：可在宿主上创建特权容器、挂载宿主目录",
    scope = "docker / containerd / podman socket 与镜像数据",
    persistence = "放行后本会话内持续有效；仅选「仅本次」时只对本次调用生效",
    suggestion = "需要容器时让 NeoAI 使用会话内 rootless runtime",
  },
  loader_hook = {
    title = "动态加载器钩子",
    ability = "写入后沙箱内每个进程都会加载指定库，等于代码注入原语",
    scope = "/etc/ld.so.preload",
    persistence = "写入后对该视图内后续所有进程生效",
    suggestion = "该文件正常系统不应存在；不要放行",
  },
  host_identity = {
    title = "宿主身份标识",
    ability = "泄露主机标识与磁盘布局，可被用于跨会话关联与混淆沙箱视图",
    scope = "/etc/machine-id、/etc/hostid、/etc/fstab",
    persistence = "只读泄露一次即长期有效",
    suggestion = "无必要不要放行",
  },
  shell_rc = {
    title = "Shell 启动脚本",
    ability = "写入后每个登录 shell 都会执行，属持久化后门面",
    scope = "~/.bashrc、~/.zshrc、~/.profile 等启动脚本",
    persistence = "发布后写入真实文件，无自动回滚",
    suggestion = "优先改项目内脚本；确需改启动脚本时逐行确认 diff",
  },
  command_history = {
    title = "命令历史",
    ability = "历史中常有明文令牌、内网地址与命令参数",
    scope = "~/.bash_history、~/.zsh_history 等历史文件",
    persistence = "只读泄露一次即长期有效",
    suggestion = "无必要不要放行",
  },
  host_logs = {
    title = "宿主日志与计划任务",
    ability = "日志含内网拓扑、令牌与用户行为；计划任务可被用来持久化",
    scope = "/var/log、/etc/cron*、/var/spool/cron",
    persistence = "只读泄露一次即长期有效；写入计划任务为持久化",
    suggestion = "排障时优先读取项目内日志",
  },
}

-- ========== 私有函数 ==========

--- 用户配置的覆盖项（`tools.sandbox.protected.consequences`）
--- @return table
local function _overrides()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.protected")
  end)
  if not ok or type(cfg) ~= "table" then return {} end
  local c = cfg.consequences
  return type(c) == "table" and c or {}
end

-- ========== 公开 API ==========

--- 取一条后果说明（合并用户覆盖）
--- @param id string|nil
--- @return table|nil { id, title, ability, scope, persistence, suggestion }
function M.get(id)
  if type(id) ~= "string" or id == "" then return nil end
  local base = CATALOG[id]
  local over = _overrides()[id]
  if not base and type(over) ~= "table" then return nil end
  local out = { id = id }
  for _, k in ipairs({ "title", "ability", "scope", "persistence", "suggestion" }) do
    local v = (type(over) == "table" and over[k]) or (base and base[k])
    out[k] = v
  end
  return out
end

--- 渲染为审批界面/待审条目用的多行文本
--- @param id string|nil
--- @param opts table|nil { persistence? string, prefix? string }
--- @return string|nil
function M.text(id, opts)
  local c = M.get(id)
  if not c then return nil end
  opts = opts or {}
  local lines = {
    "⚠ 后果：" .. tostring(c.title or id),
    "   能力  " .. tostring(c.ability or ""),
    "   范围  " .. tostring(c.scope or ""),
    "   持续  " .. tostring(opts.persistence or c.persistence or ""),
    "   建议  " .. tostring(c.suggestion or ""),
  }
  return table.concat(lines, "\n")
end

--- 一行摘要（供待审条目头部使用，避免长文本占满列表）
--- @param id string|nil
--- @return string|nil
function M.summary(id)
  local c = M.get(id)
  if not c then return nil end
  return string.format("%s — %s", tostring(c.title or id), tostring(c.ability or ""))
end

--- 全部内置 id（供文档/测试枚举）
--- @return string[]
function M.ids()
  local out = {}
  for id in pairs(CATALOG) do out[#out + 1] = id end
  table.sort(out)
  return out
end

return M
