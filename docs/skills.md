# NeoAI Skills 支持

> 技能（Skills）是目录内带 `SKILL.md` 的**可复用操作指引**（Claude / opencode 风格）：一个技能 =
> 一个目录 + `SKILL.md`（YAML frontmatter 描述元信息 + 正文片段指引）。NeoAI 扫描技能目录，
> 把「可用技能清单」注入系统提示，模型按需调用 `load_skill` 装载正文。
> 对应源码：`lua/NeoAI/services/skills.lua`、`lua/NeoAI/tools/builtin/skills.lua`。

## 1. SKILL.md 格式

```markdown
---
name: git-review          # 技能名（唯一；缺省回退目录名）
description: 评审 Git 变更  # 给模型的描述（系统提示清单里显示）
allowed-tools:            # 可选：该技能允许的工具（仅元信息）
  - read_file
  - git_diff
env:                      # 可选：环境变量（元信息）
  KEY: value
---

这里是正文（步骤式操作指引），模型 load_skill 后读取。
```

> 极简 frontmatter 解析（无第三方 YAML 依赖）：支持标量、`[a,b]` 行内数组、dash 列表；
> 复杂 YAML 暂不支持。正文受 `max_skill_bytes` 上限截断。

## 2. 配置

```lua
require("NeoAI").setup({
  skills = {
    enabled = true,
    paths = {
      vim.fn.stdpath("config") .. "/skills",
      vim.fn.stdpath("data") .. "/neoai/skills",
      ".neoai/skills",
      ".claude/skills",
    },
    max_skills_in_prompt = 20,   -- 系统提示列出技能数上限
    max_skill_bytes = 64 * 1024, -- 单技能正文上限
    inject_mode = "list",        -- list | full | none
    persist_loaded = false,      -- load_skill 是否注册 agent 级提示段常驻
    register_tools = true,       -- 注册 list_skills / load_skill
  },
})
```

- 目录路径支持 `~`、`stdpath()`、项目相对路径；同名技能**首个路径优先**。
- 扫描**递归**（子目录），发现所有 `SKILL.md`；隐藏项（`.` 开头）跳过。

## 3. 工具

| 工具 | 说明 | 默认审批 |
| --- | --- | --- |
| `list_skills` | 列出所有技能（name + description） | ✅ 自动允许 |
| `load_skill(name)` | 装载某技能正文（SKILL.md 正文）给模型 | ✅ 自动允许 |

系统提示会注入「可用技能」段（`inject_mode`）：

- `list`：`## 可用技能（Skills）` + 加载说明（何时/如何加载、加载后按正文执行）+ `- name: description`（默认）。
- `full`：把全部技能正文注入系统提示（token 占用大，慎用）。
- `none`：不注入清单，模型借助 `list_skills` 自行发现。

`persist_loaded=true` 时，`load_skill` 会额外注册一个 agent 级提示段（`agent:skill:<name>`），
使已装载技能在后续请求中常驻上下文（会改变系统提示 → 前缀缓存可能失效，默认关闭）。

## 4. 使用流程

1. 启动/`skills.init()` 扫描目录，构建索引；系统提示出现可用技能清单。
2. 判断任务匹配某技能 → 调用 `load_skill(技能名)`，模型读取正文执行步骤。
3. 技能主体与具体操作（读文件、跑 shell 等）仍由工具系统完成；技能只提供**如何做**的指引。

## 5. 生命周期与事件

- `skills.init()` 在插件 `setup()` 时同步扫描（目录小，无阻塞）。
- `skills.reload()` 重新扫描并触发 `SKILLS_UPDATED`。
- 依赖：`prefix.register_section("deployment:skills", 90, fn)`，段内容随索引变化重算；
  技能索引变化会改变系统提示 → 影响前缀缓存身份（与工具定义变化一致）。

## 相关文档

- [tool_system.md](tool_system.md)：工具系统（`category = "skill"`）。
- [configuration.md](configuration.md)：配置系统。
