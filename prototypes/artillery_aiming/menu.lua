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

local KEY_NAMES = {
	"NONE",
	"0",
	"1",
	"2",
	"3",
	"4",
	"5",
	"6",
	"7",
	"8",
	"9",
	"A",
	"B",
	"C",
	"D",
	"E",
	"F",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"S",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
}

local MODE_OPTIONS = { "Toggle", "Hold" }

function Menu.draw()
	if not tryInitMenu() then
		return
	end
	if not gui.IsMenuOpen() then
		return
	end

	if TimMenu.Begin("Artillery Aiming", true) then
		TimMenu.BeginSector("Keybinds")

		Config.keybinds.activate = TimMenu.Keybind("Activate Key", Config.keybinds.activate)
		TimMenu.NextLine()

		local activateModeIdx = (Config.keybinds.activate_mode == "toggle") and 1 or 2
		activateModeIdx = TimMenu.Selector("Activate Mode", activateModeIdx, MODE_OPTIONS)
		Config.keybinds.activate_mode = (activateModeIdx == 1) and "toggle" or "hold"
		TimMenu.NextLine()

		Config.keybinds.high_ground = TimMenu.Keybind("High Ground Key", Config.keybinds.high_ground)
		TimMenu.NextLine()

		local hgModeIdx = (Config.keybinds.high_ground_mode == "hold") and 2 or 1
		hgModeIdx = TimMenu.Selector("High Ground Mode", hgModeIdx, MODE_OPTIONS)
		Config.keybinds.high_ground_mode = (hgModeIdx == 1) and "toggle" or "hold"
		TimMenu.NextLine()

		Config.keybinds.scroll_mode_toggle = TimMenu.Keybind("Scroll Mode Key", Config.keybinds.scroll_mode_toggle)

		TimMenu.EndSector()

		TimMenu.BeginSector("Bombard Settings")

		Config.bombard.sensitivity = TimMenu.Slider("Mouse Sensitivity", Config.bombard.sensitivity, 0.1, 2.0, 0.05)
		TimMenu.NextLine()

		Config.bombard.max_distance = TimMenu.Slider("Max Distance", Config.bombard.max_distance, 500, 10000, 100)
		TimMenu.NextLine()

		Config.bombard.downward_surface_threshold =
			TimMenu.Slider("Surface Reject Angle", Config.bombard.downward_surface_threshold, 0.0, 1.0, 0.05)

		TimMenu.EndSector()

		TimMenu.BeginSector("Camera")

		Config.camera.fov = TimMenu.Slider("FOV", Config.camera.fov, 30, 120, 1)
		TimMenu.NextLine()

		Config.camera.interpSpeed = TimMenu.Slider("Smoothing", Config.camera.interpSpeed, 0.01, 1.0, 0.01)

		TimMenu.EndSector()

		TimMenu.BeginSector("Visuals")

		Config.visual.line.enabled = TimMenu.Checkbox("Draw Line", Config.visual.line.enabled)
		TimMenu.NextLine()

		Config.visual.flags.enabled = TimMenu.Checkbox("Draw Flags", Config.visual.flags.enabled)
		TimMenu.NextLine()

		Config.visual.polygon.enabled = TimMenu.Checkbox("Draw Impact", Config.visual.polygon.enabled)
		TimMenu.NextLine()

		Config.visual.outline.line_and_flags = TimMenu.Checkbox("Line Outline", Config.visual.outline.line_and_flags)
		TimMenu.NextLine()

		Config.visual.outline.polygon = TimMenu.Checkbox("Impact Outline", Config.visual.outline.polygon)

		TimMenu.EndSector()
	end
end

return Menu
