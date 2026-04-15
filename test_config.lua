-- 测试新的配置模式
local config = require("NeoAI.config")
local backend = require("NeoAI.backend")
local ui = require("NeoAI.ui")

print("=== 测试配置验证和合并 ===")

-- 测试用户配置
local user_config = {
  ui = {
    default_mode = "float",
    width = 70,
  },
  llm = {
    api_key = "test-key",
    model = "test-model",
  }
}

-- 验证和合并配置
local validated_config, errors = config.validate_and_merge(user_config)

print("验证后的配置:")
vim.print(validated_config)

if errors and #errors > 0 then
  print("验证错误:")
  for _, err in ipairs(errors) do
    print("  - " .. err)
  end
end

-- 测试后端初始化
print("\n=== 测试后端初始化 ===")
backend.setup({
  config_dir = validated_config.background.config_dir,
  config_file = validated_config.background.config_file,
  llm = validated_config.llm,
})

print("后端配置目录: " .. (backend.config_dir or "nil"))
print("后端配置文件: " .. (backend.config_file or "nil"))
print("后端 LLM 配置存在: " .. tostring(backend.llm_config ~= nil))

-- 测试 UI 初始化
print("\n=== 测试 UI 初始化 ===")
ui.setup(validated_config)

print("UI 配置存在: " .. tostring(ui.config ~= nil))
if ui.config then
  print("UI 默认模式: " .. (ui.config.ui.default_mode or "nil"))
  print("UI 宽度: " .. tostring(ui.config.ui.width))
end

print("\n=== 测试完成 ===")