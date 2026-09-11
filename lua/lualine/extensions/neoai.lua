--- NeoAI lualine 扩展
--- @module lualine.extensions.neoai
--- 在聊天主消息窗口（filetype == 'neoai'）内，用 NeoAI 状态栏代替默认状态栏；
--- 输入框等其它 NeoAI buffer 保留用户自己的 lualine，不被污染。刻意简洁：
---   第 1 行（winbar）：身份 —— 模式 / 模型 / 状态
---   第 2 行（statusline）：指标 —— 用量 / 缓存命中率 / 剩余容量
--- 关闭 winbar（ui.statusline.winbar = false）时退化为单行：身份 + 指标。
--- 各段均显式链接到鲜艳高亮组，active / inactive 一致，避免默认灰暗配色（虚化）。
--- 开启方式二选一：
---   1. 自动：检测到 lualine 时由 NeoAI.setup() / 打开聊天窗口时注入（零配置）。
---   2. 手动：lualine 配置里加 extensions = { 'neoai' }。
--- 想保留自己的全局状态栏、只附加 NeoAI 信息时，改用
--- require('NeoAI.services.status').component() 塞进自己的 sections。

local status = require("NeoAI.services.status")

--- 只有主消息窗口（filetype == 'neoai'）才渲染第一行（winbar），避免挤占输入框
--- @return boolean
local function is_main()
  return vim.bo.filetype == "neoai"
end

--- 构造单个带高亮链接的函数组件
--- @param part string 段名（mode/display/model/usage/cache/capacity/state/pending）
--- @param opts table|nil { cond? function, sep? string }
--- @return table lualine 组件
local function comp(part, opts)
  opts = opts or {}
  local colors = status.colors()
  local item = { function() return status.segment(part) end }
  item.color = colors[part] or colors.state
  if opts.cond then item.cond = opts.cond end
  if opts.sep then item.separator = opts.sep end
  return item
end

-- 身份段在 winbar 开启时应转移到第一行，故状态栏里用「非 winbar」条件占位
local function no_winbar_cond()
  return function() return not status.winbar_enabled() end
end
local function main_cond()
  return function() return status.winbar_enabled() and is_main() end
end

-- 指标（状态栏）：用量 / 缓存命中率 / 上下文容量 / 待发（正忙时排队）
-- 每次调用返回全新数组，避免同一数组被多个 section（sections/inactive_sections 等）
-- 共享，lualine 在 load_sections 时会原地改写，共享会互相污染。
-- 容量段按告警级别动态配色（接近上限黄、超限红）。
local function capacity_comp()
  local colors = status.colors()
  return {
    function() return status.segment("capacity") end,
    color = function()
      local level = status.capacity_level()
      if level == "over" then return colors.capacity_over or "ErrorMsg" end
      if level == "warn" then return colors.capacity_warn or "WarningMsg" end
      return colors.capacity
    end,
  }
end

local function metrics()
  return { comp("usage"), comp("cache"), capacity_comp(), comp("pending") }
end
-- 身份（winbar 第一行）：模式 / 模型 / 状态
local function identity()
  return {
    comp("mode", { cond = main_cond() }),
    comp("model", { cond = main_cond() }),
    comp("state", { cond = main_cond() }),
  }
end

local M = {
  -- 只接管主消息窗口（neoai）；输入框保留用户自己的 lualine，不污染
  filetypes = { "neoai" },
  sections = {
    lualine_a = { comp("mode", { cond = no_winbar_cond() }) },
    lualine_b = { comp("model", { cond = no_winbar_cond() }) },
    lualine_c = metrics(),
    lualine_y = { comp("state", { cond = no_winbar_cond() }) },
    lualine_z = {},
  },
  inactive_sections = {
    lualine_a = { comp("mode", { cond = no_winbar_cond() }) },
    lualine_b = { comp("model", { cond = no_winbar_cond() }) },
    lualine_c = metrics(),
    lualine_y = { comp("state", { cond = no_winbar_cond() }) },
    lualine_z = {},
  },
  winbar = {
    lualine_c = identity(),
  },
  inactive_winbar = {
    lualine_c = identity(),
  },
}

--- 扩展加载时订阅 NeoAI 事件，事件驱动状态栏刷新
function M.init()
  status.watch()
end

return M
