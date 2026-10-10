--- 沙箱访客文件系统映射
--- @module NeoAI.sandbox.guest_fs
--- 记录沙箱内可为「访客」写入的临时根（`/tmp`、`/var/tmp`、`/run` 等）到宿主侧**会话私有
--- 目录**的映射。沙箱内 `/tmp` 被 bind 到该私有目录（见 `sandbox.runtime._append_tmpfs_roots`），
--- 故：
---   1. 工具（如 output_guard）要把完整输出「落盘到沙箱内 /tmp」时，需据此拿到宿主侧真实
---      目录并写入；
---   2. 模型后续用 `read_file("/tmp/…")` 回读时，需据此把访客路径还原为宿主路径（否则读到
---      的是宿主真实 `/tmp`，与沙箱内视图不一致）。
---
--- 映射由 `runtime` 在真正执行 `--bind` 时通过 `set_root()` 登记，进程内全局唯一（同一
--- Neovim 进程通常只有一个活动沙箱会话）。未启用沙箱时映射为空，`to_host()` 原样返回，
--- 退化为普通宿主路径读取。

local M = {}

-- ========== 私有状态 ==========

--- 访客根 → 宿主私有目录（如 "/tmp" → "<cache>/NeoAI/sandbox/tmp/tmp_tmp/tmp"）
local roots = {}

-- ========== 公开接口 ==========

--- 登记一个访客临时根与其宿主私有目录的映射（幂等；由 runtime 在成功 bind 时调用）。
--- @param guest_root string 访客根，形如 "/tmp"
--- @param host_dir string 宿主侧私有目录
function M.set_root(guest_root, host_dir)
  if type(guest_root) ~= "string" or guest_root == "" then return end
  if type(host_dir) ~= "string" or host_dir == "" then return end
  roots[guest_root:gsub("/+$", "")] = host_dir
end

--- 取某访客根的宿主私有目录（落盘用）。未登记时返回 nil。
--- @param guest_root string 访客根，形如 "/tmp"
--- @return string|nil
function M.tmp_host(guest_root)
  if type(guest_root) ~= "string" or guest_root == "" then return nil end
  return roots[guest_root:gsub("/+$", "")]
end

--- 清除全部映射（沙箱停止/重置时调用；幂等）。
function M.clear()
  roots = {}
end

--- 把访客绝对路径还原为宿主路径（按最长前缀匹配）。无匹配时原样返回，便于在未启用沙箱时
--- 直接按宿主路径读取。命中但宿主文件不存在时不在此判定（由调用方按需 stat）。
--- @param path string 访客路径，形如 "/tmp/neoai-out/xxx.log"
--- @return string 宿主路径（无映射时即入参）
function M.to_host(path)
  if type(path) ~= "string" or path == "" then return path end
  local best_root, best_host = nil, nil
  for root, host in pairs(roots) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      if not best_root or #root > #best_root then
        best_root, best_host = root, host
      end
    end
  end
  if not best_root then return path end
  local rest = path:sub(#best_root + 1)
  return best_host .. rest
end

--- 现存的访客根列表（诊断/测试用）。
--- @return table 字符串数组
function M.roots()
  local out = {}
  for root in pairs(roots) do out[#out + 1] = root end
  return out
end

return M
