# NeoAI Skills Support

> [中文](../skills.md) | **English**

> Skills are **reusable operating instructions** contained in a directory with a `SKILL.md` (Claude / opencode style): one skill =
> one directory + `SKILL.md` (YAML frontmatter describing metadata + a body of step-by-step guidance). NeoAI scans the skills directories,
> injects the "available skills list" into the system prompt, and the model calls `load_skill` on demand to load the body.
> Corresponding source: `lua/NeoAI/services/skills.lua`, `lua/NeoAI/tools/builtin/skills.lua`.

## 1. SKILL.md Format

```markdown
---
name: git-review          # Skill name (unique; falls back to the directory name if omitted)
description: Review Git changes  # Description for the model (shown in the system prompt list)
allowed-tools:            # Optional: tools allowed for this skill (metadata only)
  - read_file
  - git_diff
env:                      # Optional: environment variables (metadata)
  KEY: value
---

This is the body (step-by-step operating guidance), read by the model after `load_skill`.
```

> Minimal frontmatter parsing (no third-party YAML dependency): supports scalars, `[a,b]` inline arrays, and dash lists;
> complex YAML is not supported yet. The body is truncated at the `max_skill_bytes` limit.

## 2. Configuration

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
    max_skills_in_prompt = 20,   -- Max number of skills listed in the system prompt
    max_skill_bytes = 64 * 1024, -- Max body size per skill
    inject_mode = "list",        -- list | full | none
    persist_loaded = false,      -- Whether load_skill registers a persistent agent-level prompt section
    register_tools = true,       -- Register list_skills / load_skill
  },
})
```

- Directory paths support `~`, `stdpath()`, and project-relative paths; for skills with the same name, **the first path wins**.
- Scanning is **recursive** (into subdirectories) and finds every `SKILL.md`; hidden entries (starting with `.`) are skipped.

## 3. Tools

| Tool | Description | Default approval |
| --- | --- | --- |
| `list_skills` | List all skills (name + description) | ✅ Auto-allowed |
| `load_skill(name)` | Load a skill's body (the SKILL.md body) into the model | ✅ Auto-allowed |

The system prompt injects an "available skills" section (`inject_mode`):

- `list`: `## Available Skills` + loading instructions (when/how to load, and to follow the body after loading) + `- name: description` (default).
- `full`: Injects every skill body into the system prompt (high token usage; use with caution).
- `none`: Injects no list; the model discovers skills on its own via `list_skills`.

When `persist_loaded=true`, `load_skill` additionally registers an agent-level prompt section (`agent:skill:<name>`),
keeping loaded skills resident in context for subsequent requests (this changes the system prompt → prefix caching may be invalidated; disabled by default).

## 4. Workflow

1. On startup / `skills.init()`, the directories are scanned and an index is built; the available skills list then appears in the system prompt.
2. If the task matches a skill → call `load_skill(skill_name)`, and the model reads the body to execute the steps.
3. The skill body and the concrete operations (reading files, running shell commands, etc.) are still handled by the tool system; skills only provide guidance on **how to do it**.

## 5. Lifecycle and Events

- `skills.init()` scans synchronously during the plugin's `setup()` (directories are small, so there is no blocking).
- `skills.reload()` rescans and fires `SKILLS_UPDATED`.
- Dependency: `prefix.register_section("deployment:skills", 90, fn)`; the section content is recomputed as the index changes;
  a change to the skills index alters the system prompt → affecting the prefix cache identity (consistent with changes to tool definitions).

## Related Documentation

- [tool_system.md](tool_system.md): The tool system (`category = "skill"`).
- [configuration.md](configuration.md): The configuration system.
