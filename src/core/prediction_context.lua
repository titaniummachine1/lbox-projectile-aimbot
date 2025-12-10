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
	local _, sv_friction = client.GetConVar("sv_friction")
	local _, sv_stopspeed = client.GetConVar("sv_stopspeed")
	local _, sv_accelerate = client.GetConVar("sv_accelerate")
	local _, sv_airaccelerate = client.GetConVar("sv_airaccelerate")
	
	return {
		sv_gravity = sv_gravity or 800,
		sv_friction = sv_friction or 4,
		sv_stopspeed = sv_stopspeed or 100,
		sv_accelerate = sv_accelerate or 10,
		sv_airaccelerate = sv_airaccelerate or 10,
		tickinterval = globals.TickInterval(),
		curtime = globals.CurTime(),
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
	assert(entity, "PredictionContext: entity is nil")
	
	local velocity = entity:GetPropVector("localdata", "m_vecVelocity[0]") or Vector3()
	local origin = entity:GetAbsOrigin() + Vector3(0, 0, 1)
	local maxspeed = entity:GetPropFloat("m_flMaxspeed") or 450
	local mins, maxs = entity:GetMins(), entity:GetMaxs()
	
	return {
		entity = entity,
		origin = Vector3(origin:Unpack()),
		velocity = Vector3(velocity:Unpack()),
		mins = mins,
		maxs = maxs,
		maxspeed = maxspeed,
		index = entity:GetIndex(),
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
	assert(info, "PredictionContext: info is nil")
	assert(startPos, "PredictionContext: startPos is nil")
	assert(angle, "PredictionContext: angle is nil")
	
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravity = sv_gravity * 0.5 * info:GetGravity(charge)
	local velocityVector = info:GetVelocity(charge)
	local speed = velocityVector:Length2D()
	
	local angForward = angle:Forward()
	local startVelocity = (angForward * velocityVector:Length2D()) + Vector3(0, 0, velocityVector.z)
	
	return {
		info = info,
		startPos = Vector3(startPos:Unpack()),
		angle = angle,
		velocity = startVelocity,
		gravity = gravity,
		speed = speed,
		charge = charge,
		localTeam = localTeam,
	}
end

return PredictionContext

