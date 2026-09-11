--- Skills 服务（技能目录 + SKILL.md）
--- @module NeoAI.services.skills
--- 扫描配置的 skills 目录，解析每个 SKILL.md 的 YAML frontmatter（name/description/
--- allowed-tools/env）与正文，构建可检索索引。
--- 系统提示段（列出可用技能）与 list_skills/load_skill 工具由 tools/builtin/skills.lua
--- 注册；本服务只负责发现、解析与查询。极简 frontmatter 解析，无第三方 YAML 依赖。

local fs = require("NeoAI.utils.fs")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 私有状态 ==========

local state = {
  index = {}, -- name -> { name, description, path, dir, body, metadata }
  loaded = false,
}

-- ========== 极简 YAML frontmatter 解析 ==========

--- 去除包裹引号
--- @param v string
--- @return string
local function _unquote(v)
  v = v:gsub("^%s+", ""):gsub("%s+$", "")
  if #v >= 2 then
    local a, b = v:sub(1, 1), v:sub(-1)
    if (a == '"' and b == '"') or (a == "'" and b == "'") then
      return v:sub(2, -2)
    end
  end
  return v
end

--- 解析一行 "key: value" 为 (key, value)
--- @param line string
--- @return string|nil, string|nil
local function _parse_kv(line)
  local key, value = line:match("^(.-):(.*)$")
  if not key then return nil end
  key = key:gsub("^%s+", ""):gsub("%s+$", "")
  value = value and (value:gsub("^%s+", ""):gsub("%s+$", "")) or ""
  return key, value
end

--- 解析 frontmatter 块内容为元数据表（处理标量、行内数组 `[a,b]`、dash 列表）
--- @param block string
--- @return table
local function _parse_yaml(block)
  local meta = {}
  local lines = vim.split(block, "\n", { plain = true })
  local i = 1
  local pending = nil
  while i <= #lines do
    local line = lines[i] .. ""
    line = line:gsub("\r$", "")
    -- 空行
    if line:gsub("%s+", "") == "" then
      i = i + 1
    else
      local is_list_item = line:match("^%s*%-%s+(.*)$")
      if is_list_item then
        -- 归属上一个 key 的列表
        if pending and meta[pending] == nil then meta[pending] = {} end
        if pending then
          local tbl = meta[pending]
          if type(tbl) ~= "table" then tbl = {} meta[pending] = tbl end
          tbl[#tbl + 1] = _unquote(is_list_item)
        end
        i = i + 1
      else
        local key, value = _parse_kv(line)
        if key and value ~= "" then
          -- 行内数组 [a, b]
          if value:sub(1, 1) == "[" and value:sub(-1) == "]" then
            local list = {}
            for item in value:sub(2, -2):gmatch("[^,]+") do
              list[#list + 1] = _unquote(item)
            end
            meta[key] = list
            pending = nil
          else
            meta[key] = _unquote(value)
            pending = key -- 后续 dash 列表归属此 key
          end
          i = i + 1
        elseif key then
          meta[key] = ""
          pending = key
          i = i + 1
        else
          -- 非 key:value 行（如注释），跳过
          i = i + 1
        end
      end
    end
  end
  return meta
end

--- 解析 SKILL.md：拆分 frontmatter 与正文
--- @param raw string
--- @return table meta, string body
local function _parse_skill(raw)
  local meta, body = {}, raw
  -- frontmatter：以单独一行 "---" 开头
  if raw:sub(1, 4) == "---\n" then
    local rest_raw = raw:sub(5)
    local end_pos = rest_raw:find("\n---", 1, true)
    if end_pos then
      -- 关闭分隔符为 "\n---"（后跟换行或结尾）
      local block = rest_raw:sub(1, end_pos - 1)
      body = rest_raw:sub(end_pos + 5) -- 跳过 "\n---" 与之后的换行
      if body:sub(1, 1) == "\n" then body = body:sub(2) end
      meta = _parse_yaml(block)
    end
  end
  meta = meta or {}
  return meta, body
end

--- 目录名作为默认技能名（frontmatter 缺省时）
local function _dir_name(path)
  return fs.basename(fs.dirname(path))
end

--- 规范化技能名
local function _norm_name(name)
  if type(name) ~= "string" or name == "" then return "" end
  return name:gsub("%s+", "-")
end

-- ========== 私有函数 =========-

--- 递归列出目录下所有 SKILL.md
--- @param root string
--- @return table 数组（绝对路径）
local function _find_skills(root)
  local out = {}
  local function walk(dir)
    local ok, entries = pcall(vim.fn.readdir, dir)
    if not ok or not entries then return end
    for _, e in ipairs(entries) do
      if e:match("^%.") == nil then -- 跳过隐藏项
        local full = fs.join(dir, e)
        if fs.is_dir(full) then
          walk(full)
        elseif e == "SKILL.md" then
          out[#out + 1] = full
        end
      end
    end
  end
  walk(root)
  return out
end

--- 扫描一个目录并合并进索引
--- @param dir string
local function _scan_dir(dir)
  local abs = fs.expand(dir)
  if not fs.is_dir(abs) then return end
  for _, path in ipairs(_find_skills(abs)) do
    local raw = fs.read_file(path)
    if not raw then
      logger.warn("[skills] 无法读取 %s", path)
    else
      local meta, body = _parse_skill(raw)
      local name = _norm_name(meta.name)
      if name == "" then name = _dir_name(path) end
      local max_bytes = config_store.get("skills.max_skill_bytes") or (64 * 1024)
      if #body > max_bytes then
        logger.warn("[skills] %s 超出大小上限，截断到 %d 字节", path, max_bytes)
        body = body:sub(1, max_bytes)
      end
      local skill = {
        name = name,
        description = type(meta.description) == "string" and meta.description or "",
        path = path,
        dir = fs.dirname(path),
        body = body,
        metadata = meta,
      }
      -- 同名保留首个（路径顺序越前优先级越高）
      if not state.index[name] then
        state.index[name] = skill
      end
    end
  end
end

--- 扫描全部配置目录
local function _scan_all()
  state.index = {}
  local cfg = config_store.get("skills") or {}
  local paths = cfg.paths or {}
  for _, p in ipairs(paths) do
    if type(p) == "string" and p ~= "" then
      _scan_dir(p)
    end
  end
end

--- 系统提示段文本：列出可用技能（受 max_skills_in_prompt 限制）
--- inject_mode：list=名称+描述（默认），full=整篇正文（受每技能字节上限限制），none=不列出
--- @return string
local function _summary_text()
  local cfg = config_store.get("skills") or {}
  local max = cfg.max_skills_in_prompt or 20
  local inject = cfg.inject_mode or "list"
  if inject == "none" then return "" end
  local list = M.list()
  if #list == 0 then return "" end
  local lines = {
    "## 可用技能（Skills）",
    "技能是针对特定任务的步骤式操作指引，按需加载，不要加载与当前任务无关的技能。",
    "何时加载：当当前任务与某技能的描述匹配时，先加载该技能再动手。",
    "如何加载：调用 load_skill 工具，name 必填，取值为下方清单中的技能名。",
    "加载后：按 SKILL.md 正文的步骤指引执行。",
  }
  local shown = 0
  for _, s in ipairs(list) do
    if shown >= max then break end
    shown = shown + 1
    local desc = (s.description and s.description ~= "") and s.description or "（无描述）"
    if inject == "full" then
      local skill = state.index[s.name]
      local body = (skill and skill.body) or ""
      if #body > 0 then
        lines[#lines + 1] = string.format("- %s: %s\n```\n%s\n```", s.name, desc, body)
      else
        lines[#lines + 1] = string.format("- %s: %s", s.name, desc)
      end
    else
      lines[#lines + 1] = string.format("- %s: %s", s.name, desc)
    end
  end
  return table.concat(lines, "\n")
end

-- ========== 公开 API ==========

--- 初始化（扫描索引；幂等）
--- @return table M
function M.init()
  if state.loaded then return M end
  state.loaded = true
  local cfg = config_store.get("skills") or {}
  if cfg.enabled ~= false then
    _scan_all()
    logger.info("[skills] 扫描完成: %d 个技能", M.count())
  end
  return M
end

--- 已索引技能数量
--- @return number
function M.count()
  local n = 0
  for _ in pairs(state.index) do n = n + 1 end
  return n
end

--- 列出所有技能（按名称排序）
--- @return table 数组 { name, description, path }
function M.list()
  local out = {}
  for _, s in pairs(state.index) do
    out[#out + 1] = { name = s.name, description = s.description, path = s.path }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- 获取技能索引项
--- @param name string
--- @return table|nil
function M.get(name)
  return state.index[name]
end

--- 装载技能正文（供 load_skill 工具回传）
--- @param name string
--- @return table|nil { name, content, path, metadata }
function M.load(name)
  local skill = state.index[name]
  if not skill then return nil end
  return { name = skill.name, content = skill.body, path = skill.path, metadata = skill.metadata }
end

--- 生成系统提示段文本（供 prefix.register_section 动态求值）
--- @return string
function M.summary_text()
  return _summary_text()
end

--- 热重载：重新扫描并触发 SKILLS_UPDATED
--- @return number 数量
function M.reload()
  _scan_all()
  event_bus.emit(events.SKILLS_UPDATED, { count = M.count() })
  return M.count()
end

--- 重置（测试用）
function M.reset()
  state.index = {}
  state.loaded = false
end

return M
