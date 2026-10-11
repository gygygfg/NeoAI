--- NeoAI 测试运行器：耗时缓存读写与解析
--- @module 'NeoAI.tests.runner.timings'
--- 管理「套件名 → 实测耗时(ms)」缓存（默认仓库根 `.neoai_test_timings.json`，gitignored），
--- 供 LPT 分片权重自均衡。纯函数为主（path/load/save/parse），仅在写盘时触碰文件系统。

local tests = require("NeoAI.tests")
local config = require("NeoAI.tests.runner.config")

local M = {}

--- 耗时缓存文件路径（默认仓库根，CI 可跨运行复用）
--- @param opts table|nil
--- @return string
function M.path(opts)
  if opts and opts.timings_path then return opts.timings_path end
  local root = tests._plugin_root()
  if root then return root .. "/" .. config.TIMINGS_FILE end
  return vim.fn.stdpath("cache") .. "/NeoAI_test_timings.json"
end

--- 读取耗时缓存
--- @param path string
--- @return table name -> ms
function M.load(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for k, v in pairs(data) do
    if type(k) == "string" and tonumber(v) then out[k] = tonumber(v) end
  end
  return out
end

--- 写入耗时缓存（四舍五入为整数毫秒）
--- @param path string
--- @param timings table name -> ms
--- @return boolean 是否写入成功
function M.save(path, timings)
  local out = {}
  for k, v in pairs(timings or {}) do
    if type(k) == "string" and tonumber(v) then out[k] = math.floor(tonumber(v) + 0.5) end
  end
  local ok, encoded = pcall(vim.json.encode, out)
  if not ok then return false end
  local f = io.open(path, "w")
  if not f then return false end
  f:write(encoded)
  f:close()
  return true
end

--- 解析子进程输出中的套件耗时行：`TIMING <name> <ms>`
--- @param output string|nil
--- @return table name -> ms
function M.parse(output)
  local out = {}
  for name, ms in (output or ""):gmatch("TIMING (%S+) ([%d%.]+)") do
    out[name] = tonumber(ms)
  end
  return out
end

return M
