local Config = require("config")
local State = require("state")
local Utils = require("utils")
local Entity = require("entity")

local clamp = Utils.clamp
local DEFAULT_GRAVITY = Config.physics.default_gravity
local DEFAULT_BASE_SPEED = Config.physics.sticky_base_speed
local DEFAULT_MAX_SPEED = Config.physics.sticky_max_speed
local DEFAULT_UPWARD_VEL = Config.physics.sticky_upward_vel

local warnedSpeedFallback = {}
local warnedGravityFallback = {}

local Bombard = {}

-- Calculate maximum ballistic range for projectile
-- Uses basic physics: d_max = v^2 / g at optimal 45° angle
local function calculateMaxRange(forwardSpeed, upwardVel, gravity)
	-- Total velocity magnitude at max charge
	local totalSpeed = math.sqrt(forwardSpeed * forwardSpeed + upwardVel * upwardVel)

	-- Maximum range at 45°: d_max = v^2 / g
	local maxRange = (totalSpeed * totalSpeed) / gravity

	return maxRange
end

local function predictImpactZ(speed, pitchDeg, upwardVel, gravity, horizontalDist)
	local ang = EulerAngles(pitchDeg, 0, 0)
	local forward = ang:Forward()
	local up = ang:Up()

	local vx = speed * math.sqrt(forward.x * forward.x + forward.y * forward.y)
	local vz = speed * forward.z + upwardVel * up.z

	if vx < 1 then
		return nil
	end
	local t = horizontalDist / vx
	return (vz * t) - (0.5 * gravity * t * t), t
end

local function findPitchInRange(speed, upwardVel, gravity, horizontalDist, targetDz, minPitch, maxPitch)
	local lowP = minPitch
	local highP = maxPitch
	local bestPitch = nil
	local bestError = math.huge

	for _ = 1, 20 do
		local mid = (lowP + highP) * 0.5
		local hitZ = predictImpactZ(speed, mid, upwardVel, gravity, horizontalDist)
		if not hitZ then
			lowP = mid
		else
			local err = hitZ - targetDz
			if math.abs(err) < bestError then
				bestError = math.abs(err)
				bestPitch = mid
			end
			if err > 0 then
				lowP = mid
			else
				highP = mid
			end
		end
	end

	return bestPitch, bestError
end

local function findLowArcPitch(speed, upwardVel, gravity, dx, dz)
	return findPitchInRange(speed, upwardVel, gravity, dx, dz, -89, 89)
end

local function findHighArcPitch(speed, upwardVel, gravity, dx, dz)
	return findPitchInRange(speed, upwardVel, gravity, dx, dz, -89, -45)
end

local MAX_ACCEPTABLE_ERROR = 100

local function solveChargeWeapon(baseSpeed, maxSpeed, upwardVel, gravity, dx, dz)
	local bestPitch = nil
	local bestCharge = nil
	local bestError = math.huge

	local minChargePitch = nil
	local minChargeVal = nil
	local minChargeErr = math.huge
	do
		local lo, hi = 0.0, 1.0
		for _ = 1, 15 do
			local mid = (lo + hi) * 0.5
			local speed = baseSpeed + mid * (maxSpeed - baseSpeed)
			local pitch, err = findLowArcPitch(speed, upwardVel, gravity, dx, dz)
			if pitch and err < MAX_ACCEPTABLE_ERROR then
				minChargePitch = pitch
				minChargeVal = mid
				minChargeErr = err
				hi = mid
			else
				lo = mid
			end
		end
		if minChargePitch and minChargeErr < bestError then
			bestPitch = minChargePitch
			bestCharge = minChargeVal
			bestError = minChargeErr
		end
	end

	if not minChargePitch or minChargeErr > MAX_ACCEPTABLE_ERROR then
		local pitch, err = findLowArcPitch(maxSpeed, upwardVel, gravity, dx, dz)
		if pitch and err < bestError then
			bestPitch = pitch
			bestCharge = 1.0
			bestError = err
		end
	end

	if bestError > MAX_ACCEPTABLE_ERROR then
		local lo, hi = 0.0, 1.0
		for _ = 1, 15 do
			local mid = (lo + hi) * 0.5
			local speed = baseSpeed + mid * (maxSpeed - baseSpeed)
			local pitch, err = findHighArcPitch(speed, upwardVel, gravity, dx, dz)
			if pitch and err < MAX_ACCEPTABLE_ERROR then
				if err < bestError then
					bestPitch = pitch
					bestCharge = mid
					bestError = err
				end
				hi = mid
			else
				lo = mid
			end
		end
	end

	if bestError > MAX_ACCEPTABLE_ERROR then
		local pitch, err = findHighArcPitch(maxSpeed, upwardVel, gravity, dx, dz)
		if pitch and err < bestError then
			bestPitch = pitch
			bestCharge = 1.0
			bestError = err
		end
	end

	return bestPitch, bestCharge or 1.0, bestError
end

local function solveFixedSpeedWeapon(speed, upwardVel, gravity, dx, dz)
	local bestPitch = nil
	local bestError = math.huge

	local lowPitch, lowErr = findLowArcPitch(speed, upwardVel, gravity, dx, dz)
	if lowPitch and lowErr < bestError then
		bestPitch = lowPitch
		bestError = lowErr
	end

	if bestError > MAX_ACCEPTABLE_ERROR then
		local highPitch, highErr = findHighArcPitch(speed, upwardVel, gravity, dx, dz)
		if highPitch and highErr < bestError then
			bestPitch = highPitch
			bestError = highErr
		end
	end

	return bestPitch, bestError
end

function Bombard.handleInput(cmd)
	if not Config.bombard.enabled then
		return
	end

	local cfg = Config.keybinds
	local st = State.bombard
	local inp = State.input

	local activateDown = input.IsButtonDown(cfg.activate)

	if cfg.activate_mode == "toggle" then
		if activateDown and not inp.lastActivateState then
			State.camera.active = not State.camera.active
			if State.camera.active then
				Bombard.lockCurrentAim()
			else
				st.useStoredCharge = false
			end
		end
		inp.lastActivateState = activateDown
	else
		local wasActive = State.camera.active
		State.camera.active = activateDown
		if activateDown and not wasActive then
			Bombard.lockCurrentAim()
		end
		if not activateDown and wasActive then
			st.useStoredCharge = false
		end
	end

	local highGroundDown = input.IsButtonDown(cfg.high_ground)
	st.highGroundHeld = highGroundDown
end

function Bombard.lockCurrentAim()
	if not input.IsButtonPressed(Config.bombard.activate) then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return
	end

	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon or not pWeapon:IsValid() then
		return
	end

	-- Get weapon context to calculate dynamic max range
	local ctx = Entity.getWeaponContext(pLocal, pWeapon)
	if not ctx then
		return
	end

	-- Calculate max range based on current weapon
	local maxRange = Config.bombard.max_distance -- fallback
	if ctx.hasCharge then
		-- For charge weapons, use max charge speed
		local chargeMaxSpeed = ctx.maxForwardSpeed or DEFAULT_MAX_SPEED
		local upwardVel = ctx.upwardVel or DEFAULT_UPWARD_VEL
		local gravity = ctx.gravity or DEFAULT_GRAVITY
		maxRange = calculateMaxRange(chargeMaxSpeed, upwardVel, gravity)
	else
		-- For fixed speed weapons
		local forwardSpeed = ctx.forwardSpeed or DEFAULT_BASE_SPEED
		local upwardVel = ctx.upwardVel or DEFAULT_UPWARD_VEL
		local gravity = ctx.gravity or DEFAULT_GRAVITY
		maxRange = calculateMaxRange(forwardSpeed, upwardVel, gravity)
	end

	local viewAngles = engine.GetViewAngles()
	if not viewAngles then
		return
	end

	local absOrigin = pLocal:GetAbsOrigin()
	local viewOffset = pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	local eyePos = absOrigin + viewOffset

	local traj = State.trajectory
	local hitPoint
	if traj.isValid and traj.impactPos then
		hitPoint = traj.impactPos
	else
		local forward = viewAngles:Forward()
		local traceEnd = eyePos + forward * maxRange -- Use calculated max range
		local res = engine.TraceLine(eyePos, traceEnd, Config.TRACE_MASK)
		hitPoint = res.endpos
	end

	local dx = hitPoint.x - eyePos.x
	local dy = hitPoint.y - eyePos.y
	local horizontalDist = math.sqrt(dx * dx + dy * dy)

	State.bombard.lockedYaw = viewAngles.y
	State.bombard.lockedDistance = clamp(horizontalDist, Config.bombard.min_distance, maxRange) -- Use calculated max range
	State.bombard.lockedOrigin = eyePos
	State.bombard.targetZHeight = hitPoint.z - eyePos.z
	State.bombard.lastValidZHeight = State.bombard.targetZHeight
end

function Bombard.execute(cmd)
	if not State.camera.active then
		return
	end
	if not Config.bombard.enabled then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return
	end

	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon or not pWeapon:IsValid() then
		return
	end

	local ctx = Entity.getWeaponContext(pLocal, pWeapon)
	if not ctx then
		State.bombard.calculatedPitch = nil
		State.trajectory.isValid = false
		return
	end

	local st = State.bombard

	local viewAngles = engine.GetViewAngles()
	if not viewAngles then
		return
	end

	local absOrigin = pLocal:GetAbsOrigin()
	local viewOffset = pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	local vHeadPos = absOrigin + viewOffset

	local yawRad = math.rad(viewAngles.y)
	local direction = Vector3(math.cos(yawRad), math.sin(yawRad), 0)

	Bombard.updateZHeight()

	st.originPoint = vHeadPos
	st.targetPoint = vHeadPos + (direction * st.lockedDistance) + Vector3(0, 0, st.targetZHeight)

	local _, baseSpeed, fUpwardVelocity, _, fGravityRaw =
		Entity.GetProjectileInformation(pWeapon, ctx.isDucking, ctx.itemCase, ctx.itemDefIndex, ctx.weaponID, pLocal, 0)

	if not baseSpeed or baseSpeed <= 0 then
		local warnKey = ctx.weaponID or "unknown"
		if not warnedSpeedFallback[warnKey] then
			print("[ArtilleryAiming] projectile speed missing; using defaults for weapon " .. tostring(warnKey))
			warnedSpeedFallback[warnKey] = true
		end
		baseSpeed = DEFAULT_BASE_SPEED
		fUpwardVelocity = DEFAULT_UPWARD_VEL
		fGravityRaw = DEFAULT_GRAVITY
	end

	local maxSpeed = baseSpeed
	if ctx.hasCharge and ctx.chargeMaxTime > 0 then
		local _, fullChargeSpeed = Entity.GetProjectileInformation(
			pWeapon,
			ctx.isDucking,
			ctx.itemCase,
			ctx.itemDefIndex,
			ctx.weaponID,
			pLocal,
			ctx.chargeMaxTime
		)
		maxSpeed = fullChargeSpeed
	end

	local apiGravityMult = pWeapon:GetProjectileGravity()
	local gravity
	if apiGravityMult and apiGravityMult > 0 then
		gravity = DEFAULT_GRAVITY * apiGravityMult
	elseif fGravityRaw and fGravityRaw > 0 then
		gravity = fGravityRaw
	else
		gravity = DEFAULT_GRAVITY
		local warnKey = ctx.weaponID or "unknown"
		if not warnedGravityFallback[warnKey] then
			print("[ArtilleryAiming] gravity missing; using default for weapon " .. tostring(warnKey))
			warnedGravityFallback[warnKey] = true
		end
	end

	local dx = st.lockedDistance
	local dz = st.targetZHeight

	local mouseY = cmd.mousedy or 0
	if gui.GetValue("Menu") ~= 1 then
		-- Calculate current max range for clamping
		local currentMaxRange = Config.bombard.max_distance -- fallback
		if ctx.hasCharge then
			local chargeMaxSpeed = maxSpeed or baseSpeed
			local upwardVel = fUpwardVelocity or DEFAULT_UPWARD_VEL
			local currentGravity = gravity or DEFAULT_GRAVITY
			currentMaxRange = calculateMaxRange(chargeMaxSpeed, upwardVel, currentGravity)
		else
			local forwardSpeed = baseSpeed
			local upwardVel = fUpwardVelocity or DEFAULT_UPWARD_VEL
			local currentGravity = gravity or DEFAULT_GRAVITY
			currentMaxRange = calculateMaxRange(forwardSpeed, upwardVel, currentGravity)
		end

		local distanceDelta = -mouseY * Config.bombard.sensitivity
		st.lockedDistance = clamp(st.lockedDistance + distanceDelta, Config.bombard.min_distance, currentMaxRange)
	end

	local bestPitch = nil
	local bestCharge = nil
	local bestError = math.huge

	if ctx.hasCharge then
		bestPitch, bestCharge, bestError = solveChargeWeapon(baseSpeed, maxSpeed, fUpwardVelocity, gravity, dx, dz)
		st.chargeLevel = bestCharge
	else
		bestPitch, bestError = solveFixedSpeedWeapon(baseSpeed, fUpwardVelocity, gravity, dx, dz)
	end

	st.calculatedPitch = bestPitch

	if bestPitch then
		cmd.mousedx = 0
		cmd.mousedy = 0

		local aimAngles = EulerAngles(bestPitch, viewAngles.y, 0)
		engine.SetViewAngles(aimAngles)
		cmd.viewangles = Vector3(bestPitch, viewAngles.y, 0)

		st.useStoredCharge = ctx.hasCharge
	end
end

function Bombard.updateZHeight()
	local traj = State.trajectory
	local st = State.bombard

	if not traj.isValid or not traj.impactPos or not traj.impactPlane then
		return
	end

	local surfaceNormalZ = traj.impactPlane.z
	local threshold = Config.bombard.downward_surface_threshold
	if surfaceNormalZ < -threshold then
		return
	end

	local origin = st.lockedOrigin or Vector3(0, 0, 0)
	local impactZ = traj.impactPos.z - origin.z

	if st.highGroundHeld then
		if impactZ > st.targetZHeight then
			st.targetZHeight = impactZ
			st.lastValidZHeight = impactZ
		end
	else
		if impactZ < st.targetZHeight then
			st.targetZHeight = impactZ
			st.lastValidZHeight = impactZ
		end
	end
end

function Bombard.handleChargeRelease(cmd)
	if not State.bombard.useStoredCharge then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return
	end

	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon or not pWeapon:IsValid() then
		return
	end

	local ctx = Entity.getWeaponContext(pLocal, pWeapon)
	if not ctx or not ctx.hasCharge then
		return
	end

	local chargeBeginTime = pWeapon:GetPropFloat("m_flChargeBeginTime") or 0
	if chargeBeginTime <= 0 then
		return
	end

	local chargeMaxTime = ctx.chargeMaxTime
	if chargeMaxTime <= 0 then
		chargeMaxTime = 4.0
	end

	local currentCharge = (globals.CurTime() - chargeBeginTime) / chargeMaxTime
	local targetCharge = State.bombard.chargeLevel

	if currentCharge >= targetCharge then
		cmd.buttons = cmd.buttons & ~Config.IN_ATTACK
	end
end

return Bombard
