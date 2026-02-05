local GameConstants = require("constants.game_constants")
local MovementSim = require("simulation.Player.movement_sim")
local WishdirEstimator = require("simulation.Player.wishdir_estimator")
local StrafePrediction = require("simulation.Player.strafe_prediction")
local StrafeRotation = require("simulation.Player.strafe_rotation")
local PlayerSimState = require("simulation.Player.player_sim_state")
local WishdirDebug = require("simulation.Player.wishdir_debug")

local consolas = draw.CreateFont("Consolas", 17, 500)

local MAX_PREDICTION_TICKS = 66
local MIN_STRAFE_SAMPLES = 6

local state = {
	enabled = true,
	showWishdirDebug = true,
	predictions = {},
	lastUpdateTime = 0,
	updateInterval = 0.1,
	wishdirDebugResults = nil,
}

local function getLocalPlayer()
	local ply = entities.GetLocalPlayer()
	if not ply or not ply:IsAlive() then
		return nil
	end
	return ply
end

local function simulatePlayerPath(entity, useStrafePred)
	local predictions = {}

	local playerState = PlayerSimState.getOrCreate(entity)
	if not playerState then
		return predictions
	end

	local sim = PlayerSimState.getSimContext()

	local vel = entity:EstimateAbsVelocity()
	if vel then
		local estimatedWishdir = WishdirEstimator.estimateFromVelocity(vel, playerState.yaw)
		playerState.relativeWishDir = estimatedWishdir
	else
		playerState.relativeWishDir = { x = 0, y = 0, z = 0 }
	end

	local avgYawDelta = 0
	if useStrafePred then
		local maxSpeed = vel and vel:Length2D() or 320
		if maxSpeed < 10 then
			maxSpeed = 320
		end
		avgYawDelta = StrafePrediction.calculateAverageYaw(entity:GetIndex(), maxSpeed, MIN_STRAFE_SAMPLES) or 0
	end
	playerState.yawDeltaPerTick = avgYawDelta

	if avgYawDelta and math.abs(avgYawDelta) > 0.001 then
		StrafeRotation.initState(entity:GetIndex(), playerState.yaw, avgYawDelta)
	end

	table.insert(
		predictions,
		{ x = playerState.origin.x, y = playerState.origin.y, z = playerState.origin.z, tick = 0 }
	)

	for tick = 1, MAX_PREDICTION_TICKS do
		MovementSim.simulateTick(playerState, sim)
		table.insert(
			predictions,
			{ x = playerState.origin.x, y = playerState.origin.y, z = playerState.origin.z, tick = tick }
		)
	end

	return predictions
end

local function recordMovementHistory(entity)
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return
	end
	local origin = entity:GetAbsOrigin()
	local velocity = entity:EstimateAbsVelocity()
	if not origin or not velocity then
		return
	end
	local flags = entity:GetPropInt("m_fFlags") or 0
	local isOnGround = (flags & GameConstants.FL_ONGROUND) ~= 0
	local mode = isOnGround and 0 or 1
	StrafePrediction.recordMovement(entity:GetIndex(), origin, velocity, mode, globals.CurTime(), velocity:Length2D())
end

local function updatePredictions()
	local currentTime = globals.RealTime()
	if currentTime - state.lastUpdateTime < state.updateInterval then
		return
	end
	state.lastUpdateTime = currentTime

	local plocal = getLocalPlayer()
	if plocal then
		recordMovementHistory(plocal)
		state.predictions = simulatePlayerPath(plocal, true)
	else
		state.predictions = {}
	end
end

local function update9DirectionDebug(entity)
	if not state.showWishdirDebug or not entity then
		return
	end
	local playerState = PlayerSimState.getOrCreate(entity)
	local sim = PlayerSimState.getSimContext()
	if not playerState or not sim then
		return
	end
	-- Use new update function: finds best match from last tick, sims 9 new, stores for next tick
	state.wishdirDebugResults = WishdirDebug.update(entity, playerState, sim)
end

local function drawPath(path, r, g, b, a, thickness)
	if not path or #path < 2 then
		return
	end
	thickness = thickness or 2
	local step = math.max(1, math.floor(#path / 50))
	for i = 1, #path - step, step do
		local p1 = path[i]
		local p2 = path[math.min(i + step, #path)]
		local w2s1 = client.WorldToScreen(Vector3(p1.x, p1.y, p1.z))
		local w2s2 = client.WorldToScreen(Vector3(p2.x, p2.y, p2.z))
		if w2s1 and w2s2 then
			local progress = i / #path
			local alpha = math.floor(a * (1 - progress * 0.5))
			draw.Color(r, g, b, alpha)
			for offset = -thickness, thickness do
				draw.Line(w2s1[1] + offset, w2s1[2], w2s2[1] + offset, w2s2[2])
				draw.Line(w2s1[1], w2s1[2] + offset, w2s2[1], w2s2[2] + offset)
			end
		end
	end
	local lastPred = path[#path]
	local w2sLast = client.WorldToScreen(Vector3(lastPred.x, lastPred.y, lastPred.z))
	if w2sLast then
		draw.Color(r, g, b, a)
		local size = 4
		draw.FilledRect(w2sLast[1] - size, w2sLast[2] - size, w2sLast[1] + size, w2sLast[2] + size)
		draw.Color(0, 0, 0, a)
		draw.OutlinedRect(w2sLast[1] - size, w2sLast[2] - size, w2sLast[1] + size, w2sLast[2] + size)
	end
end

local function onCreateMove()
	if not state.enabled then
		return
	end
	updatePredictions()
	local plocal = getLocalPlayer()
	if plocal then
		update9DirectionDebug(plocal)
	end
end

local function onDraw()
	if not state.enabled then
		return
	end
	if state.predictions and #state.predictions > 0 then
		drawPath(state.predictions, 100, 200, 255, 200, 2)
	end
	local plocal = getLocalPlayer()
	if state.showWishdirDebug and plocal and state.wishdirDebugResults then
		local sim = PlayerSimState.getSimContext()
		if sim then
			WishdirDebug.draw9Directions(plocal, state.wishdirDebugResults, sim.tickinterval)
		end
	end
	draw.Color(255, 255, 255, 255)
	draw.SetFont(consolas)
	draw.Text(10, 10, "SimTest - Local Player Only")
	plocal = getLocalPlayer()
	if plocal then
		draw.Text(10, 30, "Predictions: " .. #state.predictions)
		if state.showWishdirDebug then
			draw.Text(10, 50, "9-Dir Debug: ON")
		end
	else
		draw.Text(10, 30, "No local player")
	end
end

callbacks.Register("CreateMove", "simtest_createmove", onCreateMove)
callbacks.Register("Draw", "simtest_draw", onDraw)
printc(100, 255, 100, 255, "[SimTest] Local player simulation loaded")
