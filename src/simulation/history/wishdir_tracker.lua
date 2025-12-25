-- ============================================================================
-- WISHDIR TRACKER - 9-Direction Prediction System
-- ============================================================================
-- Predicts enemy movement by testing 9 possible inputs each tick:
--   8 directions (forward, back, left, right, 4 diagonals) + coasting (no input)
--
-- Algorithm:
--   1. Each tick, simulate 1 tick ahead for all 9 possible wishdirs
--   2. Store these 9 predictions
--   3. Next tick, compare actual position/velocity to stored predictions
--   4. The closest prediction = the player's actual wishdir
--   5. Fallback: if no prior prediction, clamp current velocity to 8 directions
-- ============================================================================

local PlayerTick = require("simulation.player_tick")
local PredictionContext = require("simulation.prediction_context")

local WishdirTracker = {}

-- Per-player state storage
local state = {}
local MAX_TRACKED = 4
local EXPIRY_TICKS = 66

local STILL_SPEED_THRESHOLD = 50
local COAST_BIAS_SPEED_THRESHOLD = 50
local COAST_ERROR_MULTIPLIER = 0.8

-- 9 possible movement directions (relative to player yaw)
-- x = forward/back component, y = left/right component
local DIRECTIONS = {
	{ name = "forward", x = 1, y = 0 },
	{ name = "forwardright", x = 1, y = -1 },
	{ name = "right", x = 0, y = -1 },
	{ name = "backright", x = -1, y = -1 },
	{ name = "back", x = -1, y = 0 },
	{ name = "backleft", x = -1, y = 1 },
	{ name = "left", x = 0, y = 1 },
	{ name = "forwardleft", x = 1, y = 1 },
	{ name = "coast", x = 0, y = 0 }, -- No input (coasting)
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function normalizeDirection(x, y)
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
	return nil
end

local function shouldPrune(entry)
	if not entry then
		return true
	end
	return (globals.TickCount() - entry.lastTick) > EXPIRY_TICKS
end

-- Clamp velocity to nearest of 8 directions (fallback when no prior prediction)
local function clampVelocityTo8Directions(velocity, yaw)
	local horizLen = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if horizLen < STILL_SPEED_THRESHOLD then
		return Vector3(0, 0, 0) -- Standing still
	end

	-- Convert velocity to relative direction (relative to yaw)
	local yawRad = yaw * (math.pi / 180)
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	-- Forward and right vectors in world space
	local forwardX, forwardY = cosYaw, sinYaw
	local rightX, rightY = sinYaw, -cosYaw

	-- Project velocity onto forward/right
	local velNormX = velocity.x / horizLen
	local velNormY = velocity.y / horizLen
	local relForward = forwardX * velNormX + forwardY * velNormY
	local relRight = rightX * velNormX + rightY * velNormY

	-- Snap to nearest 45-degree direction
	local snapX = 0
	local snapY = 0
	if relForward > 0.3 then
		snapX = 1
	elseif relForward < -0.3 then
		snapX = -1
	end
	if relRight > 0.3 then
		snapY = -1
	elseif relRight < -0.3 then
		snapY = 1
	end

	return normalizeDirection(snapX, snapY)
end

-- ============================================================================
-- CORE PREDICTION SYSTEM
-- ============================================================================

-- Simulate 1 tick ahead for a single direction
local function simulateOneDirection(entity, simCtx, dirX, dirY)
	local velocity = entity:EstimateAbsVelocity()
	local origin = entity:GetAbsOrigin()
	local maxspeed = entity:GetPropFloat("m_flMaxspeed")
	local mins, maxs = entity:GetMins(), entity:GetMaxs()
	local yaw = getEntityYaw(entity) or 0

	if not (velocity and origin and maxspeed and mins and maxs) then
		return nil
	end

	-- Create wishdir from direction components
	local wishdir = normalizeDirection(dirX, dirY)

	-- Build temporary player context for simulation
	local playerCtx = {
		entity = entity,
		origin = Vector3(origin.x, origin.y, origin.z + 1),
		velocity = Vector3(velocity:Unpack()),
		mins = mins,
		maxs = maxs,
		maxspeed = maxspeed,
		index = entity:GetIndex(),
		stepheight = 18,
		yaw = yaw,
		yawDeltaPerTick = 0,
		relativeWishDir = wishdir,
	}

	-- Simulate one tick
	local predictedPos = PlayerTick.simulateTick(playerCtx, simCtx)
	local predictedVel = Vector3(playerCtx.velocity:Unpack())

	return {
		pos = predictedPos,
		vel = predictedVel,
		wishdir = wishdir,
		dirName = nil,
	}
end

-- Simulate all 9 directions for a player
local function simulateAllDirections(entity, simCtx)
	local predictions = {}

	for i, dir in ipairs(DIRECTIONS) do
		local pred = simulateOneDirection(entity, simCtx, dir.x, dir.y)
		if pred then
			pred.dirName = dir.name
			predictions[i] = pred
		end
	end

	return predictions
end

-- Find which prediction best matches current state
local function findBestMatchingPrediction(predictions, currentPos, currentVel)
	assert(predictions, "findBestMatchingPrediction: predictions is nil")
	assert(currentPos, "findBestMatchingPrediction: currentPos is nil")
	assert(currentVel, "findBestMatchingPrediction: currentVel is nil")

	if not predictions or #predictions == 0 then
		return nil
	end

	local curHorizLen = math.sqrt(currentVel.x * currentVel.x + currentVel.y * currentVel.y)

	local bestIdx = nil
	local bestError = math.huge

	for i, pred in ipairs(predictions) do
		if pred and pred.pos and pred.vel then
			local posDx = currentPos.x - pred.pos.x
			local posDy = currentPos.y - pred.pos.y
			local posDiff = math.sqrt(posDx * posDx + posDy * posDy)

			local velDx = currentVel.x - pred.vel.x
			local velDy = currentVel.y - pred.vel.y
			local velDiff = math.sqrt(velDx * velDx + velDy * velDy)

			local totalError = posDiff + velDiff * 0.1
			if pred.dirName == "coast" and curHorizLen < COAST_BIAS_SPEED_THRESHOLD then
				totalError = totalError * COAST_ERROR_MULTIPLIER
			end

			if totalError < bestError then
				bestError = totalError
				bestIdx = i
			end
		end
	end

	if bestIdx and predictions[bestIdx] then
		return predictions[bestIdx].wishdir, bestError
	end
	return nil
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

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
	local currentVel = entity:EstimateAbsVelocity()
	local currentYaw = getEntityYaw(entity)

	if not (currentPos and currentVel and currentYaw) then
		return
	end

	s.detectedWishdir = nil
	s.detectionError = nil

	-- Step 1: If we have prior predictions, find which one matches best
	if s.predictions and s.predictionTick == globals.TickCount() - 1 then
		local bestWishdir, error = findBestMatchingPrediction(s.predictions, currentPos, currentVel)
		if bestWishdir then
			s.detectedWishdir = bestWishdir
			s.detectionError = error
		end
	end

	if not s.detectedWishdir then
		s.detectedWishdir = clampVelocityTo8Directions(currentVel, currentYaw)
		s.detectionError = nil
	end

	-- Step 2: Simulate all 9 directions for next tick comparison
	local simCtx = PredictionContext.createSimulationContext()
	if simCtx then
		s.predictions = simulateAllDirections(entity, simCtx)
		s.predictionTick = globals.TickCount()
	end

	-- Store current state
	s.lastPos = currentPos
	s.lastVel = currentVel
	s.lastYaw = currentYaw
	s.lastTick = globals.TickCount()
end

-- Get the detected relative wishdir for an entity
-- Returns Vector3 wishdir or nil if unknown
function WishdirTracker.getRelativeWishdir(entity)
	if not entity then
		return nil
	end

	local idx = entity:GetIndex()
	local s = state[idx]

	-- If we have a recent detected wishdir, use it
	if s and s.detectedWishdir and s.lastTick == globals.TickCount() then
		return s.detectedWishdir
	end

	-- Fallback: clamp current velocity to 8 directions
	if s and s.lastVel and s.lastYaw and s.lastTick == globals.TickCount() then
		return clampVelocityTo8Directions(s.lastVel, s.lastYaw)
	end

	return nil
end

---Update tracker for a provided list of entities
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

	-- Prune old entries
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
