--- 沙箱运行时探测助手
--- @module NeoAI.sandbox.execution.runtime_probe
--- 从 runtime.lua 抽出的无状态纯函数（不引用模块状态；内部相互调用保持原样）。

--- 宿主逻辑 CPU 数
--- @return number
local function _nproc()
  local ok, cpus = pcall(vim.uv.cpus)
  if ok and type(cpus) == "table" and #cpus > 0 then return #cpus end
  local raw = vim.fn.system("nproc 2>/dev/null") or ""
  local n = tonumber((raw:gsub("%s+$", "")))
  return (n and n > 0) and n or 1
end

local function _executable(name)
  return vim.fn.executable(name) == 1
end

--- 当前进程是否以 root 运行（root 下可省去 user namespace）
--- @return boolean
local function _is_root()
  return vim.uv.getuid ~= nil and vim.uv.getuid() == 0
end

--- 路径 p 是否等于 r 或位于 r 之下（按路径段边界）
--- @param p string
--- @param r string
--- @return boolean
local function _under(p, r)
  if type(p) ~= "string" or type(r) ~= "string" then return false end
  return p == r or p:sub(1, #r + 1) == r .. "/"
end

--- 清理某临时根私有基目录下除 keep_session 外的陈旧会话子目录
--- @param base string
--- @param keep_session string|nil
local function _prune_tmp_base(base, keep_session)
  if vim.fn.isdirectory(base) ~= 1 then return end
  for _, name in ipairs(vim.fn.readdir(base) or {}) do
    if name ~= keep_session then
      pcall(vim.fn.delete, base .. "/" .. name, "rf")
    end
  end
end

--- 追加 /proc/sys 整体只读绑定：一次性封闭**所有**非命名空间全局 sysctl 的写入面
--- （core_pattern/modprobe/randomize_va_space/kptr_restrict/dmesg_restrict/net.*/vm.*/fs.* 等）。
--- 这些条目的写权限按 DAC（euid == 全局 root uid）判定，`--cap-drop ALL` 无法阻止；
--- 共享 netns 下 net.* 还会直接改宿主网络。只读绑定后读仍可用、写返回 EROFS。
--- 必须在 `--proc /proc` 之后调用（源路径取自新 procfs）。
--- @param argv table
local function _append_proc_sys_ro(argv)
  argv[#argv + 1] = "--ro-bind"
  argv[#argv + 1] = "/proc/sys"
  argv[#argv + 1] = "/proc/sys"
end

return {
  nproc = _nproc,
  executable = _executable,
  is_root = _is_root,
  under = _under,
  prune_tmp_base = _prune_tmp_base,
  append_proc_sys_ro = _append_proc_sys_ro,
}
