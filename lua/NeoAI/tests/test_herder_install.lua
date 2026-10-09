--- Herder 侧集成配置安装器测试
--- @module NeoAI.tests.test_herder_install

local tests = require("NeoAI.tests")

local MARKER_BEGIN = "# >>> NeoAI herder integration (managed by NeoAI; do not edit) >>>"
local MARKER_END = "# <<< NeoAI herder integration <<<"
local KEY_LINE = "show_agent_labels_on_pane_borders = true"

--- 保存/恢复测试相关 env
local function save_env()
  return {
    config = vim.env.HERDR_CONFIG_PATH,
    herder_bin = vim.env.HERDER_BIN_PATH,
    herdr_bin = vim.env.HERDR_BIN_PATH,
    xdg = vim.env.XDG_CONFIG_HOME,
  }
end
local function restore_env(orig)
  vim.env.HERDR_CONFIG_PATH = orig.config
  vim.env.HERDER_BIN_PATH = orig.herder_bin
  vim.env.HERDR_BIN_PATH = orig.herdr_bin
  vim.env.XDG_CONFIG_HOME = orig.xdg
end

--- 建一个退出码固定的假 herdr 可执行文件
local function fake_herdr(code)
  local path = vim.fn.tempname() .. "-fake-herdr-" .. tostring(code)
  vim.fn.writefile({ "#!/bin/sh", "exit " .. tostring(code) }, path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path
end

--- 准备隔离环境：返回 { dir, config_path, orig }
local function setup(code)
  local orig = save_env()
  local dir = vim.fn.tempname() .. "-neoai-herder-install"
  vim.fn.mkdir(dir, "p")
  vim.env.HERDR_CONFIG_PATH = dir .. "/config.toml"
  local bin = fake_herdr(code or 0)
  vim.env.HERDER_BIN_PATH = bin
  vim.env.HERDR_BIN_PATH = bin
  return { dir = dir, config_path = dir .. "/config.toml", orig = orig }
end

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then return nil end
  local st = vim.uv.fs_fstat(fd)
  local data = st and st.size > 0 and vim.uv.fs_read(fd, st.size, 0) or ""
  vim.uv.fs_close(fd)
  return data
end

local function write_raw(path, content)
  local fd = vim.uv.fs_open(path, "w", 420)
  local off = 0
  while off < #content do
    local n = vim.uv.fs_write(fd, content:sub(off + 1), off)
    if not n or n == 0 then break end
    off = off + n
  end
  vim.uv.fs_close(fd)
end

--- 统计某子串出现次数
local function count(content, needle)
  local n = 0
  for _ in content:gmatch(needle:gsub("(%W)", "%%%1")) do n = n + 1 end
  return n
end

tests.suite("herder_install", function(_, it)
  it("无配置时 status 正确，install 写入 marker 块", function(t)
    local env = setup(0)
    local install = require("NeoAI.services.herder_install")

    local st = install.status()
    t.eq(env.config_path, st.config_path)
    t.false_(st.config_exists, "初始不应存在配置文件")
    t.false_(st.installed, "初始不应已安装")

    local res = install.install()
    t.true_(res.ok)
    t.true_(res.changed)
    t.eq(env.config_path, res.path)

    local content = read_file(env.config_path)
    t.not_nil(content)
    t.ok(content:find(MARKER_BEGIN, 1, true) ~= nil, "应包含起始 marker")
    t.ok(content:find(MARKER_END, 1, true) ~= nil, "应包含结束 marker")
    t.ok(content:find(KEY_LINE, 1, true) ~= nil, "应包含展示设置键")
    t.ok(content:find("^%[ui%]") ~= nil, "应包含 [ui] 表头")
    t.true_(install.status().installed)
    restore_env(env.orig)
  end)

  it("install 幂等：重复安装不改变文件", function(t)
    local env = setup(0)
    local install = require("NeoAI.services.herder_install")

    install.install()
    local first = read_file(env.config_path)
    local res = install.install()
    t.true_(res.ok)
    t.false_(res.changed)
    t.eq("already-installed", res.reason)
    t.eq(first, read_file(env.config_path), "重复安装不应修改文件")
    restore_env(env.orig)
  end)

  it("已有 [ui] 段：插入该段内，不重复定义 [ui]", function(t)
    local env = setup(0)
    local install = require("NeoAI.services.herder_install")
    local user = "[ui]\npane_borders = true\n\n[keys]\nprefix = \"ctrl+b\"\n"
    write_raw(env.config_path, user)

    local res = install.install()
    t.true_(res.ok)
    local content = read_file(env.config_path)
    t.eq(1, count(content, "[ui]"), "[ui] 表头应只出现一次（避免 TOML 冲突）")
    t.ok(content:find(KEY_LINE, 1, true) ~= nil, "应插入展示设置键")
    t.ok(content:find("pane_borders = true", 1, true) ~= nil, "应保留用户配置")
    -- 键应位于 [ui] 段内（在 [keys] 之前）
    local ui_pos = content:find("[ui]", 1, true)
    local key_pos = content:find(KEY_LINE, 1, true)
    local keys_pos = content:find("[keys]", 1, true)
    t.ok(ui_pos < key_pos and key_pos < keys_pos, "键应插入 [ui] 段内")
    restore_env(env.orig)
  end)

  it("无 [ui] 段：追加带 [ui] 头的块并创建备份", function(t)
    local env = setup(0)
    local install = require("NeoAI.services.herder_install")
    local user = "[keys]\nprefix = \"ctrl+b\"\n"
    write_raw(env.config_path, user)

    local res = install.install()
    t.true_(res.ok)
    t.not_nil(res.backup)
    local content = read_file(env.config_path)
    t.eq(1, count(content, "[ui]"), "应追加一个 [ui] 表头")
    t.ok(content:find(KEY_LINE, 1, true) ~= nil)
    t.ok(content:find("prefix = \"ctrl+b\"", 1, true) ~= nil, "应保留用户配置")
    t.eq(user, read_file(res.backup), "备份内容应为原始内容")
    restore_env(env.orig)
  end)

  it("键已由用户设置时跳过（不重复定义同键）", function(t)
    local env = setup(0)
    local install = require("NeoAI.services.herder_install")
    local user = "[ui]\nshow_agent_labels_on_pane_borders = false\n"
    write_raw(env.config_path, user)

    local res = install.install()
    t.true_(res.ok)
    t.false_(res.changed)
    t.eq("key-present", res.reason)
    t.eq(user, read_file(env.config_path), "不应修改用户已有键")
    restore_env(env.orig)
  end)

  it("uninstall 移除 marker 块并保留用户配置", function(t)
    local env = setup(0)
    local install = require("NeoAI.services.herder_install")
    local user = "[ui]\npane_borders = true\n"
    write_raw(env.config_path, user)
    install.install()

    local res = install.uninstall()
    t.true_(res.ok)
    t.true_(res.changed)
    local content = read_file(env.config_path)
    t.eq(nil, content:find(MARKER_BEGIN, 1, true), "marker 应被移除")
    t.eq(nil, content:find(KEY_LINE, 1, true), "展示设置键应被移除")
    t.ok(content:find("pane_borders = true", 1, true) ~= nil, "用户配置应保留")

    local res2 = install.uninstall()
    t.true_(res2.ok)
    t.false_(res2.changed)
    t.eq("not-installed", res2.reason)
    restore_env(env.orig)
  end)

  it("herdr config check 失败时回滚，不留下改动", function(t)
    local env = setup(1) -- 假 herdr 退出码 1，模拟校验失败
    local install = require("NeoAI.services.herder_install")
    local user = "[ui]\npane_borders = true\n"
    write_raw(env.config_path, user)

    local res = install.install()
    t.false_(res.ok, "校验失败时不应报成功")
    t.matches("config%-check%-failed", res.error)
    t.eq(user, read_file(env.config_path), "失败后应回滚到原内容")
    t.false_(install.status().installed)
    restore_env(env.orig)
  end)

  it("snippet 结构稳定（含 [ui] 头与 marker）", function(t)
    local install = require("NeoAI.services.herder_install")
    local snip = install.snippet()
    t.ok(snip:find("^%[ui%]") ~= nil, "应含 [ui] 头")
    t.ok(snip:find(KEY_LINE, 1, true) ~= nil, "应含展示设置键")
    t.ok(snip:find(MARKER_BEGIN, 1, true) ~= nil)
    t.ok(snip:find(MARKER_END, 1, true) ~= nil)
  end)

  it("尊重 XDG_CONFIG_HOME（herdr 按 XDG 读取配置）", function(t)
    local orig = save_env()
    vim.env.HERDR_CONFIG_PATH = nil
    local xdg = vim.fn.tempname() .. "-neoai-xdg"
    vim.env.XDG_CONFIG_HOME = xdg
    local bin = fake_herdr(0)
    vim.env.HERDER_BIN_PATH = bin
    vim.env.HERDR_BIN_PATH = bin

    local install = require("NeoAI.services.herder_install")
    t.eq(xdg .. "/herdr/config.toml", install.config_path(), "应按 XDG_CONFIG_HOME 解析")

    local res = install.install()
    t.true_(res.ok)
    local content = read_file(xdg .. "/herdr/config.toml")
    t.not_nil(content, "片段应写入 XDG 配置路径")
    t.ok(content:find(MARKER_BEGIN, 1, true) ~= nil, "应含 marker")
    restore_env(orig)
  end)

  it("HERDR_CONFIG_PATH 原样使用（不折叠成 config.toml）", function(t)
    local orig = save_env()
    local dir = vim.fn.tempname() .. "-neoai-herdr-custom"
    vim.fn.mkdir(dir, "p")
    local custom = dir .. "/my-herdr.toml"
    vim.env.HERDR_CONFIG_PATH = custom
    local bin = fake_herdr(0)
    vim.env.HERDER_BIN_PATH = bin
    vim.env.HERDR_BIN_PATH = bin

    local install = require("NeoAI.services.herder_install")
    t.eq(custom, install.config_path(), "应原样返回 HERDR_CONFIG_PATH")
    local res = install.install()
    t.true_(res.ok)
    t.not_nil(read_file(custom), "片段应写入自定义文件名")
    restore_env(orig)
  end)

  it("大配置写入不截断（原子写整段）", function(t)
    local env = setup(0)
    local big = string.rep("# padding line to force a large write path\n", 40000)
    write_raw(env.config_path, big)
    local install = require("NeoAI.services.herder_install")
    local res = install.install()
    t.true_(res.ok)
    local content = read_file(env.config_path)
    t.ok(content:find(big, 1, true) ~= nil, "原有大配置应被完整保留（不截断）")
    t.ok(content:find(MARKER_BEGIN, 1, true) ~= nil, "应含 marker")
    restore_env(env.orig)
  end)
end)
