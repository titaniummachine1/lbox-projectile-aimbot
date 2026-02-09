local Config = require("config")
local State = require("state")
local Utils = require("utils")

local worldToScreen = client.WorldToScreen
local drawLine = draw.Line
local setColor = draw.Color
local getScreenSize = draw.GetScreenSize

local Camera = {}

local g_iPolygonTexture = draw.CreateTextureRGBA("\xff\xff\xff" .. string.char(Config.visual.polygon.a), 1, 1)

local projCamFont = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

local function initMaterials()
	local cam = State.camera
	if cam.materialsReady then
		return true
	end

	if not materials or not materials.CreateTextureRenderTarget then
		return false
	end

	local texName = "projCamTexture"
	cam.texture = materials.CreateTextureRenderTarget(texName, Config.camera.width, Config.camera.height)
	if not cam.texture then
		return false
	end

	if not materials.Create then
		return false
	end

	cam.material = materials.Create(
		"projCamMaterial",
		string.format(
			[[
        UnlitGeneric
        {
            $basetexture    "%s"
            $ignorez        1
            $nofog          1
        }
    ]],
			texName
		)
	)
	if not cam.material then
		return false
	end

	cam.materialsReady = true
	return true
end

function Camera.isActive()
	return State.camera.active and #State.camera.storedPositions > 1
end

function Camera.handleInput()
	if not Camera.isActive() then
		return
	end

	local menuOpen = gui.GetValue("Menu") == 1
	local cam = State.camera
	local cfg = Config.camera

	if menuOpen then
		local mx, my = table.unpack(input.GetMousePos())
		local titleBarY = cfg.y - 20

		if input.IsButtonDown(MOUSE_LEFT) then
			if not cam.isDragging then
				if mx >= cfg.x and mx <= cfg.x + cfg.width and my >= titleBarY and my <= cfg.y then
					cam.isDragging = true
					cam.dragOffsetX = mx - cfg.x
					cam.dragOffsetY = my - cfg.y
				end
			else
				local screenW, screenH = getScreenSize()
				cfg.x = Utils.clamp(mx - cam.dragOffsetX, 0, screenW - cfg.width)
				cfg.y = Utils.clamp(my - cam.dragOffsetY, 25, screenH - cfg.height)
			end
		else
			cam.isDragging = false
		end
	else
		cam.isDragging = false
	end

	if not menuOpen then
		if input.IsButtonPressed(MOUSE_WHEEL_UP) then
			cam.pathPercent = Utils.clamp(cam.pathPercent + cfg.scrollStep, 0, 0.9)
		elseif input.IsButtonPressed(MOUSE_WHEEL_DOWN) then
			cam.pathPercent = Utils.clamp(cam.pathPercent - cfg.scrollStep, 0, 0.9)
		end
	end
end

function Camera.updateSmoothing()
	local positions = State.camera.storedPositions
	local velocities = State.camera.storedVelocities
	if #positions < 2 then
		return
	end

	local count = #positions
	local exactIndex = 1 + (count - 1) * State.camera.pathPercent
	local lowIdx = math.floor(exactIndex)
	local highIdx = math.ceil(exactIndex)
	local frac = exactIndex - lowIdx
	lowIdx = Utils.clamp(lowIdx, 1, count)
	highIdx = Utils.clamp(highIdx, 1, count)

	local targetPos = Utils.lerpVector(positions[lowIdx], positions[highIdx], frac)
	local targetVel
	if velocities and #velocities >= highIdx then
		targetVel = Utils.lerpVector(velocities[lowIdx], velocities[highIdx], frac)
	else
		targetVel = positions[highIdx] - positions[lowIdx]
	end

	local targetAngles = Utils.velocityToAngles(targetVel)
	targetAngles.x = targetAngles.x + 5

	local interpSpeed = Config.camera.interpSpeed
	State.camera.smoothedPos = Utils.lerpVector(State.camera.smoothedPos, targetPos, interpSpeed)
	State.camera.smoothedAngles = EulerAngles(
		Utils.lerpAngle(State.camera.smoothedAngles.x, targetAngles.x, interpSpeed),
		Utils.lerpAngle(State.camera.smoothedAngles.y, targetAngles.y, interpSpeed),
		0
	)
end

function Camera.renderView()
	if #State.camera.storedPositions < 2 then
		client.ChatPrintf("\x07FF0000Camera: Not enough positions")
		return
	end
	if not State.camera.texture then
		client.ChatPrintf("\x07FF0000Camera: No texture")
		return
	end

	local ctx = client.GetPlayerView()
	assert(ctx, "Camera.renderView: client.GetPlayerView() returned nil")

	-- Modify the view for the camera
	ctx.origin = State.camera.smoothedPos
	ctx.angles = State.camera.smoothedAngles
	ctx.fov = Config.camera.fov

	-- Set viewport to match camera texture size
	ctx.x = 0
	ctx.y = 0
	ctx.width = Config.camera.width
	ctx.height = Config.camera.height

	-- Store THIS view for WorldToScreen calls
	State.camera.lastView = ctx

	client.ChatPrintf("\x0700FF00Camera: Rendering at " .. tostring(ctx.origin))

	render.Push3DView(ctx, 0x37, State.camera.texture)
	render.ViewDrawScene(true, true, ctx)
	render.PopView()
end

function Camera.drawTexture()
	if not State.trajectory.isValid then
		return
	end
	if not State.camera.material then
		return
	end
	if not render or not render.DrawScreenSpaceRectangle then
		return
	end

	local cfg = Config.camera
	render.DrawScreenSpaceRectangle(
		State.camera.material,
		cfg.x,
		cfg.y,
		cfg.width,
		cfg.height,
		0,
		0,
		cfg.width,
		cfg.height,
		cfg.width,
		cfg.height
	)
end

local function projectToCamera(worldPos)
	local view = State.camera.lastView
	if not view then
		return nil
	end

	-- client.WorldToScreen accepts a ViewSetup as second parameter!
	local screen = client.WorldToScreen(worldPos, view)
	if not screen then
		return nil
	end

	local sx, sy = screen[1], screen[2]
	if not sx or not sy then
		return nil
	end

	-- Convert from camera texture coordinates to screen coordinates
	return Config.camera.x + sx, Config.camera.y + sy
end

function Camera.drawCameraTrajectory()
	local traj = State.trajectory
	if not traj.isValid or #traj.positions < 2 then
		return
	end

	local cfg = Config.camera
	local visCfg = Config.visual
	assert(visCfg.line, "drawCameraTrajectory: visCfg.line is nil")
	assert(visCfg.flags, "drawCameraTrajectory: visCfg.flags is nil")

	local lastSx, lastSy = nil, nil
	for i = #traj.positions, 1, -1 do
		local pos = traj.positions[i]
		local sx, sy = projectToCamera(pos)
		if sx and lastSx then
			if visCfg.line.enabled then
				setColor(visCfg.line.r, visCfg.line.g, visCfg.line.b, visCfg.line.a)
				drawLine(math.floor(lastSx), math.floor(lastSy), math.floor(sx), math.floor(sy))
			end
			if visCfg.flags.enabled then
				local flagPos = pos + traj.flagOffset
				local fx, fy = projectToCamera(flagPos)
				if fx then
					setColor(visCfg.flags.r, visCfg.flags.g, visCfg.flags.b, visCfg.flags.a)

					drawLine(math.floor(fx), math.floor(fy), math.floor(sx), math.floor(sy))
				end
			end
		end
		lastSx, lastSy = sx, sy
	end

	if traj.impactPos and traj.impactPlane then
		Camera.drawImpactPolygonInCamera(traj.impactPlane, traj.impactPos)
	end
end

function Camera.drawImpactPolygonInCamera(plane, origin)
	if not Config.visual.polygon.enabled then
		return
	end

	local iSegments = Config.visual.polygon.segments
	local fSegmentAngleOffset = math.pi / iSegments
	local fSegmentAngle = fSegmentAngleOffset * 2
	local radius = Config.visual.polygon.size
	local positions = {}

	if math.abs(plane.z) >= 0.99 then
		for i = 1, iSegments do
			local ang = i * fSegmentAngle + fSegmentAngleOffset
			local worldPos = origin + Vector3(radius * math.cos(ang), radius * math.sin(ang), 0)
			local sx, sy = projectToCamera(worldPos)
			if not sx then
				return
			end
			positions[i] = { sx, sy }
		end
	else
		local right = Vector3(-plane.y, plane.x, 0)
		local up = Vector3(plane.z * right.y, -plane.z * right.x, (plane.y * right.x) - (plane.x * right.y))
		radius = radius / math.cos(math.asin(plane.z))
		for i = 1, iSegments do
			local ang = i * fSegmentAngle + fSegmentAngleOffset
			local worldPos = origin + (right * (radius * math.cos(ang))) + (up * (radius * math.sin(ang)))
			local sx, sy = projectToCamera(worldPos)
			if not sx then
				return
			end
			positions[i] = { sx, sy }
		end
	end

	if Config.visual.outline.polygon then
		setColor(Config.visual.outline.r, Config.visual.outline.g, Config.visual.outline.b, Config.visual.outline.a)
		local last = positions[#positions]
		for i = 1, #positions do
			local new = positions[i]
			if math.abs(new[1] - last[1]) > math.abs(new[2] - last[2]) then
				drawLine(math.floor(last[1]), math.floor(last[2] + 1), math.floor(new[1]), math.floor(new[2] + 1))
				drawLine(math.floor(last[1]), math.floor(last[2] - 1), math.floor(new[1]), math.floor(new[2] - 1))
			else
				drawLine(math.floor(last[1] + 1), math.floor(last[2]), math.floor(new[1] + 1), math.floor(new[2]))
				drawLine(math.floor(last[1] - 1), math.floor(last[2]), math.floor(new[1] - 1), math.floor(new[2]))
			end
			last = new
		end
	end

	setColor(Config.visual.polygon.r, Config.visual.polygon.g, Config.visual.polygon.b, 255)
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
			drawLine(math.floor(last[1]), math.floor(last[2]), math.floor(new[1]), math.floor(new[2]))
			last = new
		end
	end
end

function Camera.drawWindow()
	local cfg = Config.camera
	local st = State.bombard
	local x, y = cfg.x, cfg.y
	local w, h = cfg.width, cfg.height

	setColor(235, 64, 52, 255)
	draw.OutlinedRect(x, y, x + w, y + h)
	draw.OutlinedRect(x, y - 20, x + w, y)

	setColor(130, 26, 17, 255)
	draw.FilledRect(x + 1, y - 19, x + w - 1, y - 1)

	draw.SetFont(projCamFont)
	setColor(255, 255, 255, 255)
	local titleText = "Artillery Aiming"
	local textW, _ = draw.GetTextSize(titleText)
	draw.Text(math.floor(x + w * 0.5 - textW * 0.5), y - 16, titleText)

	setColor(0, 255, 0, 255)
	local posText = string.format("Cam: %.0f%%", State.camera.pathPercent * 100)
	draw.Text(x + 5, y + 5, posText)

	setColor(0, 200, 255, 255)
	local distText = string.format("Dist: %.0f", st.lockedDistance)
	draw.Text(x + 5, y + 20, distText)

	setColor(255, 200, 0, 255)
	local chargeText = string.format("Charge: %.0f%%", st.chargeLevel * 100)
	draw.Text(x + 5, y + 35, chargeText)

	setColor(255, 255, 0, 255)
	local pitchText =
		string.format("Pitch: %s", st.calculatedPitch and string.format("%.1f", st.calculatedPitch) or "N/A")
	draw.Text(x + 5, y + 50, pitchText)

	local modeColor = st.highGroundHeld and { 255, 150, 0 } or { 0, 255, 100 }
	setColor(modeColor[1], modeColor[2], modeColor[3], 255)
	local modeText = st.highGroundHeld and "[Q] HIGH GROUND" or "LOW GROUND"
	draw.Text(x + 5, y + 65, modeText)

	setColor(255, 255, 255, 180)
	draw.Text(x + 5, y + h + 5, "MouseY=Dist  Scroll=CamPos")
end

function Camera.onPostRenderView(view)
	if not Camera.isActive() then
		return
	end

	if not initMaterials() then
		return
	end

	Camera.renderView()
end

function Camera.cleanup()
	State.camera.texture = nil
	State.camera.material = nil
	State.camera.materialsReady = false
	State.camera.storedPositions = {}
	State.camera.storedVelocities = {}
end

return Camera
