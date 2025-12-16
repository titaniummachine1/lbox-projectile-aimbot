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
local VISUAL_ELEMENT_OPTIONS = { "Player Path", "Projectile Path", "Bounding Box", "Multipoint", "Quads" }

-- Private helpers -----
local function getAimMethodIndex(method)
	for index, option in ipairs(AIM_METHOD_OPTIONS) do
		if option == method then
			return index
		end
	end
	return 1
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

		cfg.MaxSimTime = TimMenu.Slider("Max Sim Time", cfg.MaxSimTime or 3.0, 0.5, 6.0, 0.1)
		TimMenu.Tooltip("Caps player prediction + projectile sim horizon (seconds)")
		TimMenu.NextLine()

		cfg.MinConfidence = TimMenu.Slider("Min Confidence %", cfg.MinConfidence, 0, 100, 1)
		TimMenu.Tooltip("Minimum hit chance required to shoot")
		TimMenu.NextLine()

		cfg.TrackedTargets = TimMenu.Slider("Tracked Enemies", cfg.TrackedTargets, 1, 8, 1)
		TimMenu.Tooltip("How many nearest enemies to keep wishdir/strafe history for")
		TimMenu.NextLine()

		cfg.PreferFeet = TimMenu.Checkbox("Prefer Feet", cfg.PreferFeet)
		TimMenu.Tooltip("Only applies when target is on ground")
		TimMenu.NextLine()

		cfg.AutoFlipViewmodels = TimMenu.Checkbox("Auto Flip Viewmodels", cfg.AutoFlipViewmodels)
		TimMenu.Tooltip("Sets cl_flipviewmodels based on which side has clearer 200u forward trace")
		TimMenu.EndSector()
		TimMenu.NextLine()
	end

	-- Visuals Tab
	if ui.SelectedTab == 2 then
		TimMenu.BeginSector("Draw")
		vis.Enabled = TimMenu.Checkbox("Enable", vis.Enabled)
		TimMenu.NextLine()

		vis.FadeOutDuration = TimMenu.Slider("Fade Out", vis.FadeOutDuration or 1.0, 0, 5, 0.1)
		TimMenu.NextLine()

		vis.ShowConfidence = TimMenu.Checkbox("Confidence", vis.ShowConfidence)
		TimMenu.NextLine()

		vis.ShowProfiler = TimMenu.Checkbox("Profiler", vis.ShowProfiler)
		TimMenu.NextLine()

		vis.DrawPlayerPath = TimMenu.Checkbox("Player Path", vis.DrawPlayerPath)
		TimMenu.NextLine()

		vis.DrawProjectilePath = TimMenu.Checkbox("Projectile Path", vis.DrawProjectilePath)
		TimMenu.NextLine()

		vis.DrawBoundingBox = TimMenu.Checkbox("Bounding Box", vis.DrawBoundingBox)
		TimMenu.NextLine()

		vis.DrawMultipointTarget = TimMenu.Checkbox("Multipoint", vis.DrawMultipointTarget)
		TimMenu.NextLine()

		vis.ShowMultipointDebug = TimMenu.Checkbox("Multipoint Debug", vis.ShowMultipointDebug)
		TimMenu.NextLine()
		if vis.ShowMultipointDebug then
			vis.MultipointDebugDuration = TimMenu.Slider("Debug Fade", vis.MultipointDebugDuration or 1.0, 0, 5, 0.1)
			TimMenu.NextLine()
		end

		vis.DrawQuads = TimMenu.Checkbox("Quads", vis.DrawQuads)
		TimMenu.EndSector()

		TimMenu.BeginSector("Colors")
		vis.ColorsRGBA = vis.ColorsRGBA or {}
		vis.ColorsRGBA.PlayerPath =
			TimMenu.ColorPicker("Player Path", vis.ColorsRGBA.PlayerPath or { 0, 255, 255, 255 })
		TimMenu.NextLine()
		vis.ColorsRGBA.ProjectilePath =
			TimMenu.ColorPicker("Projectile Path", vis.ColorsRGBA.ProjectilePath or { 255, 255, 0, 255 })
		TimMenu.NextLine()
		vis.ColorsRGBA.BoundingBox =
			TimMenu.ColorPicker("Bounding Box", vis.ColorsRGBA.BoundingBox or { 0, 255, 0, 255 })
		TimMenu.NextLine()
		vis.ColorsRGBA.MultipointTarget =
			TimMenu.ColorPicker("Multipoint", vis.ColorsRGBA.MultipointTarget or { 255, 0, 0, 255 })
		TimMenu.NextLine()
		vis.ColorsRGBA.Quads = TimMenu.ColorPicker("Quads", vis.ColorsRGBA.Quads or { 0, 0, 255, 25 })
		TimMenu.EndSector()

		TimMenu.BeginSector("Thickness")
		if vis.DrawPlayerPath then
			vis.Thickness.PlayerPath = TimMenu.Slider("Player Path", vis.Thickness.PlayerPath, 0.5, 5, 0.5)
			TimMenu.NextLine()
		end
		if vis.DrawProjectilePath then
			vis.Thickness.ProjectilePath = TimMenu.Slider("Projectile Path", vis.Thickness.ProjectilePath, 0.5, 5, 0.5)
			TimMenu.NextLine()
		end
		if vis.DrawBoundingBox then
			vis.Thickness.BoundingBox = TimMenu.Slider("Bounding Box", vis.Thickness.BoundingBox, 0.5, 5, 0.5)
			TimMenu.NextLine()
		end
		if vis.DrawMultipointTarget then
			vis.Thickness.MultipointTarget = TimMenu.Slider("Multipoint", vis.Thickness.MultipointTarget, 1, 10, 0.5)
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
