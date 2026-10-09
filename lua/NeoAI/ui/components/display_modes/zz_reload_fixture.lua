_G.__NEOAI_FIXTURE_LOADS = (_G.__NEOAI_FIXTURE_LOADS or 0) + 1
local manager = require("NeoAI.ui.components.display_modes")
local M = { name = "zz_reload_fixture", label = "ReloadFixture", desc = "v1" }
function M.load(host) if host then host.set_foldexpr(function() return "0" end) end end
function M.unload(host) if host then host.set_foldexpr(nil) end end
manager.register(M)
return M
