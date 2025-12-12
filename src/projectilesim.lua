local projectiles = {}

local env = physics.CreateEnvironment()
env:SetAirDensity(2.0)
env:SetGravity(Vector3(0, 0, -800))
env:SetSimulationTimestep(globals.TickInterval())

---@return PhysicsObject
local function GetPhysicsProjectile(info)
	assert(info, "GetPhysicsProjectile: info is nil")
	assert(info.m_sModelName, "GetPhysicsProjectile: info.m_sModelName is nil")

	local modelName = info.m_sModelName
	if projectiles[modelName] then
		return projectiles[modelName]
	end

	local solid, collision = physics.ParseModelByName(info.m_sModelName)
	assert(solid, "GetPhysicsProjectile: ParseModelByName returned nil solid for model: " .. info.m_sModelName)
	assert(collision, "GetPhysicsProjectile: ParseModelByName returned nil collision for model: " .. info.m_sModelName)

	local surfaceProp = solid:GetSurfacePropName()
	assert(surfaceProp, "GetPhysicsProjectile: GetSurfacePropName returned nil for model: " .. info.m_sModelName)

	local objectParams = solid:GetObjectParameters()
	assert(objectParams, "GetPhysicsProjectile: GetObjectParameters returned nil for model: " .. info.m_sModelName)

	local projectile = env:CreatePolyObject(collision, surfaceProp, objectParams)
	assert(projectile, "GetPhysicsProjectile: CreatePolyObject returned nil for model: " .. info.m_sModelName)

	projectiles[modelName] = projectile
	return projectiles[modelName]
end

--- source: https://developer.mozilla.org/en-US/docs/Games/Techniques/3D_collision_detection
---@param currentPos Vector3
---@param vecTargetPredictedPos Vector3
---@param weaponInfo WeaponInfo
---@param vecTargetMaxs Vector3
---@param vecTargetMins Vector3
local function IsIntersectingBB(currentPos, vecTargetPredictedPos, weaponInfo, vecTargetMaxs, vecTargetMins)
	local vecProjMins = weaponInfo.m_vecMins + currentPos
	local vecProjMaxs = weaponInfo.m_vecMaxs + currentPos

	local targetMins = vecTargetMins + vecTargetPredictedPos
	local targetMaxs = vecTargetMaxs + vecTargetPredictedPos

	-- check overlap on X, Y, and Z
	if vecProjMaxs.x < targetMins.x or vecProjMins.x > targetMaxs.x then
		return false
	end
	if vecProjMaxs.y < targetMins.y or vecProjMins.y > targetMaxs.y then
		return false
	end
	if vecProjMaxs.z < targetMins.z or vecProjMins.z > targetMaxs.z then
		return false
	end

	return true -- all axis overlap
end

local function TraceProjectileHull(vStart, vEnd, mins, maxs, info, target, localTeam, currentTime)
	return engine.TraceHull(vStart, vEnd, mins, maxs, MASK_VISIBLE | MASK_SHOT_HULL, function(ent)
		if ent:GetIndex() == target:GetIndex() then
			return true
		end

		local team = ent:GetTeamNumber()

		--- teammates are ignored until delay expires
		if team == localTeam then
			return currentTime > info.m_flCollideWithTeammatesDelay
		end

		if team ~= localTeam then
			return info.m_bStopOnHittingEnemy
		end

		return true
	end)
end

---@param target Entity
---@param targetPredictedPos Vector3
---@param startPos Vector3
---@param angle EulerAngles
---@param info WeaponInfo
---@param time_seconds number
---@param localTeam integer
---@param charge number
---@return Vector3[], boolean, boolean, number[]
local function SimulateProjectile(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
	assert(target, "SimulateProjectile: target is nil")
	assert(targetPredictedPos, "SimulateProjectile: targetPredictedPos is nil")
	assert(startPos, "SimulateProjectile: startPos is nil")
	assert(angle, "SimulateProjectile: angle is nil")
	assert(info, "SimulateProjectile: info is nil")
	assert(localTeam, "SimulateProjectile: localTeam is nil")
	assert(time_seconds, "SimulateProjectile: time_seconds is nil")

	local projectile = GetPhysicsProjectile(info)
	assert(projectile, "SimulateProjectile: GetPhysicsProjectile returned nil")

	projectile:Wake()
	local angForward = angle:Forward()
	local timeEnd = env:GetSimulationTime() + time_seconds
	local tickInterval = globals.TickInterval()
	local velocityVector = info:GetVelocity(charge)
	local startVelocity = (angForward * velocityVector:Length2D()) + (Vector3(0, 0, velocityVector.z))
	projectile:SetPosition(startPos, angle:Forward(), true)
	projectile:SetVelocity(startVelocity, info:GetAngularVelocity(charge))
	local mins, maxs = info.m_vecMins, info.m_vecMaxs
	local path = {}
	local hit = false
	local simulatedFull = false
	local timetable = {}
	local curtime = globals.CurTime()

	while env:GetSimulationTime() < timeEnd do
		local vStart = projectile:GetPosition()
		env:Simulate(tickInterval)
		local vEnd = projectile:GetPosition()
		local trace = TraceProjectileHull(vStart, vEnd, mins, maxs, info, target, localTeam, env:GetSimulationTime())

		if IsIntersectingBB(vEnd, targetPredictedPos, info, target:GetMaxs(), target:GetMins()) then
			hit = true
			simulatedFull = true
			break
		end

		if trace.fraction < 1.0 then
			break
		end

		path[#path + 1] = Vector3(vEnd:Unpack())
		timetable[#timetable + 1] = curtime + env:GetSimulationTime()
	end

	-- Check if we simulated the full time
	if env:GetSimulationTime() >= timeEnd then
		simulatedFull = true
	end

	projectile:Sleep()
	env:ResetSimulationClock()
	return path, hit, simulatedFull, timetable
end

---@param target Entity
---@param targetPredictedPos Vector3
---@param startPos Vector3
---@param angle EulerAngles
---@param info WeaponInfo
---@param time_seconds number
---@param localTeam integer
---@param charge number
---@return Vector3[], boolean, boolean, number[]
local function SimulateFakeProjectile(
	target,
	targetPredictedPos,
	startPos,
	angle,
	info,
	localTeam,
	time_seconds,
	charge
)
	assert(target, "SimulateFakeProjectile: target is nil")
	assert(targetPredictedPos, "SimulateFakeProjectile: targetPredictedPos is nil")
	assert(startPos, "SimulateFakeProjectile: startPos is nil")
	assert(angle, "SimulateFakeProjectile: angle is nil")
	assert(info, "SimulateFakeProjectile: info is nil")
	assert(localTeam, "SimulateFakeProjectile: localTeam is nil")
	assert(time_seconds, "SimulateFakeProjectile: time_seconds is nil")

	local angForward = angle:Forward()
	assert(angForward, "SimulateFakeProjectile: angle:Forward() returned nil")

	local tickInterval = globals.TickInterval()
	assert(tickInterval, "SimulateFakeProjectile: globals.TickInterval() returned nil")

	local velocityVector = info:GetVelocity(charge)
	assert(velocityVector, "SimulateFakeProjectile: info:GetVelocity() returned nil")

	local startVelocity = (angForward * velocityVector:Length2D()) + Vector3(0, 0, velocityVector.z)
	local mins, maxs = info.m_vecMins, info.m_vecMaxs
	local path = {}
	local timeTable = {}
	local hit = false
	local simulatedFull = false
	local time = 0.0
	local curtime = globals.CurTime()

	-- Get gravity from info
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravity = sv_gravity * info:GetGravity(charge)
	local currentPos = startPos
	local currentVel = startVelocity
	local gravity_to_add = Vector3(0, 0, -gravity * tickInterval)

	while time < time_seconds do
		local vStart = currentPos
		-- Apply gravity to velocity
		currentVel = currentVel + gravity_to_add
		local vEnd = currentPos + currentVel * tickInterval
		local trace = TraceProjectileHull(vStart, vEnd, mins, maxs, info, target, localTeam, time)

		-- Add current position to path before checking collision
		path[#path + 1] = Vector3(vEnd:Unpack())
		timeTable[#timeTable + 1] = curtime + time

		if IsIntersectingBB(vEnd, targetPredictedPos, info, target:GetMaxs(), target:GetMins()) then
			hit = true
			simulatedFull = true
			break
		end

		if trace.fraction < 1.0 then
			break
		end

		currentPos = vEnd
		time = time + tickInterval
	end

	-- Check if we simulated the full time
	if time >= time_seconds then
		simulatedFull = true
	end

	return path, hit, simulatedFull, timeTable
end

---@param target Entity
---@param targetPredictedPos Vector3
---@param startPos Vector3
---@param angle EulerAngles
---@param info WeaponInfo
---@param time_seconds number
---@param localTeam integer
---@param charge number
---@return Vector3[], boolean?, boolean, number[]
local function Run(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
	assert(target, "projectilesim: target is nil")
	assert(targetPredictedPos, "projectilesim: targetPredictedPos is nil")
	assert(startPos, "projectilesim: startPos is nil")
	assert(angle, "projectilesim: angle is nil")
	assert(info, "projectilesim: info is nil")
	assert(localTeam, "projectilesim: localTeam is nil")
	assert(time_seconds, "projectilesim: time_seconds is nil")

	local projpath = {}
	local hit = nil
	local timetable = {}
	local full = false

	if info.m_sModelName and info.m_sModelName ~= "" then
		projpath, hit, full, timetable =
			SimulateProjectile(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
	else
		projpath, hit, full, timetable =
			SimulateFakeProjectile(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
	end

	assert(projpath, "projectilesim: simulation returned nil projpath")
	assert(type(hit) == "boolean" or hit == nil, "projectilesim: hit must be boolean or nil")
	assert(type(full) == "boolean", "projectilesim: full must be boolean")
	assert(timetable, "projectilesim: simulation returned nil timetable")

	return projpath, hit, full, timetable
end

-- Callbacks -----
local function cleanupPhysicsEnvironment()
	-- Sleep all projectiles before cleanup
	for _, projectile in pairs(projectiles) do
		if projectile and projectile.Sleep then
			projectile:Sleep()
		end
	end

	-- Clear projectile cache
	for k in pairs(projectiles) do
		projectiles[k] = nil
	end

	-- Reset simulation clock
	if env and env.ResetSimulationClock then
		env:ResetSimulationClock()
	end
end

callbacks.Register("Unload", "PROJ_AIMBOT_PHYSICS_CLEANUP", cleanupPhysicsEnvironment)

return Run
