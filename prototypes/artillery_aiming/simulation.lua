local Config = require("config")
local State = require("state")
local Entity = require("entity")
local PhysicsEnvModule = require("physics_env")
local Camera = require("camera")

local traceHull = engine.TraceHull
local traceLine = engine.TraceLine
local TRACE_MASK = Config.TRACE_MASK

local Simulation = {}

function Simulation.run(cmd)
	local traj = State.trajectory

	-- Always run simulation to get current trajectory
	traj.positions = {}
	traj.velocities = {}
	traj.impactPos = nil
	traj.impactPlane = nil
	traj.isValid = false

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or pLocal:InCond(7) or not pLocal:IsAlive() then
		return
	end

	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon or not pWeapon:IsValid() then
		return
	end

	local projectileType = pWeapon:GetWeaponProjectileType()
	if not projectileType or projectileType < 2 then
		return
	end

	local ctx = Entity.getWeaponContext(pLocal, pWeapon)
	if not ctx then
		return
	end

	local chargeOverride = nil
	if State.bombard.useStoredCharge and ctx.hasCharge then
		local chargeMaxTime = ctx.chargeMaxTime
		if chargeMaxTime <= 0 then
			chargeMaxTime = 4.0
		end
		chargeOverride = State.bombard.chargeLevel * chargeMaxTime
	end

	local vOffset, fForwardVelocity, fUpwardVelocity, vCollisionMax, fGravity, fDrag = Entity.GetProjectileInformation(
		pWeapon,
		ctx.isDucking,
		ctx.itemCase,
		ctx.itemDefIndex,
		ctx.weaponID,
		pLocal,
		chargeOverride
	)
	local vCollisionMin = -vCollisionMax

	local vStartPosition = pLocal:GetAbsOrigin() + pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	local vStartAngle = cmd and EulerAngles(cmd.viewangles.x, cmd.viewangles.y, cmd.viewangles.z)
		or engine.GetViewAngles()

	-- When camera is active, use the original player angles from the first cached position
	-- to prevent trajectory changes when camera view angles differ from player view angles
	if Camera.isActive() and #State.camera.storedPositions > 0 then
		-- Use the real player's angles, not the camera's angles
		vStartAngle = entities.GetLocalPlayer():GetEyeAngles()
	end

	local results = traceHull(
		vStartPosition,
		vStartPosition
			+ (vStartAngle:Forward() * vOffset.x)
			+ (vStartAngle:Right() * (vOffset.y * (pWeapon:IsViewModelFlipped() and -1 or 1)))
			+ (vStartAngle:Up() * vOffset.z),
		vCollisionMin,
		vCollisionMax,
		TRACE_MASK
	)
	if results.fraction ~= 1 then
		return
	end
	vStartPosition = results.endpos

	if ctx.itemCase == -1 or ((ctx.itemCase >= 7 and ctx.itemCase < 11) and fForwardVelocity ~= 0) then
		local res = traceLine(results.startpos, results.startpos + (vStartAngle:Forward() * 2000), TRACE_MASK)
		vStartAngle = (
			((res.fraction <= 0.1) and (results.startpos + (vStartAngle:Forward() * 2000)) or res.endpos)
			- vStartPosition
		):Angles()
	end

	local vVelocity = (vStartAngle:Forward() * fForwardVelocity) + (vStartAngle:Up() * fUpwardVelocity)
	traj.flagOffset = vStartAngle:Right() * -Config.visual.flags.size

	table.insert(traj.positions, vStartPosition)
	table.insert(traj.velocities, vVelocity)

	local g_fTraceInterval = Config.computed.trace_interval
	local g_fFlagInterval = Config.computed.flag_interval

	if ctx.itemCase == -1 then
		results = traceHull(
			vStartPosition,
			vStartPosition + (vStartAngle:Forward() * 10000),
			vCollisionMin,
			vCollisionMax,
			TRACE_MASK
		)
		if results.startsolid then
			return
		end
		local segCount = math.floor((results.endpos - results.startpos):Length() / g_fFlagInterval)
		local vForward = vStartAngle:Forward()
		for i = 1, segCount do
			local segPos = vForward * (i * g_fFlagInterval) + vStartPosition
			table.insert(traj.positions, segPos)
			table.insert(traj.velocities, vVelocity)
		end
		table.insert(traj.positions, results.endpos)
		table.insert(traj.velocities, vVelocity)
	elseif ctx.itemCase > 3 then
		local vPos = Vector3(0, 0, 0)
		for i = 0.01515, 5, g_fTraceInterval do
			local scalar = (fDrag == nil) and i or ((1 - math.exp(-fDrag * i)) / fDrag)
			vPos.x = vVelocity.x * scalar + vStartPosition.x
			vPos.y = vVelocity.y * scalar + vStartPosition.y
			vPos.z = (vVelocity.z - fGravity * i) * scalar + vStartPosition.z

			local vCurVel = Vector3(vVelocity.x, vVelocity.y, vVelocity.z - fGravity * i)
			if fDrag then
				local dragFactor = math.exp(-fDrag * i)
				vCurVel = Vector3(vCurVel.x * dragFactor, vCurVel.y * dragFactor, vCurVel.z * dragFactor)
			end

			if vCollisionMax.x ~= 0 then
				results = traceHull(results.endpos, vPos, vCollisionMin, vCollisionMax, TRACE_MASK)
			else
				results = traceLine(results.endpos, vPos, TRACE_MASK)
			end
			table.insert(traj.positions, results.endpos)
			table.insert(traj.velocities, vCurVel)
			if results.fraction ~= 1 then
				break
			end
		end
	else
		local modelPath = Config.PHYSICS_MODEL_PATHS[ctx.itemCase]
		if not modelPath then
			return
		end
		local pEnv = PhysicsEnvModule.get()
		if not pEnv then
			return
		end
		local obj = pEnv:getObject(modelPath)
		if not obj then
			return
		end

		obj:SetPosition(vStartPosition, vStartAngle, true)
		obj:SetVelocity(vVelocity, Vector3(0, 0, 0))
		local prevPos = vStartPosition
		for _ = 2, 330 do
			local curPos = obj:GetPosition()
			if not curPos then
				break
			end
			results = traceHull(results.endpos, curPos, vCollisionMin, vCollisionMax, TRACE_MASK)

			local deltaPos = curPos - prevPos
			table.insert(traj.positions, results.endpos)
			table.insert(traj.velocities, deltaPos * 66)
			prevPos = curPos

			if results.fraction ~= 1 then
				break
			end
			pEnv:simulate(g_fTraceInterval)
		end
		pEnv:reset()
	end

	if results and results.plane then
		traj.impactPos = results.endpos
		traj.impactPlane = results.plane
	end
	traj.isValid = #traj.positions > 1

	State.camera.storedPositions = traj.positions
	State.camera.storedVelocities = traj.velocities
	State.camera.storedImpactPos = traj.impactPos
	State.camera.storedImpactPlane = traj.impactPlane
	State.camera.storedFlagOffset = traj.flagOffset
end

return Simulation
