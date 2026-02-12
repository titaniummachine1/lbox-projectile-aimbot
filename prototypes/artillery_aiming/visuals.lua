local Config = require("config")
local State = require("state")
local Utils = require("utils")

local worldToScreen = client.WorldToScreen
local drawLine = draw.Line
local setColor = draw.Color
local getScreenSize = draw.GetScreenSize

local Visuals = {}

-- Create the polygon texture for filled polygons
local g_iPolygonTexture = draw.CreateTextureRGBA("\xff\xff\xff" .. string.char(Config.visual.polygon.a), 1, 1)

local TRACE_MASK = 100679691
local RADIAL_STEP = 25
local ELEVATION_STEP = 8

local function normalizeVector(vec)
	if not vec then
		return nil, 0
	end
	local length = vec:Length()
	if length < 0.001 then
		return nil, length
	end
	return vec / length, length
end

local function projectOntoPlane(vec, normal)
	if not vec or not normal then
		return nil
	end
	local normNormal = normalizeVector(normal)
	if not normNormal then
		return nil
	end
	local projected = vec - normNormal * vec:Dot(normNormal)
	return normalizeVector(projected)
end

local function clampToRadius(center, pos, radius)
	local offset = pos - center
	local dir, len = normalizeVector(offset)
	if not dir then
		return center
	end
	if len == radius then
		return pos
	end
	return center + dir * radius
end

local function drawOutlinedLine(from, to)
	setColor(Config.visual.outline.r, Config.visual.outline.g, Config.visual.outline.b, Config.visual.outline.a)
	if math.abs(from[1] - to[1]) > math.abs(from[2] - to[2]) then
		drawLine(math.floor(from[1]), math.floor(from[2] - 1), math.floor(to[1]), math.floor(to[2] - 1))
		drawLine(math.floor(from[1]), math.floor(from[2] + 1), math.floor(to[1]), math.floor(to[2] + 1))
	else
		drawLine(math.floor(from[1] - 1), math.floor(from[2]), math.floor(to[1] - 1), math.floor(to[2]))
		drawLine(math.floor(from[1] + 1), math.floor(from[2]), math.floor(to[1] + 1), math.floor(to[2]))
	end
end

function Visuals.drawImpactPolygon(plane, origin, radiusOverride, colorOverride)
	-- Use crawling explosion radius instead of flat polygon
	-- plane is the impact normal, origin is impact position
	local explosionRadius = radiusOverride or 146 -- Use actual TF2 explosion radius
	Visuals.drawCrawlingExplosionRadius(origin, plane, explosionRadius, colorOverride)
end

function Visuals.drawTrajectory()
	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	local traj = State.trajectory
	if not traj.isValid then
		return
	end

	if traj.impactPlane and traj.impactPos then
		local polygonColor = {
			r = Config.visual.polygon.r,
			g = Config.visual.polygon.g,
			b = Config.visual.polygon.b,
			a = Config.visual.polygon.a,
		}
		Visuals.drawCrawlingExplosionRadius(
			traj.impactPos,
			traj.impactPlane,
			Config.visual.polygon.size,
			polygonColor
		)
	end

	local num = #traj.positions
	local lastScreen = nil
	for i = 1, num do
		local worldPos = traj.positions[i]
		local screenPos = worldToScreen(worldPos)
		local flagScreenPos = worldToScreen(worldPos + traj.flagOffset)
		if lastScreen and screenPos then
			if Config.visual.line.enabled then
				if Config.visual.outline.line_and_flags then
					drawOutlinedLine(lastScreen, screenPos)
				end
				setColor(Config.visual.line.r, Config.visual.line.g, Config.visual.line.b, Config.visual.line.a)
				drawLine(lastScreen[1], lastScreen[2], screenPos[1], screenPos[2])
			end
			if Config.visual.flags.enabled and flagScreenPos then
				if Config.visual.outline.line_and_flags then
					drawOutlinedLine(flagScreenPos, screenPos)
				end
				setColor(Config.visual.flags.r, Config.visual.flags.g, Config.visual.flags.b, Config.visual.flags.a)
				drawLine(flagScreenPos[1], flagScreenPos[2], screenPos[1], screenPos[2])
			end
		end
		lastScreen = screenPos
	end
end

function Visuals.drawAimGuide()
	local st = State.bombard
	if not st.originPoint or not st.targetPoint then
		return
	end

	local start2d = worldToScreen(st.originPoint)
	local end2d = worldToScreen(st.targetPoint)
	if not start2d or not end2d then
		return
	end

	setColor(0, 255, 0, 255)
	drawLine(math.floor(start2d[1]), math.floor(start2d[2]), math.floor(end2d[1]), math.floor(end2d[2]))
end

function Visuals.drawTrackerTrajectory(proj)
	if not proj or not proj.predictedPath then
		return
	end

	-- Draw projectile trajectory path
	if #proj.predictedPath > 1 then
		setColor(
			Config.visual.live_projectiles.line.r,
			Config.visual.live_projectiles.line.g,
			Config.visual.live_projectiles.line.b,
			Config.visual.live_projectiles.line.a
		)

		for i = 1, #proj.predictedPath - 1 do
			local p1 = worldToScreen(proj.predictedPath[i])
			local p2 = worldToScreen(proj.predictedPath[i + 1])
			if p1 and p2 then
				drawLine(math.floor(p1[1]), math.floor(p1[2]), math.floor(p2[1]), math.floor(p2[2]))
			end
		end
	end

	-- Draw crawling explosion radius
	if proj.radius and (proj.impactPos or proj.origin) then
		local polygonColor = {
			r = Config.visual.polygon.r,
			g = Config.visual.polygon.g,
			b = Config.visual.polygon.b,
			a = Config.visual.polygon.a,
		}
		local surfaceNormal = proj.impactPlane
		local speed = nil
		if proj.lastVel then
			speed = proj.lastVel:Length()
		end
		if (not surfaceNormal or surfaceNormal:Length() < 0.01) and proj.lastSurfaceNormal then
			surfaceNormal = proj.lastSurfaceNormal
		end
		local impactCenter = proj.impactPos or proj.origin or proj.lastPos
		local isStatic = false
		if speed and speed < 10 then
			isStatic = true
			surfaceNormal = proj.lastSurfaceNormal or surfaceNormal
			if proj.entity and proj.entity:IsValid() then
				impactCenter = proj.entity:GetAbsOrigin()
			else
				impactCenter = proj.lastPos or impactCenter
			end
		end
		surfaceNormal = surfaceNormal or Vector3(0, 0, 1)
		if impactCenter then
			Visuals.drawCrawlingExplosionRadius(
				impactCenter,
				surfaceNormal,
				Config.visual.live_projectiles.explosion_radius,
				polygonColor
			)
		end
	end
end

function Visuals.drawCrawlingExplosionRadius(center, surfaceNormal, radius, colorOverride)
	if not Config.visual.polygon.enabled then
		return
	end

	local iSegments = Config.visual.polygon.segments
	local positions = {} -- now each positions[i] will be an array of sub-segments

	for i = 1, iSegments do
		local angle = (i - 1) * (2 * math.pi / iSegments)
		local radialDir = Vector3(math.cos(angle), math.sin(angle), 0)
		radialDir = normalizeVector(radialDir) or Vector3(1, 0, 0)

		local currentPos = center
		local currentDir = radialDir
		local subSegments = {{pos = center, dir = radialDir}}
		local lastNormal = nil -- Will be set to first hit surface normal

		local steps = 0
		local maxSteps = 64

		while steps < maxSteps do
			steps = steps + 1
			local offset = currentPos - center
			local dist = offset:Length()
			if dist >= radius - 0.5 then
				break
			end

			local remaining = radius - dist
			local stepSize = math.min(remaining, RADIAL_STEP)
			local desiredEnd = currentPos + currentDir * stepSize
			local groundTrace = engine.TraceLine(currentPos, desiredEnd, TRACE_MASK)

			if groundTrace.fraction >= 0.98 then
				currentPos = desiredEnd
				goto continue_segment
			end

			-- Hit something - always use the hit surface normal as lastNormal
			local hitNormal = groundTrace.plane or surfaceNormal
			if not lastNormal then
				lastNormal = hitNormal -- First hit becomes the reference surface
			end

			local shouldChangeDirection = false
			if lastNormal then
				local dot = hitNormal:Dot(lastNormal)
				if dot < 0.95 then -- surface changed
					shouldChangeDirection = true
				end
			end

			if shouldChangeDirection then
				-- Create new sub-segment with adjusted direction
				local outward = normalizeVector(currentPos - center) or currentDir
				local projected = projectOntoPlane(outward, hitNormal)
				if projected then
					currentDir = projected
					table.insert(subSegments, {pos = currentPos, dir = currentDir})
					
					-- Step down after surface adjustment
					local downDir = -hitNormal
					local downTrace = engine.TraceLine(currentPos, currentPos + downDir * 150, TRACE_MASK)
					if downTrace.fraction < 1.0 then
						currentPos = currentPos + downDir * (150 * downTrace.fraction)
						currentPos = clampToRadius(center, currentPos, radius)
						table.insert(subSegments, {pos = currentPos, dir = currentDir})
					end
				end
				lastNormal = hitNormal -- Update to new surface
			end

			-- Try elevation using last hit surface normal
			local elevatedStart = currentPos + hitNormal * ELEVATION_STEP
			local elevatedEnd = elevatedStart + currentDir * stepSize
			local elevatedTrace = engine.TraceLine(elevatedStart, elevatedEnd, TRACE_MASK)

			if elevatedTrace.fraction >= 0.98 then
				currentPos = elevatedStart + currentDir * (stepSize * elevatedTrace.fraction)
				table.insert(subSegments, {pos = currentPos, dir = currentDir})
				
				-- Step down after elevation
				local downDir = -hitNormal
				local downTrace = engine.TraceLine(currentPos, currentPos + downDir * 150, TRACE_MASK)
				if downTrace.fraction < 1.0 then
					currentPos = currentPos + downDir * (150 * downTrace.fraction)
					currentPos = clampToRadius(center, currentPos, radius)
					table.insert(subSegments, {pos = currentPos, dir = currentDir})
				end
				goto continue_segment
			end

			-- If elevation failed, try sliding parallel to last hit surface
			local slideDir = projectOntoPlane(currentDir, hitNormal)
			if slideDir then
				currentDir = slideDir
				local slideEnd = currentPos + currentDir * stepSize
				local slideTrace = engine.TraceLine(currentPos, slideEnd, TRACE_MASK)
				if slideTrace.fraction >= 0.1 then
					currentPos = currentPos + currentDir * (stepSize * slideTrace.fraction)
					table.insert(subSegments, {pos = currentPos, dir = currentDir})
					
					-- Step down after sliding
					local downDir = -hitNormal
					local downTrace = engine.TraceLine(currentPos, currentPos + downDir * 150, TRACE_MASK)
					if downTrace.fraction < 1.0 then
						currentPos = currentPos + downDir * (150 * downTrace.fraction)
						currentPos = clampToRadius(center, currentPos, radius)
						table.insert(subSegments, {pos = currentPos, dir = currentDir})
					end
					goto continue_segment
				end
			end

			-- If all failed, try to go around obstacle using last hit surface
			local outward = normalizeVector(currentPos - center) or currentDir
			local alternativeDir = projectOntoPlane(outward, hitNormal)
			if alternativeDir then
				currentDir = alternativeDir
				local altEnd = currentPos + currentDir * (stepSize * 0.5) -- smaller step
				local altTrace = engine.TraceLine(currentPos, altEnd, TRACE_MASK)
				if altTrace.fraction >= 0.5 then
					currentPos = currentPos + currentDir * (stepSize * 0.5 * altTrace.fraction)
					table.insert(subSegments, {pos = currentPos, dir = currentDir})
					
					-- Step down after alternative direction
					local downDir = -hitNormal
					local downTrace = engine.TraceLine(currentPos, currentPos + downDir * 150, TRACE_MASK)
					if downTrace.fraction < 1.0 then
						currentPos = currentPos + downDir * (150 * downTrace.fraction)
						currentPos = clampToRadius(center, currentPos, radius)
						table.insert(subSegments, {pos = currentPos, dir = currentDir})
					end
					goto continue_segment
				end
			end

			-- Last resort: move a small step in any direction that makes progress
			local progressDir = normalizeVector(currentPos - center) or currentDir
			local smallStep = stepSize * 0.25
			local smallEnd = currentPos + progressDir * smallStep
			local smallTrace = engine.TraceLine(currentPos, smallEnd, TRACE_MASK)
			if smallTrace.fraction >= 0.25 then
				currentPos = currentPos + progressDir * (smallStep * smallTrace.fraction)
				table.insert(subSegments, {pos = currentPos, dir = progressDir})
				
				-- Step down after small progress
				local downDir = -(lastNormal or surfaceNormal)
				local downTrace = engine.TraceLine(currentPos, currentPos + downDir * 150, TRACE_MASK)
				if downTrace.fraction < 1.0 then
					currentPos = currentPos + downDir * (150 * downTrace.fraction)
					currentPos = clampToRadius(center, currentPos, radius)
					table.insert(subSegments, {pos = currentPos, dir = progressDir})
				end
				goto continue_segment
			end

			-- If absolutely stuck, break but continue to next segment
			break

			::continue_segment::
		end

		-- Add final position
		local finalPos = clampToRadius(center, currentPos, radius)
		table.insert(subSegments, {pos = finalPos, dir = currentDir})

		-- Step down logic using last hit surface normal (always happens)
		local downDir = -(lastNormal or surfaceNormal)
		local downTrace = engine.TraceLine(finalPos, finalPos + downDir * 150, TRACE_MASK)
		if downTrace.fraction < 1.0 then
			finalPos = finalPos + downDir * (150 * downTrace.fraction)
			finalPos = clampToRadius(center, finalPos, radius)
		end
		subSegments[#subSegments].pos = finalPos

		positions[i] = subSegments
	end

	local centerScreen = worldToScreen(center)
	if not centerScreen then
		return
	end

	-- Convert world positions to screen positions
	local screenPaths = {}
	for i = 1, iSegments do
		screenPaths[i] = {}
		if positions[i] then
			for j, subSeg in ipairs(positions[i]) do
				local screenPos = worldToScreen(subSeg.pos)
				if screenPos then
					screenPaths[i][j] = screenPos
				end
			end
		end
	end

	if colorOverride then
		setColor(colorOverride.r, colorOverride.g, colorOverride.b, colorOverride.a or Config.visual.polygon.a)
	else
		setColor(Config.visual.polygon.r, Config.visual.polygon.g, Config.visual.polygon.b, Config.visual.polygon.a)
	end

	if g_iPolygonTexture then
		-- Draw triangles connecting sub-segments between adjacent radial segments
		for i = 1, iSegments do
			local currentPath = screenPaths[i]
			local nextPath = screenPaths[(i % iSegments) + 1]

			if currentPath and nextPath then
				local maxSubs = math.max(#currentPath, #nextPath)

				for j = 1, maxSubs - 1 do
					local p1 = currentPath[j] or currentPath[#currentPath]
					local p2 = currentPath[j + 1] or currentPath[#currentPath]
					local p3 = nextPath[j] or nextPath[#nextPath]
					local p4 = nextPath[j + 1] or nextPath[#nextPath]

					if p1 and p2 and p3 then
						local tri1 = {
							{ p1[1], p1[2], 0, 0 },
							{ p2[1], p2[2], 0, 0 },
							{ p3[1], p3[2], 0, 0 },
						}
						draw.TexturedPolygon(g_iPolygonTexture, tri1, true)
						local tri1Back = {
							{ p3[1], p3[2], 0, 0 },
							{ p2[1], p2[2], 0, 0 },
							{ p1[1], p1[2], 0, 0 },
						}
						draw.TexturedPolygon(g_iPolygonTexture, tri1Back, true)
					end

					if p2 and p3 and p4 then
						local tri2 = {
							{ p2[1], p2[2], 0, 0 },
							{ p4[1], p4[2], 0, 0 },
							{ p3[1], p3[2], 0, 0 },
						}
						draw.TexturedPolygon(g_iPolygonTexture, tri2, true)
						local tri2Back = {
							{ p3[1], p3[2], 0, 0 },
							{ p4[1], p4[2], 0, 0 },
							{ p2[1], p2[2], 0, 0 },
						}
						draw.TexturedPolygon(g_iPolygonTexture, tri2Back, true)
					end
				end
			end
		end
	end

	-- Draw outline for explosion radius
	if Config.visual.outline.polygon then
		if colorOverride then
			setColor(colorOverride.r, colorOverride.g, colorOverride.b, colorOverride.a or Config.visual.outline.a)
		else
			setColor(Config.visual.outline.r, Config.visual.outline.g, Config.visual.outline.b, Config.visual.outline.a)
		end

		-- Draw outline along the path points
		for i = 1, iSegments do
			local path = screenPaths[i]
			for j = 1, #path - 1 do
				local p1 = path[j]
				local p2 = path[j + 1]
				if p1 and p2 then
					if math.abs(p2[1] - p1[1]) > math.abs(p2[2] - p1[2]) then
						drawLine(math.floor(p1[1]), math.floor(p1[2] + 1), math.floor(p2[1]), math.floor(p2[2] + 1))
						drawLine(math.floor(p1[1]), math.floor(p1[2] - 1), math.floor(p2[1]), math.floor(p2[2] - 1))
					else
						drawLine(math.floor(p1[1] + 1), math.floor(p1[2]), math.floor(p2[1] + 1), math.floor(p2[2]))
						drawLine(math.floor(p1[1] - 1), math.floor(p1[2]), math.floor(p2[1] - 1), math.floor(p2[2]))
					end
				end
			end
		end
	end

	-- Draw main explosion radius lines
	if colorOverride then
		setColor(colorOverride.r, colorOverride.g, colorOverride.b, colorOverride.a or Config.visual.polygon.a)
	else
		setColor(Config.visual.polygon.r, Config.visual.polygon.g, Config.visual.polygon.b, Config.visual.polygon.a)
	end

	-- Draw main lines along the path points
	for i = 1, iSegments do
		local path = screenPaths[i]
		for j = 1, #path - 1 do
			local p1 = path[j]
			local p2 = path[j + 1]
			if p1 and p2 then
				drawLine(math.floor(p1[1]), math.floor(p1[2]), math.floor(p2[1]), math.floor(p2[2]))
			end
		end
	end
end

return Visuals
