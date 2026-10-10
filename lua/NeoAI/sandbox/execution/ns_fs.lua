--- 沙箱命名空间视图 I/O（进程内文件工具用）
--- @module 'NeoAI.sandbox.execution.ns_fs'
--- 「overlay 为权威暂存层」下的进程内工具 I/O 适配：
---   * 写入：工具产出的**视图内容**（可能含密钥 token）→ `secret.detokenize` → 经 `file_bridge`
---     在 mount 命名空间内写入 overlay 暂存层（真实工作区在发布前不受影响）。
---   * 读取：经 `file_bridge` 读 overlay 合并视图 → `secret.tokenize` 得到**视图内容**（与
---     暂存视图一致的密钥遮蔽）。
--- 仅当常驻实例在运行（overlay 就绪）时 `active()` 为真；否则所有操作返回
--- `nil, "INACTIVE"`，调用方必须回退既有工作区暂存副本（绝不静默写真实盘）。

local M = {}

-- ========== 私有函数 ==========

--- @return table|nil
local function _bridge()
  local ok, mod = pcall(require, "NeoAI.sandbox.execution.file_bridge")
  if ok and mod then return mod end
  return nil
end

--- @return table|nil
local function _secret()
  local ok, mod = pcall(require, "NeoAI.sandbox.secret.secret")
  if ok and mod then return mod end
  return nil
end

--- @param content string|nil
--- @return boolean
local function _is_text(content)
  local ok, util = pcall(require, "NeoAI.sandbox.execution.candidate_util")
  if ok and util and type(util.is_text_content) == "function" then
    return util.is_text_content(content)
  end
  if type(content) ~= "string" or content == "" then return true end
  return content:find("\0", 1, true) == nil
end

-- ========== 公开接口 ==========

--- 命名空间视图 I/O 是否可用（配置允许 + 常驻实例在运行）。
--- @return boolean
function M.active()
  local bridge = _bridge()
  if not bridge or type(bridge.available) ~= "function" then return false end
  local ok, avail = pcall(bridge.available)
  return ok and avail == true
end

--- 某真实路径是否适合走命名空间 overlay：不落在私有 tmpfs 根（/tmp、/var/tmp、/run）下。
--- 这些根在沙箱内为会话私有目录，overlay 视图与宿主真实路径不一致，须回退宿主暂存副本。
--- @param path string
--- @return boolean
function M.eligible(path)
  if not M.active() then return false end
  if type(path) ~= "string" or path == "" then return false end
  local okr, runtime = pcall(require, "NeoAI.sandbox.execution.runtime")
  if not okr or not runtime or type(runtime.tmpfs_roots) ~= "function" then return true end
  local ok2, roots = pcall(runtime.tmpfs_roots)
  if not ok2 or type(roots) ~= "table" then return true end
  local fs = require("NeoAI.utils.fs")
  local ap = fs.canonical(path)
  for _, root in ipairs(roots) do
    if ap == root or ap:sub(1, #root + 1) == root .. "/" then return false end
  end
  return true
end

--- 读文件（overlay 合并视图，token 化后的视图内容）。
--- @param path string
--- @return string|nil content
--- @return string|nil err
function M.read(path)
  local bridge = _bridge()
  if not bridge or not M.active() then return nil, "INACTIVE" end
  local raw, err = bridge.read(path)
  if raw == nil then return nil, err end
  local secret = _secret()
  if secret and _is_text(raw) and secret.enabled and secret.enabled() then
    raw = secret.tokenize(raw, { entropy = secret.is_secret_path and secret.is_secret_path(path) or false })
  end
  return raw
end

--- 写文件（视图内容 → detokenize → 命名空间 overlay 暂存层）。
--- @param path string
--- @param content string
--- @return boolean ok
--- @return string|nil err
function M.write(path, content)
  local bridge = _bridge()
  if not bridge or type(bridge.write) ~= "function" then return false, "INACTIVE" end
  local secret = _secret()
  local real_content = content or ""
  if secret and secret.detokenize and secret.enabled and secret.enabled() then
    local detok, unresolved = secret.detokenize(real_content)
    if (unresolved or 0) > 0 then return false, "SECRET_UNRESOLVED" end
    real_content = detok
  end
  local ok, err = bridge.write(path, real_content)
  return ok == true, (ok and nil or err)
end

--- 追加写（读视图 → 追加 → 写 overlay）。
--- @param path string
--- @param content string
--- @return boolean ok
--- @return string|nil err
function M.append(path, content)
  if not M.active() then return false, "INACTIVE" end
  local cur, err = M.read(path)
  if cur == nil then return false, err end
  return M.write(path, cur .. (content or ""))
end

--- @return boolean|nil
function M.exists(path)
  local bridge = _bridge()
  if not bridge or not M.active() then return nil end
  return bridge.exists(path)
end

--- @return table|nil
function M.stat(path)
  local bridge = _bridge()
  if not bridge or not M.active() then return nil end
  return bridge.stat(path)
end

--- @return boolean
function M.mkdir(path)
  local bridge = _bridge()
  if not bridge or not M.active() then return false end
  return bridge.mkdir(path)
end

--- @return boolean
function M.unlink(path)
  local bridge = _bridge()
  if not bridge or not M.active() then return false end
  return bridge.unlink(path)
end

--- @return table|nil
function M.list(path)
  local bridge = _bridge()
  if not bridge or not M.active() then return nil end
  return bridge.list(path)
end

return M
