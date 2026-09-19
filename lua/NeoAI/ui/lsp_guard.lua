--- NeoAI 界面 buffer 的 LSP 隔离
--- @module NeoAI.ui.lsp_guard
--- 阻止 LSP 客户端（native LSP / GitHub Copilot 等）挂载到 NeoAI 界面 buffer。
--- NeoAI 的聊天/输入框/悬浮窗等都是纯 UI 文本，挂上 LSP 后 `document_color` /
--- `folding_range` / `semantic_tokens` / `inline_completion`（Copilot）会持续空耗 CPU。
---
--- 识别方式：NeoAI 的所有界面 buffer 都设置 `neoai*` filetype（或已打 `b:neoai_ui` 标记）。
--- 三层拦截：
---   0. 一次性把 `neoai*` 加入 `g:copilot_filetypes`（值空 = 禁用），使 copilot.vim 从源头
---      就不 attach/启动 language server——避免「先 attach 再被解绑」造成的启动/退出开销；
---   1. `FileType neoai*`：设置时立即关闭（覆盖所有创建路径，含绕过窗口管理器的组件）；
---   2. `LspAttach`：兜底解绑异步/延迟挂载的客户端。
--- 同时逐 buffer 关闭 Copilot（`b:copilot_disabled` / `b:copilot_disable` / `b:copilot_enabled`）。

local M = {}

-- ========== 私有常量 ==========

-- NeoAI 界面 buffer 使用的 filetype（供 copilot.vim 的 g:copilot_filetypes 精确禁用）。
-- 新增 neoai* filetype 时同步补充；FileType 拦截仍按前缀 `neoai*` 兜底。
local COPILOT_FILETYPES = {
  "neoai", "neoai_input", "neoai_reasoning", "neoai_tool_args", "neoai_context_op",
  "neoai_ask_user", "neoai_approval", "neoai_model_picker", "neoai_root_prompt",
  "neoai_sandbox_diff", "neoai_sandbox_review", "neoai_subagents", "neoai_traj_path",
}

-- ========== 私有状态 ==========

local GROUP = "NeoAILspGuard"
local installed = false
local saved_copilot_filetypes = nil

-- ========== 私有函数 ==========

--- buffer 是否为 NeoAI 界面（已标记，或 filetype 前缀为 neoai）
--- @param buf number
--- @return boolean
local function _is_neoai(buf)
  if vim.b[buf] and vim.b[buf].neoai_ui then return true end
  local ft = vim.bo[buf].filetype
  return type(ft) == "string" and ft:sub(1, 5) == "neoai"
end

-- ========== 公开 API ==========

--- 对单个 buffer 关闭 LSP / Copilot，并解绑已挂载的 native LSP 客户端。
--- @param buf number
function M.disable(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  M.install()
  vim.b[buf].neoai_ui = true
  -- nofile 阻断 native LSP 的自动启动（其仅在 buftype 为 '' / help 时启动客户端）。
  -- 仅当为普通 buftype 时设置：保留 nofile/acwrite（轨迹模式 :w 保存依赖 acwrite，
  -- 其同样不是 ''/help，本就不会触发 native LSP 自动启用）。
  if vim.bo[buf].buftype == "" then
    pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = buf })
  end
  -- Copilot：copilot.vim 读 b:copilot_disabled；copilot.lua 读 b:copilot_disable / b:copilot_enabled
  vim.b[buf].copilot_disabled = true
  vim.b[buf].copilot_disable = true
  vim.b[buf].copilot_enabled = false
  local ok, clients = pcall(vim.lsp.get_clients, { bufnr = buf })
  if ok and type(clients) == "table" then
    for _, client in ipairs(clients) do
      pcall(vim.lsp.buf_detach_client, buf, client.id)
    end
  end
end

--- 安装全局拦截（幂等）。由 `NeoAI.ui.init` 调用。
function M.install()
  if installed then return end
  installed = true
  -- copilot.vim 用 g:copilot_filetypes 判定逐 filetype 禁用（值空 = 禁用）。一次性合并写入，
  -- 使 NeoAI 界面 buffer 从源头不 attach（nofile 不在其内置禁用列表里）。
  pcall(function()
    if type(vim.g.copilot_filetypes) == "table" then
      saved_copilot_filetypes = vim.deepcopy(vim.g.copilot_filetypes)
    else
      saved_copilot_filetypes = {}
    end
    local merged = vim.deepcopy(saved_copilot_filetypes)
    for _, ft in ipairs(COPILOT_FILETYPES) do merged[ft] = false end
    vim.g.copilot_filetypes = merged
  end)
  vim.api.nvim_create_augroup(GROUP, { clear = true })
  -- 所有 NeoAI 界面 buffer 都设置 neoai* filetype；在此统一关闭 LSP/Copilot
  vim.api.nvim_create_autocmd("FileType", {
    group = GROUP,
    pattern = "neoai*",
    callback = function(args)
      M.disable(args.buf)
    end,
  })
  -- 兜底：延迟/异步挂载的客户端（含 Copilot）在 attach 后立即解绑
  vim.api.nvim_create_autocmd("LspAttach", {
    group = GROUP,
    callback = function(args)
      local buf = args.buf
      if not _is_neoai(buf) then return end
      local client_id = args.data and args.data.client_id
      if not client_id then return end
      -- schedule 解绑：等客户端 attach 流程同步跑完再拆，避免其流程内再次挂载
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.lsp.buf_detach_client, buf, client_id)
        end
      end)
    end,
  })
  -- 安装前已存在的 NeoAI buffer（如会话恢复出的窗口）
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and _is_neoai(buf) then M.disable(buf) end
  end
end

--- 卸载拦截（插件卸载/测试重置）
function M.uninstall()
  if not installed then return end
  installed = false
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  if saved_copilot_filetypes ~= nil then
    if next(saved_copilot_filetypes) == nil then
      pcall(function() vim.g.copilot_filetypes = nil end)
    else
      pcall(function() vim.g.copilot_filetypes = saved_copilot_filetypes end)
    end
    saved_copilot_filetypes = nil
  end
end

--- 重置（测试用）
function M.reset()
  M.uninstall()
end

return M
