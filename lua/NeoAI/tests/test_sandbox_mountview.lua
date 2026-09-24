--- 跨挂载点工作区检测 + 兼容模式 overlay 规格测试
--- @module NeoAI.tests.test_sandbox_mountview
--- 覆盖：mount_root_of 取最深祖先挂载点；cross_mount_root 仅在独立挂载时返回；
--- build_overlay_specs 的 no_root_overlay（跨挂载点兼容模式）跳过整机根 overlay 探测。

local tests = require("NeoAI.tests")

tests.suite("sandbox_mountview", function(_, it)
  it("mount_root_of 取最深祖先挂载点，cross_mount_root 仅独立挂载时返回", function(t)
    local rt = require("NeoAI.sandbox.runtime")
    rt.set_mountinfo_for_test({ "/", "/mnt", "/mnt/uuid-1", "/tmp" })
    t.eq("/mnt/uuid-1", rt.mount_root_of("/mnt/uuid-1/Agent沙箱论文/src"))
    t.eq("/mnt", rt.mount_root_of("/mnt/other/x"))
    t.eq("/tmp", rt.mount_root_of("/tmp/foo"))
    t.eq("/", rt.mount_root_of("/root/NeoAI"))
    t.eq("/mnt/uuid-1", rt.cross_mount_root("/mnt/uuid-1/proj"))
    t.nil_(rt.cross_mount_root("/root/NeoAI"), "根挂载上不应报告跨挂载点")
    t.nil_(rt.cross_mount_root("/tmp/foo"), "沙箱已特殊处理的 tmpfs 根不应报告跨挂载点")
    rt.set_mountinfo_for_test(nil)
  end)

  it("no_root_overlay 兼容模式跳过整机根 overlay，改为覆盖工作区", function(t)
    local rt = require("NeoAI.sandbox.runtime")
    local wrapper = require("NeoAI.sandbox.wrapper")
    local orig_read_all = rt.read_all
    local orig_ow = rt.overlay_writable
    rt.read_all = function() return true end
    local probed_root = false
    rt.overlay_writable = function(lower)
      if lower == "/" then probed_root = true end
      return true
    end
    local cwd = vim.fn.getcwd()
    local base = vim.fn.tempname()
    local specs = wrapper.build_overlay_specs(cwd, base, {}, { no_root_overlay = true })
    local roots = {}
    for _, s in ipairs(specs) do roots[#roots + 1] = s.root end
    t.false_(probed_root, "no_root_overlay 不应探测整机根 overlay")
    t.false_(vim.tbl_contains(roots, "/"), "不应包含整机根 overlay")
    t.true_(vim.tbl_contains(roots, cwd), "应覆盖工作区 cwd")

    -- 对照：默认模式仍会尝试整机根 overlay
    probed_root = false
    local specs2 = wrapper.build_overlay_specs(cwd, base, {}, {})
    local root_only = (#specs2 == 1 and specs2[1].root == "/")
    t.true_(probed_root or root_only, "默认模式应尝试整机根 overlay")

    rt.read_all = orig_read_all
    rt.overlay_writable = orig_ow
    rt.reset()
  end)

  it("内核 overlay 不可用时回退 fuse-overlayfs 根视图（可用时）", function(t)
    local rt = require("NeoAI.sandbox.runtime")
    local wrapper = require("NeoAI.sandbox.wrapper")
    local fo = require("NeoAI.sandbox.fuse_overlay")
    if not fo.available() then return end
    local orig_read_all = rt.read_all
    local orig_ow = rt.overlay_writable
    rt.read_all = function() return true end
    rt.overlay_writable = function() return false end
    local cwd = vim.fn.getcwd()
    local base = vim.fn.tempname()
    local specs = wrapper.build_overlay_specs(cwd, base, {}, {})
    rt.read_all = orig_read_all
    rt.overlay_writable = orig_ow
    local fuse_spec
    for _, s in ipairs(specs) do if s.mode == "fuse" then fuse_spec = s end end
    t.not_nil(fuse_spec, "内核 overlay 不可用时应回退到 fuse 根 overlay")
    if fuse_spec then
      t.eq("/", fuse_spec.root)
      t.not_nil(fuse_spec.fuse_mnt, "应返回 fuse 挂载点")
      t.true_(fo._is_mounted(fuse_spec.fuse_mnt), "fuse 合并视图应已挂载")
      rt.fuse_release_all()
      t.false_(fo._is_mounted(fuse_spec.fuse_mnt), "释放后不应仍挂载")
    end
    rt.reset()
  end)
end)
