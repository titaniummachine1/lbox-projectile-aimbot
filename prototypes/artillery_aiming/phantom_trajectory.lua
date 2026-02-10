local PhantomTrajectory = {}
local Config = require("config")

-- Store the most recent phantom trajectory
local phantomTrajectory = nil

-- Called when we shoot a projectile
function PhantomTrajectory.onProjectileFired(simulationData, fireTime)
	if not simulationData or not simulationData.positions or #simulationData.positions == 0 then
		print("[PhantomTrajectory] No simulation data!")
		return
	end

	print("[PhantomTrajectory] Creating phantom with", #simulationData.positions, "points")

	-- Create deep copy of simulation data with time stamps
	phantomTrajectory = {
		positions = {},
		velocities = {},
		times = {}, -- Copy actual time data from simulation
		lastTime = 0,
		isValid = simulationData.isValid,
		impactPos = simulationData.impactPos,
		impactPlane = simulationData.impactPlane,
		flagOffset = simulationData.flagOffset,
		fireTime = fireTime,
	}

	-- Copy positions, velocities, and times from simulation
	for i, pos in ipairs(simulationData.positions) do
		phantomTrajectory.positions[i] = Vector3(pos.x, pos.y, pos.z)
		phantomTrajectory.times[i] = simulationData.times[i] or (i * (Config.computed.trace_interval or 0.015))
		if simulationData.velocities[i] then
			phantomTrajectory.velocities[i] =
				Vector3(simulationData.velocities[i].x, simulationData.velocities[i].y, simulationData.velocities[i].z)
		end
	end

	print("[PhantomTrajectory] Created phantom trajectory with", #phantomTrajectory.positions, "points")
end

-- Update phantom trajectory (remove points based on actual time stamps with interpolation)
function PhantomTrajectory.update()
	if not phantomTrajectory or not phantomTrajectory.positions or #phantomTrajectory.positions == 0 then
		return
	end

	local currentTime = globals.CurTime() -- Use engine time, not real time
	local timeSinceFire = currentTime - phantomTrajectory.fireTime

	-- Remove all points already passed and track last passed time
	while #phantomTrajectory.times > 0 and phantomTrajectory.times[1] <= timeSinceFire do
		phantomTrajectory.lastTime = phantomTrajectory.times[1]
		table.remove(phantomTrajectory.positions, 1)
		table.remove(phantomTrajectory.times, 1)
		if phantomTrajectory.velocities and #phantomTrajectory.velocities > 0 then
			table.remove(phantomTrajectory.velocities, 1)
		end
	end

	-- Calculate interpolation for current projectile position
	if #phantomTrajectory.positions >= 2 then
		local prevTime = phantomTrajectory.lastTime or 0
		local nextTime = phantomTrajectory.times[1] or prevTime
		local timeBetween = nextTime - prevTime
		if timeBetween > 0 then
			phantomTrajectory.interpolationProgress = (timeSinceFire - prevTime) / timeBetween
			phantomTrajectory.interpolationProgress = math.max(0, math.min(1, phantomTrajectory.interpolationProgress))
		else
			phantomTrajectory.interpolationProgress = 0
		end
	elseif #phantomTrajectory.positions == 1 then
		phantomTrajectory.interpolationProgress = 1
	else
		phantomTrajectory.interpolationProgress = 0
	end

	-- Clear trajectory if no points left
	if #phantomTrajectory.positions == 0 then
		phantomTrajectory = nil
	end
end

-- Draw phantom trajectory
function PhantomTrajectory.draw()
	if not Config.visual.phantom_trajectory.enabled then
		return
	end

	if not phantomTrajectory or not phantomTrajectory.positions or #phantomTrajectory.positions == 0 then
		return
	end

	-- Draw exactly like normal trajectory line
	local color = Config.visual.line
	draw.Color(color.r, color.g, color.b, color.a)

	-- Draw the trajectory lines
	for i = 1, #phantomTrajectory.positions - 1 do
		local pos1 = phantomTrajectory.positions[i]
		local pos2 = phantomTrajectory.positions[i + 1]

		if pos1 and pos2 then
			local screen1 = client.WorldToScreen(pos1)
			local screen2 = client.WorldToScreen(pos2)

			if screen1 and screen1[1] and screen1[2] and screen2 and screen2[1] and screen2[2] then
				draw.Line(screen1[1], screen1[2], screen2[1], screen2[2])
			end
		end
	end

	-- Draw interpolated projectile position (where projectile should be right now)
	if phantomTrajectory.interpolationProgress and #phantomTrajectory.positions >= 1 then
		local progress = phantomTrajectory.interpolationProgress

		-- If we have at least 2 points, interpolate between first two
		if #phantomTrajectory.positions >= 2 then
			local pos1 = phantomTrajectory.positions[1]
			local pos2 = phantomTrajectory.positions[2]

			if pos1 and pos2 then
				-- Linear interpolation between points
				local currentX = pos1.x + (pos2.x - pos1.x) * progress
				local currentY = pos1.y + (pos2.y - pos1.y) * progress
				local currentZ = pos1.z + (pos2.z - pos1.z) * progress
				local currentPos = Vector3(currentX, currentY, currentZ)

				local screen = client.WorldToScreen(currentPos)
				if screen and screen[1] and screen[2] then
					-- Draw a larger indicator for current projectile position
					draw.Color(255, 255, 0, 255) -- Yellow color
					draw.FilledRect(screen[1] - 4, screen[2] - 4, screen[1] + 4, screen[2] + 4)
				end
			end
		else
			-- Only one point left, draw it
			local pos = phantomTrajectory.positions[1]
			if pos then
				local screen = client.WorldToScreen(pos)
				if screen and screen[1] and screen[2] then
					draw.Color(255, 255, 0, 255) -- Yellow color
					draw.FilledRect(screen[1] - 4, screen[2] - 4, screen[1] + 4, screen[2] + 4)
				end
			end
		end
	end
end

-- Clear phantom trajectory
function PhantomTrajectory.clear()
	phantomTrajectory = nil
	print("[PhantomTrajectory] Cleared phantom trajectory")
end

return PhantomTrajectory
