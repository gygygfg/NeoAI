--- 按键映射管理
--- @module NeoAI.ui.keymap
--- 统一管理所有按键映射，按上下文分组（global/tree/chat/input/approval）。
--- 支持运行时注册/注销。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  registered = {}, -- action -> 注册信息
}

-- ========== 私有函数 ==========

--- 展开键位配置（支持 insert/normal 双模式）
--- @param key_conf table|string
--- @return table { mode = {...}, key }
local function _expand(key_conf)
  if type(key_conf) == "string" then
    return { modes = { "n" }, key = key_conf }
  end
  if key_conf.key then
    return { modes = { "n" }, key = key_conf.key }
  end
  if key_conf.insert and key_conf.insert.key then
    return { modes = { "i", "n" }, key = key_conf.insert.key }
  end
  if key_conf.normal and key_conf.normal.key then
    return { modes = { "n" }, key = key_conf.normal.key }
  end
  return nil
end

-- ========== 公开 API ==========

--- 在指定 buffer 上注册一组按键
--- @param context string "tree" | "chat" | "approval"
--- @param actions table action 名 -> 处理函数
--- @param buf number
--- @param opts table|nil { callback_map? }
function M.register_context(context, actions, buf, opts)
  opts = opts or {}
  local keymaps = config_store.get("keymaps." .. context) or {}
  for action, handler in pairs(actions) do
    local key_conf = keymaps[action]
    if not key_conf then
      key_conf = opts.callback_map and opts.callback_map[action]
    end
    if key_conf then
      local expanded = _expand(key_conf)
      if expanded then
        for _, mode in ipairs(expanded.modes) do
          vim.keymap.set(mode, expanded.key, handler, {
            buffer = buf,
            desc = key_conf.desc or ("NeoAI " .. action),
          })
        end
        state.registered[action] = { buf = buf, key = expanded.key }
      end
    end
  end
end

--- 注册全局按键
--- @param actions table action 名 -> 处理函数
function M.register_global(actions)
  local keymaps = config_store.get("keymaps.global") or {}
  for action, handler in pairs(actions) do
    local key_conf = keymaps[action]
    if key_conf and key_conf.key then
      vim.keymap.set("n", key_conf.key, handler, { desc = key_conf.desc or ("NeoAI " .. action) })
      state.registered[action] = { key = key_conf.key, global = true }
    end
  end
end

--- 注销已注册按键
--- @param context string|nil
function M.unregister(context)
  -- 简化：全量清理
  for _, info in pairs(state.registered) do
    if info.buf and vim.api.nvim_buf_is_valid(info.buf) then
      pcall(vim.api.nvim_buf_del_keymap, info.buf, "n", info.key)
    end
  end
  state.registered = {}
end

--- 显示当前键位配置（浮窗）
function M.show_keymaps()
  local config = config_store.get("keymaps") or {}
  local lines = { "# NeoAI 键位配置", "" }
  local function dump(section, name)
    lines[#lines + 1] = "## " .. name
    for action, key_conf in pairs(section) do
      if type(key_conf) == "table" then
        if key_conf.key then
          lines[#lines + 1] = string.format("  `%s`  %s", key_conf.key, key_conf.desc or action)
        elseif key_conf.insert then
          lines[#lines + 1] = string.format("  `<C-s>`  %s", (key_conf.insert.desc or action))
        end
      end
    end
    lines[#lines + 1] = ""
  end
  dump(config.global or {}, "全局")
  dump(config.tree or {}, "会话树")
  dump(config.chat or {}, "聊天")
  dump(config.chat and config.chat.approval or {}, "工具审批")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  local width = math.min(70, vim.o.columns - 10)
  local height = math.min(#lines, vim.o.lines - 10)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = "NeoAI 键位配置",
    title_pos = "center",
  })
end

--- 重置（测试用）
function M.reset()
  state.registered = {}
end

return M
