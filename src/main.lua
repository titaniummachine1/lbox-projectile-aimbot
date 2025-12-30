-- Imports
local G = require("globals")
local Config = require("config")
local Menu = require("menu")
local Visuals = require("visuals")
local GetProjectileInfo = require("projectile_info")
local TickProfiler = require("tick_profiler")
local PlayerTracker = require("player_tracker")
local FastPlayers = require("utils.fast_players")
local AimbotManager = require("aimbot.aimbot_manager")
local utils = {
	weapon = require("utils.weapon_utils"),
}

-- Fonts
local confidenceFont = draw.CreateFont("Tahoma", 16, 700, FONTFLAG_OUTLINE)

-- Input button flags
local IN_ATTACK = 1
local IN_ATTACK2 = 2048

local toggleActive = false
local previousKeyState = false

-- Function to check if activation keybind should activate aimbot logic
local function ShouldActivateAimbot(cmd)
	local cfg = G.Menu.Aimbot

	if cmd and cfg.OnAttack then
		local buttons = cmd:GetButtons()
		local isAttacking = (buttons & IN_ATTACK) ~= 0 or (buttons & IN_ATTACK2) ~= 0
		if isAttacking then
			return true
		end
	end

	if cfg.ActivationMode == 0 then
		return true
	end
	if cfg.AimKey == 0 then
		return true
	end

	local currentKeyState = input.IsButtonDown(cfg.AimKey)
	local shouldActivate = false

	if cfg.ActivationMode == 1 then
		shouldActivate = currentKeyState
	elseif cfg.ActivationMode == 2 then
		if currentKeyState and not previousKeyState then
			toggleActive = not toggleActive
		end
		shouldActivate = toggleActive
	end

	previousKeyState = currentKeyState
	return shouldActivate
end

local function onDraw()
	local cfg = G.Menu.Aimbot
	local vis = G.Menu.Visuals

	TickProfiler.SetEnabled(vis.ShowProfiler)
	TickProfiler.BeginSection("Draw:Total")

	if not cfg.Enabled then
		TickProfiler.EndSection("Draw:Total")
		return
	end

	TickProfiler.BeginSection("Draw:GetVisualData")
	local allPlayerData = PlayerTracker.GetAll()
	local bestData = nil
	local bestTick = -1
	for _, data in pairs(allPlayerData) do
		if data.lastUpdateTick > bestTick then
			bestData = data
			bestTick = data.lastUpdateTick
		end
	end
	TickProfiler.EndSection("Draw:GetVisualData")

	TickProfiler.BeginSection("Draw:Visuals")
	Visuals.draw(bestData and {
		path = bestData.path,
		projpath = bestData.projpath,
		timetable = bestData.timetable,
		projtimetable = bestData.projtimetable,
		predictedOrigin = bestData.predictedOrigin,
		aimPos = bestData.aimPos,
		multipointPos = bestData.multipointPos,
		lastUpdateTime = bestData.lastUpdateTime,
		target = bestData.entity,
	} or {})
	TickProfiler.EndSection("Draw:Visuals")

	TickProfiler.BeginSection("Draw:Confidence")
	if vis.ShowConfidence and bestData and bestData.confidence then
		local screenW, screenH = draw.GetScreenSize()
		local text = string.format("Confidence: %.1f%%", bestData.confidence)
		local r, g, b = 255, 100, 100
		if bestData.confidence >= 70 then
			r, g, b = 100, 255, 100
		elseif bestData.confidence >= 50 then
			r, g, b = 255, 255, 100
		end

		draw.Color(r, g, b, 255)
		if confidenceFont then
			draw.SetFont(confidenceFont)
		end
		local textW, textH = draw.GetTextSize(text)
		draw.Text(screenW / 2 - textW / 2, screenH / 2 + 30, text)
	end
	TickProfiler.EndSection("Draw:Confidence")

	TickProfiler.EndSection("Draw:Total")
end

local function onCreateMove(cmd)
	TickProfiler.BeginSection("CM:Total")

	local cfg = G.Menu.Aimbot
	if not cfg.Enabled then
		TickProfiler.EndSection("CM:Total")
		return
	end

	FastPlayers.Update()
	PlayerTracker.UpdatePlayerList()

	if not utils.weapon.CanShoot() then
		TickProfiler.EndSection("CM:Total")
		return
	end

	if not ShouldActivateAimbot(cmd) then
		TickProfiler.EndSection("CM:Total")
		return
	end

	local plocal = entities.GetLocalPlayer()
	if not plocal or not plocal:IsAlive() then
		TickProfiler.EndSection("CM:Total")
		return
	end

	local weapon = plocal:GetPropEntity("m_hActiveWeapon")
	if not weapon then
		TickProfiler.EndSection("CM:Total")
		return
	end

	-- Delegate to AimbotManager
	AimbotManager.Run(cmd, plocal, weapon)

	TickProfiler.EndSection("CM:Total")
end

local function onGameEvent(event)
	local eventName = event:GetName()
	if eventName == "player_disconnect" or eventName == "player_connect" or eventName == "player_spawn" then
		FastPlayers.Invalidate()
	end
end

-- Callbacks -----
callbacks.Unregister("Draw", "PROJ_AIMBOT_DRAW")
callbacks.Register("Draw", "PROJ_AIMBOT_DRAW", onDraw)

callbacks.Unregister("CreateMove", "PROJ_AIMBOT_CM")
callbacks.Register("CreateMove", "PROJ_AIMBOT_CM", onCreateMove)

callbacks.Unregister("FireGameEvent", "PROJ_AIMBOT_EVENT")
callbacks.Register("FireGameEvent", "PROJ_AIMBOT_EVENT", onGameEvent)

printc(150, 255, 150, 255, "[Aimbot] Modular system loaded")
