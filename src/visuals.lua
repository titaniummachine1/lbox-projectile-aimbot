-- Imports
local G = require("globals")
local multipoint = require("multipoint")

-- Module declaration
local Visuals = {}

-- Local constants / utilities -----
local WHITE_PIXEL_RGBA = string.char(255, 255, 255, 255)
local whiteTexture = nil

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

	local last = client.WorldToScreen(playerPath[1])
	if not last then
		return
	end

	for i = 2, #playerPath do
		local current = client.WorldToScreen(playerPath[i])
		if current and last then
			drawLine(texture, last, current, thickness)
		end
		last = current
	end
end

local function drawProjPath(texture, projPath, thickness)
	if not projPath or #projPath < 2 then
		return
	end

	local first = projPath[1]
	local last = first and client.WorldToScreen(first)
	if not last then
		return
	end

	for i = 2, #projPath do
		local entry = projPath[i]
		local current = entry and client.WorldToScreen(entry)
		if current and last then
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

local function drawMultipointTarget(texture, pos, thickness)
	if not pos then
		return
	end

	local screen = client.WorldToScreen(pos)
	if not screen then
		return
	end

	local tex = texture or getWhiteTexture()
	local s = thickness
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
		if corner then
			local screen = client.WorldToScreen(corner)
			if screen then
				local isVisible = dbg.visibleCorners and dbg.visibleCorners[i]
				if isVisible then
					-- Green for visible corners
					draw.Color(100, 255, 100, 255)
				else
					-- Red for blocked corners
					draw.Color(255, 100, 100, 180)
				end
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

	local faces = buildBoxFaces(worldMins, worldMaxs)
	local facesVisible = {}
	for _, face in ipairs(faces) do
		facesVisible[face.id] = isFaceVisible(face.normal, face.center, eyePos)
	end

	for _, edge in ipairs(edges) do
		local a = projected[edge[1]]
		local b = projected[edge[2]]
		local faceA = edge[3]
		local faceB = edge[4]

		local visibleA = facesVisible[faceA]
		local visibleB = facesVisible[faceB]

		if a and b and (visibleA or visibleB) then
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
	local multipointPos = state and state.multipointPos
	local targetEntity = state and state.target
	-- Determine a best-effort target position for rendering boxes/quads even if paths are missing
	local targetPos = lastVec(playerPath)
		or (targetEntity and targetEntity.GetAbsOrigin and targetEntity:GetAbsOrigin() or nil)

	-- Draw player path
	if vis.DrawPlayerPath and playerPath and #playerPath > 0 then
		local r, g, b, a = getColor(vis, "PlayerPath", 180)
		draw.Color(r, g, b, a)
		drawPlayerPath(texture, playerPath, vis.Thickness.PlayerPath)
	end

	-- Draw bounding box
	if vis.DrawBoundingBox and targetPos and targetEntity and eyePos then
		local r, g, b, a = getColor(vis, "BoundingBox", 120)
		draw.Color(r, g, b, a)
		drawPlayerHitbox(
			texture,
			targetPos,
			targetEntity:GetMins(),
			targetEntity:GetMaxs(),
			eyePos,
			vis.Thickness.BoundingBox
		)
	end

	-- Draw projectile path
	if vis.DrawProjectilePath and projPath and #projPath > 0 then
		local r, g, b, a = getColor(vis, "ProjectilePath", 60)
		draw.Color(r, g, b, a)
		drawProjPath(texture, projPath, vis.Thickness.ProjectilePath)
	end

	local debugDuration = vis.MultipointDebugDuration or 0
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
		draw.Color(r, g, b, a)
		if multipointPos then
			drawMultipointTarget(texture, multipointPos, vis.Thickness.MultipointTarget)
		end
		if dbgToDraw then
			drawMultipointDebug(texture, vis.Thickness.MultipointTarget * 0.5, dbgToDraw)
		end
	end

	-- Draw quads
	if vis.DrawQuads and targetPos and targetEntity and eyePos then
		local r, g, b, a = getColor(vis, "Quads", 240, 25)
		local baseColor = { r = r, g = g, b = b, a = a }

		drawQuads(texture, targetPos, targetEntity:GetMins(), targetEntity:GetMaxs(), eyePos, baseColor)
	end

	-- Draw impact/last projectile point for quick visibility when path is short
	if vis.DrawProjectilePath and projPath and #projPath >= 1 then
		local impactPos = projPath[#projPath]
		local r, g, b, a = getColor(vis, "ProjectilePath", 60)
		draw.Color(r, g, b, a)
		drawImpactDot(texture, impactPos, vis.Thickness.ProjectilePath * 2)
	end
end

return Visuals
