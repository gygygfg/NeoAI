--- 文件系统操作
--- @module NeoAI.utils.fs
--- 纯工具函数，封装 vim.fn 与 io 的文件操作，含 JSONL 追加/撕裂行恢复。
--- 同步版本供内部/测试使用；异步版本（*_async）把阻塞式 I/O 移出 nvim 主线程，
--- 经 utils.work 在线程池执行，避免大文件 / 递归搜索卡住主界面。

local work = require("NeoAI.utils.work")

local M = {}

-- ========== 基础 ==========

--- 展开路径中的 shell 风格的别名：开头的 ~ / ~user（及 $VAR 环境变量）。
--- 仅当 path 以 ~ 或 $ 开头时才展开；纯相对路径保持不变（保留 cwd 语义）。
--- 需在主线程调用（内部用 vim.fn.expand）。
--- @param path string
--- @return string
function M.expand(path)
  if type(path) ~= "string" or path == "" then return path end
  local c = path:sub(1, 1)
  if c == "~" or c == "$" then
    local ok, r = pcall(vim.fn.expand, path)
    if ok and r and r ~= "" then return r end
  end
  return path
end

--- 判断文件是否存在
--- @param path string
--- @return boolean
function M.exists(path)
  return vim.fn.filereadable(M.expand(path)) == 1
end

--- 判断目录是否存在
--- @param path string
--- @return boolean
function M.is_dir(path)
  return vim.fn.isdirectory(M.expand(path)) == 1
end

--- 解析路径的规范形式：展开 ~/$VAR → 绝对化 → 解析符号链接并折叠 `..`/`.`。
--- 用于安全判定（遮蔽/风险分级/候选发布）——必须与「打开文件时内核的解析结果」一致。
--- 注意 `fnamemodify(:p)` 在中间组件不存在时**不会**折叠 `..`，而 `vim.fn.resolve` 会，
--- 故这里以 resolve 为准（它也能解析悬空符号链接）。
--- @param path string
--- @return string
function M.canonical(path)
  if type(path) ~= "string" or path == "" then return path end
  local abs = vim.fn.fnamemodify(M.expand(path), ":p")
  local ok, resolved = pcall(vim.fn.resolve, abs)
  if ok and type(resolved) == "string" and resolved ~= "" then abs = resolved end
  abs = abs:gsub("^/+", "/"):gsub("/+$", "")
  if abs == "" then abs = "/" end
  return abs
end

--- 确保目录存在（递归创建）
--- @param path string
--- @return boolean, string|nil
function M.ensure_dir(path)
  path = M.expand(path)
  if M.is_dir(path) then return true end
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok then return false, err end
  return true
end

--- 读取整个文件
--- @param path string
--- @return string|nil, string|nil 内容, 错误
function M.read_file(path)
  local ok, data = pcall(function()
    local f = io.open(path, "rb")
    if not f then error("无法打开文件: " .. path) end
    local content = f:read("*a")
    f:close()
    return content
  end)
  if not ok then return nil, data end
  return data
end

--- 写入整个文件（覆盖）
--- @param path string
--- @param content string
--- @return boolean, string|nil
local function _write_file(path, content, mode)
  local f, err = io.open(path, mode)
  if not f then return false, err end
  -- Lua I/O 通常返回 nil, err，而不是抛异常；缓冲写入也可能到 close 才失败。
  local called, written, write_err = pcall(f.write, f, content)
  local closed, close_err = f:close()
  if not called then return false, written end
  if not written then return false, write_err end
  if not closed then return false, close_err end
  return true
end

function M.write_file(path, content)
  return _write_file(path, content, "wb")
end

--- 追加内容到文件末尾
--- @param path string
--- @param content string
--- @return boolean, string|nil
function M.append_file(path, content)
  return _write_file(path, content, "ab")
end

--- 删除文件
--- @param path string
--- @return boolean, string|nil
function M.delete_file(path)
  local ok, result = pcall(vim.fn.delete, path)
  if not ok then return false, result end
  if result ~= 0 then return false, "无法删除文件: " .. path end
  return true
end

--- 设置文件/目录权限（八进制 mode，如 493=0755）。失败返回 false。
--- @param path string
--- @param mode number
--- @return boolean
function M.chmod(path, mode)
  if type(mode) ~= "number" then return false end
  local ok = vim.uv.fs_chmod(path, mode)
  return ok ~= nil
end

--- 同目录临时文件 + fsync + rename：失败不截断原文件。
--- @param path string
--- @param content string
--- @param opts table|nil { backup?: boolean, mode?: number 保留原权限位, sync?: boolean 是否 fsync（默认 true） }
--- @return boolean, string|nil
function M.write_file_atomic(path, content, opts)
  local uv = vim.uv
  local fd, tmp = uv.fs_mkstemp(path .. ".tmp.XXXXXX")
  if not fd then return false, tmp end
  local function fail(err)
    if fd then uv.fs_close(fd); fd = nil end
    uv.fs_unlink(tmp)
    return false, err
  end
  -- fs_write 可以短写，必须写完全部内容再提交。
  local offset = 0
  while offset < #content do
    local n, err = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not n or n == 0 then return fail(err or "文件写入未完成") end
    offset = offset + n
  end
  -- sync=false：会话级 overlay 私有可写层等临时草稿无需落盘，逐文件 fsync 在暂存量大时
  -- 是主要卡顿源；真实工作区发布等需要持久化的路径保持默认 fsync。
  if not (opts and opts.sync == false) then
    local synced, sync_err = uv.fs_fsync(fd)
    if not synced then return fail(sync_err) end
  end
  local closed, close_err = uv.fs_close(fd)
  fd = nil
  if not closed then return fail(close_err) end
  -- 保留原权限位：mkstemp 默认 0600，若不 chmod 会剥离可执行位（venv/bin 脚本等）。
  if opts and type(opts.mode) == "number" then
    uv.fs_chmod(tmp, opts.mode)
  end
  if opts and opts.backup then
    local stat, stat_err, stat_code = uv.fs_stat(path)
    if stat then
      local copied, copy_err = M.copy_file(path, path .. ".bak")
      if not copied then return fail(copy_err) end
    elseif stat_code ~= "ENOENT" then
      return fail(stat_err)
    end
  end
  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then return fail(rename_err) end
  return true
end

-- ========== JSONL ==========

--- 读取 JSONL 文件，返回对象数组
--- @param path string
--- @return table 数组
function M.read_jsonl(path)
  local data = M.read_file(path)
  if not data then return {} end
  local json = require("NeoAI.utils.json")
  local out = {}
  for line in data:gmatch("[^\r\n]+") do
    local obj = json.decode_line(line)
    if obj then
      out[#out + 1] = obj
    end
  end
  return out
end

--- 追加一行 JSON 到 JSONL 文件
--- @param path string
--- @param obj table
--- @return boolean, string|nil
function M.append_jsonl(path, obj)
  local json = require("NeoAI.utils.json")
  return M.append_file(path, json.encode(obj) .. "\n")
end

--- 修复 JSONL 文件末尾可能撕裂的不完整行
--- 崩溃时最后一行可能不完整，截断即可
--- @param path string
--- @return boolean 是否有撕裂行被截断
function M.repair_jsonl(path)
  if not M.exists(path) then return false end
  local f = io.open(path, "rb")
  if not f then return false end
  local size = f:seek("end")
  if size == 0 then f:close(); return false end
  -- 正常日志只读最后一个字节，避免启动时为检查行尾额外读一遍全部历史。
  if size then
    f:seek("set", size - 1)
    if f:read(1) == "\n" then f:close(); return false end
    f:seek("set", 0)
  end
  local content = f:read("*a")
  f:close()
  if content:sub(-1) == "\n" then return false end
  local last_nl = content:find("[^\r\n]*$")
  local trailing = content:sub(last_nl)
  if trailing == "" then return false end
  local json = require("NeoAI.utils.json")
  local ok = json.decode_line(trailing) ~= nil
  if ok then
    -- 完整 JSON 但缺行尾：补齐分隔符，避免下一次追加粘成一行。
    local written, err = M.append_file(path, "\n")
    if not written then return false, err end
    return false
  end
  local cut = content:sub(1, last_nl - 1)
  local written, err = M.write_file_atomic(path, cut)
  if not written then return false, err end
  return true
end

-- ========== 其它 ==========

--- 复制文件（失败时尝试备份）
--- @param src string
--- @param dst string
--- @return boolean, string|nil
function M.copy_file(src, dst)
  local ok, err = vim.uv.fs_copyfile(src, dst)
  if not ok then return false, err end
  return true
end

--- 列出目录内容
--- @param path string
--- @return table 数组
function M.list_dir(path)
  local entries = vim.fn.readdir(path) or {}
  table.sort(entries)
  return entries
end

--- 拼接路径
--- @param ... string
--- @return string
function M.join(...)
  local parts = { ... }
  local out = ""
  for i, p in ipairs(parts) do
    if p and p ~= "" then
      if i > 1 then
        if out:sub(-1) == "/" then
          out = out .. p
        else
          out = out .. "/" .. p
        end
      else
        out = p
      end
    end
  end
  return out
end

--- 获取文件扩展名
--- @param path string
--- @return string
function M.ext(path)
  return path:match("%.([^.\\/]+)$") or ""
end

--- 获取文件名
--- @param path string
--- @return string
function M.basename(path)
  return path:match("[^/\\]+$") or path
end

--- 获取目录部分
--- @param path string
--- @return string
function M.dirname(path)
  local dir = path:match("^(.*)[/\\][^/\\]+$")
  return dir or "."
end

-- ========== 异步（线程池） ==========

-- 线程内自包含工作函数：纯 Lua + vim.uv（fs_scandir），不能依赖外部模块/upvalue。
-- 每个工作函数接收原始类型参数，返回 string。

--- 线程内递归列出目录（含子目录）
--- @param dir string 起始目录
--- @param max number 最大条数（0 = 不限）
--- @return string 每行一条路径
local function _list_worker(dir, max, entry_cap)
  local out = {}
  local count = 0
  -- 安全上限：`max<=0` 不再表示「无上限」——对 home/ 等超大目录（数十万条目）无界递归会
  -- 占满 libuv 工作线程与内存，表现为 `libuv-worker` CPU 打满、工具迟迟不返回。显式传入的
  -- 大 max 同样被硬上限钳制。`entry_cap` 仅供测试覆盖。
  local HARD_CAP = (entry_cap and entry_cap > 0) and entry_cap or 50000
  local limit = (max and max > 0) and math.min(max, HARD_CAP) or HARD_CAP
  local function walk(path)
    if count >= limit then return end
    local handle = vim.uv.fs_scandir(path)
    if not handle then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if count >= limit then return end
      local full = path .. "/" .. name
      if t == "directory" then
        out[#out + 1] = full .. "/"
        count = count + 1
        walk(full)
      else
        out[#out + 1] = full
        count = count + 1
      end
    end
  end
  walk(dir)
  return table.concat(out, "\n")
end

--- 线程内递归搜索文件内容。逐文件限制扫描字节数并跳过二进制，避免大文件 OOM。
--- @param dir string 起始目录
--- @param query string 搜索关键字（plain 匹配）
--- @param include_pat string|"" 文件名匹配的 lua pattern（主线程用 stringx.glob_to_pattern 预编译；空则不过滤）
--- @param max number 最大条数
--- @param max_bytes number 单文件最大扫描字节数（超过则跳过）
--- @return string 每行一条：路径 + 匹配片段
local function _search_worker(dir, query, include_pat, max, max_bytes, visit_cap, time_budget)
  local out = {}
  local count = 0
  local limit = max and max > 0 and max or 50
  local inc_pat = include_pat or ""
  local scan_cap = (max_bytes and max_bytes > 0) and max_bytes or (8 * 1024 * 1024)
  -- 无匹配时的遍历边界：否则 search_files 在 home/ 等超大目录会遍历数十万条目并逐个读文件，
  -- 占满工作线程（`libuv-worker` CPU 打满）且迟迟不返回。同时用**时间预算**兜底：慢文件系统上
  -- 即使条目数未到上限也可能耗时过久，达到预算即停止遍历。
  local VISIT_CAP = (visit_cap and visit_cap > 0) and visit_cap or 100000
  local TIME_BUDGET = (time_budget and time_budget > 0) and time_budget or 5 -- 秒（CPU 时间，纯 Lua os.clock 可用）
  local visited = 0
  local deadline = os.clock() + TIME_BUDGET
  local function expired()
    return visited >= VISIT_CAP or os.clock() >= deadline
  end
  local function walk(path)
    if count >= limit or expired() then return end
    local handle = vim.uv.fs_scandir(path)
    if not handle then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if count >= limit or expired() then return end
      visited = visited + 1
      local full = path .. "/" .. name
      if t == "directory" then
        walk(full)
      elseif t == "file" then
        if inc_pat == "" or name:match(inc_pat) then
          local stat = vim.uv.fs_stat(full)
          if stat and stat.size and stat.size <= scan_cap then
            local f = io.open(full, "rb")
            if f then
              -- 多读 1 字节：文件在 stat 之后增长也能被识别并跳过。
              local content = f:read(scan_cap + 1)
              f:close()
              -- 超限或二进制（含 NUL）不整读，避免内存暴涨与乱码片段。
              if content and #content <= scan_cap and not content:find("\0", 1, true) then
                local pos = content:find(query, 1, true)
                if pos then
                  local snippet = content:sub(pos, pos + 200)
                  snippet = snippet:gsub("[\n\r]+", " "):gsub("%c", " ")
                  out[#out + 1] = full .. ": " .. snippet
                  count = count + 1
                end
              end
            end
          end
        end
      end
    end
  end
  walk(dir)
  local truncated = expired()
  if #out == 0 then
    return truncated
      and ("未找到匹配内容（目录过大，已扫描 " .. visited .. " 个条目后停止；请缩小范围或指定 include）")
      or "未找到匹配内容"
  end
  local text = table.concat(out, "\n")
  if truncated then text = text .. "\n（结果可能不完整：已达扫描边界，请缩小范围或指定 include）" end
  return text
end

--- 线程内按块逐行读取，避免一次性把超大文件读入内存。
--- 注意：工作函数经 string.dump 序列化后不携带 upvalue，此函数必须定义在
--- _read_worker 内部（作为局部函数），不能作为外部 upvalue 引用。
--- @param f file* 已打开的文件
--- @param start_line number 起始行（1-based）
--- @param end_line number|0 结束行（0 = 到文件末尾）
--- @param cap number 累计输出字节上限
--- @return string 选中行拼接
local function _read_worker(filepath, start_line, end_line, max_bytes)
  local function read_lines_bounded(f, first, last, cap, trailing_nl)
    local chunk_size = 65536
    local finish = (last and last > 0) and last or math.huge
    local out, out_bytes = {}, 0
    local lineno = 0
    local pending = ""
    local done = false
    while not done do
      local chunk = f:read(chunk_size)
      if not chunk then
        if pending ~= "" then
          lineno = lineno + 1
          if lineno >= first and lineno <= finish then
            out[#out + 1] = pending
            out_bytes = out_bytes + #pending
          end
        elseif trailing_nl then
          -- 与 vim.split(content .. "\n", "\n") 语义一致：文件以换行结尾时多一个空行。
          lineno = lineno + 1
          if lineno >= first and lineno <= finish then
            out[#out + 1] = ""
          end
        end
        break
      end
      pending = pending .. chunk
      local pos = 1
      while true do
        local nl = pending:find("\n", pos, true)
        if not nl then
          pending = pending:sub(pos)
          break
        end
        local line = pending:sub(pos, nl - 1)
        lineno = lineno + 1
        if lineno >= first and lineno <= finish then
          out[#out + 1] = line
          out_bytes = out_bytes + #line + 1
          if out_bytes > cap then
            error(string.format("读取内容超过 %d 字节上限，请缩小 start_line/end_line 区间", cap))
          end
          if lineno >= finish then
            done = true
            break
          end
        end
        pos = nl + 1
        if lineno >= finish then
          done = true
          break
        end
      end
      -- 单行超长（如无换行的巨大文件）同样要设限，否则 pending 会无限增长。
      if not done and #pending > cap then
        error(string.format("单行内容超过 %d 字节上限，无法安全读取", cap))
      end
    end
    return table.concat(out, "\n")
  end

  local stat = vim.uv.fs_stat(filepath)
  if stat and stat.type == "directory" then
    error("路径是目录，无法作为文件读取: " .. filepath)
  end
  local cap = (max_bytes and max_bytes > 0) and max_bytes or (8 * 1024 * 1024)
  local f = io.open(filepath, "rb")
  if not f then error("无法打开文件: " .. filepath) end
  if start_line and start_line > 0 then
    local trailing_nl = false
    local size = f:seek("end")
    if size and size > 0 then
      f:seek("set", size - 1)
      trailing_nl = f:read(1) == "\n"
      f:seek("set", 0)
    end
    local ok, content = pcall(read_lines_bounded, f, start_line, end_line, cap, trailing_nl)
    f:close()
    if not ok then error(content) end
    return content
  end
  local content = f:read(cap + 1) or ""
  f:close()
  if #content > cap then
    error(string.format("文件过大（超过 %d 字节），请改用 start_line/end_line 读取指定区间", cap))
  end
  return content
end

--- 线程内写入文件
--- @param filepath string
--- @param content string
--- @return string "ok" 或抛错
local function _write_worker(filepath, content)
  local f, err = io.open(filepath, "wb")
  if not f then error("无法写入文件: " .. filepath .. ": " .. tostring(err)) end
  local called, written, write_err = pcall(f.write, f, content)
  local closed, close_err = f:close()
  if not called then error(written) end
  if not written then error(write_err) end
  if not closed then error(close_err) end
  return "ok"
end

--- 线程内追加文件
--- @param filepath string
--- @param content string
--- @return string "ok" 或抛错
local function _append_worker(filepath, content)
  local f, err = io.open(filepath, "ab")
  if not f then error("无法追加文件: " .. filepath .. ": " .. tostring(err)) end
  local called, written, write_err = pcall(f.write, f, content)
  local closed, close_err = f:close()
  if not called then error(written) end
  if not written then error(write_err) end
  if not closed then error(close_err) end
  return "ok"
end

--- 线程内删除文件
--- @param filepath string
--- @return string "ok" 或抛错
local function _delete_worker(filepath)
  local ok, err = vim.uv.fs_unlink(filepath)
  if not ok then error("无法删除文件: " .. filepath .. " (" .. tostring(err) .. ")") end
  return "ok"
end

--- 异步读取文件（线程池，不阻塞主线程）
--- @param filepath string
--- @param max_bytes number|nil 整读字节上限（超过则拒绝，提示改用行范围）
--- @return Deferred resolve(内容 string)
function M.read_file_async(filepath, max_bytes)
  return work.run(_read_worker, filepath, 0, 0, max_bytes or 0)
end

--- 异步读取文件（带行范围）
--- @param filepath string
--- @param start_line number
--- @param end_line number
--- @param max_bytes number|nil 累计输出字节上限
--- @return Deferred resolve(内容 string)
function M.read_file_lines_async(filepath, start_line, end_line, max_bytes)
  return work.run(_read_worker, filepath, start_line, end_line, max_bytes or 0)
end

--- 异步写入文件
--- @param filepath string
--- @param content string
--- @return Deferred
function M.write_file_async(filepath, content)
  return work.run(_write_worker, filepath, content)
end

--- 异步追加文件
--- @param filepath string
--- @param content string
--- @return Deferred
function M.append_file_async(filepath, content)
  return work.run(_append_worker, filepath, content)
end

--- 异步删除文件
--- @param filepath string
--- @return Deferred
function M.delete_file_async(filepath)
  return work.run(_delete_worker, filepath)
end

--- 异步递归列出目录
--- @param dir string
--- @param max number|nil 最大条数（nil/0 = 使用内置安全上限 50000）
--- @param opts table|nil { entry_cap? = number } 仅测试用于覆盖安全上限
--- @return Deferred resolve(每行一条路径 string)
function M.list_dir_async(dir, max, opts)
  return work.run(_list_worker, dir, max or 0, (opts and opts.entry_cap) or 0)
end

--- 异步递归搜索文件内容（线程池执行，避免递归遍历卡住主线程）
--- @param dir string 起始目录
--- @param query string 搜索关键字
--- @param opts table|nil { include?, max_results?, max_file_bytes?, visit_cap?, time_budget? }
---   visit_cap/time_budget 仅供测试覆盖遍历边界（默认 100000 条 / 5s CPU）
--- @return Deferred resolve(每行一条 string)
function M.search_files_async(dir, query, opts)
  opts = opts or {}
  -- glob 在主线程预编译为 anchored lua pattern（stringx 支持 * ? {a,b}），
  -- 线程内只需 name:match(pattern)，避免在受限线程里重新实现 glob。
  local include_pat = ""
  local include = opts.include or ""
  include = include:gsub("^%s+", ""):gsub("%s+$", "")
  if include ~= "" then
    local stringx = require("NeoAI.utils.stringx")
    include_pat = stringx.glob_to_pattern(include)
  end
  return work.run(_search_worker, dir, query, include_pat, opts.max_results or 50,
    opts.max_file_bytes or 0, opts.visit_cap or 0, opts.time_budget or 0)
end

return M
