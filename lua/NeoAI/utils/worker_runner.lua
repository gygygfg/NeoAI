--- 工作线程执行器源码（主进程线程池与后台 worker 进程共用）
--- @module 'NeoAI.utils.worker_runner'
--- 这些源码串通过 `vim.uv.new_work` 在独立 Lua state 中运行。它们必须保持
--- **自包含**：只能使用纯 Lua、`vim.uv`、`vim.mpack`、`vim.json`；禁止 `vim.fn` /
--- `vim.api` / 项目模块 / 闭包 upvalue。
---
--- 约定：
--- - `RUNNER`：`queue(dumped_fn, ...primitive_args)`，返回 `"\1<result>"` / `"\0<err>"`。
--- - `CODEC_RUNNER`：`queue(dumped_fn, mpack_payload, ...extras)`，返回
---   `"\1<mpack_result>"` / `"\0<err>"`。

local M = {}

M.RUNNER = table.concat({
  [[local code = ...]],
  [[local nargs = select("#", ...) - 1]],
  [[local args = {}]],
  [[for i = 1, nargs do args[i] = (select(i + 1, ...)) end]],
  [[local fn = assert(load(code, "=worker", "b"))]],
  [[local unpackx = table.unpack or unpack]],
  [[local ok, res = pcall(fn, unpackx(args, 1, nargs))]],
  [[if ok then]],
  [[  if res == nil then return "\1" end]],
  [[  if type(res) ~= "string" then return "\1" .. tostring(res) end]],
  [[  return "\1" .. res]],
  [[end]],
  [[return "\0" .. tostring(res)]],
}, "\n")

M.CODEC_RUNNER = table.concat({
  [[local code, payload = ...]],
  [[if not (vim and vim.mpack) then return "\0worker 缺少 vim.mpack" end]],
  [[local nextra = select("#", ...) - 2]],
  [[local extras = {}]],
  [[for i = 1, nextra do extras[i] = (select(i + 2, ...)) end]],
  [[local fn = assert(load(code, "=worker_codec", "b"))]],
  [[local data = vim.mpack.decode(payload)]],
  [[local unpackx = table.unpack or unpack]],
  [[local ok, res = pcall(fn, data, unpackx(extras, 1, nextra))]],
  [[if not ok then return "\0" .. tostring(res) end]],
  [[local ok2, enc = pcall(vim.mpack.encode, res)]],
  [[if not ok2 then return "\0" .. tostring(enc) end]],
  [[return "\1" .. enc]],
}, "\n")

return M
