local Config = require("config")
local State = require("state")

local TimMenu = nil
local menuInitialized = false

local function tryInitMenu()
	if menuInitialized then
		return TimMenu ~= nil
	end
	menuInitialized = true
	local ok, result = pcall(require, "TimMenu")
	if ok and result then
		TimMenu = result
		return true
	end
	print("[ArtilleryAiming] TimMenu not found, using defaults")
	return false
end

local Menu = {}

local MODE_OPTIONS = { "Toggle", "Hold" }
local selectedTab = 1

local function drawArtilleryTab()
	TimMenu.BeginSector("Artillery Aiming")

	Config.bombard.enabled = TimMenu.Checkbox("Enable Artillery", Config.bombard.enabled)
	TimMenu.NextLine()

	if Config.bombard.enabled then
		Config.keybinds.activate = TimMenu.Keybind("Activate Key", Config.keybinds.activate)
		TimMenu.NextLine()

		local activateModeIdx = (Config.keybinds.activate_mode == "toggle") and 1 or 2
		activateModeIdx = TimMenu.Selector("Activate Mode", activateModeIdx, MODE_OPTIONS)
		Config.keybinds.activate_mode = (activateModeIdx == 1) and "toggle" or "hold"
		TimMenu.NextLine()

		Config.keybinds.high_ground = TimMenu.Keybind("High Ground Key", Config.keybinds.high_ground)
		TimMenu.NextLine()

		Config.bombard.sensitivity = TimMenu.Slider("Mouse Sensitivity", Config.bombard.sensitivity, 0.1, 2.0, 0.05)
		TimMenu.NextLine()

		Config.bombard.max_distance = TimMenu.Slider("Max Distance", Config.bombard.max_distance, 500, 10000, 100)
	end

	TimMenu.EndSector()

	if Config.bombard.enabled then
		TimMenu.BeginSector("Camera")

		Config.camera.fov = TimMenu.Slider("FOV", Config.camera.fov, 30, 120, 1)
		TimMenu.NextLine()

		Config.camera.interpSpeed = TimMenu.Slider("Smoothing", Config.camera.interpSpeed, 0.01, 1.0, 0.01)
		TimMenu.NextLine()

		Config.camera.width = TimMenu.Slider("Width", Config.camera.width, 200, 1200, 50)
		TimMenu.NextLine()

		Config.camera.height = TimMenu.Slider("Height", Config.camera.height, 150, 800, 50)

		TimMenu.EndSector()
	end
end

local function drawVisualsTab()
	TimMenu.BeginSector("Elements")

	Config.visual.line.enabled = TimMenu.Checkbox("Trajectory Line", Config.visual.line.enabled)
	TimMenu.NextLine()

	Config.visual.flags.enabled = TimMenu.Checkbox("Flags", Config.visual.flags.enabled)
	TimMenu.NextLine()

	Config.visual.polygon.enabled = TimMenu.Checkbox("Impact Polygon", Config.visual.polygon.enabled)
	TimMenu.NextLine()

	Config.visual.outline.line_and_flags = TimMenu.Checkbox("Line Outline", Config.visual.outline.line_and_flags)
	TimMenu.NextLine()

	Config.visual.outline.polygon = TimMenu.Checkbox("Impact Outline", Config.visual.outline.polygon)

	TimMenu.EndSector()

	TimMenu.NextLine()

	TimMenu.BeginSector("Line Color")

	local lineRGBA = { Config.visual.line.r, Config.visual.line.g, Config.visual.line.b, Config.visual.line.a }
	lineRGBA = TimMenu.ColorPicker("Line", lineRGBA)
	Config.visual.line.r = lineRGBA[1]
	Config.visual.line.g = lineRGBA[2]
	Config.visual.line.b = lineRGBA[3]
	Config.visual.line.a = lineRGBA[4]

	TimMenu.EndSector()

	TimMenu.NextLine()

	TimMenu.BeginSector("Flag Color")

	local flagRGBA = { Config.visual.flags.r, Config.visual.flags.g, Config.visual.flags.b, Config.visual.flags.a }
	flagRGBA = TimMenu.ColorPicker("Flags", flagRGBA)
	Config.visual.flags.r = flagRGBA[1]
	Config.visual.flags.g = flagRGBA[2]
	Config.visual.flags.b = flagRGBA[3]
	Config.visual.flags.a = flagRGBA[4]
	TimMenu.NextLine()

	Config.visual.flags.size = TimMenu.Slider("Flag Size", Config.visual.flags.size, 1, 20, 1)

	TimMenu.EndSector()

	TimMenu.NextLine()

	TimMenu.BeginSector("Impact Polygon")

	local polyRGBA = {
		Config.visual.polygon.r,
		Config.visual.polygon.g,
		Config.visual.polygon.b,
		Config.visual.polygon.a,
	}
	polyRGBA = TimMenu.ColorPicker("Polygon", polyRGBA)
	Config.visual.polygon.r = polyRGBA[1]
	Config.visual.polygon.g = polyRGBA[2]
	Config.visual.polygon.b = polyRGBA[3]
	Config.visual.polygon.a = polyRGBA[4]
	TimMenu.NextLine()

	Config.visual.polygon.size = TimMenu.Slider("Size", Config.visual.polygon.size, 2, 30, 1)
	TimMenu.NextLine()

	Config.visual.polygon.segments = TimMenu.Slider("Segments", Config.visual.polygon.segments, 6, 40, 2)

	TimMenu.EndSector()

	TimMenu.NextLine()

	TimMenu.BeginSector("Outline Color")

	local outRGBA = {
		Config.visual.outline.r,
		Config.visual.outline.g,
		Config.visual.outline.b,
		Config.visual.outline.a,
	}
	outRGBA = TimMenu.ColorPicker("Outline", outRGBA)
	Config.visual.outline.r = outRGBA[1]
	Config.visual.outline.g = outRGBA[2]
	Config.visual.outline.b = outRGBA[3]
	Config.visual.outline.a = outRGBA[4]

	TimMenu.EndSector()

	TimMenu.BeginSector("Performance")

	local newAcc = TimMenu.Slider("Accuracy (%)", Config.visual.accuracy, 1, 100, 1)
	if newAcc ~= Config.visual.accuracy then
		Config.visual.accuracy = newAcc
		Config.recomputeComputed()
	end

	TimMenu.EndSector()
end

local function drawLiveProjectilesTab()
	local cfg = Config.visual.live_projectiles

	TimMenu.BeginSector("Live Projectile Tracking")

	cfg.enabled = TimMenu.Checkbox("Enable Tracking", cfg.enabled)
	TimMenu.NextLine()

	if cfg.enabled then
		cfg.max_distance = TimMenu.Slider("Max Distance", cfg.max_distance, 500, 8000, 100)
		TimMenu.NextLine()

		cfg.explosion_radius = TimMenu.Slider("Explosion Radius", cfg.explosion_radius, 10, 200, 5)
		TimMenu.NextLine()

		cfg.revalidate_distance = TimMenu.Slider("Recalc Distance", cfg.revalidate_distance, 10, 200, 5)
		TimMenu.NextLine()

		cfg.revalidate_angle = TimMenu.Slider("Recalc Angle (deg)", cfg.revalidate_angle, 10, 90, 5)
	end

	TimMenu.EndSector()

	if cfg.enabled then
		TimMenu.NextLine()

		TimMenu.BeginSector("Projectile Types")

		cfg.rockets = TimMenu.Checkbox("Rockets", cfg.rockets)
		TimMenu.NextLine()

		cfg.stickies = TimMenu.Checkbox("Stickies", cfg.stickies)
		TimMenu.NextLine()

		cfg.pipes = TimMenu.Checkbox("Pipes", cfg.pipes)
		TimMenu.NextLine()

		cfg.flares = TimMenu.Checkbox("Flares", cfg.flares)
		TimMenu.NextLine()

		cfg.arrows = TimMenu.Checkbox("Arrows", cfg.arrows)
		TimMenu.NextLine()

		cfg.energy = TimMenu.Checkbox("Energy Balls", cfg.energy)
		TimMenu.NextLine()

		cfg.fireballs = TimMenu.Checkbox("Fireballs", cfg.fireballs)

		TimMenu.EndSector()

		TimMenu.NextLine()

		TimMenu.BeginSector("Line Color")

		local lineRGBA = { cfg.line.r, cfg.line.g, cfg.line.b, cfg.line.a }
		lineRGBA = TimMenu.ColorPicker("Trajectory", lineRGBA)
		cfg.line.r = lineRGBA[1]
		cfg.line.g = lineRGBA[2]
		cfg.line.b = lineRGBA[3]
		cfg.line.a = lineRGBA[4]

		TimMenu.EndSector()

		TimMenu.NextLine()

		TimMenu.BeginSector("Marker")

		local markerRGBA = { cfg.marker.r, cfg.marker.g, cfg.marker.b, cfg.marker.a }
		markerRGBA = TimMenu.ColorPicker("Marker", markerRGBA)
		cfg.marker.r = markerRGBA[1]
		cfg.marker.g = markerRGBA[2]
		cfg.marker.b = markerRGBA[3]
		cfg.marker.a = markerRGBA[4]
		TimMenu.NextLine()

		cfg.marker_size = TimMenu.Slider("Size", cfg.marker_size, 1, 8, 1)

		TimMenu.EndSector()
	end
end

function Menu.draw()
	if not tryInitMenu() then
		return
	end

	TimMenu.Begin("Artillery Aiming", gui.IsMenuOpen())
	if gui.IsMenuOpen() then
		local tabs = { "Artillery", "Weapon Trajectory", "Live Projectiles" }
		selectedTab = TimMenu.TabControl("ArtilleryTabs", tabs, selectedTab)
		TimMenu.NextLine()

		if selectedTab == 1 then
			drawArtilleryTab()
		elseif selectedTab == 2 then
			drawVisualsTab()
		elseif selectedTab == 3 then
			drawLiveProjectilesTab()
		end
	end
end

return Menu
