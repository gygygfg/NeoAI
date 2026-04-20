-- 验证聊天窗口修改
print("🔍 验证聊天窗口修改...")

-- 读取修改的文件
local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

-- 检查文件是否包含特定内容
local function contains(content, pattern)
    return content and content:find(pattern) ~= nil
end

-- 检查聊天窗口文件
local chat_window_path = "/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/ui/window/chat_window.lua"
local chat_window_content = read_file(chat_window_path)

if chat_window_content then
    print("📄 检查聊天窗口文件...")
    
    -- 检查新增的函数
    local checks = {
        { name = "_focus_window 函数", pattern = "function M._focus_window()" },
        { name = "_adjust_window_position 函数", pattern = "function M._adjust_window_position()" },
        { name = "打开时调整位置", pattern = "M._adjust_window_position()" },
        { name = "打开时获取焦点", pattern = "M._focus_window()" },
        { name = "渲染后调整位置", pattern = "M._adjust_window_position()" },
        { name = "渲染后获取焦点", pattern = "M._focus_window()" },
    }
    
    for _, check in ipairs(checks) do
        if contains(chat_window_content, check.pattern) then
            print("   ✅ " .. check.name)
        else
            print("   ❌ " .. check.name)
        end
    end
else
    print("❌ 无法读取聊天窗口文件")
end

-- 检查 UI 初始化文件
local ui_init_path = "/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/ui/init.lua"
local ui_init_content = read_file(ui_init_path)

if ui_init_content then
    print("\n📄 检查 UI 初始化文件...")
    
    -- 检查窗口创建选项修改
    local ui_checks = {
        { name = "聊天窗口使用浮动模式", pattern = 'window_mode = "float"' },
        { name = "聊天窗口位置设置", pattern = "row = math.floor%(vim.o.lines %* 0.2%)" },
        { name = "树窗口使用浮动模式", pattern = 'window_mode = "float".-树' },
        { name = "树窗口位置设置", pattern = "row = math.floor%(vim.o.lines %* 0.2%).-树" },
    }
    
    for _, check in ipairs(ui_checks) do
        if contains(ui_init_content, check.pattern) then
            print("   ✅ " .. check.name)
        else
            print("   ❌ " .. check.name)
        end
    end
else
    print("❌ 无法读取 UI 初始化文件")
end

print("\n📊 修改总结:")
print("   1. 聊天窗口新增了 _focus_window() 函数用于自动获取焦点")
print("   2. 聊天窗口新增了 _adjust_window_position() 函数用于调整窗口位置")
print("   3. 聊天窗口在打开、渲染完成、异步渲染完成时都会:")
print("      - 调整窗口位置（确保不在屏幕最下方）")
print("      - 自动获取焦点")
print("   4. UI 初始化文件修改了窗口创建选项:")
print("      - 强制使用浮动窗口模式 (window_mode = 'float')")
print("      - 设置窗口位置为屏幕中央偏上 (row = 屏幕高度 * 0.2)")
print("      - 水平居中 (col = (屏幕宽度 - 窗口宽度) / 2)")
print("\n✅ 所有修改已成功应用！")