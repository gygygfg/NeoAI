# NeoAI 增强版聊天界面使用指南

## 概述

增强版聊天界面解决了原始版本的四个主要问题：
1. ✅ **异步渲染** - 渲染不在主线程执行，避免界面卡顿
2. ✅ **正文渲染** - 完整渲染AI响应内容，包括代码块和格式
3. ✅ **思考过程折叠** - 支持展开/折叠查看AI的思考过程
4. ✅ **美观界面** - 改进的UI设计，更好的视觉体验

## 快速开始

### 1. 基本使用

```lua
-- 在你的Neovim配置中（如 init.lua）
local neoai_enhanced = require("NeoAI.ui.chat_enhanced")

-- 初始化
neoai_enhanced.setup({
  width = 80,
  height = 24,
  border = "rounded",
  default_mode = "deep_thinking", -- 或 "stream"
})

-- 打开聊天窗口
vim.keymap.set("n", "<leader>ac", function()
  neoai_enhanced.open_chat()
end, { desc = "打开NeoAI聊天" })
```

### 2. 命令模式

```vim
" 打开聊天窗口
:NeoAIChat [会话名称]

" 发送消息
:NeoAISend 你的消息内容

" 切换响应模式
:NeoAIMode deep    " 深度思考模式
:NeoAIMode stream  " 流式响应模式

" 演示功能
:NeoAIDemo

" 列出活跃会话
:NeoAIList
```

## 功能特性

### 1. 深度思考模式 🤔

**特点**：
- AI先进行完整的内部推理
- 一次性输出高质量回答
- 包含详细的思考过程（可折叠）

**使用场景**：
- 复杂问题解决
- 代码审查和优化
- 逻辑推理和分析
- 需要高质量输出的任务

**示例**：
```lua
-- 深度思考模式会显示完整的思考过程
neoai_enhanced.send_message("请分析这个排序算法的复杂度")
```

### 2. 流式响应模式 ⚡

**特点**：
- AI边思考边输出
- 响应速度快，交互感强
- 适合简单对话

**使用场景**：
- 日常聊天
- 简单查询
- 快速回答
- 实时对话

**示例**：
```lua
-- 切换到流式模式
neoai_enhanced.switch_mode("stream")
neoai_enhanced.send_message("今天的天气怎么样？")
```

### 3. 思考过程折叠 📁

**操作**：
- 在聊天窗口内按 `t` 键切换思考过程显示
- 默认折叠，节省空间
- 展开后可查看AI的完整推理步骤

**显示效果**：
```
<details>
<summary>🤔 思考过程 (点击展开)</summary>

```reasoning
1. 分析用户问题...
2. 收集相关信息...
3. 构建回答框架...
```

</details>
```

### 4. 异步渲染 🔄

**优势**：
- 渲染操作在后台线程执行
- 主界面不会卡顿
- 支持大量消息的流畅显示

**技术实现**：
- 使用 `vim.defer_fn` 进行异步调度
- 渲染队列管理
- 智能批处理

## 配置选项

### 基本配置

```lua
neoai_enhanced.setup({
  -- 窗口尺寸
  width = 80,
  height = 24,
  
  -- 窗口边框样式
  border = "rounded", -- "single", "double", "rounded", "solid", "shadow"
  
  -- 默认响应模式
  default_mode = "deep_thinking", -- "deep_thinking" 或 "stream"
  
  -- 功能开关
  enable_async_render = true,
  enable_reasoning_fold = true,
  
  -- 颜色配置
  colors = {
    user_message = "Comment",
    ai_message = "String",
    reasoning = "Type",
    title = "Title",
    border = "FloatBorder",
  },
  
  -- 键位配置
  keymaps = {
    open_chat = "<leader>ac",
    toggle_reasoning = "t",
    refresh_chat = "r",
    close_chat = "q",
    send_message = "<CR>",
  },
})
```

### 高级配置

```lua
-- 自定义会话管理
local sessions = neoai_enhanced.list_sessions()

-- 动态切换模式
neoai_enhanced.switch_mode("stream")  -- 切换到流式模式
neoai_enhanced.switch_mode("deep")    -- 切换到深度思考模式

-- 重新加载配置
neoai_enhanced.reload_config({
  width = 90,
  height = 30,
  border = "double",
})
```

## 聊天窗口操作

### 窗口内快捷键

| 按键 | 功能 | 描述 |
|------|------|------|
| `i` | 进入插入模式 | 开始输入消息 |
| `<Esc>` | 退出插入模式 | 返回正常模式 |
| `<CR>` 或 `<C-s>` | 发送消息 | 发送当前输入的消息 |
| `t` | 切换思考过程 | 展开/折叠AI思考过程 |
| `r` | 刷新对话 | 重新加载会话消息 |
| `q` | 退出窗口 | 关闭当前聊天窗口 |

### 消息格式

**用户消息**：
```
### 👤 用户

```
你的消息内容
```

```

**AI响应（深度思考模式）**：
```
### 🤖 AI助手

<details>
<summary>🤔 思考过程 (点击展开)</summary>

```reasoning
AI的思考过程...
```

</details>

#### 📝 回答

AI的最终回答...
```

**AI响应（流式模式）**：
```
### 🤖 AI助手

AI的流式响应内容...
```

## 集成示例

### 与现有工作流集成

```lua
-- 在代码编辑时快速咨询AI
vim.keymap.set("n", "<leader>ai", function()
  local visual_text = ""
  
  -- 如果是可视模式，获取选中文本
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" then
    visual_text = vim.fn.getreg('"')
  end
  
  -- 打开聊天窗口
  neoai_enhanced.open_chat("code_review")
  
  -- 发送代码审查请求
  if visual_text ~= "" then
    neoai_enhanced.send_message("请审查这段代码：\n```lua\n" .. visual_text .. "\n```")
  else
    neoai_enhanced.send_message("请帮我优化当前的代码")
  end
end, { desc = "代码AI咨询" })
```

### 自定义会话管理

```lua
-- 创建专用会话
local function create_specialized_session(name, purpose)
  local session_id = "special_" .. name .. "_" .. os.time()
  
  neoai_enhanced.open_chat(name)
  
  -- 设置会话专用提示
  neoai_enhanced.send_message("我将作为您的" .. purpose .. "助手。请告诉我您需要什么帮助。", {
    stream = false
  })
  
  return session_id
end

-- 创建不同用途的会话
local code_session = create_specialized_session("code", "编程")
local writing_session = create_specialized_session("writing", "写作")
local debug_session = create_specialized_session("debug", "调试")
```

## 故障排除

### 常见问题

1. **窗口无法打开**
   - 检查是否已调用 `setup()` 初始化
   - 验证Neovim版本是否支持浮动窗口

2. **消息发送失败**
   - 确保聊天窗口已打开
   - 检查网络连接（如果使用在线AI服务）

3. **思考过程不显示**
   - 确认使用的是深度思考模式
   - 按 `t` 键切换思考过程显示

4. **界面卡顿**
   - 确保 `enable_async_render = true`
   - 减少同时打开的聊天窗口数量

### 调试模式

```lua
-- 启用调试输出
vim.g.neoai_debug = true

-- 运行快速测试
neoai_enhanced.quick_test()
```

## 性能优化建议

1. **会话管理**
   - 及时关闭不再使用的会话
   - 使用 `:NeoAIList` 查看活跃会话

2. **渲染优化**
   - 对于长对话，考虑分页显示
   - 使用折叠功能减少渲染内容

3. **内存管理**
   - 定期清理历史消息
   - 限制单个会话的消息数量

## 更新日志

### v1.0.0 (初始版本)
- ✅ 异步渲染系统
- ✅ 思考过程折叠功能
- ✅ 深度思考与流式响应双模式
- ✅ 改进的UI界面设计
- ✅ 完整的命令和键位支持
- ✅ 会话管理功能

## 下一步计划

1. **插件集成**
   - 与更多AI服务提供商集成
   - 支持自定义模型配置

2. **高级功能**
   - 对话历史导出
   - 多会话同时管理
   - 自定义提示模板

3. **用户体验**
   - 主题系统支持
   - 响应时间优化
   - 移动设备适配

---

**开始使用**：
```lua
:NeoAIDemo  -- 查看演示
:NeoAIChat  -- 开始聊天
```

如有问题或建议，请参考代码文档或提交issue。