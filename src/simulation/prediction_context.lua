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
local PlayerContext = {}

---Creates a player context from entity
---@param entity Entity
---@param lazyness number? Optional tick multiplier
---@return PlayerContext
function PredictionContext.createPlayerContext(entity, lazyness)
	assert(entity, "createPlayerContext: entity is nil")

	local velocity = entity:GetPropVector("localdata", "m_vecVelocity[0]")
	assert(velocity, "createPlayerContext: entity:GetPropVector('m_vecVelocity[0]') returned nil")

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

	local gravity = sv_gravity * 0.5 * gravityMod

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
