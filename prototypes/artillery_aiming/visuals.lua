local Config = require("config")
local State = require("state")
local Utils = require("utils")

local worldToScreen = client.WorldToScreen
local drawLine = draw.Line
local setColor = draw.Color
local getScreenSize = draw.GetScreenSize

local Visuals = {}

local g_iPolygonTexture = draw.CreateTextureRGBA("\xff\xff\xff\xff", 1, 1)

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

	-- Draw impact polygon/radius
	if proj.impactPos and proj.impactPlane and proj.radius then
		local polygonColor = {
			r = Config.visual.polygon.r,
			g = Config.visual.polygon.g,
			b = Config.visual.polygon.b,
			a = Config.visual.polygon.a,
		}
		-- Use maximum of projectile radius and config value to ensure it's not smaller than before
		local explosionRadius = math.max(proj.radius, Config.visual.live_projectiles.explosion_radius)
		Visuals.drawImpactPolygon(proj.impactPlane, proj.impactPos, explosionRadius, polygonColor)
	end
end

function Visuals.deleteTexture()
	if g_iPolygonTexture then
		draw.DeleteTexture(g_iPolygonTexture)
		g_iPolygonTexture = nil
	end
end

return Visuals
