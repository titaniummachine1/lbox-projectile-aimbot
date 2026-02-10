local PhantomTrajectory = {}
local Config = require("config")

-- Store the most recent phantom trajectory (read-only after creation)
local phantomTrajectory = nil

-- Called when we shoot a projectile
function PhantomTrajectory.onProjectileFired(simulationData, fireTime)
	assert(simulationData, "PhantomTrajectory.onProjectileFired: simulationData is nil")
	assert(simulationData.positions, "PhantomTrajectory.onProjectileFired: positions is nil")
	assert(#simulationData.positions > 0, "PhantomTrajectory.onProjectileFired: positions is empty")

	-- Create deep copy of simulation data — this data is NEVER mutated after creation
	local positions = {}
	local times = {}
	local velocities = {}

	for i, pos in ipairs(simulationData.positions) do
		positions[i] = Vector3(pos.x, pos.y, pos.z)
		times[i] = simulationData.times[i] or (i * (Config.computed.trace_interval or 0.015))
		if simulationData.velocities and simulationData.velocities[i] then
			velocities[i] =
				Vector3(simulationData.velocities[i].x, simulationData.velocities[i].y, simulationData.velocities[i].z)
		end
	end

	assert(#positions == #times, "PhantomTrajectory.onProjectileFired: position/time count mismatch")

	phantomTrajectory = {
		positions = positions, -- immutable after creation
		times = times, -- immutable after creation
		velocities = velocities, -- immutable after creation
		pointCount = #positions,
		isValid = simulationData.isValid,
		impactPos = simulationData.impactPos,
		impactPlane = simulationData.impactPlane,
		flagOffset = simulationData.flagOffset,
		fireTime = fireTime,
	}
end

-- Update: only check if trajectory expired. NEVER mutate positions/times.
function PhantomTrajectory.update()
	if not phantomTrajectory then
		return
	end

	local timeSinceFire = globals.CurTime() - phantomTrajectory.fireTime
	local lastTime = phantomTrajectory.times[phantomTrajectory.pointCount]

	-- Only expire trajectory when projectile is past the LAST point
	if timeSinceFire > lastTime then
		phantomTrajectory = nil
	end
end

-- Find interpolated position along trajectory for given elapsed time.
-- Returns: interpolatedPos, segmentIndex (1-based index of segment START point)
-- segmentIndex is the index i such that times[i] <= timeSinceFire <= times[i+1]
local function findInterpolatedPosition(traj, timeSinceFire)
	local positions = traj.positions
	local times = traj.times
	local count = traj.pointCount

	-- Before the first point — clamp to start
	if timeSinceFire <= times[1] then
		return positions[1], 1
	end

	-- Past the last point — clamp to end
	if timeSinceFire >= times[count] then
		return positions[count], count
	end

	-- Find segment: times[i] <= timeSinceFire <= times[i+1]
	for i = 1, count - 1 do
		local t0 = times[i]
		local t1 = times[i + 1]

		if timeSinceFire >= t0 and timeSinceFire <= t1 then
			local segmentDuration = t1 - t0
			if segmentDuration <= 0 then
				return positions[i], i
			end

			local progress = (timeSinceFire - t0) / segmentDuration
			-- progress is already in [0, 1] since timeSinceFire is in [t0, t1]

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

	-- Should never reach here, but clamp to last as safety
	return positions[count], count
end

-- Draw phantom trajectory
function PhantomTrajectory.draw()
	if not Config.visual.phantom_trajectory.enabled then
		return
	end

	if not phantomTrajectory then
		return
	end

	local traj = phantomTrajectory
	local timeSinceFire = globals.CurTime() - traj.fireTime

	-- Find interpolated yellow point position and which segment it's in
	local currentPos, currentSegmentIdx = findInterpolatedPosition(traj, timeSinceFire)
	assert(currentPos, "PhantomTrajectory.draw: interpolation returned nil position")
	assert(currentSegmentIdx, "PhantomTrajectory.draw: interpolation returned nil segment index")

	-- Draw white trajectory line (only segments from currentSegmentIdx forward)
	local color = Config.visual.line
	draw.Color(color.r, color.g, color.b, color.a)

	-- Current segment: draw from yellow point to segment end point
	-- (this is the segment where currentSegmentIdx <= timeSinceFire <= currentSegmentIdx+1)
	if currentSegmentIdx < traj.pointCount then
		local segEnd = traj.positions[currentSegmentIdx + 1]
		local s1 = client.WorldToScreen(currentPos)
		local s2 = client.WorldToScreen(segEnd)
		if s1 and s1[1] and s1[2] and s2 and s2[1] and s2[2] then
			draw.Line(s1[1], s1[2], s2[1], s2[2])
		end
	end

	-- Future segments: draw normally (from currentSegmentIdx+1 onward)
	for i = currentSegmentIdx + 1, traj.pointCount - 1 do
		local p1 = traj.positions[i]
		local p2 = traj.positions[i + 1]
		local s1 = client.WorldToScreen(p1)
		local s2 = client.WorldToScreen(p2)
		if s1 and s1[1] and s1[2] and s2 and s2[1] and s2[2] then
			draw.Line(s1[1], s1[2], s2[1], s2[2])
		end
	end

	-- Draw yellow interpolated projectile indicator
	local screen = client.WorldToScreen(currentPos)
	if screen and screen[1] and screen[2] then
		draw.Color(255, 255, 0, 255)
		draw.FilledRect(screen[1] - 4, screen[2] - 4, screen[1] + 4, screen[2] + 4)
	end
end

-- Clear phantom trajectory
function PhantomTrajectory.clear()
	phantomTrajectory = nil
end

return PhantomTrajectory
