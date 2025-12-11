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
	local tabs = {"Aimbot", "Visuals"}
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
		TimMenu.NextLine()

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
		TimMenu.EndSector()
	end

	-- Visuals Tab
	if ui.SelectedTab == 2 then
		TimMenu.BeginSector("Display Options")
		vis.Enabled = TimMenu.Checkbox("Enable Visuals", vis.Enabled)
		TimMenu.NextLine()
		
		vis.ShowProfiler = TimMenu.Checkbox("Performance Profiler", vis.ShowProfiler)
		TimMenu.Tooltip("Shows performance and memory usage overlay (helps find memory leaks)")
		TimMenu.NextLine()

		vis.ShowConfidence = TimMenu.Checkbox("Show Confidence Score", vis.ShowConfidence)
		TimMenu.Tooltip("Display hit chance percentage on screen")
		TimMenu.NextLine()

		vis.DrawPlayerPath = TimMenu.Checkbox("Draw Player Path", vis.DrawPlayerPath)
		TimMenu.Tooltip("Show predicted enemy movement path")
		TimMenu.NextLine()

		vis.DrawProjectilePath = TimMenu.Checkbox("Draw Projectile Path", vis.DrawProjectilePath)
		TimMenu.Tooltip("Show predicted projectile trajectory")
		TimMenu.NextLine()

		vis.DrawBoundingBox = TimMenu.Checkbox("Draw Bounding Box", vis.DrawBoundingBox)
		TimMenu.Tooltip("Show enemy hitbox at predicted position")
		TimMenu.NextLine()

		vis.DrawMultipointTarget = TimMenu.Checkbox("Draw Multipoint Target", vis.DrawMultipointTarget)
		TimMenu.Tooltip("Show calculated aim point")
		TimMenu.NextLine()

		vis.DrawQuads = TimMenu.Checkbox("Draw Quads", vis.DrawQuads)
		TimMenu.Tooltip("Show 3D filled boxes (experimental)")
		TimMenu.EndSector()
		TimMenu.NextLine()

		-- Color settings
		TimMenu.BeginSector("Colors (HSV)")
		vis.Colors.PlayerPath = TimMenu.Slider("Player Path Hue", vis.Colors.PlayerPath, 0, 360, 1)
		TimMenu.Tooltip("0=Red, 60=Yellow, 120=Green, 180=Cyan, 240=Blue, 300=Magenta, 360=White")
		TimMenu.NextLine()

		vis.Colors.ProjectilePath = TimMenu.Slider("Projectile Path Hue", vis.Colors.ProjectilePath, 0, 360, 1)
		TimMenu.NextLine()

		vis.Colors.BoundingBox = TimMenu.Slider("Bounding Box Hue", vis.Colors.BoundingBox, 0, 360, 1)
		TimMenu.NextLine()

		vis.Colors.MultipointTarget = TimMenu.Slider("Multipoint Target Hue", vis.Colors.MultipointTarget, 0, 360, 1)
		TimMenu.NextLine()

		vis.Colors.Quads = TimMenu.Slider("Quads Hue", vis.Colors.Quads, 0, 360, 1)
		TimMenu.EndSector()
		TimMenu.NextLine()

		-- Thickness settings
		TimMenu.BeginSector("Thickness")
		vis.Thickness.PlayerPath = TimMenu.Slider("Player Path", vis.Thickness.PlayerPath, 0.5, 5, 0.5)
		TimMenu.NextLine()

		vis.Thickness.ProjectilePath = TimMenu.Slider("Projectile Path", vis.Thickness.ProjectilePath, 0.5, 5, 0.5)
		TimMenu.NextLine()

		vis.Thickness.BoundingBox = TimMenu.Slider("Bounding Box", vis.Thickness.BoundingBox, 0.5, 5, 0.5)
		TimMenu.NextLine()

		vis.Thickness.MultipointTarget = TimMenu.Slider("Multipoint Target", vis.Thickness.MultipointTarget, 1, 10, 0.5)
		TimMenu.EndSector()
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
