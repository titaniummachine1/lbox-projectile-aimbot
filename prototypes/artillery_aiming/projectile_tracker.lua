local Config = require("config")

local ProjectileTracker = {}

-- Projectile class definitions with CORRECT gravity/drag matching entity.lua
-- These gravity/drag values correspond to itemCase > 3 in Entity.GetProjectileInformation
-- Stickies (cases 1-3) use physics env with gravity=0, they are physics-simulated objects
-- but once airborne they behave roughly like gravity=800 drag=nil in the simple model.
-- Pipes are case 4: gravity=400, drag=0.45
local PROJECTILE_CLASSES = {
	{ class = "CTFProjectile_Rocket", configKey = "rockets", gravity = 0, drag = nil },
	{ class = "CTFGrenadePipebombProjectile", configKey = "pipes", gravity = 400, drag = 0.45 },
	{ class = "CTFProjectile_Flare", configKey = "flares", gravity = 120, drag = 0.5 },
	{ class = "CTFProjectile_Arrow", configKey = "arrows", gravity = 200, drag = nil },
	{ class = "CTFProjectile_EnergyBall", configKey = "energy", gravity = 80, drag = nil },
	{ class = "CTFProjectile_BallOfFire", configKey = "fireballs", gravity = 120, drag = nil },
}

-- Sticky type constant (m_iType == 1 means sticky, 0 means pipe)
local PIPEBOMB_TYPE_STICKY = 1

-- Minimum velocity to consider a projectile "moving" (hu/s)
local MIN_MOVING_SPEED = 10

-- Hoisted math
local DEG_TO_RAD = math.pi / 180
local COS_FUNC = math.cos
local SQRT_FUNC = math.sqrt
local EXP_FUNC = math.exp

local traceLineFunc = engine.TraceLine

-- Tracked projectile data keyed by entity index
local tracked = {}

-- Pre-allocated removal buffer
local indicesToRemove = {}

-- Simulate trajectory using the EXACT same formula as simulation.lua (itemCase > 3 branch)
-- Formula:
--   scalar = (drag == nil) and t or ((1 - exp(-drag * t)) / drag)
--   pos.x = velocity.x * scalar + startPos.x
--   pos.y = velocity.y * scalar + startPos.y
--   pos.z = (velocity.z - gravity * t) * scalar + startPos.z
-- Loop starts at 0.01515, steps by traceInterval, up to maxTime
local function simulateTrajectory(startPos, velocity, gravity, drag, maxTime, traceInterval, traceMask)
	local positions = {}
	local times = {}
	local count = 1

	positions[1] = Vector3(startPos.x, startPos.y, startPos.z)
	times[1] = 0

	local prevEndPos = startPos

	for t = 0.01515, maxTime, traceInterval do
		local scalar
		if drag then
			scalar = (1 - EXP_FUNC(-drag * t)) / drag
		else
			scalar = t
		end

		local px = velocity.x * scalar + startPos.x
		local py = velocity.y * scalar + startPos.y
		local pz = (velocity.z - gravity * t) * scalar + startPos.z

		local predPos = Vector3(px, py, pz)
		local traceResult = traceLineFunc(prevEndPos, predPos, traceMask)

		count = count + 1
		positions[count] = traceResult.endpos
		times[count] = t

		if traceResult.fraction < 1.0 then
			break
		end

		prevEndPos = traceResult.endpos
	end

	return positions, times, count
end

-- Normalize a vector, returns direction components and length
local function normalizeVec(vx, vy, vz)
	local len = SQRT_FUNC(vx * vx + vy * vy + vz * vz)
	if len < 0.001 then
		return 0, 0, 0, 0
	end
	return vx / len, vy / len, vz / len, len
end

-- Check if direction has diverged beyond threshold (dot product check)
local function hasDirectionDiverged(dirAx, dirAy, dirAz, dirBx, dirBy, dirBz, angleThresholdDeg)
	local dot = dirAx * dirBx + dirAy * dirBy + dirAz * dirBz
	local thresholdCos = COS_FUNC(angleThresholdDeg * DEG_TO_RAD)
	return dot < thresholdCos
end

-- Find interpolated position along cached trajectory
local function findInterpolatedPosition(positions, times, pointCount, elapsed)
	if elapsed <= times[1] then
		return positions[1], 1
	end

	if elapsed >= times[pointCount] then
		return positions[pointCount], pointCount
	end

	for i = 1, pointCount - 1 do
		local t0 = times[i]
		local t1 = times[i + 1]

		if elapsed >= t0 and elapsed <= t1 then
			local segDur = t1 - t0
			if segDur <= 0 then
				return positions[i], i
			end

			local progress = (elapsed - t0) / segDur
			local p0 = positions[i]
			local p1 = positions[i + 1]
			local interpPos = Vector3(
				p0.x + (p1.x - p0.x) * progress,
				p0.y + (p1.y - p0.y) * progress,
				p0.z + (p1.z - p0.z) * progress
			)
			return interpPos, i
		end
	end

	return positions[pointCount], pointCount
end

-- Determine sticky vs pipe for CTFGrenadePipebombProjectile
local function getPipebombConfigKey(entity)
	local bombType = entity:GetPropInt("m_iType")
	if bombType and bombType == PIPEBOMB_TYPE_STICKY then
		return "stickies"
	end
	return "pipes"
end

-- Scan for projectiles, simulate and cache trajectories
function ProjectileTracker.update()
	local cfg = Config.visual.live_projectiles
	if not cfg.enabled then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return
	end

	local localPos = pLocal:GetAbsOrigin()
	local curTime = globals.CurTime()
	local maxDistSq = cfg.max_distance * cfg.max_distance
	local traceInterval = Config.computed.trace_interval or 0.015
	local traceMask = Config.TRACE_MASK
	local angleThreshold = cfg.revalidate_angle
	local distThreshold = cfg.revalidate_distance
	local distThresholdSq = distThreshold * distThreshold

	-- Mark all tracked as "not seen"
	for _, data in pairs(tracked) do
		data.seenThisFrame = false
	end

	for _, projDef in ipairs(PROJECTILE_CLASSES) do
		local configKey = projDef.configKey
		local isPipebomb = (projDef.class == "CTFGrenadePipebombProjectile")

		if isPipebomb then
			if not cfg.stickies and not cfg.pipes then
				goto continueClass
			end
		elseif not cfg[configKey] then
			goto continueClass
		end

		local foundEntities = entities.FindByClass(projDef.class)

		for _, entity in pairs(foundEntities) do
			if not (entity and entity:IsValid() and not entity:IsDormant()) then
				goto continueEntity
			end

			-- Per-entity type check for pipebombs
			local effectiveKey = configKey
			if isPipebomb then
				effectiveKey = getPipebombConfigKey(entity)
				if not cfg[effectiveKey] then
					goto continueEntity
				end
			end

			local entIdx = entity:GetIndex()
			local entPos = entity:GetAbsOrigin()

			-- Distance filter from local player
			local dx = entPos.x - localPos.x
			local dy = entPos.y - localPos.y
			local dz = entPos.z - localPos.z
			if (dx * dx + dy * dy + dz * dz) > maxDistSq then
				goto continueEntity
			end

			-- Use EstimateAbsVelocity for CURRENT velocity
			local currentVel = entity:EstimateAbsVelocity()
			if not currentVel then
				goto continueEntity
			end

			local speed = currentVel:Length()

			-- Skip stopped projectiles (stickies on ground, landed pipes)
			if speed < MIN_MOVING_SPEED then
				if tracked[entIdx] then
					tracked[entIdx] = nil
				end
				goto continueEntity
			end

			local existing = tracked[entIdx]

			if existing then
				existing.seenThisFrame = true

				-- Check 1: Distance from expected position (threshold = 10 units)
				local elapsed = curTime - existing.simStartTime
				local expectedPos, _ =
					findInterpolatedPosition(existing.positions, existing.times, existing.pointCount, elapsed)

				local shouldResim = false

				if expectedPos then
					local edx = entPos.x - expectedPos.x
					local edy = entPos.y - expectedPos.y
					local edz = entPos.z - expectedPos.z
					local edistSq = edx * edx + edy * edy + edz * edz
					if edistSq > distThresholdSq then
						shouldResim = true
					end
				end

				-- Check 2: Direction diverged from stored direction
				if not shouldResim then
					local moveDx = entPos.x - existing.lastPos.x
					local moveDy = entPos.y - existing.lastPos.y
					local moveDz = entPos.z - existing.lastPos.z
					local moveDirX, moveDirY, moveDirZ, moveLen = normalizeVec(moveDx, moveDy, moveDz)

					if moveLen > 1 then
						local storedDirX = existing.storedDirX
						local storedDirY = existing.storedDirY
						local storedDirZ = existing.storedDirZ
						if
							storedDirX
							and hasDirectionDiverged(
								moveDirX,
								moveDirY,
								moveDirZ,
								storedDirX,
								storedDirY,
								storedDirZ,
								angleThreshold
							)
						then
							shouldResim = true
						end
					end
				end

				-- Update last known position
				existing.lastPos = entPos

				if shouldResim then
					local positions, times, pointCount = simulateTrajectory(
						entPos,
						currentVel,
						projDef.gravity,
						projDef.drag,
						5,
						traceInterval,
						traceMask
					)
					existing.positions = positions
					existing.times = times
					existing.pointCount = pointCount
					existing.simStartTime = curTime

					local ndx, ndy, ndz, _ = normalizeVec(currentVel.x, currentVel.y, currentVel.z)
					existing.storedDirX = ndx
					existing.storedDirY = ndy
					existing.storedDirZ = ndz
				end
			else
				-- New projectile: simulate from current position + current velocity
				local positions, times, pointCount =
					simulateTrajectory(entPos, currentVel, projDef.gravity, projDef.drag, 5, traceInterval, traceMask)

				local ndx, ndy, ndz, _ = normalizeVec(currentVel.x, currentVel.y, currentVel.z)

				tracked[entIdx] = {
					positions = positions,
					times = times,
					pointCount = pointCount,
					simStartTime = curTime,
					lastPos = entPos,
					storedDirX = ndx,
					storedDirY = ndy,
					storedDirZ = ndz,
					seenThisFrame = true,
					configKey = effectiveKey,
				}
			end

			::continueEntity::
		end
		::continueClass::
	end

	-- Remove entries that disappeared
	local removeCount = 0
	for idx, data in pairs(tracked) do
		if not data.seenThisFrame then
			removeCount = removeCount + 1
			indicesToRemove[removeCount] = idx
		end
	end
	for i = 1, removeCount do
		tracked[indicesToRemove[i]] = nil
		indicesToRemove[i] = nil
	end
end

-- Draw all tracked projectiles
function ProjectileTracker.draw()
	local cfg = Config.visual.live_projectiles
	if not cfg.enabled then
		return
	end

	local curTime = globals.CurTime()
	local lineColor = cfg.line
	local markerColor = cfg.marker
	local markerSize = cfg.marker_size

	for _, data in pairs(tracked) do
		local elapsed = curTime - data.simStartTime

		if elapsed > data.times[data.pointCount] then
			goto continueProj
		end

		local currentPos, currentSegIdx = findInterpolatedPosition(data.positions, data.times, data.pointCount, elapsed)

		if not currentPos then
			goto continueProj
		end

		-- Draw trajectory line from interpolated position forward
		draw.Color(lineColor.r, lineColor.g, lineColor.b, lineColor.a)

		-- Current segment: interpolated pos to segment end
		if currentSegIdx < data.pointCount then
			local segEnd = data.positions[currentSegIdx + 1]
			local s1 = client.WorldToScreen(currentPos)
			local s2 = client.WorldToScreen(segEnd)
			if s1 and s1[1] and s1[2] and s2 and s2[1] and s2[2] then
				draw.Line(s1[1], s1[2], s2[1], s2[2])
			end
		end

		-- Future segments
		for i = currentSegIdx + 1, data.pointCount - 1 do
			local p1 = data.positions[i]
			local p2 = data.positions[i + 1]
			local s1 = client.WorldToScreen(p1)
			local s2 = client.WorldToScreen(p2)
			if s1 and s1[1] and s1[2] and s2 and s2[1] and s2[2] then
				draw.Line(s1[1], s1[2], s2[1], s2[2])
			end
		end

		-- Draw marker at interpolated position
		local screen = client.WorldToScreen(currentPos)
		if screen and screen[1] and screen[2] then
			draw.Color(markerColor.r, markerColor.g, markerColor.b, markerColor.a)
			draw.FilledRect(
				screen[1] - markerSize,
				screen[2] - markerSize,
				screen[1] + markerSize,
				screen[2] + markerSize
			)
		end

		::continueProj::
	end
end

-- Clear all tracked projectiles
function ProjectileTracker.clear()
	for k in pairs(tracked) do
		tracked[k] = nil
	end
end

-- Get count of tracked projectiles (debug/menu)
function ProjectileTracker.getTrackedCount()
	local count = 0
	for _ in pairs(tracked) do
		count = count + 1
	end
	return count
end

return ProjectileTracker
