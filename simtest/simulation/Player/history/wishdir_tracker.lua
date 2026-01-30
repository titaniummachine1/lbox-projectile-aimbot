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

local PlayerTick = require("simulation.Player.player_tick")
local PredictionContext = require("simulation.Player.prediction_context")

local WishdirTracker = {}

local localWishdir = nil
local localWishdirTick = -1

-- [[ POOLING LOGIC ]]
local vectorPool = {}
local function getPooledVector(x, y, z)
	local v = table.remove(vectorPool)
	if v then
		v.x, v.y, v.z = x, y, z
		return v
	end
	return Vector3(x, y, z)
end
local function releaseVector(v)
	if v then
		table.insert(vectorPool, v)
	end
end

local predPool = {}
local function getPooledPred()
	local p = table.remove(predPool)
	if p then
		return p
	end
	-- Initialize with dedicated vectors that stay within this prediction object
	return {
		pos = Vector3(0, 0, 0),
		vel = Vector3(0, 0, 0),
		wishdir = Vector3(0, 0, 0),
		name = "",
	}
end
local function releasePred(p)
	if p then
		table.insert(predPool, p)
	end
end

-- Per-player state storage
local playerState = {}
local MAX_TRACKED = 4
local EXPIRY_TICKS = 66
local STILL_SPEED_THRESHOLD = 50

local DIRECTIONS = {
	{ name = "forward", x = 1, y = 0 },
	{ name = "forwardleft", x = 1, y = 1 },
	{ name = "left", x = 0, y = 1 },
	{ name = "backleft", x = -1, y = 1 },
	{ name = "back", x = -1, y = 0 },
	{ name = "backright", x = -1, y = -1 },
	{ name = "right", x = 0, y = -1 },
	{ name = "forwardright", x = 1, y = -1 },
	{ name = "coast", x = 0, y = 0 },
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function normalizeDirection(x, y, out)
	local len = math.sqrt(x * x + y * y)
	if len < 0.0001 then
		out.x, out.y, out.z = 0, 0, 0
	else
		out.x, out.y, out.z = x / len, y / len, 0
	end
	return out
end

local function getEntityYaw(entity)
	if not entity then
		return nil
	end
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer and entity:GetIndex() == localPlayer:GetIndex() then
		local angles = engine.GetViewAngles()
		if angles then
			return angles.y
		end
	end
	return entity:GetPropFloat("m_angEyeAngles[1]")
end

-- Clamp velocity to nearest of 8 directions (fallback when no prior prediction)
local function clampVelocityTo8Directions(velocity, yaw, out)
	local horizLen = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if horizLen < STILL_SPEED_THRESHOLD then
		out.x, out.y, out.z = 0, 0, 0
		return out
	end

	local yawRad = yaw * (math.pi / 180)
	local cosYaw, sinYaw = math.cos(yawRad), math.sin(yawRad)
	local velNormX, velNormY = velocity.x / horizLen, velocity.y / horizLen

	-- Project velocity onto forward/left relative to player yaw
	local relForward = cosYaw * velNormX + sinYaw * velNormY
	local relLeft = -sinYaw * velNormX + cosYaw * velNormY

	local snapX, snapY = 0, 0
	if relForward > 0.3 then
		snapX = 1
	elseif relForward < -0.3 then
		snapX = -1
	end
	if relLeft > 0.3 then
		snapY = 1
	elseif relLeft < -0.3 then
		snapY = -1
	end

	return normalizeDirection(snapX, snapY, out)
end

-- ============================================================================
-- CORE PREDICTION SYSTEM
-- ============================================================================

-- Static player context for reuse in simulations
local staticPlayerCtx = {
	origin = getPooledVector(0, 0, 0),
	velocity = getPooledVector(0, 0, 0),
	mins = getPooledVector(0, 0, 0),
	maxs = getPooledVector(0, 0, 0),
	relativeWishDir = getPooledVector(0, 0, 0),
}

-- Simulate 1 tick ahead for a single direction
local function simulateOneDirection(entity, simCtx, dir, outPred)
	local vel = entity:EstimateAbsVelocity()
	local pos = entity:GetAbsOrigin()
	if not (vel and pos) then
		return false
	end

	local mins, maxs = entity:GetMins(), entity:GetMaxs()
	local yaw = getEntityYaw(entity) or 0
	local StrafePredictor = require("simulation.Player.history.strafe_predictor")
	local yawDelta = StrafePredictor.getYawDeltaPerTickDegrees(entity:GetIndex(), 3)

	-- Update static context
	staticPlayerCtx.entity = entity
	staticPlayerCtx.origin.x, staticPlayerCtx.origin.y, staticPlayerCtx.origin.z = pos.x, pos.y, pos.z + 1
	staticPlayerCtx.velocity.x, staticPlayerCtx.velocity.y, staticPlayerCtx.velocity.z = vel.x, vel.y, vel.z
	staticPlayerCtx.mins.x, staticPlayerCtx.mins.y, staticPlayerCtx.mins.z = mins.x, mins.y, mins.z
	staticPlayerCtx.maxs.x, staticPlayerCtx.maxs.y, staticPlayerCtx.maxs.z = maxs.x, maxs.y, maxs.z
	staticPlayerCtx.maxspeed = entity:GetPropFloat("m_flMaxspeed")
	staticPlayerCtx.index = entity:GetIndex()
	staticPlayerCtx.stepheight = 18
	staticPlayerCtx.yaw = yaw
	staticPlayerCtx.yawDeltaPerTick = yawDelta
	normalizeDirection(dir.x, dir.y, staticPlayerCtx.relativeWishDir)

	-- Simulate
	PlayerTick.simulateTick(staticPlayerCtx, simCtx)

	outPred.pos.x, outPred.pos.y, outPred.pos.z =
		staticPlayerCtx.origin.x, staticPlayerCtx.origin.y, staticPlayerCtx.origin.z
	outPred.vel.x, outPred.vel.y, outPred.vel.z =
		staticPlayerCtx.velocity.x, staticPlayerCtx.velocity.y, staticPlayerCtx.velocity.z
	outPred.wishdir.x, outPred.wishdir.y, outPred.wishdir.z =
		staticPlayerCtx.relativeWishDir.x, staticPlayerCtx.relativeWishDir.y, staticPlayerCtx.relativeWishDir.z
	outPred.name = dir.name
	return true
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function WishdirTracker.update(entity)
	if not entity or not entity:IsAlive() or entity:IsDormant() then
		return
	end
	local idx = entity:GetIndex()
	if not playerState[idx] then
		playerState[idx] = { predictions = {} }
		for i = 1, 9 do
			playerState[idx].predictions[i] = getPooledPred()
		end
	end
	local s = playerState[idx]
	local curPos, curVel = entity:GetAbsOrigin(), entity:EstimateAbsVelocity()
	local yaw = getEntityYaw(entity)
	if not (curPos and curVel and yaw) then
		return
	end

	-- Compare with previous predictions
	if not s.detectedWishdir then
		s.detectedWishdir = Vector3(0, 0, 0)
	end
	local matched = false
	if s.predictionTick == globals.TickCount() - 1 then
		local bestErr, bestIdx = 1e9, 0
		for i = 1, 9 do
			local p = s.predictions[i]
			local dx, dy = curPos.x - p.pos.x, curPos.y - p.pos.y
			local dvx, dvy = curVel.x - p.vel.x, curVel.y - p.vel.y
			-- Error metric: Pos + Vel
			local err = math.sqrt(dx * dx + dy * dy) + math.sqrt(dvx * dvx + dvy * dvy) * 0.25
			if err < bestErr then
				bestErr = err
				bestIdx = i
			end
		end
		if bestIdx > 0 then
			local p = s.predictions[bestIdx]
			s.detectedWishdir.x, s.detectedWishdir.y, s.detectedWishdir.z = p.wishdir.x, p.wishdir.y, p.wishdir.z
			matched = true
		end
	end

	if not matched then
		clampVelocityTo8Directions(curVel, yaw, s.detectedWishdir)
	end

	-- Prepare for next tick
	local simCtx = PredictionContext.createSimulationContext()
	for i = 1, 9 do
		simulateOneDirection(entity, simCtx, DIRECTIONS[i], s.predictions[i])
	end
	s.predictionTick = globals.TickCount()
	s.lastTick = globals.TickCount()
	s.lastVelYaw = { x = curVel.x, y = curVel.y, yaw = yaw }
end

-- Get the detected relative wishdir for an entity
-- Returns Vector3 wishdir or nil if unknown
function WishdirTracker.getRelativeWishdir(entity)
	if not entity then
		return nil
	end
	local idx = entity:GetIndex()

	-- Handle Local Player CMD Override
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer and idx == localPlayer:GetIndex() then
		if localWishdir and localWishdirTick == globals.TickCount() then
			return localWishdir
		end
	end

	local s = playerState[idx]
	if s and s.lastTick == globals.TickCount() then
		return s.detectedWishdir
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
	local active = {}

	-- Inclusion: Local player always tracked for self-prediction
	if pLocal and pLocal:IsAlive() then
		active[pLocal:GetIndex()] = true
		WishdirTracker.update(pLocal)
	end

	for i = 1, math.min(maxTargets, #sortedEntities) do
		local ent = sortedEntities[i]
		if ent and ent:IsAlive() and not ent:IsDormant() then
			active[ent:GetIndex()] = true
			WishdirTracker.update(ent)
		end
	end

	for idx, s in pairs(playerState) do
		if not active[idx] or (globals.TickCount() - s.lastTick) > EXPIRY_TICKS then
			if s.predictions then
				for i = 1, 9 do
					releasePred(s.predictions[i])
				end
			end
			-- s.detectedWishdir is a Vector3, if we wanted to pool it we could,
			-- but for now we'll just let GC handle it or keep it in the state object.
			playerState[idx] = nil
		end
	end
end

function WishdirTracker.clearAllHistory()
	for idx, s in pairs(playerState) do
		if s.predictions then
			for i = 1, 9 do
				releasePred(s.predictions[i])
			end
		end
		if s.detectedWishdir then
			releaseVector(s.detectedWishdir)
		end
	end
	playerState = {}
	-- Also clear static context vectors
	releaseVector(staticPlayerCtx.origin)
	releaseVector(staticPlayerCtx.velocity)
	releaseVector(staticPlayerCtx.mins)
	releaseVector(staticPlayerCtx.maxs)
	releaseVector(staticPlayerCtx.relativeWishDir)
end

return WishdirTracker
