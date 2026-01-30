local GameConstants = require("constants.game_constants")
local PlayerTick = require("simulation.Player.player_tick")
local WishdirTracker = require("simulation.Player.history.wishdir_tracker")
local StrafePrediction = require("simulation.Player.strafe_prediction")
local PlayerSimState = require("simulation.Player.player_sim_state")

local consolas = draw.CreateFont("Consolas", 17, 500)

local MAX_PREDICTION_TICKS = 66
local MIN_STRAFE_SAMPLES = 6

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

local function simulatePlayerPath(entity, useStrafePred)
	local predictions = {}

	local playerCtx = PlayerSimState.getOrCreate(entity)
	if not playerCtx then
		return predictions
	end

	local simCtx = PlayerSimState.getSimContext()

	-- Get initial wishdir from tracker (ONCE, never modified during sim)
	local trackedWishdir = WishdirTracker.getWishDir(entity:GetIndex())
	if trackedWishdir then
		playerCtx.relativeWishDir = {
			x = trackedWishdir.x,
			y = trackedWishdir.y,
			z = 0,
		}
	else
		-- Fallback: derive from velocity
		local vel = entity:EstimateAbsVelocity()
		if vel and vel:Length2D() > 50 then
			local yaw = playerCtx.yaw
			local yawRad = yaw * (math.pi / 180)
			local cosYaw = math.cos(yawRad)
			local sinYaw = math.sin(yawRad)

			local forwardMove = vel.x * cosYaw + vel.y * sinYaw
			local sideMove = -vel.x * sinYaw + vel.y * cosYaw

			playerCtx.relativeWishDir = {
				x = forwardMove,
				y = sideMove,
				z = 0,
			}
		else
			playerCtx.relativeWishDir = { x = 0, y = 0, z = 0 }
		end
	end

	-- Setup strafe prediction yaw delta
	local avgYawDelta = 0
	if useStrafePred then
		local maxSpeed = entity:EstimateAbsVelocity():Length2D()
		if maxSpeed < 10 then
			maxSpeed = 320
		end
		avgYawDelta = StrafePrediction.calculateAverageYaw(entity:GetIndex(), maxSpeed, MIN_STRAFE_SAMPLES) or 0
	end
	playerCtx.yawDeltaPerTick = avgYawDelta

	table.insert(predictions, {
		x = playerCtx.origin.x,
		y = playerCtx.origin.y,
		z = playerCtx.origin.z,
		tick = 0,
	})

	for tick = 1, MAX_PREDICTION_TICKS do
		-- simulateTick handles yaw rotation internally via yawDeltaPerTick
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
	local FL_ONGROUND = 1
	local isOnGround = (flags & FL_ONGROUND) ~= 0

	local mode = 0
	if isOnGround then
		mode = 0
	elseif math.abs(velocity.z) > 0.1 then
		mode = 1
	else
		mode = 2
	end

	local simTime = globals.CurTime()
	local maxSpeed = velocity:Length2D()

	StrafePrediction.recordMovement(entity:GetIndex(), origin, velocity, mode, simTime, maxSpeed)
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
		recordMovementHistory(state.targetEntity)
		state.predictions = simulatePlayerPath(state.targetEntity, true)
	else
		state.predictions = {}
	end
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

local selfPredCache = {
	path = nil,
	lastUpdateTime = 0,
}

local function drawPredictionPath()
	local plocal = getLocalPlayer()
	if plocal then
		local now = globals.RealTime()
		if now - selfPredCache.lastUpdateTime > 0.016 then
			local playerCtx = PlayerSimState.getOrCreate(plocal)
			local simCtx = PlayerSimState.getSimContext()
			if playerCtx and simCtx then
				-- Local player: use current velocity as wishdir
				local vel = plocal:EstimateAbsVelocity()
				if vel and vel:Length2D() > 50 then
					local yaw = playerCtx.yaw
					local yawRad = yaw * (math.pi / 180)
					local cosYaw = math.cos(yawRad)
					local sinYaw = math.sin(yawRad)

					local forwardMove = vel.x * cosYaw + vel.y * sinYaw
					local sideMove = -vel.x * sinYaw + vel.y * cosYaw

					playerCtx.relativeWishDir = {
						x = forwardMove,
						y = sideMove,
						z = 0,
					}
				else
					playerCtx.relativeWishDir = { x = 0, y = 0, z = 0 }
				end
				playerCtx.yawDeltaPerTick = 0
				local path = PlayerTick.simulatePath(playerCtx, simCtx, 1.0)
				if path then
					selfPredCache.path = {}
					for i = 1, #path do
						selfPredCache.path[i] = {
							x = path[i].x,
							y = path[i].y,
							z = path[i].z,
						}
					end
				end
				selfPredCache.lastUpdateTime = now
			end
		end

		if selfPredCache.path then
			drawPath(selfPredCache.path, 100, 200, 255, 200, 1)
		end
	end

	if state.targetEntity and state.targetEntity:IsValid() then
		drawPath(state.predictions, 255, 100, 100, 220, 2)
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
