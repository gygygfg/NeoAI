--- 进程环境探测工具
--- @module 'NeoAI.utils.env'
--- 纯工具模块，无业务依赖。

local M = {}

--- 当前 Neovim 是否运行在 NeoAI 沙箱内。
--- `run_command` 等外部进程经 `runtime.sandbox_env` 注入 `NEOAI_SANDBOX=1`，该标记随环境
--- 被沙箱内启动的嵌套 Neovim 继承。嵌套 NeoAI 据此跳过**自动**外部操作（如启动时刷新
--- 服务商模型列表），避免其写入被沙箱当作待审变更捕获。
--- @return boolean
function M.in_sandbox()
  return vim.env.NEOAI_SANDBOX == "1"
end

--- 规整 `jobstart`/`vim.system` 的 env 选项：Neovim 不接受空表（报 `E475: Invalid argument: env`），
--- 空表时返回 nil 以继承父进程环境（等价于「清空自定义环境」的合理语义）。
--- @param env table|nil
--- @return table|nil
function M.for_jobstart(env)
  if type(env) == "table" and next(env) == nil then return nil end
  return env
end

return M
