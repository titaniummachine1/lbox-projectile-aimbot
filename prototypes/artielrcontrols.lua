-------------------------------
-- SIMPLE POINT CONTROLS
-------------------------------
local config = {
	line = {
		enabled = true,
		r = 0,
		g = 255,
		b = 255,
		a = 255,
	},
	point = {
		enabled = true,
		r = 255,
		g = 255,
		b = 255,
		a = 255,
		size = 5,
	},
	speed = 0.50, -- Fixed units per pixel movement
}

local font = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

-------------------------------
-- POINT STATE
-------------------------------
local pointState = {
	distance = 0, -- Start at distance 0
	targetPoint = nil,
	originPoint = nil,
	lastMouseX = 0,
	lastMouseY = 0,
}

-------------------------------
-- UTILITY FUNCTIONS
-------------------------------
local function clamp(val, minVal, maxVal)
	if val < minVal then
		return minVal
	end
	if val > maxVal then
		return maxVal
	end
	return val
end

-------------------------------
-- POINT MOVEMENT FUNCTION
-------------------------------
local function updatePointFromMouse(mouseX, mouseY)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	-- Get player's absolute position (no view offset)
	local absOrigin = pLocal:GetAbsOrigin()
	local viewAngles = engine.GetViewAngles()
	if not absOrigin or not viewAngles then
		return
	end

	pointState.originPoint = absOrigin

	-- Mouse Y controls distance (forward/back movement)
	-- Fixed 1:1 ratio: 1 pixel = 1 unit movement
	local distanceDelta = -mouseY * config.speed -- 1.0 units per pixel
	pointState.distance = clamp(pointState.distance + distanceDelta, 0, 7200)

	-- Calculate target point based on player's current view yaw directly
	local yawRad = math.rad(viewAngles.y)
	local forwardDir = Vector3(math.cos(yawRad), math.sin(yawRad), 0)
	pointState.targetPoint = pointState.originPoint + (forwardDir * pointState.distance)
end

-------------------------------
-- DRAWING FUNCTIONS
-------------------------------
local function drawPointAndLine()
	if not pointState.originPoint or not pointState.targetPoint then
		return
	end

	-- Draw segments every 100 units for visibility
	local segmentLength = 100
	local numSegments = math.floor(pointState.distance / segmentLength)

	-- Get player's current view angles for direction
	local viewAngles = engine.GetViewAngles()
	if not viewAngles then
		return
	end

	-- Draw segment lines
	if config.line.enabled and numSegments > 0 then
		draw.Color(config.line.r, config.line.g, config.line.b, config.line.a)

		for i = 0, numSegments do
			local segmentDist = i * segmentLength
			local nextDist = math.min((i + 1) * segmentLength, pointState.distance)

			local yawRad = math.rad(viewAngles.y)
			local forwardDir = Vector3(math.cos(yawRad), math.sin(yawRad), 0)

			local segmentStart = pointState.originPoint + (forwardDir * segmentDist)
			local segmentEnd = pointState.originPoint + (forwardDir * nextDist)

			local start2d = client.WorldToScreen(segmentStart)
			local end2d = client.WorldToScreen(segmentEnd)

			if start2d and end2d then
				draw.Line(math.floor(start2d[1]), math.floor(start2d[2]), math.floor(end2d[1]), math.floor(end2d[2]))
			end
		end
	end

	-- Convert target point to screen coordinates
	local start2d = client.WorldToScreen(pointState.originPoint)
	local end2d = client.WorldToScreen(pointState.targetPoint)

	if not start2d or not end2d then
		return
	end

	-- Draw main line from player to point
	if config.line.enabled then
		draw.Color(config.line.r, config.line.g, config.line.b, config.line.a)
		draw.Line(math.floor(start2d[1]), math.floor(start2d[2]), math.floor(end2d[1]), math.floor(end2d[2]))
	end

	-- Draw target point
	if config.point.enabled then
		draw.Color(config.point.r, config.point.g, config.point.b, config.point.a)
		draw.FilledRect(
			end2d[1] - config.point.size,
			end2d[2] - config.point.size,
			end2d[1] + config.point.size,
			end2d[2] + config.point.size
		)
	end

	-- Draw debug info
	draw.Color(255, 255, 255, 255)
	draw.SetFont(font)
	draw.Text(10, 10, string.format("Distance: %.1f units", pointState.distance))
	draw.Text(10, 25, string.format("View Yaw: %.1f°", viewAngles.y))
	draw.Text(10, 40, string.format("Segments: %d", numSegments))
	draw.Text(10, 55, string.format("Mouse Y: %.1f units/pixel", config.speed))
	draw.Text(10, 70, "Mouse Y = Distance | Follows View Yaw")
end

-------------------------------
-- MAIN CALLBACKS
-------------------------------
callbacks.Register("CreateMove", "PointControl", function(cmd)
	-- Get mouse movement
	local mouseX = cmd.mousedx or 0
	local mouseY = cmd.mousedy or 0

	-- Update point position based on mouse
	updatePointFromMouse(mouseX, mouseY)

	-- Zero mouse movement to prevent normal camera movement
	cmd.mousedx = 0
	cmd.mousedy = 0
end)

callbacks.Register("Draw", "DrawPointAndLine", function()
	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	drawPointAndLine()
end)
