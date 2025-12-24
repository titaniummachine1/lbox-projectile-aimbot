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

local function simulateAllDirections(entity, yaw)
	assert(entity, "simulateAllDirections: entity is nil")
	assert(yaw, "simulateAllDirections: yaw is nil")

	local predictions = {}
	local simCtx = PredictionContext.createSimulationContext()

	for _, dir in ipairs(DIRECTIONS) do
		local relWishDir = nil
		if dir.x and dir.y then
			relWishDir = normalizeDirection(dir.x, dir.y)
		end

		local playerCtx = PredictionContext.createPlayerContext(entity, 1.0, relWishDir)
		playerCtx.yaw = yaw
		playerCtx.yawDeltaPerTick = 0

		local predictedPos = PlayerTick.simulateTick(playerCtx, simCtx)

		predictions[dir.name] = {
			position = predictedPos,
			relWishDir = relWishDir,
		}
	end

	return predictions
end

local function findClosestPrediction(actualPos, predictions)
	assert(actualPos, "findClosestPrediction: actualPos is nil")
	assert(predictions, "findClosestPrediction: predictions is nil")

	local closestName = nil
	local closestDistSq = math.huge

	for name, pred in pairs(predictions) do
		local predPos = pred.position
		local dx = actualPos.x - predPos.x
		local dy = actualPos.y - predPos.y
		local dz = actualPos.z - predPos.z
		local distSq = dx * dx + dy * dy + dz * dz

		if distSq < closestDistSq then
			closestDistSq = distSq
			closestName = name
		end
	end

	return closestName, closestDistSq
end

function WishdirTracker.update(entity)
	if not entity or not entity:IsAlive() or entity:IsDormant() then
		return
	end

	local idx = entity:GetIndex()
	if not state[idx] then
		state[idx] = {}
	end
	local s = state[idx]

	local currentPos = entity:GetAbsOrigin()
	assert(currentPos, "WishdirTracker.update: entity:GetAbsOrigin() returned nil")

	local currentYaw = getEntityYaw(entity)
	if not currentYaw then
		return
	end

	if s.predictions then
		local matchedDir, distSq = findClosestPrediction(currentPos, s.predictions)

		if matchedDir and s.predictions[matchedDir] then
			s.detectedRelWishDir = s.predictions[matchedDir].relWishDir
			s.detectedYaw = s.lastYaw
		end
	end

	s.predictions = simulateAllDirections(entity, currentYaw)
	s.lastYaw = currentYaw
	s.lastTick = globals.TickCount()
end

local function snapVelocityToClosestDirection(entity, yaw)
	local velocity = entity:EstimateAbsVelocity()
	if not velocity then
		return Vector3(1, 0, 0)
	end

	local horizLen = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if horizLen < 0.001 then
		return Vector3(1, 0, 0)
	end

	local yawRad = yaw * (math.pi / 180)
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local forward = Vector3(cosYaw, sinYaw, 0)
	local right = Vector3(sinYaw, -cosYaw, 0)

	local velNorm = Vector3(velocity.x / horizLen, velocity.y / horizLen, 0)

	local relX = forward.x * velNorm.x + forward.y * velNorm.y
	local relY = right.x * velNorm.x + right.y * velNorm.y

	local closestDir = nil
	local closestDot = -math.huge

	for _, dir in ipairs(DIRECTIONS) do
		if dir.x and dir.y then
			local normalized = normalizeDirection(dir.x, dir.y)
			if normalized then
				local dot = relX * normalized.x + relY * normalized.y
				if dot > closestDot then
					closestDot = dot
					closestDir = normalized
				end
			end
		end
	end

	return closestDir or Vector3(1, 0, 0)
end

function WishdirTracker.getRelativeWishdir(entity)
	if not entity then
		return nil
	end

	local idx = entity:GetIndex()
	local s = state[idx]

	if s and not shouldPrune(s) and s.detectedRelWishDir then
		return s.detectedRelWishDir
	end

	local yaw = getEntityYaw(entity)
	if not yaw then
		return nil
	end

	return snapVelocityToClosestDirection(entity, yaw)
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
