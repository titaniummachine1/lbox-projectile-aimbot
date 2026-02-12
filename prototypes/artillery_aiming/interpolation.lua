local Interpolation = {}

-- Find interpolated position along trajectory for given elapsed time
-- Returns: interpolatedPos, segmentIndex (1-based index of segment START point)
-- segmentIndex is the index i such that times[i] <= timeSinceFire <= times[i+1]
function Interpolation.findPosition(traj, timeSinceFire)
	local positions = traj.positions
	local times = traj.times
	local count = traj.pointCount or #positions
	
	if count < 2 then
		return positions[1], 1
	end
	
	-- Find the correct segment
	for i = 1, count - 1 do
		local segmentStartTime = times[i]
		local segmentEndTime = times[i + 1]
		
		if segmentStartTime and segmentEndTime and timeSinceFire >= segmentStartTime and timeSinceFire <= segmentEndTime then
			local pos1 = positions[i]
			local pos2 = positions[i + 1]
			
			if pos1 and pos2 then
				local segmentDuration = segmentEndTime - segmentStartTime
				local timeInSegment = timeSinceFire - segmentStartTime
				
				-- Simple exact interpolation (no smoothing)
				local progress = (segmentDuration > 0) and (timeInSegment / segmentDuration) or 0
				progress = math.max(0, math.min(1, progress))
				
				local interpolatedPos = Vector3(
					pos1.x + (pos2.x - pos1.x) * progress,
					pos1.y + (pos2.y - pos1.y) * progress,
					pos1.z + (pos2.z - pos1.z) * progress
				)
				
				return interpolatedPos, i
			end
		end
	end
	
	-- If we're past the end, use the last position
	local lastTime = times[count]
	if lastTime and timeSinceFire >= lastTime then
		return positions[count], count
	end
	
	-- If we're before the start, use the first position
	return positions[1], 1
end

-- Linear interpolation between two values
function Interpolation.lerp(a, b, t)
	return a + (b - a) * t
end

-- Linear interpolation between two vectors
function Interpolation.lerpVector(v1, v2, t)
	return Vector3(
		v1.x + (v2.x - v1.x) * t,
		v1.y + (v2.y - v1.y) * t,
		v1.z + (v2.z - v1.z) * t
	)
end

-- Smooth step interpolation
function Interpolation.smoothStep(t)
	return t * t * (3 - 2 * t)
end

-- Clamp value between min and max
function Interpolation.clamp(value, minVal, maxVal)
	return math.max(minVal, math.min(maxVal, value))
end

return Interpolation
