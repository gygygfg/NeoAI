--- Skills 服务测试（SKILL.md frontmatter 解析 + 发现 + list/load + 系统提示段）
--- @module NeoAI.tests.test_skills

local tests = require("NeoAI.tests")
local fs = require("NeoAI.utils.fs")
local config_store = require("NeoAI.kernel.config_store")

--- 构造临时技能目录
--- @param entries table { dir, content } 数组
--- @return string root
local function _make_root(entries)
  local root = vim.fn.tempname()
  for _, e in ipairs(entries) do
    local full = root .. "/" .. e.dir
    vim.fn.mkdir(full, "p")
    fs.write_file(full .. "/SKILL.md", e.content)
  end
  return root
end

tests.suite("skills", function(_, it, before_each)
  before_each(function()
    config_store.load({ skills = { paths = {} } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
  end)

  it("解析 frontmatter：name/description/列表", function(t)
    local root = _make_root({
      { dir = "git", content = "---\nname: git-review\ndescription: 评审 Git 变更\nallowed-tools:\n  - read_file\n  - git_diff\n---\n\n这里是正文。" },
    })
    config_store.load({ skills = { paths = { root } } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
    skills.init()
    t.eq(1, skills.count())
    local s = skills.get("git-review")
    t.not_nil(s, "应按 frontmatter name 索引")
    t.eq("评审 Git 变更", s.description)
    t.matches("这里是正文", s.body)
  end)

  it("缺 frontmatter name 时回退目录名", function(t)
    local root = _make_root({
      { dir = "deploy", content = "# Deploy\n正常正文，无 frontmatter" },
    })
    config_store.load({ skills = { paths = { root } } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
    skills.init()
    t.eq(1, skills.count())
    t.not_nil(skills.get("deploy"), "应以目录名作为技能名")
    t.matches("Deploy", skills.get("deploy").body)
  end)

  it("list 与 load 往返 + summary 不含空技能", function(t)
    local root = _make_root({
      { dir = "a", content = "---\nname: skill-a\ndescription: 技能A\n---\nbody-a" },
      { dir = "b", content = "---\nname: skill-b\ndescription: 技能B\n---\nbody-b" },
    })
    config_store.load({ skills = { paths = { root } } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
    skills.init()
    local list = skills.list()
    t.eq(2, #list)
    t.eq("skill-a", list[1].name)
    t.eq("skill-b", list[2].name)
    local loaded = skills.load("skill-b")
    t.eq("body-b", loaded.content)
    local summary = skills.summary_text()
    t.true_(summary:find("skill-a: 技能A", 1, true) ~= nil, "摘要应含 skill-a")
    t.true_(summary:find("skill-b: 技能B", 1, true) ~= nil, "摘要应含 skill-b")
    t.eq(nil, skills.load("nonexistent"))
  end)

  it("同名技能保留首个（路径顺序优先）", function(t)
    local root = _make_root({
      { dir = "one/a", content = "---\nname: dup\n---\nfirst-body" },
      { dir = "two/b", content = "---\nname: dup\n---\nsecond-body" },
    })
    config_store.load({ skills = { paths = { root .. "/one", root .. "/two" } } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
    skills.init()
    local s = skills.get("dup")
    t.true_(s.body:find("first-body", 1, true) ~= nil, "路径在前者优先")
  end)

  it("max_skills_in_prompt 限制摘要列出数量", function(t)
    local root = _make_root({
      { dir = "s1", content = "---\nname: s1\n---\nbody1" },
      { dir = "s2", content = "---\nname: s2\n---\nbody2" },
      { dir = "s3", content = "---\nname: s3\n---\nbody3" },
    })
    config_store.load({ skills = { paths = { root }, max_skills_in_prompt = 2 } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
    skills.init()
    local summary = skills.summary_text()
    local count = 0
    for _, line in ipairs(vim.split(summary, "\n", { plain = true })) do
      if line:sub(1, 2) == "- " then count = count + 1 end
    end
    t.eq(2, count, "摘要应受 max_skills_in_prompt 限制")
  end)

  it("回收临时目录", function(t)
    -- 上一用例已创建 temp dir；此处仅确保无状态残留
    local skills = require("NeoAI.services.skills")
    skills.reset()
    t.eq(0, skills.count())
  end)

  it("inject_mode=full 时摘要内联整篇正文", function(t)
    local root = _make_root({
      { dir = "a", content = "---\nname: skill-a\ndescription: 技能A\n---\nInline-Body-A" },
    })
    config_store.load({ skills = { paths = { root }, inject_mode = "full" } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
    skills.init()
    local summary = skills.summary_text()
    t.true_(summary:find("Inline-Body-A", 1, true) ~= nil, "full 模式应内联正文")
    t.true_(summary:find("skill-a: 技能A", 1, true) ~= nil, "full 模式应含技能名与描述")
  end)

  it("inject_mode=none 时摘要为空", function(t)
    local root = _make_root({
      { dir = "a", content = "---\nname: skill-a\ndescription: 技能A\n---\nbody-a" },
    })
    config_store.load({ skills = { paths = { root }, inject_mode = "none" } })
    local skills = require("NeoAI.services.skills")
    skills.reset()
    skills.init()
    t.eq("", skills.summary_text(), "none 模式摘要应为空")
  end)

  it("register_tools=false 时不注册工具", function(t)
    config_store.load({ skills = { register_tools = false } })
    local tools = require("NeoAI.tools.builtin.skills")
    t.eq(0, #tools.get_tools(), "register_tools=false 应返回空工具列表")
    config_store.load({ skills = { register_tools = true } })
    t.true_(#tools.get_tools() >= 2, "register_tools=true 应注册 list_skills/load_skill")
  end)
end)
