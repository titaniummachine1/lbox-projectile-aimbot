local GameConstants = require("constants.game_constants")
local StrafePredictor = require("simulation.history.strafe_predictor")

---@class PredictionContext
local PredictionContext = {}

-- ============================================================================
-- SECTION 1: SIMULATION CONTEXT
-- ============================================================================

---@class SimulationContext
---@field sv_gravity number
---@field sv_friction number
---@field sv_stopspeed number
---@field sv_accelerate number
---@field sv_airaccelerate number
---@field tickinterval number
---@field curtime number

---Creates a new simulation context with current cvars
---@return SimulationContext
function PredictionContext.createSimulationContext()
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local _, sv_friction = client.GetConVar("sv_friction")
	local _, sv_stopspeed = client.GetConVar("sv_stopspeed")
	local _, sv_accelerate = client.GetConVar("sv_accelerate")
	local _, sv_airaccelerate = client.GetConVar("sv_airaccelerate")

	local tickinterval = globals.TickInterval() or GameConstants.TICK_INTERVAL
	local curtime = globals.CurTime()

	return {
		sv_gravity = sv_gravity or GameConstants.SV_GRAVITY,
		sv_friction = sv_friction or GameConstants.SV_FRICTION,
		sv_stopspeed = sv_stopspeed or GameConstants.SV_STOPSPEED,
		sv_accelerate = sv_accelerate or GameConstants.SV_ACCELERATE,
		sv_airaccelerate = sv_airaccelerate or GameConstants.SV_AIRACCELERATE,
		tickinterval = tickinterval,
		curtime = curtime,
	}
end

-- ============================================================================
-- SECTION 2: PLAYER CONTEXT
-- ============================================================================

---@class PlayerContext
---@field entity Entity
---@field origin Vector3
---@field velocity Vector3
---@field mins Vector3
---@field maxs Vector3
---@field maxspeed number
---@field index integer
---@field stepheight number
---@field yaw number Current eye yaw angle in degrees
---@field yawDeltaPerTick number Strafe angle change per tick in degrees
---@field relativeWishDir Vector3 Wishdir relative to yaw (forward/side basis)
---@field strafeDir Vector3? Normalized movement direction

---Get entity eye yaw angle
local function getEntityEyeYaw(entity)
	local eyeYaw = entity:GetPropFloat("m_angEyeAngles[1]")
	if type(eyeYaw) == "number" then
		return eyeYaw
	end
	if entity.GetPropVector and type(entity.GetPropVector) == "function" then
		local eyeVec = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles")
		if eyeVec and type(eyeVec.y) == "number" then
			return eyeVec.y
		end
	end
	return 0
end

---Calculate fallback relative wishdir from velocity
---@param velocity Vector3
---@param yaw number
---@return Vector3
local function fallbackRelativeWishDir(velocity, yaw)
	local horizLen = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if horizLen < GameConstants.STILL_SPEED_THRESHOLD then
		return Vector3(0, 0, 0)
	end

	local yawRad = yaw * GameConstants.DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local velNormX, velNormY = velocity.x / horizLen, velocity.y / horizLen

	-- Project velocity onto forward/right basis
	local relX = cosYaw * velNormX + sinYaw * velNormY
	local relY = sinYaw * velNormX - cosYaw * velNormY

	local relLen = math.sqrt(relX * relX + relY * relY)
	if relLen > 0.001 then
		return Vector3(relX / relLen, relY / relLen, 0)
	end

	return Vector3(0, 0, 0)
end

---Creates a player context from entity
---@param entity Entity
---@param relativeWishDir Vector3? Optional override for relative wish direction
---@return PlayerContext
function PredictionContext.createPlayerContext(entity, relativeWishDir)
	assert(entity, "createPlayerContext: entity is nil")

	local velocity = entity:EstimateAbsVelocity()
	assert(velocity, "createPlayerContext: entity:EstimateAbsVelocity() returned nil")

	local origin = entity:GetAbsOrigin()
	assert(origin, "createPlayerContext: entity:GetAbsOrigin() returned nil")

	local maxspeed = entity:GetPropFloat("m_flMaxspeed")
	assert(maxspeed, "createPlayerContext: entity:GetPropFloat('m_flMaxspeed') returned nil")
	assert(maxspeed > 0, "createPlayerContext: maxspeed must be positive")

	local mins, maxs = entity:GetMins(), entity:GetMaxs()
	assert(mins, "createPlayerContext: entity:GetMins() returned nil")
	assert(maxs, "createPlayerContext: entity:GetMaxs() returned nil")

	local index = entity:GetIndex()
	assert(index, "createPlayerContext: entity:GetIndex() returned nil")

	local originWithOffset = origin + Vector3(0, 0, 1)

	local yaw = getEntityEyeYaw(entity) or 0
	local yawDeltaPerTick = calculateYawDelta(entity)

	if not relativeWishDir then
		relativeWishDir = fallbackRelativeWishDir(velocity, yaw)
	end

	return {
		entity = entity,
		origin = Vector3(originWithOffset:Unpack()),
		velocity = Vector3(velocity:Unpack()),
		mins = mins,
		maxs = maxs,
		maxspeed = maxspeed,
		index = index,
		stepheight = 18,
		yaw = yaw,
		yawDeltaPerTick = yawDeltaPerTick,
		relativeWishDir = relativeWishDir,
	}
end

---@class ProjectileContext
---@field info WeaponInfo
---@field startPos Vector3
---@field angle EulerAngles
---@field velocity Vector3
---@field gravity number
---@field speed number
---@field charge number
---@field localTeam integer
local ProjectileContext = {}

---Creates a projectile context
---@param info WeaponInfo
---@param startPos Vector3
---@param angle EulerAngles
---@param charge number
---@param localTeam integer
---@return ProjectileContext
function PredictionContext.createProjectileContext(info, startPos, angle, charge, localTeam)
	assert(info, "createProjectileContext: info is nil")
	assert(startPos, "createProjectileContext: startPos is nil")
	assert(angle, "createProjectileContext: angle is nil")
	assert(localTeam, "createProjectileContext: localTeam is nil")

	local _, sv_gravity = client.GetConVar("sv_gravity")
	assert(sv_gravity, "createProjectileContext: client.GetConVar('sv_gravity') returned nil")

	local gravityMod = 0
	if info.HasGravity and info:HasGravity() then
		gravityMod = info:GetGravity(charge) or 0
	end

	local gravity = sv_gravity * gravityMod

	local velocityVector = info:GetVelocity(charge)
	assert(velocityVector, "createProjectileContext: info:GetVelocity() returned nil")

	local speed = velocityVector:Length2D()
	assert(speed > 0, "createProjectileContext: velocityVector speed must be positive")

	local angForward = angle:Forward()
	assert(angForward, "createProjectileContext: angle:Forward() returned nil")

	local startVelocity = (angForward * velocityVector:Length2D()) + Vector3(0, 0, velocityVector.z)

	return {
		info = info,
		startPos = Vector3(startPos:Unpack()),
		angle = angle,
		velocity = startVelocity,
		gravity = gravity,
		speed = speed,
		charge = charge or 0,
		localTeam = localTeam,
	}
end

return PredictionContext
