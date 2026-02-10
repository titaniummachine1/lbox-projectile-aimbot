local Config = require("config")
local Visuals = require("visuals")
local PhysicsEnvModule = require("physics_env")
local VectorKalman = require("kalman")

local ProjectileTracker = {}

-- Projectile definitions with radius for splash visualization
-- Radius ~146hu for explosives (rockets, pipes, stickies)
local PROJECTILE_CLASSES = {
	{
		class = "CTFProjectile_Rocket",
		configKey = "rockets",
		gravity = 0,
		drag = nil,
		radius = 146,
		usePhysics = false,
	},
	{
		class = "CTFGrenadePipebombProjectile",
		configKey = "pipes",
		gravity = 400,
		drag = 0.45,
		radius = 146,
		usePhysics = true,
	}, -- Physics handled dynamically based on sticky vs pipe
	{
		class = "CTFProjectile_Flare",
		configKey = "flares",
		gravity = 120,
		drag = 0.5,
		radius = 0,
		usePhysics = false,
	},
	{
		class = "CTFProjectile_Arrow",
		configKey = "arrows",
		gravity = 200,
		drag = nil,
		radius = 0,
		usePhysics = false,
	},
	{
		class = "CTFProjectile_EnergyBall",
		configKey = "energy",
		gravity = 80,
		drag = nil,
		radius = 0,
		usePhysics = false,
	},
	{
		class = "CTFProjectile_BallOfFire",
		configKey = "fireballs",
		gravity = 120,
		drag = nil,
		radius = 0,
		usePhysics = false,
	},
}

local PIPEBOMB_TYPE_STICKY = 1
local STICKY_MODEL = "models/weapons/w_models/w_stickybomb.mdl"
local PIPE_MODEL = "models/weapons/w_models/w_grenade_grenadelauncher.mdl"

-- Thresholds
local MIN_MOVING_SPEED = 10
local RESIM_DISTANCE_SQ = 5 * 5 -- Default backup if config missing

local traceLine = engine.TraceLine
local traceHull = engine.TraceHull
local EXP_FUNC = math.exp

local tracked = {}
local indicesToRemove = {}

-- Helper: Simulate using simple Math (Gravity/Drag)
local function simulateMath(startPos, velocity, gravity, drag, maxTime, traceInterval, traceMask)
	local positions = { startPos }
	local times = { 0 }
	local count = 1
	local prevPos = startPos

	local impactPos, impactPlane

	for t = traceInterval, maxTime, traceInterval do
		local scalar = (drag == nil) and t or ((1 - EXP_FUNC(-drag * t)) / drag)
		local px = velocity.x * scalar + startPos.x
		local py = velocity.y * scalar + startPos.y
		local pz = (velocity.z - gravity * t) * scalar + startPos.z -- Correct non-0.5g formula

		local predPos = Vector3(px, py, pz)
		local tr = traceLine(prevPos, predPos, traceMask)

		count = count + 1
		positions[count] = tr.endpos
		times[count] = t
		prevPos = tr.endpos

		if tr.fraction < 1.0 then
			impactPos = tr.endpos
			impactPlane = tr.plane
			break
		end
	end

	return positions, times, count, impactPos, impactPlane
end

-- Helper: Simulate using Physics Environment (Stickies/Pipes)
-- Note: This requires the model to be valid in physics_env
local function simulatePhysics(startPos, velocity, angularVel, modelPath, maxTime, traceInterval, traceMask)
	local pEnv = PhysicsEnvModule.get()
	if not pEnv then
		return nil
	end

	local obj = pEnv:getObject(modelPath)
	if not obj then
		return nil
	end

	-- Setup simulation object
	-- Use velocity angles for orientation if undefined, but stickies spin so simple identity/vel-align is ok
	local angles = velocity:Angles()
	obj:SetPosition(startPos, angles, true)
	obj:SetVelocity(velocity, angularVel or Vector3(0, 0, 0))

	local positions = { startPos }
	local times = { 0 }
	local count = 1
	local prevPos = startPos
	local impactPos, impactPlane

	-- Step simulation
	local timeAccum = 0
	-- Limit steps to avoid lag (e.g. 5 seconds * 66 ticks = 330 steps)
	local maxSteps = math.floor(maxTime / traceInterval)

	for i = 1, maxSteps do
		pEnv:simulate(traceInterval)
		timeAccum = timeAccum + traceInterval

		local curPos = obj:GetPosition()
		if not curPos then
			break
		end

		-- Trace check between steps to find wall impact
		local tr = traceLine(prevPos, curPos, traceMask)

		count = count + 1
		positions[count] = tr.endpos
		times[count] = timeAccum
		prevPos = tr.endpos

		if tr.fraction < 1.0 then
			impactPos = tr.endpos
			impactPlane = tr.plane
			break
		end
	end

	-- Reset env mainly to clear state, object sleeps automatically
	pEnv:reset()

	return positions, times, count, impactPos, impactPlane
end

-- Unified/Chooser Simulation
local function simulateUnified(startPos, velocity, angularVel, projDef, isSticky, maxTime, traceInterval, traceMask)
	-- Try physics if requested
	if projDef.usePhysics or isSticky then
		local model = isSticky and STICKY_MODEL or PIPE_MODEL
		local pos, tim, cnt, imp, pln =
			simulatePhysics(startPos, velocity, angularVel, model, maxTime, traceInterval, traceMask)
		if pos then
			return pos, tim, cnt, imp, pln
		end
		-- Fallback to math if physics failed (missing model?)
	end

	return simulateMath(startPos, velocity, projDef.gravity, projDef.drag, maxTime, traceInterval, traceMask)
end

-- Get pipebomb specific info
local function getPipebombInfo(entity)
	local type = entity:GetPropInt("m_iType")
	return (type == PIPEBOMB_TYPE_STICKY), "pipes" -- config key is always pipes/stickies handled by loop
end

function ProjectileTracker.update()
	local cfg = Config.visual.live_projectiles
	if not cfg.enabled then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() then
		return
	end

	local curTime = globals.CurTime()
	local traceInterval = (Config.computed and Config.computed.trace_interval) or 0.015
	local traceMask = Config.TRACE_MASK or 0x4600400B -- MASK_SHOT
	-- Use configured distance or default low value (2-5)
	local distThreshold = cfg.revalidate_distance or 5
	local distThresholdSq = distThreshold * distThreshold

	-- Mark unseen
	for _, data in pairs(tracked) do
		data.seenThisFrame = false
	end

	for _, projDef in ipairs(PROJECTILE_CLASSES) do
		local baseConfigKey = projDef.configKey
		local isPipeClass = (projDef.class == "CTFGrenadePipebombProjectile")

		if isPipeClass then
			if not cfg.stickies and not cfg.pipes then
				goto continueClass
			end
		elseif not cfg[baseConfigKey] then
			goto continueClass
		end

		local found = entities.FindByClass(projDef.class)

		for _, entity in pairs(found) do
			if not (entity and entity:IsValid() and not entity:IsDormant()) then
				goto continueEntity
			end

			local configKey = baseConfigKey
			local isSticky = false

			if isPipeClass then
				local sticky
				sticky, _ = getPipebombInfo(entity)
				isSticky = sticky
				configKey = isSticky and "stickies" or "pipes"
				if not cfg[configKey] then
					goto continueEntity
				end
			end

			local entIdx = entity:GetIndex()
			local entPos = entity:GetAbsOrigin()
			-- EstimateAbsVelocity is noisy, used as measurement for Kalman
			local rawVel = entity:EstimateAbsVelocity()
			if not rawVel then
				goto continueEntity
			end

			if rawVel:Length() < MIN_MOVING_SPEED then
				if tracked[entIdx] then
					tracked[entIdx] = nil
				end
				goto continueEntity
			end

			local data = tracked[entIdx]

			-- 1. Update/Init Kalman Filter
			-- Q=5 (Process Noise - agility), R=100 (Measurement Noise - jitter)
			local dt = globals.TickInterval()
			local smoothedVel

			if data then
				-- Predict with gravity
				local g = 0
				if isSticky then
					g = (Config.physics and Config.physics.sticky_gravity) or 800
				elseif projDef.gravity then
					g = projDef.gravity
				end

				if g ~= 0 then
					data.kalman:predict(Vector3(0, 0, -g * dt))
				else
					data.kalman:predict(nil) -- Just increases uncertainty
				end

				smoothedVel = data.kalman:update(rawVel)
			else
				local kRequest = VectorKalman:new(5, 100, rawVel)
				-- Don't predict/update on first frame, trust raw velocity
				smoothedVel = rawVel
				data = {
					kalman = kRequest,
					positions = {},
					times = {},
					pointCount = 0,
					simStartTime = 0,
					lastPos = entPos,
					seenThisFrame = true,
					radius = projDef.radius,
				}
				tracked[entIdx] = data
			end

			data.seenThisFrame = true

			-- 2. Check Divergence
			-- Predict where it SHOULD be based on simulation
			local shouldResim = false
			local elapsed = curTime - data.simStartTime

			-- Find current point in cached trajectory
			local expectedPos
			if data.pointCount > 0 then
				-- Simple search or interpolation
				-- Just find nearest time index
				for i = 1, data.pointCount - 1 do
					if elapsed >= data.times[i] and elapsed <= data.times[i + 1] then
						local ratio = (elapsed - data.times[i]) / (data.times[i + 1] - data.times[i])
						local p0, p1 = data.positions[i], data.positions[i + 1]
						expectedPos = p0 + (p1 - p0) * ratio
						break
					end
				end
				if not expectedPos and elapsed < data.times[1] then
					expectedPos = data.positions[1]
				end
			end

			if not expectedPos then
				shouldResim = true
			else
				local dx = entPos.x - expectedPos.x
				local dy = entPos.y - expectedPos.y
				local dz = entPos.z - expectedPos.z
				if (dx * dx + dy * dy + dz * dz) > distThresholdSq then
					shouldResim = true
				end
			end

			-- Force resim on new entity
			if data.pointCount == 0 then
				shouldResim = true
			end

			-- 3. Resimulate if needed
			if shouldResim then
				local angVel = Vector3(0, 0, 0) -- Angular velocity hard to get, assume 0 for stable physics or random
				local ps, ts, cnt, imp, pln =
					simulateUnified(entPos, smoothedVel, angVel, projDef, isSticky, 5.0, traceInterval, traceMask)

				if ps then
					data.positions = ps
					data.times = ts
					data.pointCount = cnt
					data.impactPos = imp
					data.impactPlane = pln
					data.simStartTime = curTime
					data.lastPos = entPos
				end
			else
				-- Update last pos for reference
				data.lastPos = entPos
			end

			::continueEntity::
		end
		::continueClass::
	end

	-- Cleanup
	local removeCount = 0
	for idx, d in pairs(tracked) do
		if not d.seenThisFrame then
			removeCount = removeCount + 1
			indicesToRemove[removeCount] = idx
		end
	end
	for i = 1, removeCount do
		tracked[indicesToRemove[i]] = nil
		indicesToRemove[i] = nil
	end
end

function ProjectileTracker.draw()
	local cfg = Config.visual.live_projectiles
	if not cfg.enabled then
		return
	end

	local curTime = globals.CurTime()
	local color = cfg.line

	for idx, data in pairs(tracked) do
		-- Draw the line from current actual position -> end of predicted path
		-- This avoids "interpolated point" illusion breaking
		-- We need to find where we are in the path to skip past segments
		local elapsed = curTime - data.simStartTime
		local startIdx = 1

		-- Skip points already passed
		for i = 1, data.pointCount - 1 do
			if data.times[i + 1] > elapsed then
				startIdx = i
				break
			end
		end

		-- 1. Draw from Entity -> First future point (smooth connection)
		local pEntity = entities.GetByIndex(idx)
		if pEntity then
			local origin = pEntity:GetAbsOrigin()
			local nextPoint = data.positions[startIdx + 1]
			if nextPoint then
				draw.Color(color.r, color.g, color.b, color.a)
				local s1 = client.WorldToScreen(origin)
				local s2 = client.WorldToScreen(nextPoint)
				if s1 and s2 then
					draw.Line(s1[1], s1[2], s2[1], s2[2])
				end
			end
		end

		-- 2. Draw remaining segments
		draw.Color(color.r, color.g, color.b, color.a)
		for i = startIdx + 1, data.pointCount - 1 do
			local p1 = data.positions[i]
			local p2 = data.positions[i + 1]
			local s1 = client.WorldToScreen(p1)
			local s2 = client.WorldToScreen(p2)
			if s1 and s2 then
				draw.Line(s1[1], s1[2], s2[1], s2[2])
			end
		end

		-- 3. Draw Impact Polygon
		if data.impactPos and data.impactPlane then
			-- Temporarily override polygon config radius if we want specific weapon radius
			-- But Visuals uses Config.visual.polygon.size
			-- We'll just pass the plane/pos and let Visuals handle it for now,
			-- OR we modify Visuals to accept size override.
			-- Visuals.drawImpactPolygon(plane, origin) uses global config size.
			-- User asked for "splash radius of the weapon".
			-- We should support size override in drawImpactPolygon.
			-- For now, default call.
			Visuals.drawImpactPolygon(data.impactPlane, data.impactPos, data.radius, color)
		end
	end
end

function ProjectileTracker.clear()
	tracked = {}
end

return ProjectileTracker
