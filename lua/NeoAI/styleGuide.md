基于您的需求，我对架构进行了优化，重点在于简化结构、明确职责、强化工具调用处理。以下是优化后的架构：

优化后的架构设计

NeoAI/
├── init.lua # 主入口文件
├── default_config.lua # 全局配置验证
├── core/ # 核心业务逻辑
│ ├── init.lua # 核心模块入口
│ ├── config/ # 配置管理
│ │ ├── config_manager.lua # 配置管理（合并验证功能）
│ │ └── keymap_manager.lua # 键位配置管理器（新增）
│ ├── session/ # 会话管理
│ │ ├── session_manager.lua # 会话管理器
│ │ ├── branch_manager.lua # 分支管理
│ │ ├── message_manager.lua # 消息管理（合并操作）
│ │ └── data_operations.lua # 数据操作
│ ├── ai/ # AI交互
│ │ ├── ai_engine.lua # AI引擎主入口
│ │ ├── stream_processor.lua # 流式处理器
│ │ ├── reasoning_manager.lua # 思考过程管理
│ │ ├── tool_orchestrator.lua # 工具调用编排器
│ │ └── response_builder.lua # 响应构建器
│ └── events/ # 事件系统
│ └── event_bus.lua # 事件总线（简化）
├── ui/ # 用户界面
│ ├── init.lua # UI模块入口
│ ├── window/ # 窗口管理
│ │ ├── window_manager.lua # 窗口管理器
│ │ ├── window_mode_manager.lua # 窗口模式管理器（新增）
│ │ ├── chat_window.lua # 聊天窗口
│ │ └── tree_window.lua # 树状图窗口
│ ├── components/ # UI组件
│ │ ├── input_handler.lua # 输入处理器
│ │ ├── history_tree.lua # 历史树组件
│ │ └── reasoning_display.lua # 思考过程显示
│ └── handlers/ # 事件处理器
│ ├── tree_handlers.lua # 树界面处理器
│ └── chat_handlers.lua # 聊天界面处理器
├── tools/ # 工具系统（新增）
│ ├── init.lua # 工具模块入口
│ ├── tool_registry.lua # 工具注册表
│ ├── tool_executor.lua # 工具执行器
│ ├── tool_validator.lua # 工具验证器
│ └── builtin/ # 内置工具
│ └── file_tools.lua # 文件工具
└── utils/ # 工具库（精简）
├── init.lua # 工具模块入口
├── common.lua # 常用工具函数
├── text_utils.lua # 文本处理
├── table_utils.lua # 表操作
├── file_utils.lua # 文件操作
└── logger.lua # 日志

核心模块功能设计

1. 主入口文件

init.lua

setup(user_config) # 初始化插件，验证配置，设置全局变量
open_neoai() # 打开NeoAI主界面
close_all() # 关闭所有界面

default_config.lua

validate_config(config) # 验证用户配置
merge_defaults(config) # 合并默认配置
sanitize_config(config) # 清理配置
get_default_config() # 获取默认配置

默认配置包含：

- ui.default_ui: 默认打开的界面 ('tree' 或 'chat')
- ui.window_mode: 窗口模式 ('float', 'tab', 'split')
- ui.window: 窗口尺寸和边框配置
- ui.keymaps: 键位配置
- ai: AI相关配置
- session: 会话配置
- tools: 工具系统配置

2. 核心业务模块

core/init.lua

initialize(core_config) # 初始化核心模块
get_session_manager() # 获取会话管理器
get_ai_engine() # 获取AI引擎

core/config/config_manager.lua

get(key) # 获取配置
set(key, value) # 设置配置
validate(key, value) # 验证配置
on_change(callback) # 配置变更回调

core/config/keymap_manager.lua

load_default_keymaps() # 加载默认键位配置
get_keymap(context, action) # 获取指定上下文和动作的键位
set_keymap(context, action, key) # 设置键位映射
reset_keymap(context, action) # 重置键位到默认值
list_keymaps(context) # 列出指定上下文的所有键位
validate_key(key) # 验证键位有效性
save_keymaps() # 保存键位配置到文件
load_keymaps() # 从文件加载键位配置

core/session/session_manager.lua

create_session(name) # 创建会话
get_session(id) # 获取会话
get_current_session() # 获取当前会话
set_current_session(id) # 设置当前会话
list_sessions() # 列出所有会话
delete_session(id) # 删除会话

core/session/branch_manager.lua

create_branch(parent_id, name) # 创建分支
switch_branch(branch_id) # 切换分支
get_branch_tree(session_id) # 获取分支树
delete_branch(branch_id) # 删除分支
get_current_branch() # 获取当前分支

core/session/message_manager.lua

add_message(role, content) # 添加消息
get_messages(branch_id, limit) # 获取消息
edit_message(msg_id, content) # 编辑消息
delete_message(msg_id) # 删除消息
clear_messages(branch_id) # 清空消息

core/session/data_operations.lua

export_session(session_id, format) # 导出会话
import_session(data, format) # 导入会话
backup_sessions() # 备份会话
restore_backup(backup_id) # 恢复备份

core/ai/ai_engine.lua

generate_response(messages, options) # 生成响应
stream_response(messages, options) # 流式响应
cancel_generation() # 取消生成
is_generating() # 是否正在生成

core/ai/stream_processor.lua

process_chunk(chunk) # 处理流式数据块
handle_reasoning(content) # 处理思考内容
handle_content(content) # 处理内容输出
handle_tool_call(tool_call) # 处理工具调用
flush_buffer() # 刷新缓冲区

core/ai/reasoning_manager.lua

start_reasoning() # 开始思考过程
append_reasoning(content) # 追加思考内容
finish_reasoning() # 完成思考过程
get_reasoning_text() # 获取思考文本
clear_reasoning() # 清空思考

core/ai/tool_orchestrator.lua

execute_tool_loop(messages) # 执行工具调用循环
parse_tool_call(response) # 解析工具调用
execute_tool(tool_call) # 执行单个工具
build_context(tool_result) # 构建上下文
should_continue(result) # 判断是否继续调用

core/ai/response_builder.lua

build_messages(history, query) # 构建消息列表
format_tool_result(result) # 格式化工具结果
create_summary(messages) # 创建摘要
compact_context(messages) # 压缩上下文

core/events/event_bus.lua

on(event, callback) # 监听事件
emit(event, ...) # 触发事件
off(event, callback) # 取消监听
clear_listeners(event) # 清除监听器

3. 用户界面模块

ui/init.lua

initialize(ui_config) # 初始化UI
open_tree_ui() # 打开树界面
open_chat_ui() # 打开聊天界面
close_all_windows() # 关闭所有窗口

ui/window/window_manager.lua

create_window(type, options) # 创建窗口
close_window(window_id) # 关闭窗口
get_window(window_id) # 获取窗口
list_windows() # 列出所有窗口
focus_window(window_id) # 聚焦窗口
get_window_mode() # 获取当前窗口模式
set_window_mode(mode) # 设置窗口模式

ui/window/window_mode_manager.lua

create_float_window(options) # 创建浮动窗口
create_tab_window(options) # 创建标签页窗口
create_split_window(options) # 创建分割窗口
create_window_by_mode(mode, options) # 根据模式创建窗口
close_window(window_info) # 关闭窗口
set_window_content(window_info, content, filetype) # 设置窗口内容
append_window_content(window_info, content) # 追加窗口内容
focus_window(window_info) # 聚焦窗口
is_window_valid(window_info) # 检查窗口是否有效

ui/window/chat_window.lua

open(session_id, branch_id) # 打开聊天窗口
render_messages(messages) # 渲染消息
update_input(content) # 更新输入框
clear_input() # 清空输入框
set_keymaps() # 设置按键映射（使用keymap_manager）

ui/window/tree_window.lua

open(session_id) # 打开树状图窗口
render_tree(tree_data) # 渲染树状图
refresh_tree() # 刷新树状图
set_keymaps() # 设置按键映射（使用keymap_manager）
get_selected_node() # 获取选中节点

ui/components/input_handler.lua

setup_keymaps() # 设置按键映射（使用keymap_manager）
handle_input() # 处理输入
send_message(content) # 发送消息
edit_message(msg_id) # 编辑消息
set_mode(mode) # 设置模式

ui/components/history_tree.lua

render(session_id) # 渲染历史树
expand_node(node_id) # 展开节点
collapse_node(node_id) # 折叠节点
select_node(node_id) # 选择节点
update_node(node_id, data) # 更新节点

ui/components/reasoning_display.lua

show(content) # 显示思考过程
append(content) # 追加内容
close() # 关闭显示
is_visible() # 是否可见
set_position(x, y) # 设置位置

ui/handlers/tree_handlers.lua

handle_enter() # 处理回车（选择分支）
handle_n() # 处理n键（新建子分支）
handle_N() # 处理N键（新建根分支）
handle_d() # 处理d键（删除对话）
handle_D() # 处理D键（删除分支）

ui/handlers/chat_handlers.lua

handle_enter() # 处理回车（发送消息）
handle_ctrl_s() # 处理Ctrl+S（发送消息）
handle_escape() # 处理ESC键
handle_tab() # 处理Tab键
handle_scroll() # 处理滚动

4. 工具系统模块（新增）

tools/init.lua

initialize(tools_config) # 初始化工具系统
register_tool(tool_def) # 注册工具
get_tools() # 获取所有工具
execute_tool(name, args) # 执行工具

tools/tool_registry.lua

register(tool) # 注册工具
unregister(tool_name) # 注销工具
get(tool_name) # 获取工具定义
list() # 列出所有工具
validate_tool(tool) # 验证工具定义

tools/tool_executor.lua

execute(tool_name, args) # 执行工具
validate_args(tool, args) # 验证参数
format_result(result) # 格式化结果
handle_error(error) # 处理错误
cleanup() # 清理资源

tools/tool_validator.lua

validate_schema(schema) # 验证工具模式
validate_parameters(params) # 验证参数
validate_return_type(type) # 验证返回类型
check_permissions(tool) # 检查权限

tools/builtin/file_tools.lua

read_file(path) # 读取文件
write_file(path, content) # 写入文件
list_files(dir) # 列出文件
search_files(pattern) # 搜索文件

5. 工具库模块（精简）

utils/common.lua

deep_copy(tbl) # 深拷贝
deep_merge(t1, t2) # 深度合并
safe_call(func, ...) # 安全调用
debounce(func, delay) # 防抖
throttle(func, limit) # 节流

utils/text_utils.lua

truncate(text, length) # 截断文本
wrap(text, width) # 文本换行
escape(text) # 转义字符
unescape(text) # 反转义
format_json(data) # 格式化JSON

utils/table_utils.lua

keys(tbl) # 获取所有键
values(tbl) # 获取所有值
filter(tbl, predicate) # 过滤表
map(tbl, func) # 映射表
reduce(tbl, func, init) # 归约表

utils/file_utils.lua

read_lines(path) # 读取行
write_lines(path, lines) # 写入行
exists(path) # 检查文件是否存在
mkdir(dir) # 创建目录
join_path(...) # 连接路径

utils/logger.lua

log(level, message) # 记录日志
set_level(level) # 设置日志级别
set_output(path) # 设置输出路径
debug(message, ...) # 调试日志
info(message, ...) # 信息日志
error(message, ...) # 错误日志

关键流程说明

1. 启动流程

1. 用户调用
   "setup(config)" →
   "default_config.validate_config()"
1. 初始化核心模块 → 初始化UI模块（传递窗口模式配置） → 初始化工具系统
1. 返回包含
   "open()" 函数的表

窗口模式配置示例：

```lua
require("NeoAI").setup({
  ui = {
    default_ui = "chat",           -- 默认打开聊天界面
    window_mode = "split",          -- 使用分割窗口模式
    window = {
      width = 100,
      height = 30,
      border = "single",
    },
  },
  ai = {
    model = "gpt-4",
    api_key = os.getenv("OPENAI_API_KEY"),
  },
})
```

1. 树界面操作流程

1. ":NeoAIOpen" →
   "ui.open_tree_ui()"
1. 回车键 →
   "tree_handlers.handle_enter()" → 关闭树界面 → 打开聊天界面
1. 按键映射由
   "tree_window.set_keymaps()" 设置

1. 聊天界面消息流程

1. 用户输入 →
   "input_handler.handle_input()"
1. 发送消息 →
   "chat_handlers.handle_enter()" 或
   "handle_ctrl_s()"
1. AI处理 →
   "ai_engine.generate_response()"
1. 流式处理 →
   "stream_processor.process_chunk()"
1. 显示结果 →
   "chat_window.render_messages()"

1. 工具调用循环流程

1. 模型返回工具调用 →
   "tool_orchestrator.execute_tool_loop()"
1. 执行工具 →
   "tool_executor.execute()"
1. 重整上下文 →
   "response_builder.build_context()"
1. 继续调用模型直到结束

1. 思考过程显示流程

1. 接收到
   "reasoning_content" →
   "reasoning_manager.start_reasoning()"
1. 打开悬浮窗口 →
   "reasoning_display.show()"
1. 流式更新 →
   "reasoning_display.append()"
1. 思考结束 →
   "reasoning_display.close()" → 转换为折叠文本

1. 窗口模式配置流程

1. 插件启动时 →
   "default_config" 读取默认窗口模式配置
1. 用户自定义配置 →
   "ui.window_mode" 和 "ui.default_ui" 配置项
1. 窗口管理器初始化 →
   "window_manager.initialize()" 接收窗口模式配置
1. 创建窗口时 →
   "window_mode_manager.create_window_by_mode()" 根据模式创建窗口
1. 支持三种模式：
   - "float": 浮动窗口（默认）
   - "tab": 新标签页
   - "split": 分割窗口

1. 键位配置流程

1. 插件启动时 →
   "keymap_manager.load_default_keymaps()"
1. 用户自定义配置 →
   "keymap_manager.set_keymap(context, action, key)"
1. 窗口打开时 →
   "window.set_keymaps()" → 调用 "keymap_manager.get_keymap()"
1. 保存配置 →
   "keymap_manager.save_keymaps()"
1. 重置键位 →
   "keymap_manager.reset_keymap(context, action)"

优化点总结

1. 简化结构：减少不必要的层级，合并相关功能
2. 明确职责：每个模块/文件职责更清晰
3. 强化工具系统：新增专用工具模块，支持工具调用循环
4. 统一事件系统：使用事件总线简化通信
5. 精简工具库：合并冗余工具函数
6. 前后端分离：UI与核心逻辑完全解耦
7. 流式处理优化：专门处理思考过程和工具调用
8. 配置集中管理：统一配置入口和验证
9. 键位配置管理：新增键位配置管理器，支持自定义键位映射
10. 窗口模式支持：新增窗口模式管理器，支持 float、tab、split 三种窗口模式
11. 默认界面配置：支持配置默认打开的界面（tree 或 chat）

键位配置上下文定义

1. 树界面上下文 ("tree")
   - "select" - 选择节点/分支
   - "new_child" - 新建子分支
   - "new_root" - 新建根分支
   - "delete_dialog" - 删除对话
   - "delete_branch" - 删除分支
   - "expand" - 展开节点
   - "collapse" - 折叠节点

2. 聊天界面上下文 ("chat")
   - "send" - 发送消息
   - "cancel" - 取消生成
   - "edit" - 编辑消息
   - "delete" - 删除消息
   - "scroll_up" - 向上滚动
   - "scroll_down" - 向下滚动
   - "toggle_reasoning" - 切换思考过程显示

3. 全局上下文 ("global")
   - "open_tree" - 打开树界面
   - "open_chat" - 打开聊天界面
   - "close_all" - 关闭所有窗口
   - "toggle_ui" - 切换UI显示

默认键位配置示例

```lua
{
  tree = {
    select = "<CR>",           -- 回车键
    new_child = "n",           -- n键
    new_root = "N",            -- Shift+n键
    delete_dialog = "d",       -- d键
    delete_branch = "D",       -- Shift+d键
    expand = "o",              -- o键
    collapse = "O",             -- Shift+o键
  },
  chat = {
    send = "<C-s>",           -- Ctrl+s键
    cancel = "<Esc>",         -- ESC键
    edit = "e",               -- e键
    delete = "dd",            -- dd键
    scroll_up = "<C-u>",      -- Ctrl+u键
    scroll_down = "<C-d>",    -- Ctrl+d键
    toggle_reasoning = "r",    -- r键
  },
  global = {
    open_tree = "<leader>at",  -- leader+at键
    open_chat = "<leader>ac",  -- leader+ac键
    close_all = "<leader>aq",  -- leader+aq键
    toggle_ui = "<leader>aa",  -- leader+aa键
  }
}
```

这个架构更符合您的需求，特别是工具调用循环和思考过程显示的部分得到了重点优化。

## 使用示例

### 基本配置

```lua
-- 基本配置：浮动窗口，默认打开树界面
require("NeoAI").setup({
  ui = {
    default_ui = "tree",           -- 默认打开树界面
    window_mode = "float",          -- 浮动窗口模式
    window = {
      width = 80,
      height = 20,
      border = "rounded",
    },
  },
  ai = {
    model = "deepseek-reasoner",
    api_key = os.getenv("DEEPSEEK_API_KEY"),
  },
})
```

### 标签页模式配置

```lua
-- 标签页模式，默认打开聊天界面
require("NeoAI").setup({
  ui = {
    default_ui = "chat",           -- 默认打开聊天界面
    window_mode = "tab",           -- 标签页模式
  },
  ai = {
    model = "gpt-4",
    api_key = os.getenv("OPENAI_API_KEY"),
  },
})
```

### 分割窗口模式配置

```lua
-- 分割窗口模式，垂直分割
require("NeoAI").setup({
  ui = {
    default_ui = "tree",           -- 默认打开树界面
    window_mode = "split",         -- 分割窗口模式
    window = {
      split_direction = "vertical", -- 垂直分割
      split_size = "50%",          -- 分割大小
    },
  },
})
```

### 完整配置示例

```lua
-- 完整配置示例
require("NeoAI").setup({
  ui = {
    default_ui = "chat",           -- 默认打开聊天界面
    window_mode = "float",         -- 浮动窗口模式
    window = {
      width = 100,
      height = 30,
      border = "single",
      position = "right",          -- 窗口位置
      winblend = 10,              -- 窗口透明度
    },
    keymaps = {
      tree = {
        select = { key = "<CR>", desc = "选择节点/分支" },
        new_child = { key = "n", desc = "新建子分支" },
        new_root = { key = "N", desc = "新建根分支" },
      },
      chat = {
        send = { key = "<C-s>", desc = "发送消息" },
        cancel = { key = "<Esc>", desc = "取消生成" },
        toggle_reasoning = { key = "r", desc = "切换思考过程显示" },
      },
    },
  },
  ai = {
    base_url = "https://api.openai.com/v1/chat/completions",
    model = "gpt-4-turbo",
    api_key = os.getenv("OPENAI_API_KEY"),
    temperature = 0.8,
    max_tokens = 8192,
    stream = true,
  },
  session = {
    auto_save = true,
    save_path = vim.fn.stdpath("data") .. "/neoai_sessions",
    max_history = 200,
  },
  tools = {
    enabled = true,
    builtin = true,
  },
})
```

## 命令和快捷键注册

### 已注册的 Neovim 命令

插件初始化时会自动注册以下命令：

1. **:NeoAIOpen** - 打开 NeoAI 主界面（根据配置选择默认界面）
2. **:NeoAIClose** - 关闭所有 NeoAI 窗口
3. **:NeoAITree** - 打开树界面
4. **:NeoAIChat** - 打开聊天界面
5. **:NeoAIKeymaps** - 显示当前键位配置（在浮动窗口中）

### 全局快捷键

插件会根据配置自动注册以下全局快捷键：

1. **打开树界面** - `<leader>at`（可配置）
2. **打开聊天界面** - `<leader>ac`（可配置）
3. **关闭所有窗口** - `<leader>aq`（可配置）
4. **切换 UI 显示** - `<leader>aa`（可配置）
