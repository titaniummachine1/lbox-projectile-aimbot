local G = require("globals")
local PredictionContext = require("simulation.prediction_context")
local PlayerTick = require("simulation.player_tick")
local SimulateProj = require("projectilesim")
local Latency = require("utils.latency")
local PlayerTracker = require("player_tracker")
local FastPlayers = require("utils.fast_players")
local WeaponOffsets = require("constants.weapon_offsets")
local StrafePredictor = require("simulation.history.strafe_predictor")
local WishdirTracker = require("simulation.history.wishdir_tracker")
local TickProfiler = require("tick_profiler")
local multipoint = require("targeting.multipoint")
local ViewmodelManager = require("targeting.viewmodel_manager")
local utils = {
	math = require("utils.math"),
	weapon = require("utils.weapon_utils"),
	pool = require("utils.pool"),
}

local ProjectileAimbot = {}

-- Local state
local trackedTargetIndices = {}
local trackedCornerVisible = {}
local autoFlipDecided = false

-- Persistent reuse tables
local entitylist = {}
local candidates = {}
local historyPlayers = {}

-- Constants
local DEFAULT_MAX_DISTANCE = 3000
local IN_ATTACK = 1
local IN_ATTACK2 = 2048
local FL_DUCKING = 2

local noSilentTbl = {
	[E_WeaponBaseID.TF_WEAPON_CLEAVER] = true,
	[E_WeaponBaseID.TF_WEAPON_BAT_WOOD] = true,
	[E_WeaponBaseID.TF_WEAPON_BAT_GIFTWRAP] = true,
	[E_WeaponBaseID.TF_WEAPON_LUNCHBOX] = true,
	[E_WeaponBaseID.TF_WEAPON_JAR] = true,
	[E_WeaponBaseID.TF_WEAPON_JAR_MILK] = true,
	[E_WeaponBaseID.TF_WEAPON_JAR_GAS] = true,
	[E_WeaponBaseID.TF_WEAPON_FLAME_BALL] = true,
}

local doSecondaryFiretbl = {
	[E_WeaponBaseID.TF_WEAPON_BAT_GIFTWRAP] = true,
	[E_WeaponBaseID.TF_WEAPON_LUNCHBOX] = true,
	[E_WeaponBaseID.TF_WEAPON_BAT_WOOD] = true,
}

-- Helpers extracted from main.lua
local function Normalize(vec)
	local len = vec:Length()
	if len == 0 then
		return 0
	end
	vec.x = vec.x / len
	vec.y = vec.y / len
	vec.z = vec.z / len
	return len
end

local function CalculateHitchance(entity, projpath, hit, distance, speed, gravity, time, maxDistance)
	local score = 100.0
	local distanceCap = maxDistance or DEFAULT_MAX_DISTANCE
	local distanceFactor = math.min(distance / distanceCap, 1.0)
	score = score - (distanceFactor * 40)

	if time > 2.0 then
		score = score - ((time - 2.0) * 15)
	elseif time > 1.0 then
		score = score - ((time - 1.0) * 10)
	end

	if projpath then
		if not hit then
			score = score - 40
		end
		if #projpath > 100 then
			score = score - 20
		elseif #projpath > 50 then
			score = score - 10
		end
	else
		score = score - 100
	end

	if gravity > 0 then
		local gravityFactor = math.min(gravity / 400, 1.0)
		score = score - (gravityFactor * 15)
	end

	local velocity = entity:EstimateAbsVelocity() or Vector3()
	if velocity then
		local speed2d = velocity:Length()
		if speed2d > 300 then
			score = score - 15
		elseif speed2d > 200 then
			score = score - 10
		elseif speed2d > 100 then
			score = score - 5
		end
	end

	if entity:IsPlayer() then
		local class = entity:GetPropInt("m_iClass")
		if class == E_Character.TF2_Scout then
			score = score - 10
		end
		if class == E_Character.TF2_Heavy or class == E_Character.TF2_Sniper then
			score = score + 5
		end
		if entity:InCond(E_TFCOND.TFCond_BlastJumping) then
			score = score - 15
		end
	else
		score = score + 15
	end

	if speed < 1000 then
		score = score - 10
	elseif speed < 1500 then
		score = score - 5
	end

	return math.max(0, math.min(100, score))
end

local function traceHitsTarget(plocal, target, endPos)
	if not (target and endPos) then
		return false
	end
	local targetIndex = target:GetIndex()
	local function shouldHitEntity(ent, contentsMask)
		if not ent then
			return false
		end
		local idx = ent:GetIndex()
		if idx == plocal:GetIndex() then
			return false
		end
		if idx == targetIndex then
			return true
		end
		return false
	end
	local trace = engine.TraceLine(
		plocal:GetAbsOrigin() + plocal:GetPropVector("localdata", "m_vecViewOffset[0]"),
		endPos,
		MASK_SHOT,
		shouldHitEntity
	)
	if not trace then
		return false
	end
	if trace.fraction >= 0.999 then
		return true
	end
	local hitEnt = trace.entity
	if hitEnt and hitEnt:GetIndex() == targetIndex then
		return true
	end
	return false
end

local function canSeeAnyCorner(plocal, target)
	local origin = target:GetAbsOrigin()
	local mins, maxs = target:GetMins(), target:GetMaxs()
	if not (mins and maxs) then
		return false
	end
	local worldMins, worldMaxs = origin + mins, origin + maxs
	local corners = {
		Vector3(worldMins.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMins.y, worldMaxs.z),
		Vector3(worldMins.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMins.y, worldMaxs.z),
	}
	for i = 1, 8 do
		if traceHitsTarget(plocal, target, corners[i]) then
			return true
		end
	end
	return false
end

local function canSeeTargetCom(plocal, target)
	local mins, maxs = target:GetMins(), target:GetMaxs()
	if not (mins and maxs) then
		return false
	end
	local comPos = target:GetAbsOrigin() + (mins + maxs) * 0.5
	return traceHitsTarget(plocal, target, comPos)
end

local function insertTopK(top, item, k, better)
	local n = #top
	if k <= 0 then
		return
	end
	if n < k then
		top[n + 1] = item
		local i = n + 1
		while i > 1 and better(top[i], top[i - 1]) do
			top[i], top[i - 1] = top[i - 1], top[i]
			i = i - 1
		end
		return
	end
	if not better(item, top[n]) then
		return
	end
	top[n] = item
	local i = n
	while i > 1 and better(top[i], top[i - 1]) do
		top[i], top[i - 1] = top[i - 1], top[i]
		i = i - 1
	end
end

local function selectTopKQuick(arr, k, better)
	if #arr <= k then
		local out = {}
		for i = 1, #arr do
			out[i] = arr[i]
		end
		table.sort(out, better)
		return out
	end
	-- Fallback for now to simple sort
	table.sort(arr, better)
	local out = {}
	for i = 1, k do
		out[i] = arr[i]
	end
	return out
end

local function ProcessClass(plocal, className, enemyTeam, outTable, maxDistance)
	local localPos = plocal:GetAbsOrigin()
	for _, entity in pairs(entities.FindByClass(className)) do
		local isPlayer = entity:IsPlayer()
		if
			(isPlayer == true and entity:IsAlive() or (isPlayer == false and entity:GetHealth() > 0))
			and not entity:IsDormant()
			and entity:GetTeamNumber() == enemyTeam
			and not entity:InCond(E_TFCOND.TFCond_Cloaked)
			and (localPos - entity:GetAbsOrigin()):Length() <= maxDistance
		then
			outTable[#outTable + 1] = entity
		end
	end
end

function ProjectileAimbot.Run(cmd, plocal, weapon, info)
	TickProfiler.BeginSection("Proj:Run")
	local cfg = G.Menu.Aimbot
	local enemyTeam = plocal:GetTeamNumber() == 2 and 3 or 2
	local localPos = plocal:GetAbsOrigin()
	local maxDistance = cfg.MaxDistance or DEFAULT_MAX_DISTANCE

	-- 1. Scan for targets
	local entitylist = {}
	ProcessClass(plocal, "CTFPlayer", enemyTeam, entitylist, maxDistance)
	if cfg.AimSentry then
		ProcessClass(plocal, "CObjectSentrygun", enemyTeam, entitylist, maxDistance)
	end
	if cfg.AimOtherBuildings then
		ProcessClass(plocal, "CObjectDispenser", enemyTeam, entitylist, maxDistance)
		ProcessClass(plocal, "CObjectTeleporter", enemyTeam, entitylist, maxDistance)
	end

	if #entitylist == 0 then
		TickProfiler.EndSection("Proj:Run")
		return false
	end

	-- 2. Setup aiming parameters
	local eyePos = localPos + plocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	local aimEyePos = eyePos
	local netchannel = clientstate.GetNetChannel()
	if netchannel then
		local outgoingLatency = netchannel:GetLatency(E_Flows.FLOW_OUTGOING) or 0
		local localVel = plocal:EstimateAbsVelocity() or Vector3()
		if outgoingLatency > 0 then
			aimEyePos = eyePos + (localVel * outgoingLatency)
		end
	end

	local charge = info.m_bCharges and weapon:GetCurrentCharge() or 0.0
	local speed = info:GetVelocity(charge):Length2D()
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravityScale = 0
	if info.HasGravity and info:HasGravity() then
		gravityScale = info:GetGravity(charge) or 0
	end
	local gravity = (sv_gravity or 0) * gravityScale * 2

	local hullMins = info.m_vecMins or Vector3(0, 0, 0)
	local hullMaxs = info.m_vecMaxs or Vector3(0, 0, 0)
	local traceMask = info.m_iTraceMask or MASK_SHOT
	local weaponID = weapon:GetWeaponID()
	local viewangle = engine.GetViewAngles()

	-- 3. Targeted Visibility & Sorting
	utils.pool.ReleaseArray(candidates, true)
	candidates = utils.pool.GetTable()

	local RAD2DEG = 180 / math.pi
	local maxFov = cfg.AimFOV or 15

	for _, entity in ipairs(entitylist) do
		local mins, maxs = entity:GetMins(), entity:GetMaxs()
		local origin = entity:GetAbsOrigin()
		local entityCenter = utils.pool.GetVector(
			origin.x + (mins.x + maxs.x) * 0.5,
			origin.y + (mins.y + maxs.y) * 0.5,
			origin.z + (mins.z + maxs.z) * 0.5
		)

		local distance = (entityCenter - localPos):Length()
		local dirToEntity = (entityCenter - aimEyePos)
		Normalize(dirToEntity)
		local forward = viewangle:Forward()
		local angle = math.acos(math.max(-1, math.min(1, forward:Dot(dirToEntity)))) * RAD2DEG

		if angle <= maxFov then
			local fovScore = angle / maxFov
			local distScore = distance / maxDistance
			local cand = utils.pool.GetTable()
			cand.entity = entity
			cand.fov = angle
			cand.dist = distance
			cand.score = (fovScore * 2.0) + distScore
			cand.visible = false
			candidates[#candidates + 1] = cand
		end
		utils.pool.ReleaseVector(entityCenter)
	end

	if #candidates == 0 then
		TickProfiler.EndSection("Proj:Run")
		return false
	end

	local trackedCount = cfg.TrackedTargets or 2
	local topKCount = math.min(#candidates, trackedCount * 2)
	local topK = selectTopKQuick(candidates, topKCount, function(a, b)
		return a.score < b.score
	end)

	-- Visibility pass
	for i, entry in ipairs(topK) do
		local ent = entry.entity
		if ent:IsPlayer() then
			entry.visible = (i <= trackedCount) and canSeeAnyCorner(plocal, ent) or canSeeTargetCom(plocal, ent)
		else
			local center = ent:GetAbsOrigin() + (ent:GetMins() + ent:GetMaxs()) * 0.5
			entry.visible = traceHitsTarget(plocal, ent, center)
		end
		if entry.visible then
			entry.score = entry.score - 10.0
		end
	end
	table.sort(topK, function(a, b)
		return a.score < b.score
	end)

	local bestEntry = nil
	local aimMode = cfg.AimMode or 0
	for _, entry in ipairs(topK) do
		if aimMode == 0 then
			if entry.visible then
				bestEntry = entry
				break
			end
		else
			bestEntry = entry
			break
		end
	end

	if not bestEntry then
		TickProfiler.EndSection("Proj:Run")
		return false
	end

	-- 4. History & Prediction
	local entity = bestEntry.entity
	utils.pool.ReleaseArray(historyPlayers)
	historyPlayers = utils.pool.GetTable()
	for i = 1, math.min(#topK, trackedCount * 2) do
		if topK[i].entity:IsPlayer() then
			historyPlayers[#historyPlayers + 1] = topK[i].entity
		end
	end
	WishdirTracker.updateTop(plocal, historyPlayers, trackedCount * 2)

	-- 5. Prediction Loop (Simplified for now, aiming for parity with main.lua)
	local lerp = Latency.getLerpTime()
	local maxFlightTime = cfg.MaxSimTime or 1.5
	local outgoingLatency = netchannel and netchannel:GetLatency(E_Flows.FLOW_OUTGOING) or 0

	local flightTime = (entity:GetAbsOrigin() - aimEyePos):Length() / speed
	flightTime = math.max(0.0, math.min(maxFlightTime, flightTime))
	local totalTime = outgoingLatency + lerp + flightTime

	-- Simulation context
	local simCtx = PredictionContext.createSimulationContext()
	local relWishDir = WishdirTracker.getRelativeWishdir(entity)
	local playerCtx = PredictionContext.createPlayerContext(entity, relWishDir)

	local path = utils.pool.GetTable()
	path[1] = utils.pool.GetVector(playerCtx.origin:Unpack())
	local timetable = utils.pool.GetTable()
	timetable[1] = simCtx.curtime
	local lastPos = path[1]

	-- Simulate until totalTime
	local targetTotal = math.min(maxFlightTime + outgoingLatency + lerp, totalTime)
	for _ = 1, math.ceil(targetTotal / simCtx.tickinterval) do
		local nextPos = PlayerTick.simulateTick(playerCtx, simCtx)
		lastPos = utils.pool.GetVector(nextPos:Unpack())
		path[#path + 1] = lastPos
		timetable[#timetable + 1] = simCtx.curtime + (#path - 1) * simCtx.tickinterval
	end

	local predictedOrigin = lastPos
	local angle = utils.math.SolveBallisticArc(aimEyePos, predictedOrigin, speed, gravity)

	if not angle then
		TickProfiler.EndSection("Proj:Run")
		return false
	end

	-- 6. Final Simulation & Apply
	local firePos = info:GetFirePosition(plocal, aimEyePos, angle, weapon:IsViewModelFlipped())
	if not firePos then
		TickProfiler.EndSection("Proj:Run")
		return false
	end

	local projpath, hit, fullSim, projtimetable =
		SimulateProj(entity, predictedOrigin, firePos, angle, info, plocal:GetTeamNumber(), flightTime + 0.1, charge)

	if fullSim then
		local confidence = CalculateHitchance(
			entity,
			projpath,
			hit,
			(predictedOrigin - localPos):Length(),
			speed,
			gravity,
			totalTime,
			maxDistance
		)

		-- Update persistent visuals
		PlayerTracker.Update(entity, {
			path = path,
			projpath = projpath,
			timetable = timetable,
			projtimetable = projtimetable,
			predictedOrigin = predictedOrigin,
			aimPos = lastPos,
			shotTime = simCtx.curtime + totalTime,
			confidence = confidence,
			entity = entity,
		})

		if confidence >= cfg.MinConfidence and not cfg.DrawOnly then
			-- Set command angles and buttons
			local aimMethod = cfg.AimMethod or "silent +"
			if aimMethod ~= "silent +" and aimMethod ~= "silent" then
				engine.SetViewAngles(angle)
			end
			if aimMethod == "silent +" then
				cmd.sendpacket = false
			end

			cmd.viewangles = Vector3(angle:Unpack())
			if doSecondaryFiretbl[weaponID] then
				cmd.buttons = cmd.buttons | IN_ATTACK2
			else
				cmd.buttons = cmd.buttons | IN_ATTACK
			end

			TickProfiler.EndSection("Proj:Run")
			return true
		end
	end

	TickProfiler.EndSection("Proj:Run")
	return false
end

return ProjectileAimbot
