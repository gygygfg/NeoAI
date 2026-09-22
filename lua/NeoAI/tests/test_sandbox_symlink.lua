--- 符号链接候选专项测试
--- @module NeoAI.tests.test_sandbox_symlink
--- 覆盖：`candidate.stage_link` → finish → merge → publish 的符号链接候选全链路；
--- systemd `enable` 产生的软链被捕获为候选（不落宿主机）。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  if merged.tools.sandbox.ephemeral_roots == nil then
    merged.tools.sandbox.ephemeral_roots = {}
  end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("sandbox_symlink", function(_, it)
  it("物化：指向目录的符号链接（venv lib64 -> lib）不误报类型冲突", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      sandbox.reset()
      local base = fs.canonical(vim.fn.tempname())
      local dir = base .. "/app"
      fs.ensure_dir(dir .. "/lib")
      local lib64 = dir .. "/lib64"
      vim.uv.fs_symlink("lib", lib64)
      -- 模拟会话级 overlay upper 中已存在同名链接（上一轮命令/物化遗留）：
      -- `lib64 -> lib` 且 `lib` 是真实目录——旧代码用 isdirectory 跟随链接会误报冲突。
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper .. "/lib"); fs.ensure_dir(work)
      vim.uv.fs_symlink("lib", upper .. "/lib64")
      candidate.merge_candidate({
        files = { { path = lib64, action = "create", link = "lib", before_hash = nil } },
      })
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      local conflicts = candidate.materialize_overlay(specs)
      t.eq(0, #conflicts, "指向目录的符号链接不应被误判为类型冲突")
      local lst = vim.uv.fs_lstat(upper .. "/lib64")
      t.eq("link", lst and lst.type, "物化后应仍是符号链接")
      t.eq("lib", vim.uv.fs_readlink(upper .. "/lib64"), "链接目标应保持")
    end)
  end)

  it("物化：真实目录仍拒绝文件/链接覆盖（类型冲突防御不放松）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      sandbox.reset()
      local base = fs.canonical(vim.fn.tempname())
      local dir = base .. "/app"
      local target = dir .. "/real"
      fs.ensure_dir(target)
      -- upper 中该路径是真实目录：文件暂存不得覆盖（应报冲突）。
      local upper, work = base .. "/upper", base .. "/work"
      fs.ensure_dir(upper .. "/real"); fs.ensure_dir(work)
      candidate.merge_candidate({
        files = { { path = target, action = "modify", content = "x\n", before_hash = nil, mode = 420 } },
      })
      local specs = { { root = dir, upper = upper, work = work, mode = "overlay" } }
      local conflicts = candidate.materialize_overlay(specs)
      t.eq(1, #conflicts, "真实目录应仍报类型冲突")
      t.eq("directory", (vim.uv.fs_lstat(upper .. "/real") or {}).type, "目录不得被覆盖")
    end)
  end)

  it("符号链接候选：stage_link → finish → publish 在真实盘创建软链", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = { sandbox = { enabled = true, mode = "dry_run" } } }, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local unit = dir .. "/neoai-t.service"
      fs.write_file(unit, "[Unit]\nDescription=x\n")
      local link = dir .. "/default.target.wants/neoai-t.service"
      local control = require("NeoAI.sandbox.control")
      local candidate = require("NeoAI.sandbox.candidate")
      local store = require("NeoAI.sandbox.store")
      local attempt = control.new_attempt("run_command", { command = "enable" }, {}, { effect = "process" })
      candidate.begin(attempt, store.root())
      local entry = candidate.stage_link(attempt.attempt_id, link, unit)
      t.not_nil(entry, "应登记软链条目")
      local cand = candidate.finish(attempt.attempt_id)
      t.eq(1, #(cand and cand.files or {}), "应产生一个候选")
      local f = cand.files[1]
      t.eq(link, f.path)
      t.eq("create", f.action)
      t.eq(unit, f.link, "候选应携带链接目标")
      candidate.merge_candidate(cand, {})
      t.not_nil(candidate.read_path(link), "软链应进入暂存视图")
      t.true_(vim.uv.fs_lstat(link) == nil, "发布前真实盘不应有软链")
      local pub = candidate.publish(cand, {})
      t.true_(pub.ok, "发布应成功: " .. tostring(pub.reason))
      local lst = vim.uv.fs_lstat(link)
      t.not_nil(lst, "真实盘应创建软链")
      t.eq("link", lst.type)
      t.eq(unit, vim.uv.fs_readlink(link), "软链目标应正确")
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("systemctl --user enable：软链暂存为候选且不落宿主机", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local sduser = require("NeoAI.sandbox.systemd_user")
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
          resident = { enabled = true },
          systemd = { enabled = true, user = { enabled = true } },
          review = { enabled = true },
        },
      },
    }, function()
      if not sduser.available() then return end
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local unit_name = "neoai-enable-" .. tostring(os.time()) .. ".service"
      local link = "/root/.config/systemd/user/default.target.wants/" .. unit_name
      vim.fn.delete(link)
      local cmd = table.concat({
        "mkdir -p \"$HOME/.config/systemd/user\"",
        "cat > \"$HOME/.config/systemd/user/" .. unit_name .. "\" <<'UNIT'",
        "[Unit]", "Description=NeoAI enable test", "[Service]", "Type=oneshot",
        "ExecStart=/bin/true", "[Install]", "WantedBy=default.target", "UNIT",
        "systemctl --user daemon-reload",
        "systemctl --user enable " .. unit_name,
      }, "\n")
      local done, result = false, nil
      require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {})
        :then_(function(r) result = tostring(r); done = true end, function() done = true end)
      t.true_(vim.wait(60000, function() return done end, 100), "命令应完成")
      t.matches("Created symlink", result, "enable 应创建软链（沙箱内）")
      t.true_(vim.uv.fs_lstat(link) == nil, "软链不应落宿主机")
      t.not_nil(require("NeoAI.sandbox.candidate").read_path(link), "软链应进入暂存视图")
      vim.fn.chdir(prev)
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 3000 })
    end)
  end)

  it("systemctl enable（系统级门面）：软链暂存为候选且不落宿主机", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
          resident = { enabled = true },
          systemd = { enabled = true, stage_install = true },
          review = { enabled = true },
        },
      },
    }, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local unit = "neoai-sys-enable-" .. tostring(os.time()) .. ".service"
      local unit_path = "/etc/systemd/system/" .. unit
      local link = "/etc/systemd/system/multi-user.target.wants/" .. unit
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = "printf '[Unit]\\nDescription=x\\n[Service]\\nType=oneshot\\nExecStart=/bin/true\\n[Install]\\nWantedBy=multi-user.target\\n' > "
          .. unit_path,
        description = "t",
      }, {}):then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(30000, function() return done end, 50), "创建单元应完成")
      local done2, result = false, nil
      require("NeoAI.tools").execute("run_command", { command = "systemctl enable " .. unit, description = "t" }, {})
        :then_(function(r) result = tostring(r); done2 = true end, function(e) result = "ERR:" .. tostring(e and (e.message or e)); done2 = true end)
      t.true_(vim.wait(30000, function() return done2 end, 50), "enable 应完成")
      t.matches("已暂存", result, "enable 应暂存软链变更: " .. tostring(result))
      t.true_(vim.uv.fs_lstat(link) == nil, "软链不应落宿主机")
      t.not_nil(require("NeoAI.sandbox.candidate").read_path(link), "软链应进入暂存视图")
      vim.fn.chdir(prev)
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 3000 })
    end)
  end)
end)
