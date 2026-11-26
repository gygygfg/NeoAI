--- 容器重建规格测试
local tests = require("NeoAI.tests")

local function insp(over)
  local base = {
    Id = "abc",
    Name = "/svc",
    Image = "sha256:img",
    State = { Running = true },
    Config = { Image = "alpine", Cmd = { "sleep", "10" }, Env = { "A=1" } },
    HostConfig = {
      CapDrop = { "ALL" }, Memory = 1024 * 1024, PidsLimit = 128,
      NetworkMode = "bridge", Binds = { "/work/proj:/data:ro" },
    },
    Mounts = {},
  }
  return vim.tbl_deep_extend("force", base, over or {})
end

tests.suite("sandbox_docker_specs", function(_, it)
  local specs = require("NeoAI.sandbox.docker.specs")
  local fs = require("NeoAI.utils.fs")
  local root = vim.fn.tempname()

  it("安全 + 运行中 -> auto；停止的容器 -> auto(create-only) 且打印提示", function(t)
    specs.reset()
    vim.fn.delete(root, "rf")
    specs.init(root)
    local a = specs.capture(insp(), { workspace_roots = { "/work/proj" }, name = "svc" })
    t.not_nil(a)
    t.eq("auto", a.mode)
    t.true_(specs.is_auto(a.spec_id))
    local b = specs.capture(insp({ State = { Running = false } }), { workspace_roots = { "/work/proj" }, name = "svc2" })
    t.eq("auto", b.mode, "关闭的容器也属于自动重建规格")
    t.eq(false, b.auto_start, "关闭容器只 create 不 start")
    t.matches("^docker run", specs.rebuild_command(a))
    t.matches("安全等级: safe", specs.safety_text(a))
  end)

  it("非 workspace 挂载 / 无限制 / secret env -> manual", function(t)
    specs.reset(); vim.fn.delete(root, "rf"); specs.init(root)
    local a = specs.capture(insp({ HostConfig = {
      CapDrop = { "ALL" }, Memory = 1024, PidsLimit = 10, NetworkMode = "bridge", Binds = { "/etc:/host" },
    } }), { workspace_roots = { "/work" } })
    t.eq("manual", a.mode)
    local b = specs.capture(insp({ Config = { Image = "alpine", Env = { "API_TOKEN=x" } } }), { workspace_roots = { "/work/proj" } })
    t.eq("manual", b.mode)
  end)

  it("保存/读取/删除 + 失败挂起", function(t)
    specs.reset(); vim.fn.delete(root, "rf"); specs.init(root)
    local a = specs.capture(insp(), { workspace_roots = { "/work/proj" } })
    local all = specs.load_all()
    local found = false
    for _, s in ipairs(all) do if s.spec_id == a.spec_id then found = true end end
    t.true_(found)
    for _ = 1, 3 do specs.note_failure(a.spec_id) end
    t.true_(specs.is_suspended(a.spec_id))
    t.true_(specs.is_pending(a.spec_id))
    specs.remove(a.spec_id)
    t.eq(0, #specs.list_pending())
    specs.reset()
    pcall(vim.fn.delete, root, "rf")
  end)
end)
