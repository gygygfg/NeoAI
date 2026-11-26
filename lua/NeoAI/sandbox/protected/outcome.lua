--- 沙箱结果信封（回给 AI 的结构化结果）
--- @module 'NeoAI.sandbox.protected.outcome'
--- 把「硬拒绝」与「进暂存待审」两类结果以**机器可读 + 可行动**的形式回给模型，
--- 取代过去一句 `路径位于宿主敏感遮蔽路径: …` 或「假装修改已完成」。
---
--- 设计约束（与 `docs/sandbox.md` 一致）：
---   * 只报告**事实与下一步**，不透露密钥值、不透露宿主路径以外的敏感信息；
---   * 明确 `retryable`：拒绝与待审都不可通过重试解决，避免模型反复刷调用；
---   * 待审（STAGED）不是失败：改动已冻结在暂存层，等用户确认，模型不需要也不会重做。
---
--- 文本格式按「首行机器可读、后续行人类可读」组织：模型能解析 `key=value`，
--- 用户侧日志也读得懂。

local M = {}

-- ========== 私有函数 ==========

--- 文件列表摘要（最多 5 个，其余以 +N 表示）
--- @param files table|nil
--- @return string
local function _files_brief(files)
  local out, n = {}, 0
  for _, f in ipairs(files or {}) do
    n = n + 1
    if #out < 5 then
      out[#out + 1] = tostring(type(f) == "table" and f.path or f)
    end
  end
  if n > #out then out[#out + 1] = ("+%d"):format(n - #out) end
  return table.concat(out, ", ")
end

--- 单行化（去掉换行，限长）
--- @param s any
--- @param max integer|nil
--- @return string
local function _one_line(s, max)
  local t = tostring(s or ""):gsub("%s+", " ")
  max = max or 240
  if #t > max then t = t:sub(1, max) .. "…" end
  return t
end

-- ========== 公开 API ==========

--- 构造硬拒绝结果
--- @param opts table {
---   resource: string, op: string|nil, class: string|nil,
---   code: string|nil, reason: string|nil, hint: string|nil }
--- @return table { code, resource, op, class, text }
function M.blocked(opts)
  opts = opts or {}
  local code = opts.code or "PROTECTED_RESOURCE"
  local lines = {
    ("[沙箱] BLOCKED code=%s"):format(code),
    ("resource=%s op=%s class=%s"):format(
      _one_line(opts.resource, 512), tostring(opts.op or "read"), tostring(opts.class or "unknown")),
  }
  if opts.reason and opts.reason ~= "" then
    lines[#lines + 1] = "reason=" .. _one_line(opts.reason)
  end
  if opts.hint and opts.hint ~= "" then
    lines[#lines + 1] = "hint=" .. _one_line(opts.hint)
  end
  lines[#lines + 1] = "retryable=false do_not_repeat=true"
  return {
    code = code,
    resource = opts.resource,
    op = opts.op,
    class = opts.class,
    text = table.concat(lines, "\n"),
  }
end

--- 构造「已暂存、等待审批」结果
--- @param opts table {
---   change_set: string|nil, files: table|nil, consequence_id: string|nil,
---   tool: string|nil, state: string|nil }
--- @return table { change_set, text }
function M.staged(opts)
  opts = opts or {}
  local lines = {
    ("[沙箱] STAGED change_set=%s files=%d decision=NEEDS_CONFIRMATION"):format(
      tostring(opts.change_set or "?"), #(opts.files or {})),
  }
  local brief = _files_brief(opts.files)
  if brief ~= "" then lines[#lines + 1] = "what=" .. _one_line(brief, 512) end
  if opts.consequence_id then
    local ok, consequence = pcall(require, "NeoAI.sandbox.review.consequence")
    local c = ok and consequence and consequence.get(opts.consequence_id) or nil
    lines[#lines + 1] = ("consequence=%s%s"):format(
      tostring(opts.consequence_id),
      c and c.title and (" (" .. _one_line(c.title, 80) .. ")") or "")
    if c and c.ability then lines[#lines + 1] = "why=" .. _one_line(c.ability) end
  end
  lines[#lines + 1] = "state=" .. _one_line(opts.state
    or "改动已冻结在会话暂存层，等用户在审批界面确认后写入真实文件")
  lines[#lines + 1] = "retryable=false do_not_repeat=true"
  return {
    change_set = opts.change_set,
    text = table.concat(lines, "\n"),
  }
end

--- 把结果信封附加到工具返回值上（不改动原有结构）
--- 字符串直接拼接；表按输出字段顺序写入，避免覆盖业务字段。
--- @param result any
--- @param text string|nil
--- @return any
function M.append(result, text)
  if type(text) ~= "string" or text == "" then return result end
  if type(result) == "string" then
    if result == "" then return text end
    return result .. "\n\n" .. text
  end
  if type(result) == "table" then
    if type(result.stdout) == "string" then
      result.stdout = (result.stdout ~= "" and (result.stdout .. "\n\n") or "") .. text
    elseif type(result.content) == "string" then
      result.content = (result.content ~= "" and (result.content .. "\n\n") or "") .. text
    elseif type(result.message) == "string" and result.message ~= "" then
      result.message = result.message .. "\n\n" .. text
    else
      result.notice = text
    end
    return result
  end
  return result
end

return M
