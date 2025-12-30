-- Imports
local G = require("globals")
local Config = require("config")
local Menu = require("menu")
local Visuals = require("visuals")
local ProjectileInfo = require("projectile_info")
local TickProfiler = require("tick_profiler")
local PlayerTracker = require("player_tracker")
local FastPlayers = require("utils.fast_players")
local StrafePredictor = require("simulation.history.strafe_predictor")
local AimbotManager = require("aimbot.aimbot_manager")
local utils = {
	weapon = require("utils.weapon_utils"),
}

-- ConVars (used for prediction/simulation)
local sv_gravity = client.GetConVar("sv_gravity")
local sv_friction = client.GetConVar("sv_friction")
local sv_stopspeed = client.GetConVar("sv_stopspeed")
local sv_accelerate = client.GetConVar("sv_accelerate")
local sv_airaccelerate = client.GetConVar("sv_airaccelerate")

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

	-- Update core state even if aimbot is disabled (needed for visuals/self-prediction)
	FastPlayers.Update()

	-- Update player histories
	local WishdirTracker = require("simulation.history.wishdir_tracker")
	local players = FastPlayers.GetAll()
	StrafePredictor.cleanupStalePlayers(FastPlayers)
	for _, player in pairs(players) do
		if player:IsAlive() and not player:IsDormant() then
			local velocity = player:EstimateAbsVelocity()
			if velocity and velocity:Length2D() > 10 then
				local relWishdir = WishdirTracker.getRelativeWishdir(player)
				StrafePredictor.recordVelocity(player:GetIndex(), velocity, 10, relWishdir)
			end
		else
			StrafePredictor.clearHistory(player:GetIndex())
		end
	end

	PlayerTracker.UpdatePlayerList()

	-- Store local wishdir for visuals/self-prediction
	local fwd, side = cmd:GetForwardMove(), cmd:GetSideMove()
	local len = math.sqrt(fwd * fwd + side * side)
	if len > 0.1 then
		-- Engine Standard: +fwd is Forward, +side is LEFT (-450 for A, 450 for D?)
		-- Wait, if ComputeMove sin(-90)=-1, then A is -450.
		-- We want Left = +1, so we use -side.
		G.LocalWishdir = Vector3(fwd / len, -side / len, 0)
	else
		G.LocalWishdir = Vector3(0, 0, 0)
	end
	G.LocalWishdirTick = globals.TickCount()

	local cfg = G.Menu.Aimbot
	if not cfg.Enabled then
		TickProfiler.EndSection("CM:Total")
		return
	end

	if not utils.weapon.CanShoot() then
		TickProfiler.EndSection("CM:Total")
		return
	end

	if not ShouldActivateAimbot(cmd) then
		TickProfiler.EndSection("CM:Total")
		return
	end

	-- Delegate to AimbotManager
	local plocal = entities.GetLocalPlayer()
	local weapon = plocal:GetPropEntity("m_hActiveWeapon")
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
