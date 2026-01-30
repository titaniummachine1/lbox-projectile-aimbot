local GameConstants = require("constants.game_constants")
local PlayerTick = require("simulation.Player.player_tick")
local PredictionContext = require("simulation.Player.prediction_context")
local WishdirTracker = require("simulation.Player.history.wishdir_tracker")

local consolas = draw.CreateFont("Consolas", 17, 500)

local TICK_INTERVAL = GameConstants.TICK_INTERVAL
local MAX_PREDICTION_TICKS = 66

local state = {
	enabled = true,
	targetEntity = nil,
	predictions = {},
	lastUpdateTime = 0,
	updateInterval = 0.1,
}

local function getLocalPlayer()
	local ply = entities.GetLocalPlayer()
	if not ply or not ply:IsAlive() then
		return nil
	end
	return ply
end

local function findBestTarget()
	local plocal = getLocalPlayer()
	if not plocal then
		return nil
	end

	local localPos = plocal:GetAbsOrigin()
	if not localPos then
		return nil
	end

	local bestTarget = nil
	local bestDist = math.huge

	local players = entities.FindByClass("CTFPlayer")
	for _, ply in ipairs(players) do
		if ply and ply:IsValid() and ply:IsAlive() and not ply:IsDormant() then
			if ply:GetTeamNumber() ~= plocal:GetTeamNumber() and ply:GetIndex() ~= plocal:GetIndex() then
				local pos = ply:GetAbsOrigin()
				if pos then
					local dist = (pos - localPos):Length()
					if dist < bestDist then
						bestDist = dist
						bestTarget = ply
					end
				end
			end
		end
	end

	return bestTarget
end

local function simulatePlayerPath(entity)
	local predictions = {}

	local playerCtx = PredictionContext.createPlayerContext(entity)
	if not playerCtx then
		return predictions
	end

	local simCtx = {
		tickinterval = TICK_INTERVAL,
		sv_gravity = GameConstants.SV_GRAVITY,
		sv_friction = GameConstants.SV_FRICTION,
		sv_stopspeed = GameConstants.SV_STOPSPEED,
		sv_accelerate = GameConstants.SV_ACCELERATE,
		sv_airaccelerate = GameConstants.SV_AIRACCELERATE,
	}

	local currentPos = {
		x = playerCtx.origin.x,
		y = playerCtx.origin.y,
		z = playerCtx.origin.z,
	}

	table.insert(predictions, {
		x = currentPos.x,
		y = currentPos.y,
		z = currentPos.z,
		tick = 0,
	})

	for tick = 1, MAX_PREDICTION_TICKS do
		PlayerTick.simulateTick(playerCtx, simCtx)

		table.insert(predictions, {
			x = playerCtx.origin.x,
			y = playerCtx.origin.y,
			z = playerCtx.origin.z,
			tick = tick,
		})
	end

	return predictions
end

local function updatePredictions()
	local currentTime = globals.RealTime()
	if currentTime - state.lastUpdateTime < state.updateInterval then
		return
	end
	state.lastUpdateTime = currentTime

	if not state.targetEntity or not state.targetEntity:IsValid() or not state.targetEntity:IsAlive() then
		state.targetEntity = findBestTarget()
	end

	if state.targetEntity then
		WishdirTracker.update(state.targetEntity)
		state.predictions = simulatePlayerPath(state.targetEntity)
	else
		state.predictions = {}
	end
end

local function drawPredictionPath()
	if #state.predictions < 2 then
		return
	end

	for i = 1, #state.predictions - 1 do
		local p1 = state.predictions[i]
		local p2 = state.predictions[i + 1]

		local w2s1 = client.WorldToScreen(Vector3(p1.x, p1.y, p1.z))
		local w2s2 = client.WorldToScreen(Vector3(p2.x, p2.y, p2.z))

		if w2s1 and w2s2 then
			local alpha = math.floor(255 * (1 - (i / #state.predictions)))
			draw.Color(0, 255, 0, alpha)
			draw.Line(w2s1[1], w2s1[2], w2s2[1], w2s2[2])
		end
	end

	local lastPred = state.predictions[#state.predictions]
	local w2sLast = client.WorldToScreen(Vector3(lastPred.x, lastPred.y, lastPred.z))
	if w2sLast then
		draw.Color(255, 0, 0, 255)
		draw.FilledRect(w2sLast[1] - 3, w2sLast[2] - 3, w2sLast[1] + 3, w2sLast[2] + 3)
	end
end

local function onCreateMove()
	if not state.enabled then
		return
	end

	updatePredictions()
end

local function onDraw()
	if not state.enabled then
		return
	end

	drawPredictionPath()

	draw.Color(255, 255, 255, 255)
	draw.SetFont(consolas)
	draw.Text(10, 10, "Player Simulation Test")

	if state.targetEntity and state.targetEntity:IsValid() then
		local info = state.targetEntity:GetName()
		draw.Text(10, 30, "Target: " .. info)
		draw.Text(10, 50, "Predictions: " .. #state.predictions)
	else
		draw.Text(10, 30, "No target")
	end
end

callbacks.Register("CreateMove", "simtest_createmove", onCreateMove)
callbacks.Register("Draw", "simtest_draw", onDraw)

printc(100, 255, 100, 255, "[SimTest] Player simulation test loaded")
