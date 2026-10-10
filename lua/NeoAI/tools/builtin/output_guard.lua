--- 工具输出「AI 上下文限流」
--- @module NeoAI.tools.builtin.output_guard
--- 工具回传给模型的文本可能极其庞大（`git log`/`run_command` 数万行、超大文件整读），
--- 一次性塞给模型会瞬间耗尽上下文、稀释关键信息。本模块提供统一出口护栏 `cap()`：
---   - 文本字符数 <= `tools.output_guard.max_chars` 时原样返回；
---   - 超过时只保留「头 head_chars + 截断标记 + 尾 tail_chars」，并把**完整输出**写入
---     沙箱私有 `/tmp` 下的临时文件（沙箱内路径，供模型用 `read_file` 的 start_line/end_line
---     分段回读），标记中给出该路径。
---
--- 与 `tools.run_command.max_output_bytes`（16 MiB「防冻结硬杀限」，保护主线程）职责分离：
--- 本项保护的是**模型上下文**，量级小得多（默认 2 万字符）。
---
--- 路径一致性：落盘目录取沙箱访客 `/tmp` 在宿主侧的**会话私有目录**（`sandbox.guest_fs` 登记，
--- 由 `_append_tmpfs_roots` 在 bind 时写入）。因此工具落盘与模型随后 `read_file("/tmp/…")`
--- 回读落在同一目录；未启用沙箱（无映射）时退化为「仅截断、不落盘」。

local M = {}

local textmetrics = require("NeoAI.utils.textmetrics")
local fs = require("NeoAI.utils.fs")

-- ========== 私有函数 ==========

--- 读取生效配置（opts 可覆盖），并做健壮性钳制。
--- @param opts table|nil
--- @return table { enabled, max_chars, head_chars, tail_chars, spill, spill_dir }
local function _cfg(opts)
  opts = opts or {}
  local raw = {}
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.output_guard")
  end)
  if ok and type(cfg) == "table" then raw = cfg end
  local enabled = opts.enabled
  if enabled == nil then enabled = raw.enabled ~= false end
  local max_chars = tonumber(opts.max_chars) or tonumber(raw.max_chars) or 20000
  local head_chars = tonumber(opts.head_chars) or tonumber(raw.head_chars) or 14000
  local tail_chars = tonumber(opts.tail_chars) or tonumber(raw.tail_chars) or 4000
  local spill = opts.spill
  if spill == nil then spill = raw.spill ~= false end
  local spill_dir = opts.spill_dir or raw.spill_dir or "neoai-out"
  -- 钳制：头+尾必须 < max_chars，否则截断后不收缩。按比例缩放。
  if head_chars < 0 then head_chars = 0 end
  if tail_chars < 0 then tail_chars = 0 end
  if max_chars < 1 then max_chars = 1 end
  if head_chars + tail_chars >= max_chars then
    local budget = math.max(0, max_chars - 1)
    local total = head_chars + tail_chars
    if total > 0 then
      head_chars = math.floor(budget * head_chars / total)
      tail_chars = budget - head_chars
    else
      head_chars, tail_chars = budget, 0
    end
  end
  return {
    enabled = enabled,
    max_chars = max_chars,
    head_chars = head_chars,
    tail_chars = tail_chars,
    spill = spill,
    spill_dir = spill_dir,
  }
end

--- 生成落盘文件名（含工具名/时间戳/pid，避免并发覆盖）。
--- @param opts table
--- @return string basename
local function _basename(opts)
  local tool = tostring(opts.tool or "output"):gsub("[^%w_%-]", "_")
  local label = opts.label and tostring(opts.label):gsub("[^%w_%-]", "_") or nil
  local ts = os.date("%Y%m%d-%H%M%S")
  local name = tool .. (label and ("-" .. label) or "") .. "-" .. ts .. "-" .. tostring(vim.fn.getpid())
  return name .. ".log"
end

--- 把完整内容写入沙箱私有 /tmp，返回访客可见路径（供提示/回读）。
--- 无沙箱映射或写入失败时返回 nil + 原因。
--- @param content string
--- @param opts table { tool?, label?, spill_dir? }
--- @return string|nil guest_path
--- @return string|nil reason "truncated-bytes"|"no-sandbox-tmp"|"mkdir-failed"|"write-failed"
local function _spill(content, opts)
  local guest_fs = require("NeoAI.sandbox.execution.guest_fs")
  local host_root = guest_fs.tmp_host("/tmp")
  if not host_root then
    return nil, "no-sandbox-tmp"
  end
  local dir = host_root .. "/" .. tostring(opts.spill_dir or "neoai-out")
  local ok_dir = pcall(fs.ensure_dir, dir)
  if not ok_dir or vim.fn.isdirectory(dir) ~= 1 then
    return nil, "mkdir-failed"
  end
  local name = _basename(opts)
  local host_path = dir .. "/" .. name
  -- 写入前按 read_file.max_read_bytes 约束：避免落盘一个无法回读的超大文件。
  local cap_bytes = 5 * 1024 * 1024
  pcall(function()
    local rc = require("NeoAI.kernel.config_store").get("tools.read_file")
    if type(rc) == "table" and tonumber(rc.max_read_bytes) then cap_bytes = tonumber(rc.max_read_bytes) end
  end)
  local note = nil
  if #content > cap_bytes then
    content = content:sub(1, cap_bytes)
    note = "truncated-bytes"
  end
  local ok = pcall(fs.write_file, host_path, content)
  if not ok then
    return nil, "write-failed"
  end
  return "/tmp/" .. tostring(opts.spill_dir or "neoai-out") .. "/" .. name, note
end

-- ========== 公开接口 ==========

--- 限流一段将回传给模型的文本。
--- @param text string 已组装好的文本（务必在脱敏之后调用，否则路径会被抹掉）
--- @param opts table|nil { tool?, label?, spill_text?, enabled?, max_chars?, head_chars?, tail_chars?, spill?, spill_dir? }
--- @return string 可安全回传模型的文本（可能含截断标记与落盘路径）
function M.cap(text, opts)
  opts = opts or {}
  if type(text) ~= "string" or text == "" then return text end
  local cfg = _cfg(opts)
  if not cfg.enabled then return text end
  local n = textmetrics.strchars(text)
  if n <= cfg.max_chars then return text end
  local head = textmetrics.strcharpart(text, 0, cfg.head_chars)
  local tail = textmetrics.strcharpart(text, n - cfg.tail_chars, cfg.tail_chars)
  local marker
  if cfg.spill then
    local path, reason = _spill(opts.spill_text or text, { tool = opts.tool, label = opts.label, spill_dir = cfg.spill_dir })
    if path then
      local extra = (reason == "truncated-bytes") and "（文件过大，仅落盘前段）" or ""
      marker = string.format(
        "\n\n…（输出过长已截断：原文 %d 字，此处仅显示前 %d 字与后 %d 字。"
          .. "完整内容已写入 %s%s，可用 read_file 的 start_line/end_line 分段查看。）\n\n",
        n, cfg.head_chars, cfg.tail_chars, path, extra
      )
    else
      marker = string.format(
        "\n\n…（输出过长已截断：原文 %d 字，此处仅显示前 %d 字与后 %d 字；"
          .. "当前无可写的沙箱私有 /tmp，未落盘完整内容。）\n\n",
        n, cfg.head_chars, cfg.tail_chars
      )
    end
  else
    marker = string.format(
      "\n\n…（输出过长已截断：原文 %d 字，此处仅显示前 %d 字与后 %d 字。）\n\n",
      n, cfg.head_chars, cfg.tail_chars
    )
  end
  return head .. marker .. tail
end

--- 把完整内容落盘并把提示（含访客路径）附加到已展示文本后（用于「展示大纲/预览，但完整
--- 内容可回读」的场景，如 read_file 的大纲/无 parser 回退）。未启用或无法落盘时返回原文。
--- @param display string 已展示给模型的文本
--- @param content string 要落盘的完整内容
--- @param opts table|nil { tool?, label?, spill_dir?, spill_text? }
--- @return string
function M.note_spill(display, content, opts)
  opts = opts or {}
  local cfg = _cfg(opts)
  if not cfg.enabled or not cfg.spill then return display end
  if type(content) ~= "string" or content == "" then return display end
  local path, reason = _spill(opts.spill_text or content, { tool = opts.tool, label = opts.label, spill_dir = cfg.spill_dir })
  if not path then return display end
  local extra = (reason == "truncated-bytes") and "（文件过大，仅落盘前段）" or ""
  return display
    .. string.format("\n\n（完整内容已写入 %s%s，可用 read_file 的 start_line/end_line 分段查看。）", path, extra)
end

--- 当前是否具备落盘能力（供调用方决定展示形态）。
--- @return boolean
function M.spill_available()
  local ok, guest_fs = pcall(require, "NeoAI.sandbox.execution.guest_fs")
  if not ok or not guest_fs then return false end
  return guest_fs.tmp_host("/tmp") ~= nil
end

return M
