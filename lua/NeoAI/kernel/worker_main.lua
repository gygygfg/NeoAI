--- 后台 worker 入口（由 `nvim -l .../worker_main.lua` 执行）
--- @module 'NeoAI.kernel.worker_main'
--- 不加载 NeoAI 插件/配置；只启动任务 RPC server。

local ok, err = pcall(function()
  local root = vim.env.NEOAI_PLUGIN_ROOT
  if type(root) == "string" and root ~= "" then
    vim.opt.rtp:append(root)
  end
  require("NeoAI.kernel.worker_server").main()
end)
if not ok then
  pcall(function() io.stderr:write("[neoai-worker] fatal: " .. tostring(err) .. "\n") end)
  os.exit(1)
end
