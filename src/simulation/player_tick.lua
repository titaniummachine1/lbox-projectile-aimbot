local GameConstants = require("constants.game_constants")

local PlayerTick = {}

local DEG2RAD = math.pi / 180
local RAD2DEG = 180 / math.pi

local function getConVarNumber(name, fallback)
	assert(name, "getConVarNumber: name is nil")
	local ok, value = client.GetConVar(name)
	if ok and type(value) == "number" then
		return value
	end
	return fallback
end

local function length2D(vec)
	assert(vec, "length2D: vec is nil")
	return math.sqrt(vec.x * vec.x + vec.y * vec.y)
end

return PlayerTick
