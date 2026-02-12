-- projectile/surface_walker.lua
local SurfaceWalker = {}

-- Ray-march steps to find surface continuity
local TRACE_MASK = (1 | 0x4000) -- MASK_SOLID | CONTENTS_GRATE (standard world clip) - adjust as needed
local STEP_SIZE = 10 -- Step size for "walking" along surface (smaller = smoother but more expensive)
local MAX_STEPS_PER_RAY = 16 -- Cap to prevent infinite loops

local function vector_angles(forward)
	local yaw, pitch
	if forward.y == 0 and forward.x == 0 then
		yaw = 0
		if forward.z > 0 then
			pitch = 270
		else
			pitch = 90
		end
	else
		yaw = (math.atan(forward.y, forward.x) * 180 / math.pi)
		if yaw < 0 then
			yaw = yaw + 360
		end
		pitch = (math.atan(-forward.z, forward:Length2D()) * 180 / math.pi)
		if pitch < 0 then
			pitch = pitch + 360
		end
	end
	return EulerAngles(pitch, yaw, 0)
end

local function angle_vectors(angles)
	local pitch = angles.x * math.pi / 180
	local yaw = angles.y * math.pi / 180
	local cp = math.cos(pitch)
	local sp = math.sin(pitch)
	local cy = math.cos(yaw)
	local sy = math.sin(yaw)
	return Vector3(cp * cy, cp * sy, -sp)
end

-- Perform a "walk" from origin in a specific direction for a max distance
-- Returns the final position after wrapping around geometry
local function WalkRay(origin, direction, maxDist)
	local currentPos = origin
	local remainingDist = maxDist
	local currentDir = direction

	-- Lift the start slightly to avoid z-fighting or starting inside geometry
	-- currentPos = currentPos + (Vector3(0,0,1) * 2)

	local steps = 0

	-- Iterative walking
	while remainingDist > 0 and steps < MAX_STEPS_PER_RAY do
		steps = steps + 1

		-- 1. Try to move forward along current surface direction
		local traceEnd = currentPos + (currentDir * math.min(remainingDist, STEP_SIZE * 4)) -- Look ahead a bit further
		local trace = engine.TraceLine(currentPos, traceEnd, TRACE_MASK)

		local distTravelled = (trace.endpos - currentPos):Length()
		remainingDist = remainingDist - distTravelled
		currentPos = trace.endpos

		if trace.fraction < 1.0 then
			-- We hit a wall/obstacle
			-- Project direction onto the new surface (wall climb)
			-- New Dir = Cross Product logic or just project along plane

			local normal = trace.plane
			-- Project currentDir onto plane defined by normal
			local dot = currentDir:Dot(normal)
			local newDir = currentDir - (normal * dot)
			newDir = newDir / newDir:Length() -- Normalize

			-- Offset slightly from wall
			currentPos = currentPos + (normal * 0.1)

			currentDir = newDir
		else
			-- We moved clear. Check if floor dropped out (cliff)
			-- Trace DOWN from currentPos
			local downTrace = engine.TraceLine(currentPos, currentPos - Vector3(0, 0, STEP_SIZE * 2), TRACE_MASK)

			if downTrace.fraction == 1.0 then
				-- Floor lost (cliff/ledge)
				-- We should probably bend DOWN
				-- For simplicity, let's curve down
				currentDir = Vector3(0, 0, -1)
			elseif downTrace.fraction > 0.05 then
				-- Floor is there, but deeper (slope down)
				-- Snapping to floor
				currentPos = downTrace.endpos + Vector3(0, 0, 0.1) -- small offset
			else
				-- Floor is right there, continue
			end
		end

		if remainingDist <= 1 then
			break
		end
	end

	return currentPos
end

-- Generate the mesh vertices for a splash polygon
-- @param origin: Vector3 - center of explosion
-- @param normal: Vector3 - surface normal at center
-- @param radius: number - splash radius
-- @param segmentCount: number - complexity of polygon
function SurfaceWalker.GenerateSplashMesh(origin, normal, radius, segmentCount)
	segmentCount = segmentCount or 16
	local vertices = {}

	-- Base axis calculation to create a circle on the plane defined by 'normal'
	-- We need an arbitrary 'right' and 'forward' vector on this plane
	local arbitrary = Vector3(0, 0, 1)
	if math.abs(normal.z) > 0.9 then
		arbitrary = Vector3(1, 0, 0)
	end

	local tangent = normal:Cross(arbitrary)
	tangent = tangent / tangent:Length()

	local bitangent = normal:Cross(tangent)

	for i = 0, segmentCount - 1 do
		local theta = (i / segmentCount) * math.pi * 2

		-- Calculate radial direction on the plane
		local cosTheta = math.cos(theta)
		local sinTheta = math.sin(theta)

		local dir = (tangent * cosTheta) + (bitangent * sinTheta)
		dir = dir / dir:Length()

		-- Instead of just adding radius, we "walk" this ray
		-- For optimization, we can reduce step count or use a simpler trace if wanted
		local vertexPos = WalkRay(origin + (normal * 2), dir, radius)

		table.insert(vertices, vertexPos)
	end

	return vertices
end

return SurfaceWalker
