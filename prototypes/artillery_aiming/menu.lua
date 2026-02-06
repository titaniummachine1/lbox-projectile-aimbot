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

function Menu.draw()
	if not tryInitMenu() then
		return
	end

	TimMenu.Begin("Artillery Aiming", gui.IsMenuOpen())
	if gui.IsMenuOpen() then
		local tabs = { "Artillery", "Visuals" }
		selectedTab = TimMenu.TabControl("ArtilleryTabs", tabs, selectedTab)
		TimMenu.NextLine()

		if selectedTab == 1 then
			drawArtilleryTab()
		elseif selectedTab == 2 then
			drawVisualsTab()
		end
	end
end

return Menu
