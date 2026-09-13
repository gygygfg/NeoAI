--- 沙箱候选服务：私有暂存、冻结、CAS 发布
--- @module NeoAI.sandbox.candidate
--- 隔离执行只写私有 upper 目录；冻结后计算 candidate_digest；发布做 CAS。
--- 每次尝试使用独立可写层，不与其他命令共享（设计文档 §4.2/§4.3/§4.5）。

local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 私有状态 ==========

local state = {
  attempts = {}, -- attempt_id -> { dir, mapping = { [real] = entry }, config }
}

-- ========== 私有函数 ==========

local function _sha(content)
  local ok, hex = pcall(vim.fn.sha256, content or "")
  return ok and ("sha256:" .. hex) or "sha256:?"
end

local function _abs(path)
  return vim.fn.fnamemodify(fs.expand(path), ":p")
end

local function _hash_key(path)
  local ok, hex = pcall(vim.fn.sha256, path)
  return ok and hex or path:gsub("[^%w]", "_")
end

local function _read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- 记录路径基线（首次）
--- @param attempt table
--- @param real string
--- @return table entry
local function _base_entry(attempt, real)
  local mapping = attempt.mapping
  local entry = mapping[real]
  if entry then return entry end
  local stat = vim.uv.fs_stat(real)
  entry = {
    real = real,
    staged = attempt.dir .. "/upper/" .. _hash_key(real),
    base_exists = stat ~= nil,
    base_type = stat and stat.type or nil,
    base_hash = nil,
    base_mode = stat and stat.mode or nil,
  }
  if stat and stat.type == "file" then
    local content = _read(real)
    entry.base_hash = content and _sha(content) or nil
  end
  mapping[real] = entry
  return entry
end

-- ========== 公开 API ==========

--- 开始一次暂存尝试
--- @param attempt table control.new_attempt 返回
--- @param root string 沙箱根目录
--- @return table
function M.begin(attempt, root)
  local dir = string.format("%s/attempts/%s", root, attempt.attempt_id)
  fs.ensure_dir(dir .. "/upper")
  local record = { dir = dir, mapping = {}, attempt = attempt }
  state.attempts[attempt.attempt_id] = record
  return record
end

--- 获取（必要时建立）某真实路径的暂存副本路径
--- 已存在文件复制进 upper；不存在则返回 upper 内新路径（供创建）。
--- @param attempt_id string
--- @param real_path string
--- @return string|nil staged_path
function M.stage_path(attempt_id, real_path)
  local attempt = state.attempts[attempt_id]
  if not attempt then return nil end
  local real = _abs(real_path)
  local entry = _base_entry(attempt, real)
  if entry.base_exists and entry.base_type == "file" and not fs.exists(entry.staged) then
    fs.ensure_dir(vim.fn.fnamemodify(entry.staged, ":h"))
    fs.copy_file(real, entry.staged)
  end
  return entry.staged
end

--- 递归登记 overlay upper 中的文件为候选条目（相对 real_root）
--- 用于外部进程（run_command）在 overlay 私有可写层中产生的文件改动。
--- @param attempt_id string
--- @param real_root string 真实工作目录（overlay lower）
--- @param upper_root string overlay 私有可写层
function M.capture_overlay(attempt_id, real_root, upper_root)
  local attempt = state.attempts[attempt_id]
  if not attempt then return end
  real_root = _abs(real_root):gsub("/$", "")
  local function walk(dir, rel)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      local child_rel = rel == "" and name or (rel .. "/" .. name)
      local child = dir .. "/" .. name
      if t == "directory" then
        walk(child, child_rel)
      elseif t == "file" then
        local real = real_root .. "/" .. child_rel
        local stat = vim.uv.fs_stat(real)
        local entry = {
          real = real,
          staged = child,
          base_exists = stat ~= nil,
          base_type = stat and stat.type or nil,
          base_hash = (stat and stat.type == "file") and _sha(_read(real)) or nil,
        }
        attempt.mapping[real] = entry
      end
    end
  end
  walk(upper_root, "")
end

--- 供 persist_buffer 使用的暂存目标（buffer 写盘重定向）
--- @param real_path string
--- @return string|nil staged_path
--- @return string|nil attempt_id
function M.persist_target(real_path)
  local active = require("NeoAI.sandbox").active_attempt()
  if not active then return nil end
  return M.stage_path(active.attempt_id, real_path), active.attempt_id
end

--- 冻结：生成候选（不修改真实工作区）
--- @param attempt_id string
--- @return table candidate
function M.finish(attempt_id)
  local attempt = state.attempts[attempt_id]
  if not attempt then return nil end
  local files = {}
  for real, entry in pairs(attempt.mapping) do
    local staged_stat = vim.uv.fs_stat(entry.staged)
    local action, after_hash, content
    if entry.base_type == "directory" then
      if staged_stat and staged_stat.type == "directory" then
        if not entry.base_exists then action = "mkdir" end
      else
        if entry.base_exists then action = "rmdir" end
      end
    else
      if staged_stat and staged_stat.type == "file" then
        content = _read(entry.staged)
        after_hash = _sha(content)
        if not entry.base_exists then
          action = "create"
        elseif entry.base_hash ~= after_hash then
          action = "modify"
        end
      else
        if entry.base_exists then action = "delete" end
      end
    end
    if action then
      files[#files + 1] = {
        path = real,
        action = action,
        before_hash = entry.base_hash,
        after_hash = after_hash,
        base_exists = entry.base_exists,
        base_type = entry.base_type,
        content = (action == "create" or action == "modify") and content or nil,
      }
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  local manifest = {}
  for _, f in ipairs(files) do
    manifest[#manifest + 1] = { path = f.path, action = f.action, after_hash = f.after_hash }
  end
  local candidate = {
    candidate_digest = _sha(require("NeoAI.utils.json").encode(manifest)),
    files = files,
    created_at = os.time(),
    command_id = attempt.attempt.command_id,
    attempt_id = attempt_id,
    effect = attempt.attempt.effect,
  }
  return candidate
end

--- CAS 发布候选到真实工作区
--- 仅当真实当前状态等于候选基线时应用；否则 CONFLICT（设计文档 §4.5）。
--- @param candidate table
--- @param opts table|nil { expected_base?: string }
--- @return table { ok, state, reason?, receipt? }
function M.publish(candidate, opts)
  opts = opts or {}
  -- 冲突预检：任一文件真实状态偏离基线则整体拒绝
  for _, f in ipairs(candidate.files or {}) do
    local stat = vim.uv.fs_stat(f.path)
    local exists = stat ~= nil
    if f.action == "create" or f.action == "mkdir" then
      if exists then
        return { ok = false, state = "CONFLICT", reason = "TARGET_ALREADY_EXISTS: " .. f.path }
      end
    else
      if not exists then
        return { ok = false, state = "CONFLICT", reason = "TARGET_MISSING: " .. f.path }
      end
      if stat.type == "file" then
        local cur = _read(f.path)
        if _sha(cur) ~= f.before_hash then
          return { ok = false, state = "CONFLICT", reason = "BASELINE_CHANGED: " .. f.path }
        end
      end
    end
  end
  -- 应用
  for _, f in ipairs(candidate.files or {}) do
    if f.action == "create" or f.action == "modify" then
      fs.ensure_dir(vim.fn.fnamemodify(f.path, ":h"))
      local ok, err = fs.write_file_atomic(f.path, f.content or "")
      if not ok then
        return { ok = false, state = "ROLLBACK_FAILED", reason = "WRITE_FAILED: " .. f.path .. " " .. tostring(err) }
      end
    elseif f.action == "mkdir" then
      fs.ensure_dir(f.path)
    elseif f.action == "delete" then
      fs.delete_file(f.path)
    elseif f.action == "rmdir" then
      pcall(vim.fn.delete, f.path, "d")
    end
  end
  local receipt = {
    operation_id = "op_" .. (candidate.candidate_digest or ""):gsub("[^%w]", ""),
    candidate_digest = candidate.candidate_digest,
    old_version = opts.expected_base,
    new_version = candidate.candidate_digest,
    target = "workspace",
    published_at = os.time(),
    file_count = #(candidate.files or {}),
  }
  return { ok = true, state = "COMMITTED", receipt = receipt }
end

--- 释放尝试的暂存目录
--- @param attempt_id string
function M.cleanup(attempt_id)
  local attempt = state.attempts[attempt_id]
  if not attempt then return end
  pcall(vim.fn.delete, attempt.dir, "rf")
  state.attempts[attempt_id] = nil
end

--- 重置（测试用）
function M.reset()
  for id, attempt in pairs(state.attempts) do
    pcall(vim.fn.delete, attempt.dir, "rf")
  end
  state.attempts = {}
end

return M
