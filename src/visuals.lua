-- Imports
local G = require("globals")
local multipoint = require("multipoint")
local PlayerTick = require("simulation.player_tick")
local PredictionContext = require("simulation.prediction_context")

-- Module declaration
local Visuals = {}

-- Local constants / utilities -----
local WHITE_PIXEL_RGBA = string.char(255, 255, 255, 255)
local whiteTexture = nil
local PLAYER_PATH_GAP_SQ = 80 * 80

local function getWhiteTexture()
	if whiteTexture then
		return whiteTexture
	end
	if not draw or not draw.CreateTextureRGBA then
		return nil
	end
	whiteTexture = draw.CreateTextureRGBA(WHITE_PIXEL_RGBA, 1, 1)
	return whiteTexture
end

local function hsvToRgb(hue, saturation, value)
	if saturation == 0 then
		return value, value, value
	end

	local hueSector = math.floor(hue / 60)
	local hueSectorOffset = (hue / 60) - hueSector

	local p = value * (1 - saturation)
	local q = value * (1 - saturation * hueSectorOffset)
	local t = value * (1 - saturation * (1 - hueSectorOffset))

	if hueSector == 0 then
		return value, t, p
	elseif hueSector == 1 then
		return q, value, p
	elseif hueSector == 2 then
		return p, value, t
	elseif hueSector == 3 then
		return p, q, value
	elseif hueSector == 4 then
		return t, p, value
	else
		return value, p, q
	end
end

local function xyuv(point, u, v)
	return { point[1], point[2], u, v }
end

local function drawLine(texture, p1, p2, thickness)
	if not (p1 and p2) then
		return
	end

	local tex = texture or getWhiteTexture()

	local dx = p2[1] - p1[1]
	local dy = p2[2] - p1[2]
	local len = math.sqrt(dx * dx + dy * dy)
	if len <= 0 then
		return
	end

	dx = dx / len
	dy = dy / len
	local px = -dy * thickness
	local py = dx * thickness

	if not tex then
		draw.Line(p1[1], p1[2], p2[1], p2[2])
		return
	end

	local verts = {
		{ p1[1] + px, p1[2] + py, 0, 0 },
		{ p1[1] - px, p1[2] - py, 0, 1 },
		{ p2[1] - px, p2[2] - py, 1, 1 },
		{ p2[1] + px, p2[2] + py, 1, 0 },
	}

	draw.TexturedPolygon(tex, verts, false)
end

local function buildBoxFaces(worldMins, worldMaxs)
	local midX = (worldMins.x + worldMaxs.x) * 0.5
	local midY = (worldMins.y + worldMaxs.y) * 0.5
	local midZ = (worldMins.z + worldMaxs.z) * 0.5

	return {
		{
			id = "bottom",
			indices = { 1, 4, 3, 2 },
			normal = Vector3(0, 0, -1),
			center = Vector3(midX, midY, worldMins.z),
			flip_v = true,
		},
		{
			id = "top",
			indices = { 5, 6, 7, 8 },
			normal = Vector3(0, 0, 1),
			center = Vector3(midX, midY, worldMaxs.z),
		},
		{
			id = "front",
			indices = { 2, 3, 7, 6 },
			normal = Vector3(0, 1, 0),
			center = Vector3(midX, worldMaxs.y, midZ),
		},
		{
			id = "back",
			indices = { 1, 5, 8, 4 },
			normal = Vector3(0, -1, 0),
			center = Vector3(midX, worldMins.y, midZ),
			flip_u = true,
		},
		{
			id = "left",
			indices = { 1, 2, 6, 5 },
			normal = Vector3(-1, 0, 0),
			center = Vector3(worldMins.x, midY, midZ),
		},
		{
			id = "right",
			indices = { 4, 8, 7, 3 },
			normal = Vector3(1, 0, 0),
			center = Vector3(worldMaxs.x, midY, midZ),
		},
	}
end

local function isFaceVisible(normal, faceCenter, eyePos)
	if not (normal and faceCenter and eyePos) then
		return true
	end

	local toEye = Vector3(eyePos.x - faceCenter.x, eyePos.y - faceCenter.y, eyePos.z - faceCenter.z)
	local dot = (toEye.x * normal.x) + (toEye.y * normal.y) + (toEye.z * normal.z)
	return dot > 0
end

-- Private helpers -----
local function drawPlayerPath(texture, playerPath, thickness)
	if not playerPath or #playerPath < 2 then
		return
	end

	local prevWorld = playerPath[1]
	local last = client.WorldToScreen(prevWorld)
	if not last then
		return
	end

	for i = 2, #playerPath do
		local curWorld = playerPath[i]
		local current = curWorld and client.WorldToScreen(curWorld)
		if curWorld and prevWorld and current and last then
			local dx = curWorld.x - prevWorld.x
			local dy = curWorld.y - prevWorld.y
			local dz = curWorld.z - prevWorld.z
			local distSq = (dx * dx) + (dy * dy) + (dz * dz)
			if distSq <= PLAYER_PATH_GAP_SQ then
				drawLine(texture, last, current, thickness)
			end
		end
		prevWorld = curWorld
		last = current
	end
end

local function drawProjPath(texture, projPath, thickness, startColor, endColor, alphaMul)
	if not projPath or #projPath < 2 then
		return
	end

	local pathLength = #projPath

	-- Calculate total path distance for proper interpolation
	local totalDistance = 0
	local distances = { 0 } -- Distance from start to each point
	for i = 2, pathLength do
		local prev = projPath[i - 1]
		local curr = projPath[i]
		local dist = (curr - prev):Length()
		totalDistance = totalDistance + dist
		distances[i] = totalDistance
	end

	local first = projPath[1]
	local last = first and client.WorldToScreen(first)
	if not last then
		return
	end

	for i = 2, pathLength do
		local entry = projPath[i]
		local current = entry and client.WorldToScreen(entry)
		if current and last then
			-- Calculate gradient color based on distance along path (more accurate)
			local t = distances[i] / totalDistance -- Position from 0 to 1 along total path distance

			-- Interpolate each color component
			local r = startColor[1] + (endColor[1] - startColor[1]) * t
			local g = startColor[2] + (endColor[2] - startColor[2]) * t
			local b = startColor[3] + (endColor[3] - startColor[3]) * t
			local a = (startColor[4] + (endColor[4] - startColor[4]) * t) * (alphaMul or 1.0)

			-- Convert to integers with proper rounding
			r = math.floor(r + 0.5)
			g = math.floor(g + 0.5)
			b = math.floor(b + 0.5)
			a = math.floor(a + 0.5)

			-- Ensure values are within valid range
			r = math.max(0, math.min(255, r))
			g = math.max(0, math.min(255, g))
			b = math.max(0, math.min(255, b))
			a = math.max(0, math.min(255, a))

			draw.Color(r, g, b, a)
			drawLine(texture, last, current, thickness)
		end
		last = current
	end
end

local function drawImpactDot(texture, pos, size)
	if not pos then
		return
	end
	local tex = texture or getWhiteTexture()
	local screen = client.WorldToScreen(pos)
	if not screen then
		return
	end

	local s = size or 3
	local verts = {
		{ screen[1] - s, screen[2] - s, 0, 0 },
		{ screen[1] + s, screen[2] - s, 1, 0 },
		{ screen[1] + s, screen[2] + s, 1, 1 },
		{ screen[1] - s, screen[2] + s, 0, 1 },
	}

	if tex then
		draw.TexturedPolygon(tex, verts, false)
	else
		draw.FilledRect(screen[1] - s, screen[2] - s, screen[1] + s, screen[2] + s)
	end
end

local function lastVec(tbl)
	if not tbl or #tbl == 0 then
		return nil
	end
	return tbl[#tbl]
end

local function filterPathByTime(path, timetable, nowTime, maxAbsTime)
	if not path or #path < 2 or not timetable or #timetable ~= #path then
		return path
	end

	local minKeep = nowTime - 0.1
	local maxKeep = nil
	if type(maxAbsTime) == "number" then
		maxKeep = maxAbsTime
	end
	if G and G.Menu and G.Menu.Aimbot then
		local maxSimTime = G.Menu.Aimbot.MaxSimTime
		if type(maxSimTime) == "number" then
			local horizon = nowTime + math.max(0.1, math.min(6.0, maxSimTime))
			if maxKeep then
				maxKeep = math.min(maxKeep, horizon)
			else
				maxKeep = horizon
			end
		end
	end
	local firstKeep = nil
	local lastKeep = nil
	for i = 1, #timetable do
		local t = timetable[i]
		if t and t >= minKeep and (not maxKeep or t <= maxKeep) then
			if not firstKeep then
				firstKeep = i
			end
			lastKeep = i
		end
	end

	if not (firstKeep and lastKeep) then
		return nil
	end

	local startIdx = math.max(1, firstKeep - 1)
	local out = {}
	for i = startIdx, lastKeep do
		out[#out + 1] = path[i]
	end
	if #out >= 2 then
		return out
	end
	return nil
end

local function drawMultipointTarget(texture, pos, thickness)
	if not pos then
		return
	end

	local screen = client.WorldToScreen(pos)
	if not screen then
		return
	end

	local tex = texture or getWhiteTexture()
	local s = math.max(4, (thickness or 1) * 2)
	local t = math.max(1, (thickness or 1) * 0.75)
	local x = screen[1]
	local y = screen[2]

	drawLine(tex, { x - s, y }, { x + s, y }, t)
	drawLine(tex, { x, y - s }, { x, y + s }, t)
end

local function drawMultipointDebug(texture, thickness, dbgOverride)
	local dbg = dbgOverride or multipoint.debugState
	if not dbg or not dbg.corners then
		return
	end

	local tex = texture or getWhiteTexture()
	local cornerSize = 3

	-- Draw all 8 corners with visibility status
	for i = 1, 8 do
		local corner = dbg.corners[i]
		local isVisible = dbg.visibleCorners and dbg.visibleCorners[i] == true
		if corner and dbg.visibleCorners and not isVisible then
			local screen = client.WorldToScreen(corner)
			if screen then
				draw.Color(255, 100, 100, 180)
				draw.FilledRect(
					math.floor(screen[1] - cornerSize),
					math.floor(screen[2] - cornerSize),
					math.floor(screen[1] + cornerSize),
					math.floor(screen[2] + cornerSize)
				)
			end
		end
	end

	-- Draw AABB center (cyan)
	if dbg.aabbCenter then
		local screen = client.WorldToScreen(dbg.aabbCenter)
		if screen then
			draw.Color(100, 255, 255, 200)
			draw.FilledRect(
				math.floor(screen[1] - 2),
				math.floor(screen[2] - 2),
				math.floor(screen[1] + 2),
				math.floor(screen[2] + 2)
			)
		end
	end

	-- Draw face center (yellow - target for horizontal search)
	if dbg.faceCenter then
		local screen = client.WorldToScreen(dbg.faceCenter)
		if screen then
			draw.Color(255, 255, 0, 220)
			draw.FilledRect(
				math.floor(screen[1] - 3),
				math.floor(screen[2] - 3),
				math.floor(screen[1] + 3),
				math.floor(screen[2] + 3)
			)
		end
	end

	if dbg.intersectPoint then
		local screen = client.WorldToScreen(dbg.intersectPoint)
		if screen then
			draw.Color(255, 255, 255, 240)
			draw.FilledRect(
				math.floor(screen[1] - 3),
				math.floor(screen[2] - 3),
				math.floor(screen[1] + 3),
				math.floor(screen[2] + 3)
			)
		end
	end

	-- Draw binary search path (orange line)
	if dbg.searchPath and #dbg.searchPath >= 2 then
		draw.Color(255, 165, 0, 255)
		local prev = client.WorldToScreen(dbg.searchPath[1])
		for i = 2, #dbg.searchPath do
			local curr = client.WorldToScreen(dbg.searchPath[i])
			if prev and curr then
				drawLine(tex, prev, curr, thickness)
			end
			prev = curr
		end
	end

	-- Draw final best point (large magenta square)
	if dbg.bestPoint then
		local screen = client.WorldToScreen(dbg.bestPoint)
		if screen then
			draw.Color(255, 0, 255, 255)
			local s = 5
			draw.FilledRect(
				math.floor(screen[1] - s),
				math.floor(screen[2] - s),
				math.floor(screen[1] + s),
				math.floor(screen[2] + s)
			)
		end
	end
end

local function drawPlayerHitbox(texture, playerPos, targetMinHull, targetMaxHull, eyePos, thickness)
	if not (playerPos and targetMinHull and targetMaxHull) then
		return
	end

	local worldMins = playerPos + targetMinHull
	local worldMaxs = playerPos + targetMaxHull

	local corners = {
		Vector3(worldMins.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMins.y, worldMaxs.z),
		Vector3(worldMins.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMins.y, worldMaxs.z),
	}

	local projected = {}
	for i = 1, 8 do
		projected[i] = client.WorldToScreen(corners[i])
	end

	for i = 1, 8 do
		if not projected[i] then
			return
		end
	end

	local edges = {
		{ 1, 2, "bottom", "left" },
		{ 2, 3, "bottom", "front" },
		{ 3, 4, "bottom", "right" },
		{ 4, 1, "bottom", "back" },
		{ 5, 6, "top", "left" },
		{ 6, 7, "top", "front" },
		{ 7, 8, "top", "right" },
		{ 8, 5, "top", "back" },
		{ 1, 5, "left", "back" },
		{ 2, 6, "left", "front" },
		{ 3, 7, "right", "front" },
		{ 4, 8, "right", "back" },
	}

	for _, edge in ipairs(edges) do
		local a = projected[edge[1]]
		local b = projected[edge[2]]
		if a and b then
			drawLine(texture, a, b, thickness)
		end
	end
end

local function drawQuadFace(texture, projected, indices, flipU, flipV)
	if not (projected and indices) then
		return
	end

	local tex = texture or getWhiteTexture()

	local uvs = {
		{ 0, 0 },
		{ 1, 0 },
		{ 1, 1 },
		{ 0, 1 },
	}

	if flipU then
		for i = 1, 4 do
			uvs[i][1] = 1 - uvs[i][1]
		end
	end

	if flipV then
		for i = 1, 4 do
			uvs[i][2] = 1 - uvs[i][2]
		end
	end

	local poly = {}
	for i = 1, 4 do
		local vertex = projected[indices[i]]
		if not vertex then
			return
		end

		poly[i] = xyuv(vertex, uvs[i][1], uvs[i][2])
	end

	if tex then
		draw.TexturedPolygon(tex, poly, true)
	else
		-- Fallback: basic filled quad if texture creation fails
		draw.FilledRect(poly[1][1], poly[1][2], poly[3][1], poly[3][2])
	end
end

local function getBoxVertices(pos, mins, maxs)
	if not (pos and mins and maxs) then
		return nil
	end

	local worldMins = pos + mins
	local worldMaxs = pos + maxs

	return {
		Vector3(worldMins.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMins.y, worldMaxs.z),
		Vector3(worldMins.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMins.y, worldMaxs.z),
	}
end

local function drawQuads(texture, pos, targetMinHull, targetMaxHull, eyePos, baseColor)
	if not (pos and targetMinHull and targetMaxHull and eyePos) then
		return
	end

	local worldMins = pos + targetMinHull
	local worldMaxs = pos + targetMaxHull
	local vertices = getBoxVertices(pos, targetMinHull, targetMaxHull)
	if not vertices then
		return
	end

	local projected = {}
	for index, vertex in ipairs(vertices) do
		projected[index] = client.WorldToScreen(vertex)
	end

	local faces = buildBoxFaces(worldMins, worldMaxs)

	baseColor = baseColor or { r = 255, g = 255, b = 255, a = 25 }
	local baseR = baseColor.r or 255
	local baseG = baseColor.g or 255
	local baseB = baseColor.b or 255
	local baseA = baseColor.a or 255

	for _, face in ipairs(faces) do
		local isVisible = isFaceVisible(face.normal, face.center, eyePos)
		if isVisible then
			local toEyeX = eyePos.x - face.center.x
			local toEyeY = eyePos.y - face.center.y
			local toEyeZ = eyePos.z - face.center.z
			local length = math.sqrt((toEyeX * toEyeX) + (toEyeY * toEyeY) + (toEyeZ * toEyeZ))
			local intensity = 1
			if length > 0 then
				local dirX = toEyeX / length
				local dirY = toEyeY / length
				local dirZ = toEyeZ / length
				local cosTheta = (dirX * face.normal.x) + (dirY * face.normal.y) + (dirZ * face.normal.z)
				if cosTheta < 0 then
					cosTheta = 0
				elseif cosTheta > 1 then
					cosTheta = 1
				end
				intensity = 0.42 + (cosTheta * 0.58)
			end

			local r = (baseR * intensity) // 1
			local g = (baseG * intensity) // 1
			local b = (baseB * intensity) // 1
			draw.Color(r, g, b, baseA)
			drawQuadFace(texture, projected, face.indices, face.flip_u, face.flip_v)
		end
	end
end

local function getColorFromHue(hue)
	if hue >= 360 then
		return 255, 255, 255, 255
	else
		local r, g, b = hsvToRgb(hue, 0.5, 1)
		return (r * 255) // 1, (g * 255) // 1, (b * 255) // 1, 255
	end
end

local function getColor(vis, key, fallbackHue, fallbackAlpha)
	if vis and vis.ColorsRGBA then
		local rgba = vis.ColorsRGBA[key]
		if type(rgba) == "table" then
			local r = tonumber(rgba[1])
			local g = tonumber(rgba[2])
			local b = tonumber(rgba[3])
			local a = tonumber(rgba[4])
			if r and g and b then
				if not a then
					a = fallbackAlpha or 255
				end
				return r, g, b, a
			end
		end
	end

	if vis and vis.Colors and type(vis.Colors[key]) == "number" then
		local r, g, b, a = getColorFromHue(vis.Colors[key])
		if fallbackAlpha and type(fallbackAlpha) == "number" then
			a = fallbackAlpha
		end
		return r, g, b, a
	end

	if type(fallbackHue) == "number" then
		local r, g, b, a = getColorFromHue(fallbackHue)
		if fallbackAlpha and type(fallbackAlpha) == "number" then
			a = fallbackAlpha
		end
		return r, g, b, a
	end

	return 255, 255, 255, fallbackAlpha or 255
end

-- Public API ----
function Visuals.draw(state)
	assert(G.Menu, "Visuals: G.Menu is nil")
	assert(G.Menu.Visuals, "Visuals: G.Menu.Visuals is nil")

	local vis = G.Menu.Visuals

	if not vis.Enabled then
		return
	end

	local alphaMul = 1.0
	local fadeOut = vis.FadeOutDuration
	if type(fadeOut) ~= "number" then
		fadeOut = 0
	end
	if fadeOut > 0 then
		local now = (globals and globals.RealTime and globals.RealTime()) or 0
		local lastUpdate = state and state.lastUpdateTime
		if type(lastUpdate) == "number" and lastUpdate > 0 then
			local age = now - lastUpdate
			if age > 0 then
				alphaMul = math.max(0.0, math.min(1.0, 1.0 - (age / fadeOut)))
			end
		end
	end
	if alphaMul <= 0 then
		return
	end

	-- Create texture if needed (fallback to no-op if creation fails)
	local texture = getWhiteTexture()

	-- Get eye position
	local eyePos = nil
	local localPlayer = entities and entities.GetLocalPlayer and entities.GetLocalPlayer()
	if localPlayer then
		local origin = localPlayer:GetAbsOrigin()
		local viewOffset = localPlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
		if origin and viewOffset then
			eyePos = origin + viewOffset
		elseif origin then
			eyePos = origin
		end
	end

	-- Get target info from state
	local playerPath = state and state.path
	local projPath = state and state.projpath
	local playerTime = state and state.timetable
	local projTime = state and state.projtimetable
	local predictedOrigin = state and state.predictedOrigin
	local aimPos = state and state.aimPos
	local multipointPos = state and state.multipointPos
	local shotTime = state and state.shotTime
	local targetEntity = state and state.target
	-- Determine a best-effort target position for rendering boxes/quads even if paths are missing
	local curTime = (globals and globals.CurTime and globals.CurTime()) or 0
	playerPath = filterPathByTime(playerPath, playerTime, curTime, shotTime)
	-- Don't filter projectile path - it's a future trajectory, not historical data
	local currentOrigin = (targetEntity and targetEntity.GetAbsOrigin and targetEntity:GetAbsOrigin()) or nil
	local targetPos = predictedOrigin or lastVec(playerPath) or currentOrigin

	-- Draw player path
	if vis.DrawPlayerPath and playerPath and #playerPath > 1 then
		local r, g, b, a = getColor(vis, "PlayerPath", 180)
		a = math.floor(a * alphaMul)
		draw.Color(r, g, b, a)
		if currentOrigin then
			local lastWorld = currentOrigin
			local last = client.WorldToScreen(currentOrigin)
			if last then
				for i = 1, #playerPath do
					local curWorld = playerPath[i]
					local current = curWorld and client.WorldToScreen(curWorld)
					if curWorld and lastWorld and current and last then
						local dx = curWorld.x - lastWorld.x
						local dy = curWorld.y - lastWorld.y
						local dz = curWorld.z - lastWorld.z
						local distSq = (dx * dx) + (dy * dy) + (dz * dz)
						if distSq <= PLAYER_PATH_GAP_SQ then
							drawLine(texture, last, current, vis.Thickness.PlayerPath)
						end
					end
					lastWorld = curWorld
					last = current
				end
			else
				drawPlayerPath(texture, playerPath, vis.Thickness.PlayerPath)
			end
		else
			drawPlayerPath(texture, playerPath, vis.Thickness.PlayerPath)
		end
	end

	-- Draw bounding box
	local boxOrigin = predictedOrigin or currentOrigin or targetPos
	if vis.DrawBoundingBox and boxOrigin and targetEntity and eyePos then
		local r, g, b, a = getColor(vis, "BoundingBox", 120)
		a = math.floor(a * alphaMul)
		draw.Color(r, g, b, a)
		drawPlayerHitbox(
			texture,
			boxOrigin,
			targetEntity:GetMins(),
			targetEntity:GetMaxs(),
			eyePos,
			vis.Thickness.BoundingBox
		)
	end

	-- Draw projectile path
	if vis.DrawProjectilePath then
		if not projPath then
			printc(255, 0, 0, 255, "[Visuals] projPath is nil")
		elseif #projPath == 0 then
			printc(255, 165, 0, 255, "[Visuals] projPath is empty (length 0)")
		else
			printc(0, 255, 0, 255, "[Visuals] projPath has " .. #projPath .. " points")
		end
	end

	if vis.DrawProjectilePath and projPath and #projPath > 0 then
		local startR, startG, startB, startA = getColor(vis, "ProjectilePathStart", 60)
		local endR, endG, endB, endA = getColor(vis, "ProjectilePathEnd", 60)
		local startColor = {
			math.floor(startR + 0.5),
			math.floor(startG + 0.5),
			math.floor(startB + 0.5),
			startA,
		}
		local endColor = {
			math.floor(endR + 0.5),
			math.floor(endG + 0.5),
			math.floor(endB + 0.5),
			endA,
		}
		drawProjPath(texture, projPath, vis.Thickness.ProjectilePath, startColor, endColor, alphaMul)
	end

	local debugDuration = (vis.ShowMultipointDebug and (vis.MultipointDebugDuration or 0)) or 0
	local dbgToDraw = nil
	if debugDuration > 0 and multipoint and multipoint.debugPersist and multipoint.debugPersist.state then
		local now = (globals and globals.RealTime and globals.RealTime()) or 0
		local age = now - (multipoint.debugPersist.time or 0)
		if age >= 0 and age <= debugDuration then
			dbgToDraw = multipoint.debugPersist.state
		end
	end

	-- Draw multipoint target
	if vis.DrawMultipointTarget then
		local r, g, b, a = getColor(vis, "MultipointTarget", 0)
		a = math.floor(a * alphaMul)
		draw.Color(r, g, b, a)
		local markPos = aimPos or multipointPos
		if markPos then
			drawMultipointTarget(texture, markPos, vis.Thickness.MultipointTarget)
		end
		if dbgToDraw then
			drawMultipointDebug(texture, vis.Thickness.MultipointTarget * 0.5, dbgToDraw)
		end
	end

	-- Draw quads
	if vis.DrawQuads and boxOrigin and targetEntity and eyePos then
		local r, g, b, a = getColor(vis, "Quads", 240, 25)
		a = math.floor(a * alphaMul)
		local baseColor = { r = r, g = g, b = b, a = a }

		drawQuads(texture, boxOrigin, targetEntity:GetMins(), targetEntity:GetMaxs(), eyePos, baseColor)
	end

	-- Draw impact/last projectile point for quick visibility when path is short
	if vis.DrawProjectilePath and projPath and #projPath >= 1 then
		local impactPos = projPath[#projPath]
		local r, g, b, a = getColor(vis, "ProjectilePath", 60)
		a = math.floor(a * alphaMul)
		draw.Color(r, g, b, a)
		drawImpactDot(texture, impactPos, vis.Thickness.ProjectilePath * 2)
	end

	-- Draw self-prediction (local player movement prediction for debugging)
	if vis.SelfPrediction and localPlayer and localPlayer:IsAlive() then
		local predictDuration = vis.SelfPredictionDuration or 2.0

		local success, err = pcall(function()
			local playerCtx = PredictionContext.createPlayerContext(localPlayer, 1.0)
			local simCtx = PredictionContext.createSimulationContext()

			if playerCtx and simCtx then
				local path, lastPos, timetable = PlayerTick.simulatePath(playerCtx, simCtx, predictDuration)

				if path and #path > 1 then
					local r, g, b, a = getColor(vis, "SelfPrediction", 300)
					draw.Color(r, g, b, a)

					local last = nil
					for i = 1, #path do
						local curWorld = path[i]
						local current = curWorld and client.WorldToScreen(curWorld)
						if current and last then
							drawLine(texture, last, current, vis.Thickness.SelfPrediction or 2.0)
						end
						last = current
					end
				end
			end
		end)

		if not success then
			printc(255, 100, 100, 255, "[Visuals] Self-prediction error: " .. tostring(err))
		end
	end
end

return Visuals
