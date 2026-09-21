--- 沙箱长驻服务工具
--- @module NeoAI.tools.builtin.service
--- 后台常驻进程（dev server / watch / 守护进程）跨工具调用存活，直到显式停止或会话结束。
--- 每个服务在独立沙箱 overlay + 资源域内运行；停止时其工作区改动冻结为候选并经异步审批。
--- run_command 中的 `&`/nohup/setsid 会自动转为长驻服务（跨调用存活）；需要显式命名/管理时
--- 直接用本模块的 service_start。

local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- @return table|nil
local function _svc()
  local ok, mod = pcall(require, "NeoAI.sandbox.service")
  if not ok then return nil end
  return mod
end

--- 格式化服务状态行
--- @param info table
--- @return string
local function _fmt_status(info)
  local parts = {
    string.format("%s [%s]", tostring(info.name), tostring(info.status)),
    "id=" .. tostring(info.id),
  }
  if info.pid then parts[#parts + 1] = "pid=" .. tostring(info.pid) end
  if info.exit_code ~= nil then parts[#parts + 1] = "exit=" .. tostring(info.exit_code) end
  if info.cwd then parts[#parts + 1] = "cwd=" .. tostring(info.cwd) end
  if info.log_bytes then parts[#parts + 1] = "log=" .. tostring(info.log_bytes) .. "B" end
  return table.concat(parts, " ")
end

-- ========== 工具定义 ==========

local service_tools = {}

service_tools.service_start = helpers.define_tool(
  "service_start",
  "启动一个**后台常驻服务**（dev server、watch、守护进程等），跨工具调用持续运行，直到 "
  .. "service_stop 或会话结束。命令在独立沙箱内运行，其工作区写入在停止时进入待审。"
  .. "run_command 中以后台方式结束的命令（`&`/nohup/setsid）会自动转为长驻服务；"
  .. "需要显式命名/管理时用本工具。启动后用 service_logs 查看输出、service_status 查看状态。",
  {
    type = "object",
    properties = {
      name = { type = "string", description = "服务名（唯一，用于 logs/status/stop 引用）" },
      command = { type = "string", description = "启动命令（前台运行，不要加 & / nohup）" },
      cwd = { type = "string", description = "工作目录（默认当前工作区）" },
      network = { type = "boolean", description = "是否允许联网（默认允许）" },
    },
    required = { "name", "command" },
  },
  function(args, on_success, on_error, _ctx)
    local svc_mod = _svc()
    if not svc_mod then return on_error("长驻服务模块不可用") end
    local name, err = helpers.require_string(args, "name", "service_start")
    if not name then return on_error(err) end
    local command, cerr = helpers.require_string(args, "command", "service_start")
    if not command then return on_error(cerr) end
    local svc, serr = svc_mod.start(name, command, {
      cwd = args.cwd,
      network = args.network,
    })
    if not svc then return on_error(serr or "服务启动失败") end
    on_success(string.format(
      "服务已启动：%s（id=%s, pid=%s, cwd=%s）。用 service_logs 查看输出，service_stop 停止。",
      svc.name, svc.id, tostring(svc.job), tostring(svc.cwd)))
  end,
  { category = "system", approval = { auto_allow = false }, timeout = -1 }
)

service_tools.service_logs = helpers.define_tool(
  "service_logs",
  "读取后台服务的输出日志（stdout+stderr）。可用 tail 限制返回的末尾字节数。",
  {
    type = "object",
    properties = {
      name = { type = "string", description = "服务名或 id" },
      tail = { type = "integer", description = "仅返回末尾 N 字节（可选）" },
    },
    required = { "name" },
  },
  function(args, on_success, on_error, _ctx)
    local svc_mod = _svc()
    if not svc_mod then return on_error("长驻服务模块不可用") end
    local text, err = svc_mod.logs(args.name, tonumber(args.tail))
    if not text then return on_error(err or "读取日志失败") end
    on_success(text ~= "" and text or "（暂无日志）")
  end,
  { category = "system", approval = { auto_allow = true }, timeout = -1 }
)

service_tools.service_status = helpers.define_tool(
  "service_status",
  "查看一个服务的状态；不传 name 时列出全部服务。",
  {
    type = "object",
    properties = {
      name = { type = "string", description = "服务名或 id（省略则列出全部）" },
    },
    required = {},
  },
  function(args, on_success, on_error, _ctx)
    local svc_mod = _svc()
    if not svc_mod then return on_error("长驻服务模块不可用") end
    if args.name and args.name ~= "" then
      local info = svc_mod.status(args.name)
      if not info then return on_error("服务不存在：" .. tostring(args.name)) end
      return on_success(_fmt_status(info))
    end
    local list = svc_mod.list()
    if #list == 0 then return on_success("（无运行中的服务）") end
    local lines = {}
    for _, info in ipairs(list) do lines[#lines + 1] = _fmt_status(info) end
    on_success(table.concat(lines, "\n"))
  end,
  { category = "system", approval = { auto_allow = true }, timeout = -1 }
)

service_tools.service_stop = helpers.define_tool(
  "service_stop",
  "停止一个后台服务；其工作区改动会被冻结为候选并进入待审（与其它沙箱写入一致）。",
  {
    type = "object",
    properties = {
      name = { type = "string", description = "服务名或 id" },
    },
    required = { "name" },
  },
  function(args, on_success, on_error, _ctx)
    local svc_mod = _svc()
    if not svc_mod then return on_error("长驻服务模块不可用") end
    local name, err = helpers.require_string(args, "name", "service_stop")
    if not name then return on_error(err) end
    svc_mod.stop(name, function(serr, info)
      if serr then return on_error(serr) end
      local tail = svc_mod.logs(info and info.id or name, 2048) or ""
      local msg = string.format("服务已停止：%s（id=%s, exit=%s）",
        tostring(info and info.name), tostring(info and info.id), tostring(info and info.exit_code))
      if tail ~= "" then msg = msg .. "\n\n[末尾日志]\n" .. tail end
      on_success(msg)
    end)
  end,
  { category = "system", approval = { auto_allow = false }, timeout = -1 }
)

-- 长驻服务：门禁完成预检/脚本扫描/硬拒绝后，不进入一次性进程的捕获/冻结流程。
service_tools.service_start.long_lived = true
service_tools.service_stop.long_lived = true

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(service_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
