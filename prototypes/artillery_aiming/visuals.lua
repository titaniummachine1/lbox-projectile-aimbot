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
	if not Config.visual.polygon.enabled then
		return
	end

	local iSegments = Config.visual.polygon.segments
	local fSegmentAngleOffset = math.pi / iSegments
	local fSegmentAngle = fSegmentAngleOffset * 2
	local radius = radiusOverride or Config.visual.polygon.size
	local positions = {}

	if math.abs(plane.z) >= 0.99 then
		for i = 1, iSegments do
			local ang = i * fSegmentAngle + fSegmentAngleOffset
			positions[i] = worldToScreen(origin + Vector3(radius * math.cos(ang), radius * math.sin(ang), 0))
			if not positions[i] then
				return
			end
		end
	else
		local right = Vector3(-plane.y, plane.x, 0)
		local up = Vector3(plane.z * right.y, -plane.z * right.x, (plane.y * right.x) - (plane.x * right.y))
		radius = radius / math.cos(math.asin(plane.z))
		for i = 1, iSegments do
			local ang = i * fSegmentAngle + fSegmentAngleOffset
			positions[i] = worldToScreen(origin + (right * (radius * math.cos(ang))) + (up * (radius * math.sin(ang))))
			if not positions[i] then
				return
			end
		end
	end

	if Config.visual.outline.polygon then
		if colorOverride then
			setColor(colorOverride.r, colorOverride.g, colorOverride.b, colorOverride.a or Config.visual.outline.a)
		else
			setColor(Config.visual.outline.r, Config.visual.outline.g, Config.visual.outline.b, Config.visual.outline.a)
		end
		local last = positions[#positions]
		for i = 1, #positions do
			local new = positions[i]
			if math.abs(new[1] - last[1]) > math.abs(new[2] - last[2]) then
				drawLine(last[1], last[2] + 1, new[1], new[2] + 1)
				drawLine(last[1], last[2] - 1, new[1], new[2] - 1)
			else
				drawLine(last[1] + 1, last[2], new[1] + 1, new[2])
				drawLine(last[1] - 1, last[2], new[1] - 1, new[2])
			end
			last = new
		end
	end

	if colorOverride then
		setColor(colorOverride.r, colorOverride.g, colorOverride.b, colorOverride.a or Config.visual.polygon.a)
	else
		setColor(Config.visual.polygon.r, Config.visual.polygon.g, Config.visual.polygon.b, Config.visual.polygon.a)
	end
	do
		local cords, reverse_cords = {}, {}
		local sizeof = #positions
		local sum = 0
		for i, pos in pairs(positions) do
			local convertedTbl = { pos[1], pos[2], 0, 0 }
			cords[i], reverse_cords[sizeof - i + 1] = convertedTbl, convertedTbl
			sum = sum + Utils.cross2D(pos, positions[(i % sizeof) + 1], positions[1])
		end
		draw.TexturedPolygon(g_iPolygonTexture, (sum < 0) and reverse_cords or cords, true)
	end

	do
		local last = positions[#positions]
		for i = 1, #positions do
			local new = positions[i]
			drawLine(last[1], last[2], new[1], new[2])
			last = new
		end
	end
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
		Visuals.drawImpactPolygon(traj.impactPlane, traj.impactPos)
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
		if speed and speed < 10 then
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
	local positions = {}
	local upVector = surfaceNormal and normalizeVector(surfaceNormal) or Vector3(0, 0, 1)
	if not upVector then
		upVector = Vector3(0, 0, 1)
	end

	for i = 1, iSegments do
		local angle = (i - 1) * (2 * math.pi / iSegments)
		local radialDir = Vector3(math.cos(angle), math.sin(angle), 0)
		radialDir = normalizeVector(radialDir) or Vector3(1, 0, 0)

		local currentPos = center
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
			local desiredEnd = currentPos + radialDir * stepSize
			local groundTrace = engine.TraceLine(currentPos, desiredEnd, TRACE_MASK)
			if groundTrace.fraction >= 0.98 then
				currentPos = desiredEnd
				goto continue_segment
			end

			local elevatedStart = currentPos + upVector * ELEVATION_STEP
			local elevatedEnd = elevatedStart + radialDir * stepSize
			local elevatedTrace = engine.TraceLine(elevatedStart, elevatedEnd, TRACE_MASK)

			if elevatedTrace.fraction >= 0.98 then
				local elevatedAdvance = stepSize * elevatedTrace.fraction
				local groundAdvance = stepSize * (groundTrace.fraction or 0)
				currentPos = elevatedStart + radialDir * elevatedAdvance

				if elevatedAdvance > groundAdvance + 4 then
					local climbAttempts = 0
					while climbAttempts < 10 do
						climbAttempts = climbAttempts + 1
						local climbStart = currentPos + upVector * ELEVATION_STEP
						local climbEnd = climbStart + radialDir * stepSize
						local climbTrace = engine.TraceLine(climbStart, climbEnd, TRACE_MASK)
						if climbTrace.fraction >= 0.98 then
							currentPos = climbStart + radialDir * (stepSize * climbTrace.fraction)
						else
							local climbNormal = climbTrace.plane
							local outwardNorm = normalizeVector(currentPos - center) or radialDir
							local projected = projectOntoPlane(outwardNorm, climbNormal)
							if projected then
								radialDir = projected
							end
							break
						end
					end
				end
				goto continue_segment
			end

			local slideNormal = groundTrace.plane or elevatedTrace.plane or surfaceNormal
			local outward = normalizeVector(currentPos - center) or radialDir
			local slideDir = projectOntoPlane(outward, slideNormal)
			if slideDir then
				radialDir = slideDir
				local slideEnd = currentPos + radialDir * stepSize
				local slideTrace = engine.TraceLine(currentPos, slideEnd, TRACE_MASK)
				if slideTrace.fraction >= 0.1 then
					currentPos = currentPos + radialDir * (stepSize * slideTrace.fraction)
					goto continue_segment
				end
			end
			break -- no progress

			::continue_segment::
		end

		currentPos = clampToRadius(center, currentPos, radius)
		positions[i] = worldToScreen(currentPos) or worldToScreen(center)
	end

	-- Draw filled explosion radius using textured polygon
	local cords, reverse_cords = {}, {}
	local sizeof = #positions
	local sum = 0
	for i, pos in pairs(positions) do
		local convertedTbl = { pos[1], pos[2], 0, 0 }
		cords[i], reverse_cords[sizeof - i + 1] = convertedTbl, convertedTbl
		sum = sum + Utils.cross2D(pos, positions[(i % sizeof) + 1], positions[1])
	end
	if g_iPolygonTexture then
		draw.TexturedPolygon(g_iPolygonTexture, (sum < 0) and reverse_cords or cords, true)
	end

	-- Draw outline for explosion radius
	if Config.visual.outline.polygon then
		if colorOverride then
			setColor(colorOverride.r, colorOverride.g, colorOverride.b, colorOverride.a or Config.visual.outline.a)
		else
			setColor(Config.visual.outline.r, Config.visual.outline.g, Config.visual.outline.b, Config.visual.outline.a)
		end

		local last = positions[#positions]
		for i = 1, #positions do
			local new = positions[i]
			if last and new then
				if math.abs(new[1] - last[1]) > math.abs(new[2] - last[2]) then
					drawLine(math.floor(last[1]), math.floor(last[2] + 1), math.floor(new[1]), math.floor(new[2] + 1))
					drawLine(math.floor(last[1]), math.floor(last[2] - 1), math.floor(new[1]), math.floor(new[2] - 1))
				else
					drawLine(math.floor(last[1] + 1), math.floor(last[2]), math.floor(new[1] + 1), math.floor(new[2]))
					drawLine(math.floor(last[1] - 1), math.floor(last[2]), math.floor(new[1] - 1), math.floor(new[2]))
				end
			end
			last = new
		end
	end

	-- Draw main explosion radius lines
	if colorOverride then
		setColor(colorOverride.r, colorOverride.g, colorOverride.b, colorOverride.a or Config.visual.polygon.a)
	else
		setColor(Config.visual.polygon.r, Config.visual.polygon.g, Config.visual.polygon.b, Config.visual.polygon.a)
	end

	local last = positions[#positions]
	for i = 1, #positions do
		local new = positions[i]
		if last and new then
			drawLine(math.floor(last[1]), math.floor(last[2]), math.floor(new[1]), math.floor(new[2]))
		end
		last = new
	end
end

return Visuals
