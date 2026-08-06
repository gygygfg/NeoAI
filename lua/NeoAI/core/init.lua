--- NeoAI 核心业务层入口
--- @module NeoAI.core
--- 依赖：kernel + utils。向上（services）暴露模块引用。
--- 本层只做模块编排，不含具体业务逻辑。

local M = {}

--- 核心子模块引用（懒加载，避免初始化时加载全部）
M.session = {
  session = require("NeoAI.core.session.session"),
  session_store = require("NeoAI.core.session.session_store"),
  context_builder = require("NeoAI.core.session.context_builder"),
}
M.model = {
  registry = require("NeoAI.core.model.registry"),
  fetcher = require("NeoAI.core.model.fetcher"),
  adapter = require("NeoAI.core.model.adapter"),
  cache = require("NeoAI.core.model.cache"),
}
M.agent = {
  runtime = require("NeoAI.core.agent.runtime"),
  request = require("NeoAI.core.agent.request"),
  stream = require("NeoAI.core.agent.stream"),
  tool_loop = require("NeoAI.core.agent.tool_loop"),
}

return M
