--- 沙箱访客文件系统映射
--- @module NeoAI.sandbox.execution.guest_fs
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

--- 解析「工具看到的路径」→ 宿主实际可读路径（沙箱内聚，工具层不感知映射细节）。
--- 优先级（高 → 低）：
---   1. 沙箱暂存（staged）命名空间路径：工作区内已暂存的文件（编辑/命令产物）读其副本，
---      使 AI 看到与 git_diff/命令视图一致的未发布内容；
---   2. 真实/命名空间路径：原路径在宿主存在时原样返回——工作区可能恰在宿主 `/tmp` 下（测试
---      临时目录、把 /tmp 当项目目录的用户），其字符串与访客 `/tmp` 同前缀，不可误映射；
---   3. 访客临时根映射：`/tmp`、`/var/tmp` 等被 bind 到会话私有目录，output_guard 落盘的输出
---      文件即在此；仅当原路径在宿主不存在时才映射。
--- 注：目录级只读工具（search_files/list_files）的目录参数须保持命名空间路径，暂存叠加由工具
--- 自身完成（`_merge_search`/`_merge_list`），误映射进私有 /tmp 会导致匹配不到覆盖而漏改动。
--- @param path string
--- @return string
function M.resolve_read_path(path)
  if type(path) ~= "string" or path == "" then return path end
  local okc, cand = pcall(require, "NeoAI.sandbox.execution.candidate")
  if okc and cand and type(cand.read_path) == "function" then
    local staged = cand.read_path(path)
    if staged then return staged end
  end
  local mapped = M.to_host(path)
  if mapped == path then return path end
  if vim.uv.fs_stat(path) ~= nil then return path end
  return mapped
end

--- 现存的访客根列表（诊断/测试用）。
--- @return table 字符串数组
function M.roots()
  local out = {}
  for root in pairs(roots) do out[#out + 1] = root end
  return out
end

return M
