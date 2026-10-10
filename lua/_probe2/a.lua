--- @module 'NeoAI._probe2.a'
local M = {}

--- @class ProbeDef
--- @field _state 'pending'|'resolved'
--- @field _value any
--- @field then_ fun(self: ProbeDef, on_fulfilled: function|nil, on_rejected: function|nil): ProbeDef
--- @field resolve fun(self: ProbeDef, value: any): ProbeDef
local ProbeDef = {}
ProbeDef.__index = ProbeDef

--- @return ProbeDef
function ProbeDef.new()
	local self = setmetatable({}, ProbeDef)
	self._state = "pending"
	self._value = nil
	return self
end

function ProbeDef:resolve(value)
	if self._state ~= "pending" then return self end
	self._state = "resolved"
	self._value = value
	return self
end

function ProbeDef:then_(on_fulfilled, on_rejected)
	return self
end

M.ProbeDef = ProbeDef

--- @return ProbeDef
function M.make()
	return ProbeDef.new()
end

return M
