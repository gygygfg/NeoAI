--- 镜像 Neovim 工具
--- @module 'NeoAI.tools.builtin.nvim_ops'
---
--- AI 的 `:lua` / Ex 命令**绝不在主 Neovim 进程执行**：每次调用在沙箱内起一个独立的
--- headless Neovim「镜像」，把当前编辑器的普通 buffer 对象（名字/内容/关键选项/光标）
--- 加载进去，再执行用户代码。
---
--- 不变量：
---   * 镜像 buffer 内容取沙箱视图（= 用户 save-all 基线 + AI 暂存改动）；没有视图条目时
---     回退父 buffer 实时内容。AI 与其它沙箱工具看到同一份内容；
---   * 镜像内的 `:write` / `vim.fn.writefile` 写入沙箱 overlay → 候选捕获/审批；
---   * 镜像 buffer 修改随进程退出丢弃，**绝不回写主编辑器**；
---   * 结果统一 redact + tokenize + 限流后回传（镜像能读真实内容，但 AI 只看到遮蔽视图）；
---   * 沙箱不可用时拒绝执行（无法保证写入落沙箱），不提供未隔离直跑降级（测试可 opt-in）。

local helpers = require("NeoAI.tools.builtin.tool_helpers")
local buffer_ref = require("NeoAI.utils.buffer")
local fs = require("NeoAI.utils.fs")
local json = require("NeoAI.utils.json")
local output_guard = require("NeoAI.tools.builtin.output_guard")

local M = {}

-- ========== 私有状态 ==========

local seq = 0

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.nvim")
  end)
  return (ok and type(cfg) == "table") and cfg or {}
end

--- 镜像会话临时目录（沙箱内 `/tmp/...</>` 与宿主侧会话私有目录一一对应）。
--- @param uniq string
--- @return string host_dir
--- @return string guest_dir
local function _mirror_dirs(uniq)
  local guest = "/tmp/neoai-nvim/" .. uniq
  local host = guest
  local ok, guest_fs = pcall(require, "NeoAI.sandbox.execution.guest_fs")
  if ok and guest_fs and type(guest_fs.tmp_host) == "function" then
    local dir = guest_fs.tmp_host("/tmp")
    if dir and dir ~= "" then host = dir .. "/neoai-nvim/" .. uniq end
  end
  fs.ensure_dir(host)
  return host, guest
end

--- 读取路径的「视图内容」：优先沙箱暂存（单视图/旧布局），否则磁盘。
--- 旧布局暂存可能是 token 化视图：镜像需要真实内容，尽量 detokenize。
--- @param real string
--- @return string|nil content
--- @return boolean staged 是否来自沙箱条目（false = 磁盘内容）
local function _view_content(real)
  if type(real) ~= "string" or real == "" then return nil, false end
  local staged
  local ok_c, cand = pcall(require, "NeoAI.sandbox.execution.candidate")
  if ok_c and cand and type(cand.read_path) == "function" then
    local ok, p = pcall(cand.read_path, real)
    if ok then staged = p end
  end
  local content = staged and fs.read_file(staged) or nil
  local from_staged = content ~= nil
  if content == nil then content = fs.read_file(real) end
  if content == nil then return nil, false end
  local ok_s, secret = pcall(require, "NeoAI.sandbox.secret.secret")
  if ok_s and secret and type(secret.detokenize) == "function" then
    local ok_d, detok, unresolved = pcall(secret.detokenize, content)
    if ok_d and type(detok) == "string" and (tonumber(unresolved) or 0) == 0 then
      return detok, from_staged
    end
  end
  return content, from_staged
end

--- 把文本切成镜像 buffer 行（保留 fileformat 信息）。
--- @param content string
--- @return string[] lines
--- @return string fileformat
--- @return boolean eol
local function _split_content(content)
  local text = content or ""
  local ff = "unix"
  if text:find("\r\n", 1, true) then
    ff = "dos"
    text = text:gsub("\r\n", "\n")
  end
  local eol = text:sub(-1) == "\n"
  local body = eol and text:sub(1, -2) or text
  local lines = (body == "") and { "" } or vim.split(body, "\n", { plain = true })
  return lines, ff, eol
end

--- 收集要加载进镜像的 buffer 载荷。
--- @param ids number[]|nil 显式 buffer id（来自 #{buffer}）
--- @param opts table { max_buffer_bytes, max_total_bytes, current }
--- @return table buffers, table notes
local function _collect_buffers(ids, opts)
  local explicit = {}
  for _, id in ipairs(ids or {}) do
    if type(id) == "number" then explicit[id] = true end
  end
  local bufs, notes = {}, {}
  local total, omitted = 0, 0
  local function add(buf, force)
    local obj = buffer_ref.object(buf)
    if not obj then return end
    -- 非显式引用时只镜像已加载 buffer（未加载没有实时状态的必要）。
    if not force and not obj.loaded then return end
    local content, from_staged = nil, false
    if obj.name ~= "" then
      content, from_staged = _view_content(obj.name)
    end
    -- 没有沙箱条目时，优先父 buffer 实时内容（含未保存修改）；有条目时以沙箱视图为准
    -- （= save-all 基线 + AI 暂存改动，与 read_file/run_command/LSP 一致）。
    if not from_staged and obj.loaded then
      local live = buffer_ref.content(buf)
      if live ~= nil then content = live end
    end
    if content == nil and obj.loaded then content = buffer_ref.content(buf) end
    if content == nil then
      content = ""
      notes[#notes + 1] = ("buffer %d (%s) 内容不可读（二进制或未加载）"):format(
        obj.bufnr, obj.name ~= "" and obj.name or "[无名称]")
    end
    local per_cap = opts.max_buffer_bytes or (1024 * 1024)
    if #content > per_cap or (total + #content) > (opts.max_total_bytes or (8 * 1024 * 1024)) then
      omitted = omitted + 1
      content = ""
      notes[#notes + 1] = ("buffer %d (%s) 超过镜像体积上限，未加载内容")
        :format(obj.bufnr, obj.name ~= "" and obj.name or "[无名称]")
    else
      total = total + #content
    end
    local lines, ff, eol = _split_content(content)
    bufs[#bufs + 1] = {
      id = obj.bufnr,
      name = obj.name,
      lines = lines,
      options = {
        filetype = obj.filetype,
        buftype = obj.buftype,
        fileformat = ff,
        eol = eol,
        expandtab = vim.bo[buf].expandtab,
        shiftwidth = vim.bo[buf].shiftwidth,
        tabstop = vim.bo[buf].tabstop,
        softtabstop = vim.bo[buf].softtabstop,
        textwidth = vim.bo[buf].textwidth,
        commentstring = vim.bo[buf].commentstring,
      },
      cursor = obj.cursor,
      modified = obj.modified,
    }
  end
  local seen = {}
  for _, buf in ipairs(buffer_ref.normal_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      add(buf, explicit[buf] == true)
    end
  end
  -- 显式引用但已不是普通 buffer（或已被删除）的条目：尽力按对象加载。
  for id in pairs(explicit) do
    if not seen[id] and vim.api.nvim_buf_is_valid(id) then add(id, true) end
  end
  if omitted > 0 then
    notes[#notes + 1] = ("另有 %d 个 buffer 因体积上限未加载内容"):format(omitted)
  end
  return bufs, notes
end

--- 镜像脚本：按载荷重建 buffer，执行用户代码，把结果写入结果文件。
local RUN_SCRIPT = [==[
local out_path = os.getenv("NEOAI_MIRROR_OUT")
local payload_path = os.getenv("NEOAI_MIRROR_PAYLOAD")
local code_path = os.getenv("NEOAI_MIRROR_CODE")
local kind = os.getenv("NEOAI_MIRROR_KIND") or "lua"
local result = { ok = true, output = "", result = "", messages = "", error = "" }
local function write_result()
  local ok, enc = pcall(vim.json.encode, result)
  local f = out_path and io.open(out_path, "w")
  if f then
    f:write(ok and enc or "{\"ok\":false,\"error\":\"result encode failed\"}")
    f:close()
  end
end
local ok, err = xpcall(function()
  -- 不创建 swap/backup/undo：镜像进程短命且与主编辑器共享同一文件，绝不能触发 swap 冲突。
  pcall(function()
    vim.o.swapfile = false
    vim.o.backup = false
    vim.o.writebackup = false
    vim.o.undofile = false
    vim.o.more = false
  end)
  local f = assert(io.open(payload_path, "rb"))
  local payload = vim.json.decode(f:read("*a"))
  f:close()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  local map = {}
  for _, info in ipairs(payload.buffers or {}) do
    local b = vim.api.nvim_create_buf(true, false)
    if info.name and info.name ~= "" then
      local okn = pcall(vim.api.nvim_buf_set_name, b, info.name)
      if not okn then pcall(vim.api.nvim_buf_set_name, b, info.name .. "#" .. tostring(b)) end
    end
    if info.lines then vim.api.nvim_buf_set_lines(b, 0, -1, false, info.lines) end
    for k, v in pairs(info.options or {}) do
      if v ~= nil then pcall(vim.api.nvim_set_option_value, k, v, { buf = b }) end
    end
    pcall(function() vim.bo[b].modified = false end)
    map[info.id] = b
  end
  vim.g.neoai_buffers = {}
  for id, b in pairs(map) do vim.g.neoai_buffers[tostring(id)] = b end
  _G.NeoAI = {
    buf = function(id) return map[tonumber(id) or id] end,
    buffers = map,
  }
  local cur = map[payload.current_id] or next(map) or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_set_current_buf, cur)
  if payload.cursor and map[payload.current_id] then
    pcall(vim.api.nvim_win_set_cursor, 0, {
      tonumber(payload.cursor.row) or 1,
      math.max(0, (tonumber(payload.cursor.col) or 1) - 1),
    })
  end
  if payload.cwd and payload.cwd ~= "" then
    pcall(vim.cmd, "silent! cd " .. vim.fn.fnameescape(payload.cwd))
  end
  if kind == "lua" then
    local chunk, load_err = loadfile(code_path)
    if not chunk then error(load_err, 0) end
    local rets = { pcall(chunk) }
    if not rets[1] then error(rets[2], 0) end
    if #rets > 1 then
      local vals = {}
      for i = 2, #rets do
        local v = rets[i]
        if type(v) == "string" then
          vals[#vals + 1] = v
        else
          local okj, enc = pcall(vim.json.encode, v)
          vals[#vals + 1] = (okj and type(enc) == "string") and enc or vim.inspect(v)
        end
      end
      result.result = table.concat(vals, "\n")
    end
  else
    local ef = assert(io.open(code_path, "rb"))
    local ex = ef:read("*a")
    ef:close()
    local okx, res = pcall(vim.api.nvim_exec2, ex, { output = true })
    if not okx then error(res, 0) end
    result.output = (res and res.output) or ""
  end
end, debug.traceback)
if not ok then
  result.ok = false
  result.error = tostring(err)
end
pcall(function()
  local m = vim.api.nvim_exec2("messages", { output = true })
  result.messages = (m and m.output) or ""
end)
write_result()
pcall(vim.cmd, "qall!")
]==]

--- 把宿主 nvim 二进制（含 AppImage 挂载点 / VIMRUNTIME）以只读方式绑定进沙箱前缀。
--- 沙箱用会话私有 `/tmp` 覆盖了宿主 `/tmp`：AppImage 的 `/tmp/.mount_nvim*` 因此不可见，
--- 直接 spawn 会 exit 127。这里把挂载点目录（或二进制本身）按原路径 ro-bind 回去。
--- @param prefix string[] 沙箱前缀（copy）
--- @param bin string
local function _bind_nvim(prefix, bin)
  local binds = {}
  local function add(src)
    -- 目录（AppImage 挂载点 / VIMRUNTIME）不能用 `fs.exists`（filereadable 对目录恒为 false）。
    if type(src) ~= "string" or src == "" or vim.uv.fs_stat(src) == nil then return end
    -- 同一路径重复绑定无害；去重避免前缀膨胀。
    for _, s in ipairs(binds) do if s == src then return end end
    binds[#binds + 1] = src
  end
  local mount = type(bin) == "string" and bin:match("^(/tmp/%.mount_[^/]+)") or nil
  if mount then
    add(mount)
  else
    add(fs.canonical(bin))
    add(bin)
  end
  local runtime_dir = vim.env.VIMRUNTIME
  if type(runtime_dir) == "string" and runtime_dir ~= "" then add(runtime_dir) end
  if #binds == 0 then return end
  -- 找到 bwrap 选项与「载荷包装器」的边界：bwrap 之后可能还有 setpriv（降权）、
  -- 网络代理包装（`sh -c <script> neoai-net`）等；必须把 --ro-bind 插在它们**之前**，
  -- 否则会被当成包装器的参数（实测 `exec: --ro-bind: not found`）。
  local insert_at = #prefix + 1
  local bwrap_at = 1
  for i, v in ipairs(prefix) do
    if v == "bwrap" then bwrap_at = i break end
  end
  for i = bwrap_at + 1, #prefix do
    local v = prefix[i]
    if v == "setpriv" or v == "--" then insert_at = i break end
    if v == "sh" and prefix[i + 1] == "-c" and prefix[i + 3] == "neoai-net" then
      insert_at = i
      break
    end
  end
  -- 未发现载荷包装器：若原生 seccomp 是最后一个 bwrap 选项，插在 `--seccomp <fd>` 之后。
  if insert_at == #prefix + 1 then
    for i = bwrap_at + 1, #prefix do
      if prefix[i] == "--seccomp" then insert_at = math.min(#prefix + 1, i + 2) break end
    end
  end
  local args = {}
  for _, src in ipairs(binds) do
    args[#args + 1] = "--ro-bind"
    args[#args + 1] = src
    args[#args + 1] = src
  end
  for i = #args, 1, -1 do table.insert(prefix, insert_at, args[i]) end
end

--- 启动镜像进程并收集结果。
--- @param payload table
--- @param code string 用户代码
--- @param kind string "lua" | "ex"
--- @param ctx table|nil
--- @param cb function(ok:boolean, data:table|string)
local function _run_mirror(payload, code, kind, ctx, cb)
  ctx = ctx or {}
  local cfg = _cfg()
  seq = seq + 1
  local uniq = ("%d-%d-%d"):format(vim.fn.getpid(), vim.uv.now(), seq)
  local host_dir, guest_dir = _mirror_dirs(uniq)
  local prefix = {}
  for _, v in ipairs(ctx.sandbox_prefix or {}) do prefix[#prefix + 1] = v end
  local allow_unisolated = cfg.allow_unisolated == true
  if #prefix == 0 and not allow_unisolated then
    cb(false, "沙箱不可用：nvim 工具必须在沙箱内运行（修改必须落沙箱）。")
    return
  end
  local nvim_bin = vim.v.progpath
  if type(nvim_bin) ~= "string" or nvim_bin == "" then nvim_bin = "nvim" end
  -- AppImage/自定义安装路径：把镜像二进制与 VIMRUNTIME 只读绑进沙箱（/tmp 被私有 tmpfs 覆盖）。
  if #prefix > 0 then pcall(_bind_nvim, prefix, nvim_bin) end
  local payload_path = host_dir .. "/payload.json"
  local code_path = host_dir .. "/code." .. (kind == "lua" and "lua" or "ex")
  local script_path = host_dir .. "/run.lua"
  local out_guest = guest_dir .. "/result.json"
  local out_host = host_dir .. "/result.json"
  local ok_w = fs.write_file(payload_path, json.encode(payload))
    and fs.write_file(code_path, code)
    and fs.write_file(script_path, RUN_SCRIPT)
  if not ok_w then
    pcall(vim.fn.delete, host_dir, "rf")
    cb(false, "无法写入镜像载荷（目录不可写）")
    return
  end
  -- 脚本与载荷在沙箱内使用访客路径；未隔离测试（allow_unisolated）直接用宿主路径。
  local in_sandbox = #prefix > 0
  local payload_guest = in_sandbox and (guest_dir .. "/payload.json") or payload_path
  local code_guest = in_sandbox and (guest_dir .. "/code." .. (kind == "lua" and "lua" or "ex"))
    or code_path
  local script_guest = in_sandbox and (guest_dir .. "/run.lua") or script_path
  local out_arg = in_sandbox and out_guest or out_host
  local env = vim.tbl_extend("force", {}, ctx.sandbox_env or {})
  env.NEOAI_MIRROR_PAYLOAD = payload_guest
  env.NEOAI_MIRROR_CODE = code_guest
  env.NEOAI_MIRROR_OUT = out_arg
  env.NEOAI_MIRROR_KIND = kind
  local argv = {
    nvim_bin, "--headless", "-u", "NONE", "-i", "NONE", "--noplugin",
    "-c", "luafile " .. script_guest,
  }
  local full = {}
  for _, v in ipairs(prefix) do full[#full + 1] = v end
  for _, v in ipairs(argv) do full[#full + 1] = v end
  local out, err = {}, {}
  local done = false
  local timer
  local function finish(code_out, timed_out)
    if done then return end
    done = true
    if timer then
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
      timer = nil
    end
    local raw = fs.read_file(out_host)
    pcall(vim.fn.delete, host_dir, "rf")
    if timed_out then
      cb(false, "镜像执行超时")
      return
    end
    if raw == nil then
      cb(false, ("镜像未返回结果（退出码 %s）\n%s\n%s"):format(
        tostring(code_out), table.concat(out, ""), table.concat(err, "")))
      return
    end
    local okj, data = pcall(json.decode, raw)
    if not okj or type(data) ~= "table" then
      cb(false, "镜像结果解析失败")
      return
    end
    data.stdout = table.concat(out, "\n")
    data.stderr = table.concat(err, "\n")
    cb(data.ok ~= false, data)
  end
  local job = vim.fn.jobstart(full, {
    cwd = ctx.sandbox_cwd or payload.cwd or vim.fn.getcwd(),
    env = env,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, d)
      for i = 1, #(d or {}) do
        if d[i] ~= "" then out[#out + 1] = d[i] end
      end
    end,
    on_stderr = function(_, d)
      for i = 1, #(d or {}) do
        if d[i] ~= "" then err[#err + 1] = d[i] end
      end
    end,
    on_exit = function(_, code_out) finish(code_out, false) end,
  })
  if job <= 0 then
    pcall(vim.fn.delete, host_dir, "rf")
    cb(false, "无法启动镜像 Neovim（binary 不存在或沙箱前缀拒绝执行）")
    return
  end
  local timeout_ms = tonumber(cfg.timeout_ms) or 30000
  if timeout_ms > 0 then
    timer = vim.uv.new_timer()
    if timer then
      timer:start(timeout_ms, 0, function()
        vim.schedule(function()
          if done then return end
          if ctx and type(ctx.sandbox_kill) == "function" then pcall(ctx.sandbox_kill) end
          pcall(vim.fn.jobstop, job)
          finish(-1, true)
        end)
      end)
    end
  end
end

--- 结果脱敏 + 限流。
--- @param text string
--- @return string
local function _sanitize(text)
  local out = text or ""
  local ok, conceal = pcall(require, "NeoAI.sandbox.observe.conceal")
  if ok and conceal and type(conceal.redact) == "function" then
    local okr, red = pcall(conceal.redact, out)
    if okr and type(red) == "string" then out = red end
  end
  local ok2, secret = pcall(require, "NeoAI.sandbox.secret.secret")
  if ok2 and secret and type(secret.tokenize) == "function" then
    local okt, tok = pcall(secret.tokenize, out)
    if okt and type(tok) == "string" then out = tok end
  end
  return output_guard.cap(out, { tool = "nvim" })
end

-- ========== 工具定义 ==========

local nvim_tools = {}

nvim_tools.nvim = helpers.define_tool(
  "nvim",
  "在沙箱内的镜像 Neovim 中执行 Lua / Ex 命令：可读取当前 buffer 的实时内容与编辑器状态；"
    .. "写入落沙箱暂存（发布前不改真实盘），镜像 buffer 修改不会回写主编辑器。"
    .. "lua 与 ex 二选一；可用 #{buffer} 的对象 id 通过 buffer_ids 强制加载。"
    .. "镜像里没有用户 LSP 客户端/插件（LSP 查询请用 lsp_* 工具）。",
  {
    type = "object",
    properties = {
      lua = { type = "string", description = "在镜像中执行的 Lua 代码（可用 vim.* / vim.api.*）" },
      ex = { type = "string", description = "在镜像中执行的 Ex 命令（也可用 :lua）" },
      buffer_ids = {
        type = "array",
        items = { type = "integer" },
        description = "要强制加载进镜像的 buffer 对象 id（来自 #{buffer} 的 id）",
      },
    },
    required = {},
  },
  function(args, on_success, on_error, ctx)
    local cfg = _cfg()
    if cfg.enabled == false then
      on_error("nvim 工具已禁用（tools.nvim.enabled=false）")
      return
    end
    local has_lua = type(args.lua) == "string" and args.lua ~= ""
    local has_ex = type(args.ex) == "string" and args.ex ~= ""
    if has_lua == has_ex then
      on_error("nvim：lua 与 ex 必须二选一")
      return
    end
    local ids = {}
    if type(args.buffer_ids) == "table" then
      for _, v in ipairs(args.buffer_ids) do
        local n = tonumber(v)
        if n then ids[#ids + 1] = math.floor(n) end
      end
    end
    local cur = vim.api.nvim_get_current_buf()
    if not buffer_ref.is_normal(cur) then cur = nil end
    local buffers, notes = _collect_buffers(ids, {
      max_buffer_bytes = tonumber(cfg.max_buffer_bytes) or (1024 * 1024),
      max_total_bytes = tonumber(cfg.max_total_bytes) or (8 * 1024 * 1024),
      current = cur,
    })
    local current_id = cur
    if not current_id or not vim.api.nvim_buf_is_valid(current_id) then
      current_id = buffers[1] and buffers[1].id or nil
    end
    local cursor = nil
    if current_id then
      local obj = buffer_ref.object(current_id)
      cursor = obj and obj.cursor or nil
    end
    local payload = {
      cwd = (ctx and ctx.sandbox_cwd) or vim.fn.getcwd(),
      current_id = current_id,
      cursor = cursor,
      buffers = buffers,
    }
    local code = has_lua and args.lua or args.ex
    local kind = has_lua and "lua" or "ex"
    _run_mirror(payload, code, kind, ctx, function(ok, data)
      if not ok then
        local msg = type(data) == "table" and data.error or data
        on_error("nvim 镜像执行失败：" .. tostring(msg))
        return
      end
      local parts = {}
      if type(data.result) == "string" and data.result ~= "" then
        parts[#parts + 1] = "返回值：\n" .. data.result
      end
      if type(data.output) == "string" and data.output ~= "" then
        parts[#parts + 1] = "输出：\n" .. data.output
      end
      if type(data.messages) == "string" and data.messages ~= "" then
        parts[#parts + 1] = "messages：\n" .. data.messages
      end
      if type(data.stdout) == "string" and data.stdout ~= "" then
        parts[#parts + 1] = "stdout：\n" .. data.stdout
      end
      if type(data.stderr) == "string" and data.stderr ~= "" then
        parts[#parts + 1] = "stderr：\n" .. data.stderr
      end
      if type(data.error) == "string" and data.error ~= "" then
        parts[#parts + 1] = "错误：\n" .. data.error
      end
      if #notes > 0 then parts[#parts + 1] = "镜像说明：\n- " .. table.concat(notes, "\n- ") end
      if #parts == 0 then parts[1] = "（无输出）" end
      on_success(_sanitize(table.concat(parts, "\n\n")))
    end)
  end,
  { category = "editor", approval = { auto_allow = false } }
)

--- @return table
function M.get_tools()
  local out = {}
  for _, tool in pairs(nvim_tools) do out[#out + 1] = tool end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- 测试/诊断：直接运行镜像（不经工具包装/审批）。
--- @param opts table { lua?, ex?, buffer_ids?, cwd?, ctx? }
--- @param cb function(ok:boolean, data:table|string)
function M._run(opts, cb)
  opts = opts or {}
  local ids = opts.buffer_ids or {}
  local buffers = _collect_buffers(ids, {
    max_buffer_bytes = tonumber(_cfg().max_buffer_bytes) or (1024 * 1024),
    max_total_bytes = tonumber(_cfg().max_total_bytes) or (8 * 1024 * 1024),
  })
  local cur = vim.api.nvim_get_current_buf()
  if not buffer_ref.is_normal(cur) then cur = buffers[1] and buffers[1].id or nil end
  local obj = cur and buffer_ref.object(cur) or nil
  _run_mirror({
    cwd = opts.cwd or vim.fn.getcwd(),
    current_id = cur,
    cursor = obj and obj.cursor or nil,
    buffers = buffers,
  }, opts.lua or opts.ex or "", opts.lua and "lua" or "ex", opts.ctx, cb)
end

--- 重置（测试用）
function M.reset()
  seq = 0
end

return M
