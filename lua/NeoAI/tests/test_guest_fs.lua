--- 沙箱访客文件系统映射（sandbox.guest_fs）专项测试
--- @module NeoAI.tests.test_guest_fs
--- 覆盖：set_root/tmp_host 往返；to_host 无映射回退；最长前缀匹配；clear。
local tests = require("NeoAI.tests")

tests.suite("guest_fs", function(_, it, before_each)
  local guest_fs

  before_each(function()
    guest_fs = require("NeoAI.sandbox.guest_fs")
    guest_fs.clear()
  end)

  it("set_root / tmp_host 往返", function(t)
    guest_fs.set_root("/tmp", "/host/base/tmp")
    t.eq("/host/base/tmp", guest_fs.tmp_host("/tmp"))
    -- 路径末尾斜杠归一化
    guest_fs.set_root("/var/tmp/", "/host/base/vartmp")
    t.eq("/host/base/vartmp", guest_fs.tmp_host("/var/tmp"))
  end)

  it("to_host：无映射时原样返回", function(t)
    t.eq("/tmp/x", guest_fs.to_host("/tmp/x"))
  end)

  it("to_host：按最长前缀匹配", function(t)
    guest_fs.set_root("/tmp", "/h/tmp")
    guest_fs.set_root("/tmp/sub", "/h/sub")
    t.eq("/h/sub/a", guest_fs.to_host("/tmp/sub/a"))
    t.eq("/h/tmp/b", guest_fs.to_host("/tmp/b"))
  end)

  it("to_host：非访客路径不受影响", function(t)
    guest_fs.set_root("/tmp", "/h/tmp")
    t.eq("/etc/hosts", guest_fs.to_host("/etc/hosts"))
    t.eq("/tmpfoo/x", guest_fs.to_host("/tmpfoo/x"), "前缀相近但不同段不应命中")
  end)

  it("clear 清空全部映射", function(t)
    guest_fs.set_root("/tmp", "/h/tmp")
    guest_fs.clear()
    t.nil_(guest_fs.tmp_host("/tmp"))
    t.eq("/tmp/x", guest_fs.to_host("/tmp/x"))
  end)

  it("set_root 忽略空值", function(t)
    guest_fs.set_root("", "/h/tmp")
    guest_fs.set_root("/tmp", "")
    t.nil_(guest_fs.tmp_host("/tmp"))
    t.nil_(guest_fs.tmp_host(""))
  end)
end)
