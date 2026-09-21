--- 后台命令识别（& / nohup / setsid）
--- @module NeoAI.sandbox.background
--- 识别 `run_command` 中「意图后台执行」的命令，供门禁自动转为长驻服务（`sandbox.service`），
--- 使其跨工具调用存活——每个一次性命令在独立 pid namespace + cgroup 内运行，命令结束时
--- `cgroup.release` → `cgroup.kill` 会终止整个进程树，后台进程无法存活。
---
--- 保守识别，避免误判：
---   * 终止 `&`：末尾为 `&` 且前一字符非 `&`（排除 `&&`）、非 `>`（排除 `2>&1`/`&>`）；
---   * 前导 `nohup`/`setsid`（取 basename，允许带路径）；
---   * 中段 `&`（`a & b`）不识别——此类命令的语义是「同一次调用内并行」，仍走一次性执行。

local M = {}

--- 识别命令的后台意图。
--- @param command string
--- @return table|nil { command = string 去掉后台运算符后的命令, kind = "amp"|"nohup"|"setsid" }
function M.parse(command)
  if type(command) ~= "string" or command == "" then return nil end
  local body = command:gsub("%s+$", "")
  local kind = nil

  -- 终止 &（排除 &&、>&、&>）
  if body:sub(-1) == "&" then
    local prev = body:sub(-2, -2)
    if prev ~= "&" and prev ~= ">" then
      kind = "amp"
      body = body:sub(1, -2):gsub("%s+$", "")
    end
  end

  -- 前导 nohup / setsid（可能同时带终止 &）
  local first = body:match("^%s*(%S+)")
  if first then
    local base = first:match("[^/]+$") or first
    if base == "nohup" or base == "setsid" then
      kind = kind or base
      body = body:gsub("^%s*" .. vim.pesc(first) .. "%s*", "", 1)
    end
  end

  if not kind or body == "" then return nil end
  return { command = body, kind = kind }
end

return M
