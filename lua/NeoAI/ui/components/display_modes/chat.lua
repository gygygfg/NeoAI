--- 显示模式插件：对话（默认）
--- @module NeoAI.ui.components.display_modes.chat
--- 默认聊天显示：按角色消息渲染，推理 / 每个工具块（调用+结果）各自独立折叠。
--- 由 display_modes 管理器懒加载，本模块顶层向管理器自注册。

local manager = require("NeoAI.ui.components.display_modes")

local M = {
  name = "chat",
  label = "对话",
  desc = "默认对话模式：按角色渲染消息，推理与工具调用各自折叠",
}

--- 激活：使用默认块折叠（清除覆盖）。重渲染由管理器统一触发。
--- @param host table|nil 宿主 API
function M.load(host)
  if host then
    host.set_foldexpr(nil)
    host.set_foldtext(nil)
  end
end

--- 停用：还原折叠覆盖（由激活的下一个插件接管）
--- @param host table|nil 宿主 API
function M.unload(host)
  if host then
    host.set_foldexpr(nil)
    host.set_foldtext(nil)
  end
end

--- 渲染消息到 buffer（复用 message_list 的对话渲染）
--- @param buf number
--- @param messages table
--- @param opts table|nil 渲染选项（流式表格）
function M.render(buf, messages, opts)
  local message_list = require("NeoAI.ui.components.message_list")
  message_list.render_chat(buf, messages, opts)
end

manager.register(M)

return M