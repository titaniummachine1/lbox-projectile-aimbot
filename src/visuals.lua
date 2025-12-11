-- Imports
local G = require("globals")

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
	local targetPos = multipointPos
		or lastVec(playerPath)
		or (targetEntity and targetEntity.GetAbsOrigin and targetEntity:GetAbsOrigin() or nil)

	-- Draw player path
	if vis.DrawPlayerPath and playerPath and #playerPath > 0 then
		local r, g, b, a = getColorFromHue(vis.Colors.PlayerPath)
		draw.Color(r, g, b, a)
		drawPlayerPath(texture, playerPath, vis.Thickness.PlayerPath)
	end

	-- Draw bounding box
	if vis.DrawBoundingBox and targetPos and targetEntity and eyePos then
		local r, g, b, a = getColorFromHue(vis.Colors.BoundingBox)
		draw.Color(r, g, b, a)
		drawPlayerHitbox(texture, targetPos, targetEntity:GetMins(), targetEntity:GetMaxs(), eyePos, vis.Thickness.BoundingBox)
	end

	-- Draw projectile path
	if vis.DrawProjectilePath and projPath and #projPath > 0 then
		local r, g, b, a = getColorFromHue(vis.Colors.ProjectilePath)
		draw.Color(r, g, b, a)
		drawProjPath(texture, projPath, vis.Thickness.ProjectilePath)
	end

	-- Draw multipoint target
	if vis.DrawMultipointTarget and multipointPos then
		local r, g, b, a = getColorFromHue(vis.Colors.MultipointTarget)
		draw.Color(r, g, b, a)
		drawMultipointTarget(texture, multipointPos, vis.Thickness.MultipointTarget)
	end

	-- Draw quads
	if vis.DrawQuads and targetPos and targetEntity and eyePos then
		local baseColor
		if vis.Colors.Quads >= 360 then
			baseColor = { r = 255, g = 255, b = 255, a = 25 }
		else
			local r, g, b = hsvToRgb(vis.Colors.Quads, 0.5, 1)
			baseColor = {
				r = (r * 255) // 1,
				g = (g * 255) // 1,
				b = (b * 255) // 1,
				a = 25,
			}
		end

		drawQuads(texture, targetPos, targetEntity:GetMins(), targetEntity:GetMaxs(), eyePos, baseColor)
	end

	-- Draw impact/last projectile point for quick visibility when path is short
	if vis.DrawProjectilePath and projPath and #projPath >= 1 then
		local impactPos = projPath[#projPath]
		local r, g, b, a = getColorFromHue(vis.Colors.ProjectilePath)
		draw.Color(r, g, b, a)
		drawImpactDot(texture, impactPos, vis.Thickness.ProjectilePath * 2)
	end

	-- Cleanup texture
	draw.DeleteTexture(texture)
end

return Visuals

