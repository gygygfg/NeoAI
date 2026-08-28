--- 显示模式管理器
--- @module NeoAI.ui.components.display_modes
--- 参照 deepseek-harness 的 Cordis 插件模型，把聊天界面的不同「显示模式」做成插件：
--- - 每个模式是一个独立 Lua 模块（本目录下，模块名 = 模式名），模块自行向本管理器注册；
--- - 每个插件定义 load(host) / unload(host)：激活时挂载折叠行为与渲染，停用时还原；
--- - 切换模式 = 卸载当前插件（unload）→ 加载目标插件（load），即热插拔；
--- - reload(name) 清除 require 缓存后重新加载模块，实现插件热加载。
---
--- 插件接口：
---   { name, label, desc, load?(host), unload?(host), render?(buf, messages) }
--- host 由 chat_view 注入，提供 get_buf/get_messages/set_foldexpr/set_foldtext/refresh。

local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

-- 插件模块统一放在本目录，模块名 = 模式名（reload 时据此重建 require 路径）
local MODULE_PREFIX = "NeoAI.ui.components.display_modes."

-- 内置显示模式（首次使用 / 循环切换时懒加载，模块自身 register）
local BUILTINS = { "chat", "trajectory" }

local registry = {} -- name -> 插件表
local order = {} -- 注册顺序（用于循环切换）
local current = nil -- 当前激活的模式名
local host = nil -- chat_view 注入的宿主 API

-- ========== 私有函数 ==========

--- 加载（并注册）指定模式的插件模块。
--- 模块顶层调用 manager.register 完成自注册；模块已缓存（reset 清空注册表后再次
--- require 不会重跑 register）时，这里用模块自身补注册，保证 registry/order 一致。
--- @param name string
--- @return table|nil
local function _load_module(name)
  local ok, mod = pcall(require, MODULE_PREFIX .. name)
  if not ok then
    vim.notify("[NeoAI] 显示模式插件加载失败 (" .. name .. "): " .. tostring(mod), vim.log.levels.ERROR)
    return nil
  end
  local plugin = registry[name]
  if not plugin then
    if type(mod) == "table" and mod.name then
      M.register(mod)
      plugin = registry[name] or mod
    else
      vim.notify("[NeoAI] 显示模式插件未注册 (" .. name .. ")", vim.log.levels.ERROR)
      return nil
    end
  end
  return plugin
end

--- 确保插件已加载并返回注册表条目
--- @param name string
--- @return table|nil
local function _ensure(name)
  if registry[name] then return registry[name] end
  return _load_module(name)
end

--- 触发显示模式切换事件（chat_view 据此重渲染，status_float 据此刷新徽标）
--- @param name string
--- @param opts table|nil { reload? }
local function _emit_changed(name, opts)
  opts = opts or {}
  event_bus.emit(events.DISPLAY_MODE_CHANGED, {
    mode = name,
    label = registry[name] and registry[name].label or name,
    reloaded = opts.reload or false,
  })
end

-- ========== 公开 API ==========

--- 注册一个显示模式插件
--- @param plugin table { name, label?, desc?, load?, unload?, render? }
function M.register(plugin)
  assert(plugin and type(plugin) == "table" and plugin.name, "显示模式插件缺少 name")
  if not registry[plugin.name] then
    order[#order + 1] = plugin.name
  end
  registry[plugin.name] = plugin
  return plugin
end

--- 获取插件（未加载时懒加载模块）
--- @param name string
--- @return table|nil
function M.get(name)
  return _ensure(name)
end

--- 列出全部已注册显示模式（保证内置模式已加载）
--- @return table 数组
function M.list()
  -- 懒加载确保内置插件进入注册表（模块自身 register）
  for _, n in ipairs(BUILTINS) do _ensure(n) end
  local out = {}
  for _, n in ipairs(order) do
    if registry[n] then out[#out + 1] = registry[n] end
  end
  return out
end

--- 当前激活的插件（未激活时 nil，渲染回退默认对话模式）
--- @return table|nil
function M.get_current()
  if not current then return nil end
  return registry[current]
end

--- 当前激活的模式名
--- @return string|nil
function M.get_current_name()
  return current
end

--- 指定模式是否激活
--- @param name string
--- @return boolean
function M.is_active(name)
  return current == name
end

--- 注入宿主 API（chat_view.open 时调用）
--- @param h table|nil { get_buf, get_messages, set_foldexpr, set_foldtext, refresh }
function M.attach(h)
  host = h
end

--- 卸载当前插件并清除宿主（chat_view.close 时调用）
function M.detach()
  M.deactivate()
  host = nil
end

--- 激活指定显示模式（卸载当前插件 → 加载目标插件，即热插拔）
--- force=true 时对已激活的模式也重新执行 load（窗口重开后注入新的 host）
--- @param name string
--- @param opts table|nil { force? }
--- @return table|nil
function M.activate(name, opts)
  opts = opts or {}
  local plugin = _ensure(name)
  if not plugin then return nil end
  if current == name and not opts.force then
    return plugin
  end
  -- 卸载当前插件
  if current and current ~= name then
    local prev = registry[current]
    if prev and prev.unload then
      pcall(prev.unload, host)
    end
  end
  current = name
  -- 加载目标插件
  if plugin.load then
    pcall(plugin.load, host)
  end
  -- 无论插件是否自行刷新，切换后一律重渲染（保证界面立即变化）
  if host and host.refresh then
    pcall(host.refresh)
  end
  _emit_changed(name)
  return plugin
end

--- 停用当前插件（不清除宿主）
function M.deactivate()
  if not current then return end
  local plugin = registry[current]
  if plugin and plugin.unload then
    pcall(plugin.unload, host)
  end
  current = nil
end

--- 循环切换到下一个显示模式（按注册顺序）
--- @return table|nil 新激活的插件
function M.cycle()
  local list = M.list()
  if #list == 0 then return nil end
  local idx = 1
  if current then
    for i, p in ipairs(list) do
      if p.name == current then
        idx = i % #list + 1
        break
      end
    end
  end
  return M.activate(list[idx].name)
end

--- 热加载指定插件：清除 require 缓存 → 重新加载模块（自注册覆盖）→ 若原本激活则重新 load。
--- 无需重启界面即可让插件代码改动生效。
--- @param name string|nil 缺省 = 当前激活模式
--- @return table|nil 重载后的插件
function M.reload(name)
  name = name or current
  if not name then
    vim.notify("[NeoAI] 无当前显示模式可重载", vim.log.levels.WARN)
    return nil
  end
  local was_active = (current == name)
  -- 先卸载（若正激活），确保折叠/渲染挂钩被还原
  if was_active then
    local prev = registry[name]
    if prev and prev.unload then
      pcall(prev.unload, host)
    end
    current = nil
  end
  -- 清除 require 缓存，强制从磁盘重新执行模块（模块顶层 register 自注册覆盖）
  package.loaded[MODULE_PREFIX .. name] = nil
  local plugin = _load_module(name)
  if not plugin then
    -- 加载失败：保留旧条目并恢复激活，避免界面失去渲染能力
    if was_active and registry[name] then
      current = name
      if registry[name].load then pcall(registry[name].load, host) end
    end
    return nil
  end
  -- 若原本激活，重新 load 让新代码生效
  if was_active then
    current = name
    if plugin.load then
      pcall(plugin.load, host)
    end
    if host and host.refresh then
      pcall(host.refresh)
    end
    _emit_changed(name, { reload = true })
  end
  return plugin
end

--- 重置（测试用）：清空注册表与激活状态
function M.reset()
  M.deactivate()
  host = nil
  registry = {}
  order = {}
  current = nil
end

return M