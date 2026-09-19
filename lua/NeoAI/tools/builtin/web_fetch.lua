--- web_fetch 工具
--- @module NeoAI.tools.builtin.web_fetch
--- 把动态网页（React/Vue/SPA）渲染为 Markdown 供模型阅读。
---
--- 管线：Neovim(Lua 编排) → bash → Node(Playwright 渲染 + 注入 JS + 取 DOM)
---       → turndown(HTML→MD) → 结果信封（可选落缓存）。
---
--- 设计要点：
--- - 默认不启用（`tools.web_fetch.enabled = false`）；关闭时零副作用。
--- - 启用后在缓存目录（`stdpath('cache')/NeoAI/web_fetch`）用 bash 检查并安装
---   Node 依赖与浏览器内核；`auto_install` 时后台异步触发，首次调用前等待完成。
--- - Node/npm 缺失不自动改系统包管理器，返回可操作的错误提示。
--- - 结果按 URL+参数 缓存，带 TTL / 条数 / 总容量（默认 500MB）上限，LRU 淘汰。
---
--- 依赖清单：node、npm、`npm i playwright turndown @mozilla/readability`、
--- `npx playwright install <engine>`（内核装进缓存目录下的 browsers/）。

local async = require("NeoAI.utils.async")
local fs = require("NeoAI.utils.fs")
local json = require("NeoAI.utils.json")
local strx = require("NeoAI.utils.stringx")
local config_store = require("NeoAI.kernel.config_store")
local logger = require("NeoAI.kernel.logger")
local helpers = require("NeoAI.tools.builtin.tool_helpers")
local sandbox_exec = require("NeoAI.sandbox.exec")

local M = {}

-- ========== 私有常量 ==========

--- 支持的浏览器引擎白名单（防注入）
local ENGINES = { chromium = true, firefox = true, webkit = true }

--- 支持的输出格式
local FORMATS = { markdown = true, text = true }

--- 默认脚本名
local DEFAULT_SCRIPT = "clean"

--- 本模块文件路径（用于定位插件根目录下的内置资源）
local MODULE_FILE = (debug.getinfo(1, "S").source or ""):gsub("^@", "")

--- 需要 @mozilla/readability 的脚本名
local READABILITY_SCRIPTS = { readability = true }

--- 图片临时目录前缀（mktemp -d 模板；退出 nvim 时整体删除）
local IMAGES_TMP_PREFIX = "neoai_web_fetch."

-- ========== 私有状态 ==========

local state = {
  deps_ready = false, --- 依赖是否已就绪
  deps = nil, --- 进行中的依赖安装 Deferred
  install_started = false, --- 后台安装是否已触发
  cache_dir_override = nil, --- 测试用：覆盖缓存目录
  images_dir = nil, --- 当前会话的图片临时目录（懒创建，mktemp -d）
  images_dirs = {}, --- 已创建的所有图片临时目录（供退出时清理）
  images_cleanup_registered = false, --- 退出清理钩子是否已注册
}

-- ========== 私有函数：路径与资源 ==========

--- 配置读取（含默认值合并）
--- @return table
local function _cfg()
  return config_store.get("tools.web_fetch") or {}
end

--- 判断工具是否启用
--- @return boolean
local function _is_enabled()
  local cfg = _cfg()
  return cfg.enabled == true
end

--- 插件根目录（定位内置资源 assets/）
--- @return string
local function _plugin_root()
  local root = MODULE_FILE:match("^(.-)[/\\]lua[/\\]NeoAI[/\\]tools[/\\]builtin[/\\][^/\\]+$")
  if root and root ~= "" then
    return root
  end
  -- 回退：向上 5 层（.../lua/NeoAI/tools/builtin/web_fetch.lua → 插件根）
  local dir = MODULE_FILE
  for _ = 1, 5 do
    dir = fs.dirname(dir)
  end
  return dir
end

--- 内置资源目录（render_url.js / scripts/*.js / package.json）
--- @return string
local function _assets_dir()
  return fs.join(_plugin_root(), "assets", "web_fetch")
end

--- 安装目录（缓存目录下，含 node_modules / browsers / cache / tmp）
--- @return string
local function _install_dir()
  return fs.join(vim.fn.stdpath("cache"), "NeoAI", "web_fetch")
end

--- 缓存目录（可被测试覆盖）
--- @return string
local function _cache_dir()
  return state.cache_dir_override or fs.join(_install_dir(), "cache")
end

--- 图片临时目录：用 `mktemp -d` 懒创建（每会话一个），退出时整体删除。
--- 返回 nil 表示创建失败（Node 侧将放弃转存，图片直接丢弃）。
--- @return string|nil
local function _images_dir()
  if state.images_dir then
    return state.images_dir
  end
  -- 位于宿主与沙箱同路径可见的共享目录：node 在沙箱内转存图片后，宿主侧可读取该路径
  -- （供后续 read_image 使用），且不暴露宿主 /tmp。
  local base = sandbox_exec.ensure_shared()
  local template = fs.join(base, IMAGES_TMP_PREFIX .. "XXXXXX")
  local out = vim.fn.system({ "mktemp", "-d", template })
  if vim.v.shell_error ~= 0 then
    logger.warn("[web_fetch] mktemp -d 失败：%s", tostring(out))
    return nil
  end
  local dir = (out or ""):gsub("%s+$", "")
  if dir == "" or not fs.is_dir(dir) then
    logger.warn("[web_fetch] mktemp -d 返回无效目录：%s", tostring(out))
    return nil
  end
  state.images_dir = dir
  state.images_dirs[#state.images_dirs + 1] = dir
  logger.info("[web_fetch] 图片临时目录：%s", dir)
  return dir
end

--- 删除本会话创建的所有图片临时目录（退出钩子 / 测试用）
--- @return number 删除的目录数
local function _cleanup_images()
  local n = 0
  for _, dir in ipairs(state.images_dirs) do
    if type(dir) == "string" and dir ~= "" and fs.is_dir(dir) then
      pcall(vim.fn.delete, dir, "rf")
      n = n + 1
    end
  end
  state.images_dirs = {}
  state.images_dir = nil
  return n
end

--- 幂等注册退出清理钩子（启用后注册一次）
--- @return boolean 本次是否新注册
local function _ensure_cleanup_registered()
  if state.images_cleanup_registered then
    return false
  end
  state.images_cleanup_registered = true
  require("NeoAI.kernel.lifecycle").on_shutdown(function()
    pcall(_cleanup_images)
  end)
  return true
end

--- 用户自定义脚本目录（可扩展/覆盖内置脚本）
--- @return string
local function _user_scripts_dir()
  local cfg = _cfg()
  if cfg.scripts_dir and cfg.scripts_dir ~= "" then
    return fs.expand(cfg.scripts_dir)
  end
  return fs.join(vim.fn.stdpath("config"), "NeoAI", "web_fetch", "scripts")
end

--- 清洗脚本名（防路径穿越）
--- @param name string
--- @return string|nil
local function _sanitize_script_name(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  name = name:gsub("%.js$", "")
  if name:find("%.%.", 1, true) then
    return nil
  end
  if not name:match("^[%w_%-%.]+$") then
    return nil
  end
  return name
end

--- 列出可用脚本名（用户目录优先，其次内置）
--- @return table 数组
local function _list_scripts()
  local seen = {}
  local out = {}
  local function _scan(dir)
    if not fs.is_dir(dir) then
      return
    end
    for _, name in ipairs(fs.list_dir(dir)) do
      local base = name:match("^([%w_%-%.]+)%.js$")
      if base and not seen[base] then
        seen[base] = true
        out[#out + 1] = base
      end
    end
  end
  _scan(_user_scripts_dir())
  _scan(fs.join(_assets_dir(), "scripts"))
  table.sort(out)
  return out
end

--- 解析脚本文件路径：用户目录同名覆盖内置
--- @param name string
--- @return string|nil 存在的文件路径
local function _resolve_script_file(name)
  local n = _sanitize_script_name(name)
  if not n then
    return nil
  end
  local user = fs.join(_user_scripts_dir(), n .. ".js")
  if fs.exists(user) then
    return user
  end
  local builtin = fs.join(_assets_dir(), "scripts", n .. ".js")
  if fs.exists(builtin) then
    return builtin
  end
  return nil
end

-- ========== 私有函数：进程执行 ==========

--- 执行 bash 脚本（统一经沙箱：overlay 暂存安装/缓存目录 → 冻结候选；支持超时与取消）。
--- 始终 resolve 结果表；仅进程无法启动/被拒时 reject。
--- @param script string bash 脚本内容
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred resolve({ code, stdout, stderr, timed_out?, aborted?, message? })
local function _run_bash(script, opts)
  opts = opts or {}
  -- 工具自身安装/缓存目录与共享临时目录作为可写根：写入经 overlay 暂存并冻结为候选，
  -- 不直接落盘；node/npm 仍能在会话 overlay 内看到自己写入的内容。
  return sandbox_exec.run({ "bash", "-c", script }, {
    name = "web_fetch",
    writable_roots = { _install_dir(), sandbox_exec.shared_root() },
    network = true,
    timeout_ms = opts.timeout_ms or 30000,
    signal = opts.signal,
    command = script,
  })
end

--- bash 单引号安全包裹
--- @param s string
--- @return string
local function _sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- ========== 私有函数：依赖安装 ==========

--- 把内置资源（render_url.js / package.json）拷贝到安装目录
--- @param dir string
--- @return boolean, string|nil
local function _sync_assets(dir)
  local assets = _assets_dir()
  local ok, err = fs.ensure_dir(dir)
  if not ok then
    return false, err
  end

  local files = { "render_url.js", "package.json" }
  for _, name in ipairs(files) do
    local src = fs.join(assets, name)
    local content = fs.read_file(src)
    if content then
      fs.write_file(fs.join(dir, name), content)
    end
  end
  return true
end

--- 构造网络相关环境变量导出/清除行（安装与渲染共用）。
--- 每行形如 `export K=V` 或 `unset K`，供拼接进 bash 脚本。
--- 默认配置（各键为空 / ignore_system_proxy=false）时返回空数组，行为与旧版一致。
--- @param cfg table
--- @return string[] 行数组
local function _build_env_exports(cfg)
  cfg = cfg or {}
  local q = _sh_quote
  local lines = {}

  local dl_host = cfg.playwright_download_host
  if type(dl_host) == "string" and dl_host ~= "" then
    lines[#lines + 1] = "export PLAYWRIGHT_DOWNLOAD_HOST=" .. q(dl_host)
  end

  if cfg.ignore_system_proxy == true then
    lines[#lines + 1] = "unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy"
  else
    local hp = cfg.http_proxy
    if type(hp) == "string" and hp ~= "" then
      lines[#lines + 1] = "export http_proxy=" .. q(hp) .. " HTTP_PROXY=" .. q(hp)
    end
    local sp = cfg.https_proxy
    if type(sp) == "string" and sp ~= "" then
      lines[#lines + 1] = "export https_proxy=" .. q(sp) .. " HTTPS_PROXY=" .. q(sp)
    end
  end

  return lines
end

--- 构造依赖安装脚本
--- @param dir string
--- @param engine string
--- @param cfg table
--- @return string
local function _build_install_script(dir, engine, cfg)
  local q = _sh_quote
  local node_bin = (cfg.node_path and cfg.node_path ~= "") and cfg.node_path or "node"
  local npm_install = "npm install --no-audit --no-fund --loglevel=error"
  if type(cfg.npm_registry) == "string" and cfg.npm_registry ~= "" then
    npm_install = npm_install .. " --registry=" .. q(cfg.npm_registry)
  end
  local lines = {
    "set -e",
    "cd " .. q(dir),
    "command -v " .. q(node_bin) .. " >/dev/null 2>&1 || { echo NODE_MISSING; exit 42; }",
    "command -v npm >/dev/null 2>&1 || { echo NPM_MISSING; exit 43; }",
    "export PLAYWRIGHT_BROWSERS_PATH=" .. q(fs.join(dir, "browsers")),
  }
  for _, ln in ipairs(_build_env_exports(cfg)) do
    lines[#lines + 1] = ln
  end
  local rest = {
    "if [ ! -d node_modules/playwright ] || [ ! -d node_modules/turndown ] || [ ! -d node_modules/@mozilla/readability ]; then",
    "  " .. npm_install,
    "fi",
    "if [ ! -f " .. q(".browsers_ok_" .. engine) .. " ]; then",
    "  npx playwright install "
      .. engine
      .. (cfg.install_os_deps and " --with-deps" or "")
      .. " || { echo BROWSER_INSTALL_FAILED; exit 44; }",
    "  : > " .. q(".browsers_ok_" .. engine),
    "fi",
    "echo WEB_FETCH_DEPS_OK",
  }
  for _, ln in ipairs(rest) do
    lines[#lines + 1] = ln
  end
  return table.concat(lines, "\n")
end

--- 确保依赖就绪（memoized；失败后允许重试）。
--- @param opts table|nil { force?: boolean, signal?: object }
--- @return Deferred resolve({ dir = string }), reject({ kind, message })
local function _ensure_deps(opts)
  opts = opts or {}
  local cfg = _cfg()
  local dir = _install_dir()

  if opts.force then
    state.deps_ready = false
    state.deps = nil
  end

  if state.deps_ready and not state.deps then
    return async.resolve({ dir = dir })
  end
  if state.deps then
    -- 已有进行中的安装
    return state.deps
  end

  local d = async.Deferred.new()
  state.deps = d

  local ok, err = _sync_assets(dir)
  if not ok then
    state.deps = nil
    return async.reject({ kind = "web_fetch", message = "写入安装目录失败: " .. tostring(err) })
  end

  local engine = ENGINES[cfg.engine] and cfg.engine or "chromium"
  local script = _build_install_script(dir, engine, cfg)
  local install_timeout = tonumber(cfg.install_timeout_ms) or 600000

  logger.info("[web_fetch] 检查/安装依赖于 %s（engine=%s）", dir, engine)
  -- vim.notify("[NeoAI] web_fetch 正在检查/安装依赖（首次较慢）…", vim.log.levels.INFO)

  _run_bash(script, { timeout_ms = install_timeout, signal = opts.signal })
    :then_(function(result)
      local out = result.stdout or ""
      if result.aborted then
        return async.reject({ kind = "web_fetch", message = "依赖安装已取消" })
      end
      if result.timed_out then
        return async.reject({ kind = "web_fetch", message = "依赖安装超时" })
      end
      if result.code == 42 or out:find("NODE_MISSING", 1, true) then
        return async.reject({
          kind = "web_fetch",
          message = "未找到 node，请先安装 Node.js（>=18）并确保在 PATH 中，或用 tools.web_fetch.node_path 指定",
        })
      end
      if result.code == 43 or out:find("NPM_MISSING", 1, true) then
        return async.reject({ kind = "web_fetch", message = "未找到 npm，请随 Node.js 一并安装" })
      end
      if result.code ~= 0 then
        local tail = (result.stderr or "")
        if tail == "" then
          tail = out
        end
        tail = tail:sub(-800)
        return async.reject({
          kind = "web_fetch",
          message = "依赖安装失败（退出码 " .. tostring(result.code) .. "）:\n" .. tail,
        })
      end
      return async.resolve({ dir = dir })
    end)
    :then_(function(v)
      state.deps_ready = true
      state.deps = nil
      logger.info("[web_fetch] 依赖就绪")
      -- vim.notify("[NeoAI] web_fetch 依赖已就绪", vim.log.levels.INFO)
      d:resolve(v)
    end, function(e)
      state.deps = nil -- 允许下次重试
      logger.warn("[web_fetch] 依赖准备失败: %s", type(e) == "table" and (e.message or "") or tostring(e))
      d:reject(e)
    end)

  return d
end

-- ========== 私有函数：渲染 ==========

--- 组装传给 Node 的选项
--- @param url string
--- @param params table 用户参数
--- @param cfg table
--- @return table|nil options, string|nil err
local function _build_options(url, params, cfg)
  local format = params.format or cfg.format or "markdown"
  format = tostring(format):lower()
  if not FORMATS[format] then
    return nil, "不支持的 format：" .. tostring(format) .. "（可选 markdown/text）"
  end

  local engine = params.engine or cfg.engine or "chromium"
  engine = tostring(engine):lower()
  if not ENGINES[engine] then
    return nil, "不支持的 engine：" .. tostring(engine) .. "（可选 chromium/firefox/webkit）"
  end

  local script_name = params.script or DEFAULT_SCRIPT
  local script_file = _resolve_script_file(script_name)
  if not script_file then
    local avail = table.concat(_list_scripts(), ", ")
    return nil, "未知注入脚本：" .. tostring(script_name) .. "（可用：" .. avail .. "）"
  end

  local nav_timeout = tonumber(params.nav_timeout_ms) or tonumber(cfg.nav_timeout_ms) or 30000
  local wait_ms = tonumber(params.wait_ms) or 0

  return {
    url = url,
    engine = engine,
    format = format,
    nav_timeout_ms = nav_timeout,
    wait_selector = params.wait_selector,
    wait_ms = wait_ms,
    script_file = script_file,
    script_args = { selector = params.selector, url = url },
    need_readability = READABILITY_SCRIPTS[_sanitize_script_name(script_name) or ""] == true,
    headless = true,
    user_agent = cfg.user_agent,
    -- 图片：转存到临时目录（mktemp -d），正文仅保留 [image: 路径] 占位
    images_dir = _images_dir(),
    max_images = tonumber(cfg.max_images) or 50,
    max_image_bytes = tonumber(cfg.max_image_bytes) or (5 * 1024 * 1024),
    image_timeout_ms = tonumber(cfg.image_timeout_ms) or 15000,
  }
end

--- 解析 Node 的 JSON 输出
--- @param stdout string
--- @return table { ok:boolean, content?:string, title?:string, error?:string }
local function _parse_node_output(stdout)
  if type(stdout) ~= "string" or stdout:gsub("%s", "") == "" then
    return { ok = false, error = "Node 无输出" }
  end
  local trimmed = stdout:gsub("^%s+", ""):gsub("%s+$", "")
  local ok, decoded = pcall(json.decode, trimmed)
  if not ok or type(decoded) ~= "table" then
    -- 按字节截断可能切断 UTF-8 多字节字符，产生乱码；改用 UTF-8 安全截断。
    local snippet = strx.safe_truncate(trimmed, 500, "")
    return { ok = false, error = "解析 Node 输出失败：" .. snippet }
  end
  return decoded
end

--- 执行 Node 渲染
--- @param url string
--- @param params table
--- @param cfg table
--- @param ctx table|nil
--- @return Deferred resolve({ title, content, engine, format, script }), reject({kind,message})
local function _render(url, params, cfg, ctx)
  local opts, err = _build_options(url, params, cfg)
  if not opts then
    return async.reject({ kind = "web_fetch", message = err })
  end

  local dir = _install_dir()
  local tmp_dir = fs.join(dir, "tmp")
  fs.ensure_dir(tmp_dir)
  local opts_file = fs.join(tmp_dir, string.format("opts_%d_%d.json", vim.fn.getpid(), math.random(1e8)))

  local wok, werr = fs.write_file(opts_file, json.encode(opts))
  if not wok then
    return async.reject({ kind = "web_fetch", message = "写入选项文件失败: " .. tostring(werr) })
  end

  local node_bin = (cfg.node_path and cfg.node_path ~= "") and cfg.node_path or "node"
  local q = _sh_quote
  local script_lines = {
    "cd " .. q(dir),
    "export PLAYWRIGHT_BROWSERS_PATH=" .. q(fs.join(dir, "browsers")),
  }
  for _, ln in ipairs(_build_env_exports(cfg)) do
    script_lines[#script_lines + 1] = ln
  end
  script_lines[#script_lines + 1] = "exec "
    .. q(node_bin)
    .. " "
    .. q(fs.join(dir, "render_url.js"))
    .. " "
    .. q(opts_file)
  local script = table.concat(script_lines, "\n")

  local nav_timeout = tonumber(opts.nav_timeout_ms) or 30000
  local total_timeout = tonumber(cfg.timeout_ms) or 45000
  if total_timeout <= 0 then
    total_timeout = nav_timeout + 15000
  end

  local signal = ctx and ctx.signal
  local d = async.Deferred.new()

  _run_bash(script, { timeout_ms = total_timeout, signal = signal })
    :then_(function(result)
      pcall(vim.fn.delete, opts_file)

      if result.aborted then
        return async.reject({ kind = "web_fetch", message = "抓取已取消" })
      end
      if result.timed_out then
        return async.reject({ kind = "web_fetch", message = "抓取超时（" .. tostring(total_timeout) .. "ms）" })
      end

      local parsed = _parse_node_output(result.stdout)
      if not parsed.ok then
        local detail = parsed.error or "未知错误"
        local tail = (result.stderr or ""):sub(-800)
        if tail ~= "" then
          detail = detail .. "\n" .. tail
        end
        return async.reject({ kind = "web_fetch", message = detail })
      end
      return async.resolve({
        title = parsed.title or "",
        content = parsed.content or "",
        engine = parsed.engine or opts.engine,
        format = parsed.format or opts.format,
        readability = parsed.readability,
        images = parsed.images or {},
        script = _sanitize_script_name(params.script or DEFAULT_SCRIPT) or DEFAULT_SCRIPT,
      })
    end)
    :then_(function(v)
      d:resolve(v)
    end, function(e)
      d:reject(e)
    end)

  return d
end

-- ========== 私有函数：缓存 ==========

--- 计算缓存 key
--- @param url string
--- @param params table
--- @return string
local function _cache_key(url, params)
  local parts = {
    url,
    params.selector or "",
    params.wait_selector or "",
    tostring(params.wait_ms or ""),
    params.format or "",
    params.engine or "",
    params.script or DEFAULT_SCRIPT,
  }
  return vim.fn.sha256(table.concat(parts, "\1"))
end

--- 遍历缓存条目（返回 path/ts/size）
--- @return table 数组
local function _iter_cache_entries()
  local dir = _cache_dir()
  local out = {}
  if not fs.is_dir(dir) then
    return out
  end
  for _, name in ipairs(fs.list_dir(dir)) do
    local key = name:match("^([%w]+)%.json$")
    if key then
      local path = fs.join(dir, name)
      local size = tonumber(vim.fn.getfsize(path)) or 0
      local content = fs.read_file(path)
      local ts = 0 --- @type number
      if content then
        local ok, obj = pcall(json.decode, content)
        if ok and type(obj) == "table" then
          local t = tonumber(obj.ts)
          if t then
            ts = t
          end
        end
      end
      out[#out + 1] = { path = path, key = key, ts = ts, size = (size > 0) and size or 0 }
    end
  end
  return out
end

--- 缓存目录当前总字节数（实际 *.json 文件大小的和）
--- @return number
local function _cache_size_bytes()
  local total = 0
  for _, e in ipairs(_iter_cache_entries()) do
    total = total + e.size
  end
  return total
end

--- 读取缓存条目（命中且未过期才返回）
--- @param key string
--- @param cfg table
--- @return table|nil entry
local function _cache_read(key, cfg)
  local cache_cfg = cfg.cache or {}
  if cache_cfg.enabled == false then
    return nil
  end
  local path = fs.join(_cache_dir(), key .. ".json")
  local content = fs.read_file(path)
  if not content then
    return nil
  end
  local ok, entry = pcall(json.decode, content)
  if not ok or type(entry) ~= "table" then
    return nil
  end
  local ttl = tonumber(cache_cfg.ttl_sec) or 3600
  if ttl > 0 and entry.ts and (os.time() - entry.ts) > ttl then
    pcall(vim.fn.delete, path)
    return nil
  end
  return entry
end

--- 淘汰缓存，使写入 incoming 字节后满足条数/容量上限。
--- @param incoming number 待写入字节数
--- @param cfg table
--- @return table { size = number, count = number }
local function _prune_cache(incoming, cfg)
  local cache_cfg = cfg.cache or {}
  local max_bytes = tonumber(cache_cfg.max_bytes) or (500 * 1024 * 1024)
  local max_entries = tonumber(cache_cfg.max_entries) or 200
  local ttl = tonumber(cache_cfg.ttl_sec) or 3600
  local now = os.time()

  local entries = _iter_cache_entries()

  -- 1) 过期清理
  if ttl > 0 then
    for _, e in ipairs(entries) do
      if e.ts > 0 and (now - e.ts) > ttl then
        pcall(vim.fn.delete, e.path)
        e.deleted = true
      end
    end
  end

  -- 2) 超限清理（按 ts 最旧优先）
  local live = {}
  for _, e in ipairs(entries) do
    if not e.deleted then
      live[#live + 1] = e
    end
  end
  table.sort(live, function(a, b)
    return a.ts < b.ts
  end)

  local total = 0
  for _, e in ipairs(live) do
    total = total + e.size
  end

  local idx = 1
  local live_left = #live
  while (live_left >= max_entries or (total + (incoming or 0)) > max_bytes) and idx <= #live do
    local e = live[idx]
    pcall(vim.fn.delete, e.path)
    total = total - e.size
    idx = idx + 1
    live_left = #live - (idx - 1)
  end

  local kept = {}
  for i = idx, #live do
    kept[#kept + 1] = live[i]
  end
  return { size = total, count = #kept }
end

--- 写入缓存条目（含单条守卫 + 淘汰 + 原子替换）
--- @param key string
--- @param entry table { url, title, format, content, ts }
--- @param cfg table
--- @return boolean written
local function _cache_write(key, entry, cfg)
  local cache_cfg = cfg.cache or {}
  if cache_cfg.enabled == false then
    return false
  end

  local dir = _cache_dir()
  fs.ensure_dir(dir)

  local encoded = json.encode(entry)
  local max_bytes = tonumber(cache_cfg.max_bytes) or (500 * 1024 * 1024)
  -- 单条守卫：单条即超总容量时不写
  if #encoded >= max_bytes then
    logger.warn("[web_fetch] 单条缓存 %d 字节 >= 上限 %d，跳过写入", #encoded, max_bytes)
    return false
  end

  _prune_cache(#encoded, cfg)

  local path = fs.join(dir, key .. ".json")
  local tmp = path .. ".tmp"
  local ok = fs.write_file(tmp, encoded)
  if not ok then
    return false
  end
  pcall(vim.fn.rename, tmp, path)

  local stats = { size = _cache_size_bytes(), count = #_iter_cache_entries() }
  logger.info("[web_fetch] 缓存写入 %s（当前 %d 条 / %d 字节）", key:sub(1, 12), stats.count, stats.size)
  return true
end

-- ========== 私有函数：信封 ==========

--- 内容截断（超上限时保留头部并附提示）
--- @param content string
--- @param max_bytes number
--- @return string, boolean truncated
local function _truncate(content, max_bytes)
  if not max_bytes or max_bytes <= 0 or #content <= max_bytes then
    return content, false
  end
  return content:sub(1, max_bytes) .. "\n\n…（内容超 " .. tostring(max_bytes) .. " 字节已截断）", true
end

--- 构造返回给模型的文本信封
--- @param source string
--- @param meta table { title, engine, format, cached, script, truncated }
--- @param content string
--- @return string
local function _format_envelope(source, meta, content)
  local lines = {
    "source: " .. source,
    "title: " .. (meta.title or ""),
    string.format(
      "engine: %s | format: %s | bytes: %d | cached: %s | script: %s",
      meta.engine or "chromium",
      meta.format or "markdown",
      #content,
      meta.cached and "yes" or "no",
      meta.script or DEFAULT_SCRIPT
    ),
  }
  if meta.truncated then
    lines[#lines + 1] = "note: 内容已按 max_bytes 截断"
  end
  lines[#lines + 1] = "---"
  lines[#lines + 1] = content
  return table.concat(lines, "\n")
end

-- ========== 工具定义 ==========

--- @param url any
--- @return boolean
local function _http_url(url)
  return type(url) == "string" and url:match("^https?://") ~= nil
end

local web_fetch = helpers.define_tool(
  "web_fetch",
  "抓取网页并渲染为可读内容（Markdown/纯文本），只输出正文、不含原始 HTML 标签与样式。对动态网页（React/Vue/SPA）会在无头浏览器中执行 JavaScript 后再取最终 DOM，再用通用转换器转成 Markdown。默认不启用，需在配置中开启 `tools.web_fetch.enabled`；首次启用会在缓存目录自动安装依赖（Node + Playwright + turndown）。参数：url 必填；selector/wait_selector/wait_ms 用于定位与等待；script 选择注入脚本（clean/readability）；format 选择输出格式（markdown/text）；force_refresh 跳过本地缓存。正文中的图片不会写入正文，而是转存到临时目录并在原位保留 `[image: 路径]` 占位符（可用 read_image 查看），退出 Neovim 时自动删除。",
  {
    type = "object",
    properties = {
      url = { type = "string", description = "要抓取的网页 URL（http/https）" },
      selector = {
        type = "string",
        description = "可选 CSS 选择器：仅提取该子树（缺省自动选 article/main/body）",
      },
      wait_selector = { type = "string", description = "可选：加载后等待该选择器出现（用于 SPA）" },
      wait_ms = { type = "integer", description = "可选：加载后额外等待毫秒数" },
      script = {
        type = "string",
        description = "注入脚本名（默认 clean；内置 clean/readability，可用用户目录扩展）",
      },
      format = {
        type = "string",
        enum = { "markdown", "text" },
        description = "输出格式（markdown 或纯文本 text），默认 markdown",
      },
      force_refresh = { type = "boolean", description = "为 true 时忽略本地缓存强制抓取" },
    },
    required = { "url" },
  },
  function(args, on_success, on_error, ctx)
    local cfg = _cfg()

    if not _is_enabled() then
      on_error("web_fetch 未启用。请在配置中设置 tools.web_fetch.enabled = true")
      return
    end

    local url = args.url
    if not _http_url(url) then
      on_error("web_fetch 需要 http(s) 开头的 url")
      return
    end

    -- 参数预校验（避免无谓地触发依赖安装）
    local probe, perr = _build_options(url, args, cfg)
    if not probe then
      on_error(perr)
      return
    end

    local cache_cfg = cfg.cache or {}
    local cache_key = _cache_key(url, args)

    -- 1) 缓存命中
    if not args.force_refresh and cache_cfg.enabled ~= false then
      local hit = _cache_read(cache_key, cfg)
      if hit then
        local content, truncated = _truncate(hit.content or "", tonumber(cfg.max_bytes) or 0)
        on_success(_format_envelope(url, {
          title = hit.title,
          engine = hit.engine or probe.engine,
          format = hit.format or probe.format,
          script = hit.script or probe.script,
          cached = true,
          truncated = truncated,
        }, content))
        return
      end
    end

    -- 2) 确保依赖 → 渲染 → 写缓存
    local signal = ctx and ctx.signal
    _ensure_deps({ signal = signal })
      :then_(function()
        return _render(url, args, cfg, ctx)
      end)
      :then_(function(res)
        local content, truncated = _truncate(res.content or "", tonumber(cfg.max_bytes) or 0)
        _cache_write(cache_key, {
          url = url,
          title = res.title,
          engine = res.engine,
          format = res.format,
          script = res.script,
          content = res.content or "",
          ts = os.time(),
        }, cfg)
        on_success(_format_envelope(url, {
          title = res.title,
          engine = res.engine,
          format = res.format,
          script = res.script,
          cached = false,
          truncated = truncated,
        }, content))
      end, function(e)
        on_error(type(e) == "table" and (e.message or json.encode(e)) or tostring(e))
      end)
  end,
  { category = "web", approval = { auto_allow = true }, timeout = -1 }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  if not _is_enabled() then
    return {}
  end

  local cfg = _cfg()
  -- 退出 nvim 时删除图片临时目录（幂等，仅注册一次）
  _ensure_cleanup_registered()
  -- 启用后：后台异步检查/安装依赖（不阻塞启动/首个请求）
  if cfg.auto_install ~= false and not state.install_started then
    state.install_started = true
    vim.schedule(function()
      _ensure_deps({}):catch(function(e)
        local msg = type(e) == "table" and (e.message or "") or tostring(e)
        logger.warn("[web_fetch] 后台依赖安装失败：%s", msg)
      end)
    end)
  end

  return { web_fetch }
end

--- 重置内部状态（测试用）
function M.reset()
  state.deps_ready = false
  state.deps = nil
  state.install_started = false
  state.cache_dir_override = nil
  state.images_dir = nil
  state.images_dirs = {}
  state.images_cleanup_registered = false
end

-- ========== 测试可见的内部 API ==========
M._cfg = _cfg
M._is_enabled = _is_enabled
M._install_dir = _install_dir
M._assets_dir = _assets_dir
M._cache_dir = _cache_dir
M._images_dir = _images_dir
M._cleanup_images = _cleanup_images
M._ensure_cleanup_registered = _ensure_cleanup_registered
M._set_cache_dir = function(path)
  state.cache_dir_override = path
end
M._list_scripts = _list_scripts
M._resolve_script_file = _resolve_script_file
M._sanitize_script_name = _sanitize_script_name
M._build_options = _build_options
M._build_install_script = _build_install_script
M._build_env_exports = _build_env_exports
M._parse_node_output = _parse_node_output
M._format_envelope = _format_envelope
M._cache_key = _cache_key
M._cache_read = _cache_read
M._cache_write = _cache_write
M._cache_size_bytes = _cache_size_bytes
M._prune_cache = _prune_cache
M._iter_cache_entries = _iter_cache_entries
M._truncate = _truncate

return M
