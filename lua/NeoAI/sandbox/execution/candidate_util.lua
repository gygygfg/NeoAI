--- 沙箱候选纯工具函数
--- @module NeoAI.sandbox.execution.candidate_util
--- 从 candidate.lua 抽出的无状态纯函数（权限位/哈希/stat 签名/内容读取/文本判定）。
--- 仅依赖 stdlib 与 Neovim 内置，不引用模块状态；内部相互调用保持原样。

--- 取权限位（低 12 位，含 setuid/setgid/sticky）。st_mode 形如 0o104755；`% 4096` 即 0o7777 掩码。
--- 完整保留权限位：不因「安全默认」有意丢弃特殊位（权限以真实盘/暂存视图为准）。
--- @param mode number|nil
--- @return number|nil
local function _perm(mode)
  if type(mode) ~= "number" then return nil end
  return mode % 4096
end

local function _sha(content)
  local ok, hex = pcall(vim.fn.sha256, content or "")
  return ok and ("sha256:" .. hex) or "sha256:?"
end

--- 文件 stat 签名（`sig:<mtime.sec>:<mtime.nsec>:<size>`）：超大文件不读取内容做 CAS，
--- 改用此签名判定基线是否变化（与捕获阶段未变快速判定同口径，避免读取数百 MB）。
--- @param st table|nil vim.uv.fs_stat 结果
--- @return string|nil
local function _stat_sig(st)
  if not (st and st.type == "file" and st.mtime) then return nil end
  return string.format("sig:%s:%s:%s",
    tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size))
end

local function _read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- 读取候选条目的发布内容（供发布解密预检与写入）：
--- 非大文件 blob 从 blob 读取（token 化内容，需 detokenize）；大文件 blob 返回 nil（按文件复制）。
--- @param f table
--- @return string|nil
local function _candidate_content(f)
  if f.blob and not f.large then return _read(f.blob) end
  return f.content
end

--- 内容是否可安全当文本处理：合法 UTF-8 且不含 NUL。
--- 二进制（keyring/图片/可执行文件等）返回 false——绝不对其做密钥 token 化或 UTF-8 清洗，
--- 否则会把二进制当文本处理而损坏（如 OpenPGP keyring 被替换字符破坏）。
--- @param content string|nil
--- @return boolean
local function _is_text_content(content)
  if type(content) ~= "string" or content == "" then return true end
  if content:find("\0", 1, true) then return false end
  return require("NeoAI.utils.stringx").is_valid_utf8(content)
end

return {
  perm = _perm,
  sha = _sha,
  stat_sig = _stat_sig,
  read = _read,
  candidate_content = _candidate_content,
  is_text_content = _is_text_content,
}
