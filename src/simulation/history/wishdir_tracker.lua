local PlayerTick = require("simulation.player_tick")
local PredictionContext = require("simulation.prediction_context")

local WishdirTracker = {}

local state = {}
local MAX_TRACKED = 4
local EXPIRY_TICKS = 132

local DIRECTIONS = {
	{ name = "forward", x = 1, y = 0 },
	{ name = "forwardright", x = 1, y = 1 },
	{ name = "right", x = 0, y = 1 },
	{ name = "backright", x = -1, y = 1 },
	{ name = "back", x = -1, y = 0 },
	{ name = "backleft", x = -1, y = -1 },
	{ name = "left", x = 0, y = -1 },
	{ name = "forwardleft", x = 1, y = -1 },
	{ name = "coasting", x = nil, y = nil },
}

local function normalizeDirection(x, y)
	if not x or not y then
		return nil
	end
	local len = math.sqrt(x * x + y * y)
	if len < 0.0001 then
		return Vector3(0, 0, 0)
	end
	return Vector3(x / len, y / len, 0)
end

local function getEntityYaw(entity)
	if not entity then
		return nil
	end
	local yaw = entity:GetPropFloat("m_angEyeAngles[1]")
	if yaw then
		return yaw
	end
	if entity.GetPropVector and type(entity.GetPropVector) == "function" then
		local eyeVec = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles")
		if eyeVec and eyeVec.y then
			return eyeVec.y
		end
	end
	local vel = entity:EstimateAbsVelocity()
	if vel and vel:Length2D() > 1 then
		local ang = vel:Angles()
		if ang and ang.y then
			return ang.y
		end
	end
	return nil
end

local function shouldPrune(entry)
	if not entry then
		return true
	end
	return (globals.TickCount() - entry.lastTick) > EXPIRY_TICKS
end

-- REMOVED: simulateAllDirections - will be hooked up to local player prediction later

-- REMOVED: findClosestPrediction - will be hooked up to local player prediction later

function WishdirTracker.update(entity)
	-- Keep basic tracking for history but no prediction
	if not entity or not entity:IsAlive() or entity:IsDormant() then
		return
	end

	local idx = entity:GetIndex()
	if not state[idx] then
		state[idx] = {}
	end
	local s = state[idx]

	local currentPos = entity:GetAbsOrigin()
	if not currentPos then
		return
	end

	local currentYaw = getEntityYaw(entity)
	if not currentYaw then
		return
	end

	-- Store basic position/yaw history for later hookup
	s.lastPos = currentPos
	s.lastYaw = currentYaw
	s.lastTick = globals.TickCount()
end

-- REMOVED: snapVelocityToClosestDirection and getRelativeWishdir
-- These will be hooked up to local player prediction later

function WishdirTracker.getRelativeWishdir(entity)
	-- Return nil - no prediction for enemies, only history collection
	return nil
end

---Update tracker for a provided, pre-sorted list of entities (nearest/top).
---@param pLocal Entity
---@param sortedEntities Entity[]
---@param maxTargets integer
function WishdirTracker.updateTop(pLocal, sortedEntities, maxTargets)
	assert(pLocal, "WishdirTracker.updateTop: pLocal is nil")
	assert(sortedEntities, "WishdirTracker.updateTop: sortedEntities is nil")

	maxTargets = maxTargets or MAX_TRACKED

	local keep = {}
	for i = 1, math.min(maxTargets, #sortedEntities) do
		local ent = sortedEntities[i]
		if ent and ent:IsAlive() and not ent:IsDormant() and ent ~= pLocal then
			keep[ent:GetIndex()] = true
			WishdirTracker.update(ent)
		end
	end

	for idx, entry in pairs(state) do
		if not keep[idx] or shouldPrune(entry) then
			state[idx] = nil
		end
	end
end

function WishdirTracker.clearAllHistory()
	state = {}
end

return WishdirTracker
