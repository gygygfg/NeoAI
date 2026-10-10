local a = require("NeoAI._probe2.a")

--- @param d ProbeDef
local function use(d)
	d:resolve(1)
	d:then_(function() end, nil)
	d:then_(nil, function() end)
	if d._state == "resolved" then
		local v = d._value
		print(v)
	end
end

local x = a.make()
use(x)
x:then_(nil, nil)

return use
