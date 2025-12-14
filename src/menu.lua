-- Imports
local G = require("globals")
local Config = require("config")

-- Try to load TimMenu (assumes it's installed globally in Lmaobox)
local TimMenu = nil
local timMenuLoaded, timMenuModule = pcall(require, "TimMenu")
if timMenuLoaded and timMenuModule then
	TimMenu = timMenuModule
	printc(100, 255, 100, 255, "[Menu] TimMenu loaded successfully")
else
	error("[Menu] TimMenu not found! Please install TimMenu to %localappdata%\\lmaobox\\Scripts\\TimMenu.lua")
end

-- Module declaration
local Menu = {}

-- Local constants / utilities -----
local AIM_METHOD_OPTIONS = { "silent +", "silent", "normal" }
local VISUAL_PRESET_OPTIONS = { "None", "Simulation", "Simulation + Box", "Multipoint", "All", "Custom" }
local COLOR_OPTIONS = { "Red", "Yellow", "Green", "Cyan", "Blue", "Magenta", "White" }
local COLOR_HUES = { 0, 60, 120, 180, 240, 300, 360 }

-- Private helpers -----
local function getAimMethodIndex(method)
	for index, option in ipairs(AIM_METHOD_OPTIONS) do
		if option == method then
			return index
		end
	end
	return 1
end

local function getHueIndex(hue)
	if type(hue) ~= "number" then
		return 7
	end
	local closestIndex = 7
	local bestDist = math.huge
	for i = 1, #COLOR_HUES do
		local d = math.abs((COLOR_HUES[i] or 360) - hue)
		if d < bestDist then
			bestDist = d
			closestIndex = i
		end
	end
	return closestIndex
end

local function getHueValue(index)
	local v = COLOR_HUES[index]
	if type(v) ~= "number" then
		return 360
	end
	return v
end

local function applyVisualPreset(presetIndex, vis)
	if not vis then
		return
	end

	local preset = presetIndex or 2
	if preset == 1 then
		vis.DrawPlayerPath = false
		vis.DrawProjectilePath = false
		vis.DrawBoundingBox = false
		vis.DrawMultipointTarget = false
		vis.DrawQuads = false
		return
	end

	if preset == 2 then
		vis.DrawPlayerPath = true
		vis.DrawProjectilePath = true
		vis.DrawBoundingBox = false
		vis.DrawMultipointTarget = false
		vis.DrawQuads = false
		return
	end

	if preset == 3 then
		vis.DrawPlayerPath = true
		vis.DrawProjectilePath = true
		vis.DrawBoundingBox = true
		vis.DrawMultipointTarget = false
		vis.DrawQuads = false
		return
	end

	if preset == 4 then
		vis.DrawPlayerPath = false
		vis.DrawProjectilePath = false
		vis.DrawBoundingBox = false
		vis.DrawMultipointTarget = true
		vis.DrawQuads = false
		return
	end

	if preset == 5 then
		vis.DrawPlayerPath = true
		vis.DrawProjectilePath = true
		vis.DrawBoundingBox = true
		vis.DrawMultipointTarget = true
		vis.DrawQuads = true
		return
	end
end

local function drawMenu()
	assert(G.Menu, "Menu: G.Menu is nil")
	assert(TimMenu, "Menu: TimMenu is nil")

	-- Begin the menu - visibility parameter syncs with Lmaobox menu without resetting position
	TimMenu.Begin("Projectile Aimbot", gui.IsMenuOpen())

	local cfg = G.Menu.Aimbot
	local vis = G.Menu.Visuals
	local ui = G.Menu.UI

	-- Tab Control
	local tabs = { "Aimbot", "Visuals" }
	ui.SelectedTab = TimMenu.TabControl("MainTabs", tabs, ui.SelectedTab)
	TimMenu.NextLine()

	-- Aimbot Tab
	if ui.SelectedTab == 1 then
		TimMenu.BeginSector("Main Settings")
		cfg.Enabled = TimMenu.Checkbox("Enable", cfg.Enabled)
		TimMenu.NextLine()

		-- Activation Mode Dropdown
		local activationModes = { "Always", "On Hold", "Toggle" }
		local dropdownValue = TimMenu.Dropdown("Activation Mode", cfg.ActivationMode + 1, activationModes)
		cfg.ActivationMode = dropdownValue - 1 -- Convert back to 0-based
		TimMenu.Tooltip("Always=Always active, Hold=While key held, Toggle=Press to toggle")
		TimMenu.NextLine()

		-- Only show keybind if not in Always mode (mode 0)
		if cfg.ActivationMode ~= 0 then
			cfg.AimKey = TimMenu.Keybind("Activation Key", cfg.AimKey)
			TimMenu.Tooltip("Key for activation mode")
			TimMenu.NextLine()
		end

		-- On Attack checkbox (works with any mode)
		cfg.OnAttack = TimMenu.Checkbox("On Attack", cfg.OnAttack)
		TimMenu.Tooltip("Also activate when attacking (combines with activation mode)")
		TimMenu.NextLine()

		cfg.AimFOV = TimMenu.Slider("Aim FOV", cfg.AimFOV, 1, 180, 1)
		TimMenu.Tooltip("Field of view in degrees for target selection")
		TimMenu.NextLine()

		local aimMethodIndex = getAimMethodIndex(cfg.AimMethod)
		aimMethodIndex = TimMenu.Dropdown("Aim Method", aimMethodIndex, AIM_METHOD_OPTIONS)
		cfg.AimMethod = AIM_METHOD_OPTIONS[aimMethodIndex]
		TimMenu.Tooltip("silent+ = no packet, silent = packet sent, normal = view change")
		TimMenu.NextLine()

		cfg.AimSentry = TimMenu.Checkbox("Aim Sentry", cfg.AimSentry)
		TimMenu.NextLine()

		cfg.AimOtherBuildings = TimMenu.Checkbox("Aim Other Buildings", cfg.AimOtherBuildings)
		TimMenu.Tooltip("Target dispensers and teleporters")
		TimMenu.EndSector()

		-- Prediction Settings
		TimMenu.BeginSector("Prediction")
		cfg.MaxDistance = TimMenu.Slider("Max Distance", cfg.MaxDistance, 500, 6000, 50)
		TimMenu.NextLine()

		cfg.MinAccuracy = TimMenu.Slider("Min Lazyness", cfg.MinAccuracy, 1, 12, 1)
		TimMenu.Tooltip("Ticks to skip at close range (lower = more accurate, slower)")
		TimMenu.NextLine()

		local maxAccuracyMinimum = math.max(cfg.MinAccuracy, 2)
		cfg.MaxAccuracy = TimMenu.Slider("Max Lazyness", cfg.MaxAccuracy, maxAccuracyMinimum, 12, 1)
		cfg.MaxAccuracy = math.max(cfg.MaxAccuracy, cfg.MinAccuracy)
		cfg.MaxAccuracy = math.min(cfg.MaxAccuracy, 12)
		TimMenu.Tooltip("Ticks to skip at max range (higher = less accurate, faster)")
		TimMenu.NextLine()

		cfg.MinConfidence = TimMenu.Slider("Min Confidence %", cfg.MinConfidence, 0, 100, 1)
		TimMenu.Tooltip("Minimum hit chance required to shoot")
		TimMenu.NextLine()

		cfg.TrackedTargets = TimMenu.Slider("Tracked Enemies", cfg.TrackedTargets, 1, 8, 1)
		TimMenu.Tooltip("How many nearest enemies to keep wishdir/strafe history for")
		TimMenu.NextLine()

		cfg.VisibilityCheckTargets =
			TimMenu.Slider("Visibility Check Targets", cfg.VisibilityCheckTargets or 4, 0, 8, 1)
		TimMenu.Tooltip("How many best targets get an extra can-hit check (no binary search)")
		TimMenu.NextLine()

		cfg.PreferFeet = TimMenu.Checkbox("Prefer Feet", cfg.PreferFeet)
		TimMenu.Tooltip("Only applies when target is on ground")
		TimMenu.EndSector()
		TimMenu.NextLine()
	end

	-- Visuals Tab
	if ui.SelectedTab == 2 then
		TimMenu.BeginSector("Draw")
		vis.Enabled = TimMenu.Checkbox("Enable", vis.Enabled)
		TimMenu.NextLine()

		vis.DrawPreset = vis.DrawPreset or 2
		vis.DrawPreset = TimMenu.Dropdown("Preset", vis.DrawPreset, VISUAL_PRESET_OPTIONS)
		TimMenu.NextLine()

		vis.MultipointDebugDuration = TimMenu.Slider("Debug Duration", vis.MultipointDebugDuration or 1.0, 0, 5, 0.1)
		TimMenu.NextLine()

		vis.ShowConfidence = TimMenu.Checkbox("Confidence", vis.ShowConfidence)
		TimMenu.NextLine()

		vis.ShowProfiler = TimMenu.Checkbox("Profiler", vis.ShowProfiler)
		TimMenu.EndSector()

		TimMenu.BeginSector("Options")
		vis.ShowAdvanced = TimMenu.Checkbox("Advanced", vis.ShowAdvanced)
		TimMenu.NextLine()

		if vis.DrawPreset == 6 then
			vis.DrawPlayerPath = TimMenu.Checkbox("Player Path", vis.DrawPlayerPath)
			TimMenu.NextLine()
			vis.DrawProjectilePath = TimMenu.Checkbox("Projectile Path", vis.DrawProjectilePath)
			TimMenu.NextLine()
			vis.DrawBoundingBox = TimMenu.Checkbox("Bounding Box", vis.DrawBoundingBox)
			TimMenu.NextLine()
			vis.DrawMultipointTarget = TimMenu.Checkbox("Multipoint", vis.DrawMultipointTarget)
			TimMenu.NextLine()
			vis.DrawQuads = TimMenu.Checkbox("Quads", vis.DrawQuads)
			TimMenu.NextLine()
		else
			applyVisualPreset(vis.DrawPreset, vis)
		end

		if vis.ShowAdvanced then
			local idx
			idx = TimMenu.Dropdown("Player Path Color", getHueIndex(vis.Colors.PlayerPath), COLOR_OPTIONS)
			vis.Colors.PlayerPath = getHueValue(idx)
			TimMenu.NextLine()
			idx = TimMenu.Dropdown("Projectile Color", getHueIndex(vis.Colors.ProjectilePath), COLOR_OPTIONS)
			vis.Colors.ProjectilePath = getHueValue(idx)
			TimMenu.NextLine()
			idx = TimMenu.Dropdown("Box Color", getHueIndex(vis.Colors.BoundingBox), COLOR_OPTIONS)
			vis.Colors.BoundingBox = getHueValue(idx)
			TimMenu.NextLine()
			idx = TimMenu.Dropdown("Multipoint Color", getHueIndex(vis.Colors.MultipointTarget), COLOR_OPTIONS)
			vis.Colors.MultipointTarget = getHueValue(idx)
			TimMenu.NextLine()
			idx = TimMenu.Dropdown("Quads Color", getHueIndex(vis.Colors.Quads), COLOR_OPTIONS)
			vis.Colors.Quads = getHueValue(idx)
			TimMenu.NextLine()

			vis.Thickness.PlayerPath = TimMenu.Slider("Thick: Player", vis.Thickness.PlayerPath, 0.5, 5, 0.5)
			TimMenu.NextLine()
			vis.Thickness.ProjectilePath = TimMenu.Slider("Thick: Proj", vis.Thickness.ProjectilePath, 0.5, 5, 0.5)
			TimMenu.NextLine()
			vis.Thickness.BoundingBox = TimMenu.Slider("Thick: Box", vis.Thickness.BoundingBox, 0.5, 5, 0.5)
			TimMenu.NextLine()
			vis.Thickness.MultipointTarget = TimMenu.Slider("Thick: MP", vis.Thickness.MultipointTarget, 1, 10, 0.5)
		end
		TimMenu.EndSector()
		TimMenu.NextLine()
	end

	-- Always end the menu
	TimMenu.End()
end

-- Public API ----
function Menu.draw()
	if not G.Menu then
		printc(255, 100, 100, 255, "[Menu] Error: G.Menu not initialized")
		return
	end

	drawMenu()
end

function Menu.getConfig()
	return G.Menu
end

-- Don't auto-register Draw callback - only draw when menu is open
local function safeDrawMenu()
	if not gui.IsMenuOpen() then
		return
	end

	if not G.Menu or not TimMenu then
		return
	end

	pcall(drawMenu)
end

-- Callbacks -----
callbacks.Unregister("Draw", "PROJ_AIMBOT_MENU")
callbacks.Register("Draw", "PROJ_AIMBOT_MENU", safeDrawMenu)

return Menu
