-- Imports

-- Module declaration
local PredictionContext = {}

---@class SimulationContext
---@field sv_gravity number
---@field sv_friction number
---@field sv_stopspeed number
---@field sv_accelerate number
---@field sv_airaccelerate number
---@field tickinterval number
---@field curtime number
local SimulationContext = {}

---Creates a new simulation context with current cvars
---@return SimulationContext
function PredictionContext.createContext()
	local _, sv_gravity = client.GetConVar("sv_gravity")
	assert(sv_gravity, "createContext: client.GetConVar('sv_gravity') returned nil")

	local _, sv_friction = client.GetConVar("sv_friction")
	assert(sv_friction, "createContext: client.GetConVar('sv_friction') returned nil")

	local _, sv_stopspeed = client.GetConVar("sv_stopspeed")
	assert(sv_stopspeed, "createContext: client.GetConVar('sv_stopspeed') returned nil")

	local _, sv_accelerate = client.GetConVar("sv_accelerate")
	assert(sv_accelerate, "createContext: client.GetConVar('sv_accelerate') returned nil")

	local _, sv_airaccelerate = client.GetConVar("sv_airaccelerate")
	assert(sv_airaccelerate, "createContext: client.GetConVar('sv_airaccelerate') returned nil")

	local tickinterval = globals.TickInterval()
	assert(tickinterval, "createContext: globals.TickInterval() returned nil")
	assert(tickinterval > 0, "createContext: tickinterval must be positive")

	local curtime = globals.CurTime()
	assert(curtime, "createContext: globals.CurTime() returned nil")
	assert(curtime >= 0, "createContext: curtime must be non-negative")

	return {
		sv_gravity = sv_gravity,
		sv_friction = sv_friction,
		sv_stopspeed = sv_stopspeed,
		sv_accelerate = sv_accelerate,
		sv_airaccelerate = sv_airaccelerate,
		tickinterval = tickinterval,
		curtime = curtime,
	}
end

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
local PlayerContext = {}

local DEG2RAD = math.pi / 180
local RAD2DEG = 180 / math.pi

---Normalize angle to [-180, 180]
local function normalizeAngle(angle)
	angle = (angle + 180) % 360 - 180
	return angle
end

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
	return nil
end

---Calculate yaw delta per tick from velocity changes (EMA smoothed)
---@param entity Entity
---@return number yawDeltaPerTick
local function calculateYawDelta(entity)
	local vel = entity:EstimateAbsVelocity()
	if not vel then
		return 0
	end

	local speed2DSqr = vel.x * vel.x + vel.y * vel.y
	local minSpeed = 10
	if speed2DSqr < (minSpeed * minSpeed) then
		return 0
	end

	return 0
end

---Calculate relative wishdir from velocity and yaw
---@param velocity Vector3
---@param yaw number
---@return Vector3 relativeWishDir
local function calculateRelativeWishDir(velocity, yaw)
	local horizLen = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if horizLen < 0.001 then
		return Vector3(1, 0, 0)
	end

	local yawRad = yaw * DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local forward = Vector3(cosYaw, sinYaw, 0)
	local right = Vector3(sinYaw, -cosYaw, 0)

	local velNorm = Vector3(velocity.x / horizLen, velocity.y / horizLen, 0)

	local relX = forward.x * velNorm.x + forward.y * velNorm.y
	local relY = right.x * velNorm.x + right.y * velNorm.y

	local relLen = math.sqrt(relX * relX + relY * relY)
	if relLen > 0.001 then
		return Vector3(relX / relLen, relY / relLen, 0)
	end

	return Vector3(1, 0, 0)
end

---Creates a player context from entity
---@param entity Entity
---@param lazyness number? Optional tick multiplier
---@return PlayerContext
function PredictionContext.createPlayerContext(entity, lazyness)
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
	local relativeWishDir = calculateRelativeWishDir(velocity, yaw)

	return {
		entity = entity,
		origin = Vector3(originWithOffset:Unpack()),
		velocity = Vector3(velocity:Unpack()),
		mins = mins,
		maxs = maxs,
		maxspeed = maxspeed,
		index = index,
		stepheight = 18,
		lazyness = lazyness or 1,
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
