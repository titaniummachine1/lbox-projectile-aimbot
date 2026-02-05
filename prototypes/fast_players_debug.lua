-- fast_players_debug.lua - Standalone debug display for player tracking
-- Modified to use the profiled FastPlayers module

-- Imports
local TickProfiler = require("tick_profiler")
local FastPlayers = require("fast_players")
--dpo nto dare require glbols the yare globaly defined

-- Constants
local BOX_WIDTH = 400
local BOX_HEIGHT = 600
local PADDING = 10
local DISPLAY_MAX_PLAYERS = 50

-- State
local lastMemoryCheck = 0
local memoryUsageKb = 0
local debugFont = draw.CreateFont("Verdana", 14, 400)

-- ENABLE PROFILER
TickProfiler.SetEnabled(true)

-- Rendering Helpers -----

local function drawPlayerListItem(x, y, player, index, isLocal)
	local team = player:GetTeamNumber() or 0
	local name = player:GetName() or "Unknown"
	local health = player:GetHealth() or 0

	if isLocal then
		draw.Color(0, 255, 0, 255)
	elseif team == 2 then
		draw.Color(255, 100, 100, 255)
	elseif team == 3 then
		draw.Color(100, 100, 255, 255)
	else
		draw.Color(200, 200, 200, 255)
	end

	draw.Text(x + 20, y, string.format("[%d] %s (HP:%d, T:%d)", index, name, health, team))
end

local function drawDebugInfo()
	TickProfiler.BeginSection("Debug:Total")

	-- 1. USE FAST PLAYERS MODULE
	FastPlayers.Update()
	local allPlayers = FastPlayers.GetAll()
	local enemies = FastPlayers.GetEnemies() -- Trigger profiling for Enemies
	local teammates = FastPlayers.GetTeammates() -- Trigger profiling for Teammates

	local localPlayer = FastPlayers.GetLocal()
	local localIdx = localPlayer and localPlayer:GetIndex() or -1

	-- Memory periodic check
	local currentTick = globals.TickCount()
	if currentTick - lastMemoryCheck >= 60 then
		memoryUsageKb = collectgarbage("count")
		lastMemoryCheck = currentTick
	end

	-- Positioning
	local _, screenH = draw.GetScreenSize()
	local x = 10
	local y = screenH - BOX_HEIGHT - 50

	-- Rendering Chain
	draw.SetFont(debugFont)

	-- Draw BG
	draw.Color(0, 0, 0, 180)
	draw.FilledRect(x, y, x + BOX_WIDTH, y + BOX_HEIGHT)
	draw.Color(255, 255, 255, 255)
	draw.OutlinedRect(x, y, x + BOX_WIDTH, y + BOX_HEIGHT)

	-- Draw Header & Stats
	draw.Color(0, 255, 0, 255)
	draw.Text(x + PADDING, y + PADDING, "Standalone Player Debug Monitor")

	-- Count active and iterate through all players sequentially
	local activeCount = 0
	for i = 1, 64 do
		if allPlayers[i] then
			activeCount = activeCount + 1
		end
	end

	draw.Color(255, 255, 255, 255)
	draw.Text(x + PADDING, y + 35, string.format("All Players: %d", activeCount))

	if localPlayer and localPlayer:IsValid() then
		draw.Color(100, 200, 255, 255)
		draw.Text(
			x + PADDING,
			y + 75,
			string.format(
				"Local Player: %s (Team: %d)",
				localPlayer:GetName() or "Unknown",
				localPlayer:GetTeamNumber() or 0
			)
		)
	else
		draw.Color(255, 100, 100, 255)
		draw.Text(x + PADDING, y + 75, "Local Player: Invalid")
	end

	draw.Text(x + PADDING, y + 100, string.format("Memory: %.2f KB", memoryUsageKb))
	draw.Text(x + PADDING, y + 120, string.format("Tick: %d", currentTick))

	-- Draw Player List
	draw.Color(0, 255, 255, 255)
	draw.Text(x + PADDING, y + 165, "Player List (FastPlayers Module - Sorted by Distance):")

	-- Sort players by distance to local player
	local localPlayer = FastPlayers.GetLocal()
	local localOrigin
	if localPlayer and localPlayer:IsValid() then
		localOrigin = localPlayer:GetAbsOrigin()
	else
		localOrigin = { x = 0, y = 0, z = 0 }
	end
	local sortedPlayers = {}

	for i = 1, globals.MaxClients() do
		local player = allPlayers[i]
		if not player then
			break
		end

		local origin = player:GetAbsOrigin()
		if not origin or not localOrigin then
			-- Skip players with invalid positions
		else
			local distance = (origin - localOrigin):Length()

			sortedPlayers[#sortedPlayers + 1] = {
				entity = player,
				distance = distance,
			}
		end
	end

	-- Sort by distance
	table.sort(sortedPlayers, function(a, b)
		return a.distance < b.distance
	end)

	local currentY = y + 185
	local drawnCount = 0

	for i = 1, #sortedPlayers do
		local playerData = sortedPlayers[i]
		local player = playerData.entity

		if drawnCount < DISPLAY_MAX_PLAYERS then
			drawPlayerListItem(x, currentY, player, player:GetIndex(), player:GetIndex() == localIdx)
			-- Add distance info
			draw.Color(255, 255, 100, 255)
			draw.Text(x + 250, currentY, string.format("%.1f units", playerData.distance))
			currentY = currentY + 15
			drawnCount = drawnCount + 1
		else
			draw.Color(255, 255, 255, 255)
			draw.Text(x + 20, currentY, string.format("... and %d more players", #sortedPlayers - DISPLAY_MAX_PLAYERS))
			break
		end
	end

	TickProfiler.EndSection("Debug:Total")
end

-- Callbacks
callbacks.Unregister("Draw", "Standalone_Player_Debug")
callbacks.Register("Draw", "Standalone_Player_Debug", drawDebugInfo)

callbacks.Register("Unload", function()
	package.loaded["tick_profiler"] = nil
	package.loaded["fast_players"] = nil
	print("[Standalone Debug] Unloaded and dependencies cleared from cache.")
end)

print("[Standalone Debug] Initialized with Profiled FastPlayers Module.")
