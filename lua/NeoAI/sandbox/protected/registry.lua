--- 受保护资源分类表
--- @module 'NeoAI.sandbox.protected.registry'
--- 把「遮蔽路径」升级为「受保护资源」：给路径一个稳定的 class / 后果 id / 允许的能力（op）。
--- 本模块是**分类**的唯一事实来源：审批弹窗的后果文案、待审条目的后果标注、结构化拒绝
--- 回给 AI 的 resource/class 都从这里取，避免同一风险在各工具里各写一套说法。
---
--- 注意：本模块**不做**访问判定。判定仍由沙箱门禁负责
--- （进程内工具走 `runtime.is_masked_path`，外部进程走 mount 遮蔽），这里只做归类。
---
--- `ops` 是「该资源允许被请求的能力」的声明：空表表示不提供任何能力（纯遮蔽，任何审批都
--- 不会解锁）；`{ "sign", "tunnel" }` 表示可以使用但**不提供读取**。预授权绑定只能在这些
--- 已声明的能力里挑选，不能新增 op。

local M = {}

-- ========== 私有常量 ==========

--- 分类规则（顺序敏感：先命中先返回）
--- @type table[] { id: string, class: string, ops: string[], pats: string[] }
local RULES = {
  {
    id = "ssh_private_key",
    class = "credential",
    ops = { "sign", "tunnel" },
    pats = { "/%.ssh/", "/%.ssh$" },
  },
  {
    id = "ssh_service",
    class = "socket",
    ops = {},
    pats = {
      "^/run/sshd", "/run/ssh%-agent%.socket", "^/tmp/ssh%-",
      "/%.ssh%-agent",
    },
  },
  {
    id = "credential_store",
    class = "credential",
    ops = {},
    pats = {
      "/%.aws/", "/%.gnupg/", "/%.kube/", "/%.config/gcloud",
      "/%.docker/config%.json", "/%.netrc$", "/%.git%-credentials$",
      "/%.git%-credential%-cache", "/%.config/gh", "/%.config/git/credentials",
      "/%.npmrc$", "/%.pypirc$",
    },
  },
  {
    id = "system_account_db",
    class = "system",
    ops = {},
    pats = {
      "^/etc/shadow", "^/etc/gshadow", "^/etc/sudoers", "^/etc/passwd$",
      "^/etc/group$", "^/etc/krb5%.keytab$", "^/etc/ipa/",
    },
  },
  {
    id = "container_socket",
    class = "socket",
    ops = {},
    pats = {
      "docker%.sock", "/run/containerd", "/var/lib/docker", "/var/lib/containerd",
      "/run/podman", "/var/lib/containers",
    },
  },
  {
    id = "loader_hook",
    class = "system",
    ops = {},
    pats = { "^/etc/ld%.so%.preload$" },
  },
  {
    id = "host_identity",
    class = "system",
    ops = {},
    pats = { "^/etc/machine%-id$", "^/etc/hostid$", "^/etc/fstab$" },
  },
  {
    id = "shell_rc",
    class = "config",
    ops = {},
    pats = {
      "/%.bashrc$", "/%.bash_profile$", "/%.bash_aliases$", "/%.bash_login$",
      "/%.zshrc$", "/%.zprofile$", "/%.zshenv$", "/%.zlogin$", "/%.profile$",
      "/%.config/fish/",
    },
  },
  {
    id = "command_history",
    class = "credential",
    ops = {},
    pats = {
      "/%.bash_history$", "/%.zsh_history$", "/%.sh_history$", "/%.fish_history$",
      "/%.python_history$", "/%.mysql_history$", "/%.psql_history$",
      "/%.sqlite_history$", "/%.node_repl_history$", "/%.irb_history$",
      "/%.wget%-hsts$", "/%.lesshst$", "/%.viminfo$", "/%.pgpass$",
    },
  },
  {
    id = "host_logs",
    class = "system",
    ops = {},
    pats = {
      "^/var/log/", "^/var/spool/cron", "^/etc/crontab$", "^/etc/cron%.",
    },
  },
}

-- ========== 私有函数 ==========

--- 规范化路径（展开 ~、绝对化、去尾部斜杠）
--- @param path string|nil
--- @return string|nil
local function _norm(path)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, p = pcall(vim.fn.fnamemodify, vim.fn.expand(path), ":p")
  if not ok or type(p) ~= "string" or p == "" then p = path end
  if p ~= "/" then p = p:gsub("/+$", "") end
  return p
end

-- ========== 公开 API ==========

--- 分类一个路径
--- @param path string|nil
--- @param operation string|nil 预留：同一个资源在不同 op 下的说明可不同（当前共用）
--- @return table|nil { id, class, ops }
function M.classify(path, operation) -- luacheck: ignore operation
  local p = _norm(path)
  if not p then return nil end
  for _, rule in ipairs(RULES) do
    for _, pat in ipairs(rule.pats) do
      if p:find(pat) then
        return { id = rule.id, class = rule.class, ops = rule.ops }
      end
    end
  end
  return nil
end

--- 路径是否属于受保护资源
--- @param path string|nil
--- @return boolean
function M.is_protected(path)
  return M.classify(path) ~= nil
end

--- 该资源声明允许的能力（副本；空表 = 纯遮蔽）
--- @param id string|nil 资源 id 或路径
--- @return string[]
function M.ops(id)
  if type(id) ~= "string" or id == "" then return {} end
  for _, rule in ipairs(RULES) do
    if rule.id == id then
      local out = {}
      for i, v in ipairs(rule.ops) do out[i] = v end
      return out
    end
  end
  local c = M.classify(id)
  return c and M.ops(c.id) or {}
end

--- 全部资源 id（供文档/测试枚举）
--- @return string[]
function M.ids()
  local out = {}
  for _, rule in ipairs(RULES) do out[#out + 1] = rule.id end
  return out
end

return M
