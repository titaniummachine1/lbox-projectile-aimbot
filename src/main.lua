-- Imports
local G = require("globals")
local Config = require("config")
local Menu = require("menu")
local Visuals = require("visuals")
local multipoint = require("targeting.multipoint")
local GetProjectileInfo = require("constants.projectile_info")
local PredictionContext = require("simulation.prediction_context")
local PlayerTick = require("simulation.player_tick")
local SimulateProj = require("projectilesim")
local Latency = require("utils.latency")
local WeaponOffsets = require("constants.weapon_offsets")
local StrafePredictor = require("simulation.history.strafe_predictor")
local TickProfiler = require("tick_profiler")
local PlayerTracker = require("player_tracker")

-- Local constants / utilities -----
local DEFAULT_MAX_DISTANCE = 3000

local utils = {}
utils.math = require("utils.math")
utils.weapon = require("utils.weapon_utils")

-- Fonts
local confidenceFont = draw.CreateFont("Tahoma", 16, 700, FONTFLAG_OUTLINE)

---@class State Current tick aim state (ephemeral)
---@field target Entity?
---@field angle EulerAngles?
---@field charge number
---@field charges boolean
---@field silent boolean
---@field secondaryfire boolean
local state = {
	target = nil,
	angle = nil,
	charge = 0,
	charges = false,
	silent = true,
	secondaryfire = false,
}

-- Activation mode state tracking
local previousKeyState = false
local toggleActive = false

-- Input button flags
local IN_ATTACK = 1
local IN_ATTACK2 = 2048

-- Function to check if activation keybind should activate aimbot logic
-- cmd parameter is optional - only available in CreateMove callback
local function ShouldActivateAimbot(cmd)
	assert(G.Menu, "ShouldActivateAimbot: G.Menu is nil")
	assert(G.Menu.Aimbot, "ShouldActivateAimbot: G.Menu.Aimbot is nil")

	local cfg = G.Menu.Aimbot

	-- Check if attacking from cmd buttons (only in CreateMove where cmd exists)
	if cmd and cfg.OnAttack then
		local buttons = cmd:GetButtons()
		-- Check for IN_ATTACK (primary) or IN_ATTACK2 (secondary like bow charge)
		local isAttacking = (buttons & IN_ATTACK) ~= 0 or (buttons & IN_ATTACK2) ~= 0

		-- If attacking, activate immediately regardless of keybind
		if isAttacking then
			return true
		end
	end

	-- Mode 0: Always - always active, no keybind needed
	if cfg.ActivationMode == 0 then
		return true
	end

	-- For other modes, check keybind
	if cfg.AimKey == 0 then
		return true -- Fallback if no keybind set
	end

	local currentKeyState = input.IsButtonDown(cfg.AimKey)
	local shouldActivate = false

	-- Mode 1: On Hold - only active while holding the key
	if cfg.ActivationMode == 1 then
		shouldActivate = currentKeyState

	-- Mode 2: Toggle - toggle on/off with key press
	elseif cfg.ActivationMode == 2 then
		if currentKeyState and not previousKeyState then
			toggleActive = not toggleActive
		end
		shouldActivate = toggleActive
	end

	previousKeyState = currentKeyState
	return shouldActivate
end

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

---@param localPos Vector3
---@param className string
---@param enemyTeam integer
---@param outTable table
---@param maxDistance number
local function ProcessClass(localPos, className, enemyTeam, outTable, maxDistance)
	local isPlayer = false
	local distanceLimit = maxDistance or DEFAULT_MAX_DISTANCE

	for _, entity in pairs(entities.FindByClass(className)) do
		isPlayer = entity:IsPlayer()
		if
			(isPlayer == true and entity:IsAlive() or (isPlayer == false and entity:GetHealth() > 0))
			and not entity:IsDormant()
			and entity:GetTeamNumber() == enemyTeam
			and not entity:InCond(E_TFCOND.TFCond_Cloaked)
			and (localPos - entity:GetAbsOrigin()):Length() <= distanceLimit
		then
			--print(string.format("Is alive: %s, Health: %d", entity:IsAlive(), entity:GetHealth()))
			outTable[#outTable + 1] = entity
		end
	end
end

---@param tbl Vector3[]
local function DrawPath(tbl)
	if #tbl >= 2 then
		local prev = client.WorldToScreen(tbl[1])
		if prev then
			draw.Color(255, 255, 255, 255)
			for i = 2, #tbl do
				local curr = client.WorldToScreen(tbl[i])
				if curr and prev then
					draw.Line(prev[1], prev[2], curr[1], curr[2])
					prev = curr
				else
					break
				end
			end
		end
	end
end

local function CleanTimeTable(pathtbl, timetbl)
	-- Keep data if counts differ so we don't throw away visuals when timetables
	-- are missing/misaligned; only prune when we have matching timestamps.
	if not pathtbl or not timetbl or #pathtbl < 2 then
		return pathtbl, timetbl
	end
	if #pathtbl ~= #timetbl then
		return pathtbl, timetbl
	end

	local curtime = globals.CurTime()
	local newpath = {}
	local newtime = {}

	for i = 1, #timetbl do
		if timetbl[i] >= curtime then
			newpath[#newpath + 1] = pathtbl[i]
			newtime[#newtime + 1] = timetbl[i]
		end
	end

	-- Return nil if we filtered everything out
	if #newpath == 0 then
		return nil, nil
	end

	return newpath, newtime
end

---@param entity Entity The target entity
---@param projpath Vector3[]? The predicted projectile path
---@param hit boolean? Whether projectile simulation hit the target
---@param distance number Distance to target
---@param speed number Projectile speed
---@param gravity number Gravity modifier
---@param time number Prediction time
---@param maxDistance number
---@return number score Hitchance score from 0-100%
local function CalculateHitchance(entity, projpath, hit, distance, speed, gravity, time, maxDistance)
	local score = 100.0

	local distanceCap = maxDistance or DEFAULT_MAX_DISTANCE
	local distanceFactor = math.min(distance / distanceCap, 1.0)
	score = score - (distanceFactor * 40)

	--- prediction time penalty (longer predictions = less accurate)
	if time > 2.0 then
		score = score - ((time - 2.0) * 15)
	elseif time > 1.0 then
		score = score - ((time - 1.0) * 10)
	end

	--- projectile simulation penalties
	if projpath then
		--- if hit something, penalize the shit out of it
		if not hit then
			score = score - 40
		end

		--- penalty for very long projectile paths (more chance for error)
		if #projpath > 100 then
			score = score - 20
		elseif #projpath > 50 then
			score = score - 10
		end
	else
		--- i dont remember if i ever return nil for projpath
		--- but fuck it we ball
		score = score - 100
	end

	--- gravity penalty (high arc = less accurate (kill me))
	if gravity > 0 then
		--- using 400 or 800 gravity is such a pain
		--- i dont remember anymore why i chose 400 here
		--- but its working fine as far as i know
		--- unless im using 800 graviy
		--- then this is probably giving a shit ton of score
		--- but im so confused and sleep deprived that i dont care
		local gravityFactor = math.min(gravity / 400, 1.0)
		score = score - (gravityFactor * 15)
	end

	--- targed speed penalty
	--- more speed = less confiident we are
	local velocity = entity:EstimateAbsVelocity() or Vector3()
	if velocity then
		local speed2d = velocity:Length2D()
		if speed2d > 300 then
			score = score - 15
		elseif speed2d > 200 then
			score = score - 10
		elseif speed2d > 100 then
			score = score - 5
		end
	end

	--- target class bonus/penalty
	if entity:IsPlayer() then
		local class = entity:GetPropInt("m_iClass")
		--- scouts are harder to hit
		if class == E_Character.TF2_Scout then -- Scout
			score = score - 10
		end

		--- classes easier to hit
		if class == E_Character.TF2_Heavy or class == E_Character.TF2_Sniper then -- Heavy or Sniper
			score = score + 5
		end

		--- penalize air targets
		--- i wrote this shit at 3 am, wtf is this?
		if entity:InCond(E_TFCOND.TFCond_BlastJumping) then
			score = score - 15
		end
	else
		--- buildings dont have feet (at least the ones i know)
		score = score + 15
	end

	--- projectile speed penalty (slow projectiles are harder to hit)
	if speed < 1000 then
		score = score - 10
	elseif speed < 1500 then
		score = score - 5
	end

	--- clamp this
	return math.max(0, math.min(100, score))
end

---Normalizes a vector in place
---@param vec Vector3
---@return number length
local function Normalize(vec)
	local len = vec:Length()
	vec.x = vec.x / len
	vec.y = vec.y / len
	vec.z = vec.z / len
	return len
end

-- Local constants / utilities -----
local origProjValue = gui.GetValue("projectile aimbot")

local function getAimMethod()
	assert(G.Menu, "main: G.Menu is nil")
	assert(G.Menu.Aimbot, "main: G.Menu.Aimbot is nil")

	return G.Menu.Aimbot.AimMethod or "silent +"
end

-- Private helpers -----
local function onDraw()
	-- Zero Trust: Assert external state
	assert(G.Menu, "main: G.Menu is nil")
	assert(G.Menu.Aimbot, "main: G.Menu.Aimbot is nil")

	local cfg = G.Menu.Aimbot
	local vis = G.Menu.Visuals

	-- Update profiler state before any BeginSection calls
	TickProfiler.SetEnabled(vis.ShowProfiler)
	TickProfiler.BeginSection("Draw:Total")

	-- Guard clause: Check if aimbot is enabled
	if not cfg.Enabled then
		if origProjValue ~= nil and gui.GetValue("projectile aimbot") ~= origProjValue then
			gui.SetValue("projectile aimbot", origProjValue)
		end
		TickProfiler.EndSection("Draw:Total")
		return
	end

	-- Disable built-in projectile aimbot
	if gui.GetValue("projectile aimbot") ~= "none" then
		origProjValue = gui.GetValue("projectile aimbot")
		gui.SetValue("projectile aimbot", 0)
	end

	TickProfiler.BeginSection("Draw:GetVisualData")
	-- Get all valid player data for rendering
	local allPlayerData = PlayerTracker.GetAll()

	-- Find best target to visualize (most recent update)
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
	-- Draw advanced visualizations from persistent player data
	if bestData then
		Visuals.draw({
			path = bestData.path,
			projpath = bestData.projpath,
			multipointPos = bestData.multipointPos,
			target = bestData.entity,
		})
	end
	TickProfiler.EndSection("Draw:Visuals")

	TickProfiler.BeginSection("Draw:Confidence")
	-- Draw confidence score from persistent player data
	if vis.ShowConfidence and bestData and bestData.confidence then
		local screenW, screenH = draw.GetScreenSize()
		local text = string.format("Confidence: %.1f%%", bestData.confidence)

		-- Color based on confidence
		local r, g, b = 255, 255, 255
		if bestData.confidence >= 70 then
			r, g, b = 100, 255, 100 -- Green
		elseif bestData.confidence >= 50 then
			r, g, b = 255, 255, 100 -- Yellow
		else
			r, g, b = 255, 100, 100 -- Red
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

---@param cmd UserCmd
local function onCreateMove(cmd)
	TickProfiler.BeginSection("CM:Total")

	-- Zero Trust: Assert config exists
	assert(G.Menu, "main: G.Menu is nil")
	assert(G.Menu.Aimbot, "main: G.Menu.Aimbot is nil")

	--- Reset ephemeral aim state every tick
	state.angle = nil
	state.target = nil
	state.charge = 0
	state.charges = false

	local cfg = G.Menu.Aimbot

	-- Update player list (detect disconnects/joins) and clean stale data
	PlayerTracker.UpdatePlayerList()
	StrafePredictor.cleanupStalePlayers()

	-- Guard clauses
	if not cfg.Enabled then
		TickProfiler.EndSection("CM:Total")
		return
	end

	-- Guard clauses
	local netchannel = clientstate.GetNetChannel()
	if not netchannel then
		TickProfiler.EndSection("CM:Total")
		return
	end

	if clientstate.GetClientSignonState() <= E_SignonState.SIGNONSTATE_SPAWN then
		TickProfiler.EndSection("CM:Total")
		return
	end

	if not utils.weapon.CanShoot() then
		TickProfiler.EndSection("CM:Total")
		return
	end

	-- Pass cmd to check attack button state from command
	if not ShouldActivateAimbot(cmd) then
		TickProfiler.EndSection("CM:Total")
		return
	end

	-- Guard clause: Get local player
	local plocal = entities.GetLocalPlayer()
	if not plocal then
		TickProfiler.EndSection("CM:Total")
		return
	end

	-- Guard clause: Get weapon
	local weapon = plocal:GetPropEntity("m_hActiveWeapon")
	if not weapon then
		TickProfiler.EndSection("CM:Total")
		return
	end

	-- Guard clause: Get projectile info
	local info = GetProjectileInfo(weapon:GetPropInt("m_iItemDefinitionIndex"))
	if not info then
		TickProfiler.EndSection("CM:Total")
		return
	end

	local enemyTeam = plocal:GetTeamNumber() == 2 and 3 or 2
	local localPos = plocal:GetAbsOrigin()

	TickProfiler.BeginSection("CM:EntityScan")
	---@type Entity[]
	local entitylist = {}
	ProcessClass(localPos, "CTFPlayer", enemyTeam, entitylist, cfg.MaxDistance)

	if cfg.AimSentry then
		ProcessClass(localPos, "CObjectSentrygun", enemyTeam, entitylist, cfg.MaxDistance)
	end

	if cfg.AimOtherBuildings then
		ProcessClass(localPos, "CObjectDispenser", enemyTeam, entitylist, cfg.MaxDistance)
		ProcessClass(localPos, "CObjectTeleporter", enemyTeam, entitylist, cfg.MaxDistance)
	end
	TickProfiler.EndSection("CM:EntityScan")

	-- Guard clause: Check if we have targets
	if #entitylist == 0 then
		TickProfiler.EndSection("CM:Total")
		return
	end

	local eyePos = localPos + plocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	local aimEyePos = eyePos
	do
		local outgoingLatency = netchannel:GetLatency(E_Flows.FLOW_OUTGOING) or 0
		local localVel = plocal:EstimateAbsVelocity() or Vector3()
		if outgoingLatency > 0 then
			aimEyePos = eyePos + (localVel * outgoingLatency)
		end
	end
	local viewangle = engine.GetViewAngles()

	local charge = info.m_bCharges and weapon:GetCurrentCharge() or 0.0
	local speed = info:GetVelocity(charge):Length2D()
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravity = sv_gravity * 0.5 * info:GetGravity(charge)
	local weaponID = weapon:GetWeaponID()

	TickProfiler.BeginSection("CM:FOVSort")
	local sortedEntities = {}
	local RAD2DEG = 180 / math.pi
	for _, entity in ipairs(entitylist) do
		local entityCenter = entity:GetAbsOrigin() + (entity:GetMins() + entity:GetMaxs()) * 0.5
		local dirToEntity = (entityCenter - aimEyePos)
		Normalize(dirToEntity)
		local forward = viewangle:Forward()
		local angle = math.acos(forward:Dot(dirToEntity)) * RAD2DEG

		if angle <= cfg.AimFOV then
			table.insert(sortedEntities, {
				entity = entity,
				fov = angle,
			})
		end
	end

	--- sort by fov (lowest to highest)
	table.sort(sortedEntities, function(a, b)
		return a.fov < b.fov
	end)
	TickProfiler.EndSection("CM:FOVSort")

	-- Guard clause: Check if we have targets in FOV
	if #sortedEntities == 0 then
		TickProfiler.EndSection("CM:Total")
		return
	end

	TickProfiler.BeginSection("CM:StrafeRecord")
	-- Fedoraware Optional: Record velocity history for strafe prediction
	-- Update velocity history for all potential targets
	for _, entData in ipairs(sortedEntities) do
		local entity = entData.entity
		if entity:IsPlayer() then
			local velocity = entity:EstimateAbsVelocity()
			if velocity then
				StrafePredictor.recordVelocity(entity:GetIndex(), velocity, 10)
			end
		end
	end
	TickProfiler.EndSection("CM:StrafeRecord")

	TickProfiler.BeginSection("CM:PredictionLoop")
	for _, entData in ipairs(sortedEntities) do
		local entity = entData.entity
		local entityCenter = entity:GetAbsOrigin() + (entity:GetMins() + entity:GetMaxs()) * 0.5
		local distance = (entityCenter - localPos):Length()
		-- Fedoraware Critical #1: Full latency compensation (outgoing + incoming + lerp)
		local time = Latency.getAdjustedPredictionTime(distance, speed)
		local lazyness = cfg.MinAccuracy
			+ (cfg.MaxAccuracy - cfg.MinAccuracy) * (math.min(distance / cfg.MaxDistance, 1.0) ^ 1.5)

		TickProfiler.BeginSection("CM:SimPlayer")
		local simCtx = PredictionContext.createContext()
		assert(simCtx and simCtx.sv_gravity and simCtx.tickinterval, "Main: createContext failed")

		local playerCtx = PredictionContext.createPlayerContext(entity, lazyness)
		assert(playerCtx and playerCtx.origin and playerCtx.velocity, "Main: createPlayerContext failed")

		local path, lastPos, timetable = PlayerTick.simulatePath(playerCtx, simCtx, time)
		TickProfiler.EndSection("CM:SimPlayer")

		-- Zero Trust: Assert SimulatePlayer returns
		assert(path, "Main: SimulatePlayer returned nil path")
		assert(lastPos, "Main: SimulatePlayer returned nil lastPos")
		assert(#path > 0, "Main: SimulatePlayer returned empty path")

		local drop = gravity * time * time

		-- TODO: Deep integration - Apply strafe prediction to each simulation tick
		-- Currently only recording history; deeper integration requires modifying PlayerTick.simulateTick
		-- to accept and use StrafePredictor.predictStrafeDirection per tick

		TickProfiler.BeginSection("CM:Multipoint")
		local multipointHitbox, multipointPos =
			multipoint.Run(entity, weapon, info, aimEyePos, lastPos, drop, speed, gravity)
		TickProfiler.EndSection("CM:Multipoint")

		-- Zero Trust: Assert multipoint returns (multipointPos can be nil, that's ok)
		-- multipointHitbox can be nil if no multipoint selected, that's intentional
		if multipointPos then
			assert(type(multipointPos.x) == "number", "Main: multipointPos has invalid x")
			assert(type(multipointPos.y) == "number", "Main: multipointPos has invalid y")
			assert(type(multipointPos.z) == "number", "Main: multipointPos has invalid z")
			lastPos = multipointPos
			state.multipointPos = multipointPos
		end

		TickProfiler.BeginSection("CM:Ballistics")
		local angle = utils.math.SolveBallisticArc(aimEyePos, lastPos, speed, gravity)
		TickProfiler.EndSection("CM:Ballistics")

		-- Zero Trust: Assert ballistics solution
		-- angle can be nil if no solution exists, skip this target

		if angle then
			--- check visibility
			local isFlipped = weapon:IsViewModelFlipped()

			local weaponDefIndex = weapon:GetPropInt("m_iItemDefinitionIndex")
			assert(weaponDefIndex, "Main: weapon:GetPropInt('m_iItemDefinitionIndex') returned nil")
			local isDucking = (plocal:GetPropInt("m_fFlags") & FL_DUCKING) ~= 0
			local weaponOffset = WeaponOffsets.getOffset(weaponDefIndex, isDucking, isFlipped)

			local function computeFirePos(testAngle)
				if weaponOffset then
					local offsetPos = aimEyePos
						+ (testAngle:Forward() * weaponOffset.x)
						+ (testAngle:Right() * weaponOffset.y)
						+ (testAngle:Up() * weaponOffset.z)
					local resultTrace =
						engine.TraceHull(aimEyePos, offsetPos, -Vector3(8, 8, 8), Vector3(8, 8, 8), MASK_SHOT_HULL)
					if not resultTrace or resultTrace.startsolid then
						return nil
					end
					return resultTrace.endpos
				end

				return info:GetFirePosition(plocal, aimEyePos, testAngle, isFlipped)
			end

			local firePos = computeFirePos(angle)
			assert(firePos, "Main: info:GetFirePosition returned nil")

			local translatedAngle = utils.math.SolveBallisticArc(firePos, lastPos, speed, gravity)
			-- translatedAngle can be nil if no solution, that's expected

			if translatedAngle then
				firePos = computeFirePos(translatedAngle)
				if not firePos then
					translatedAngle = nil
				end
			end

			if translatedAngle then
				local finalAngle = utils.math.SolveBallisticArc(firePos, lastPos, speed, gravity)
				if finalAngle then
					local finalFirePos = computeFirePos(finalAngle)
					if finalFirePos then
						translatedAngle = finalAngle
						firePos = finalFirePos
					end
				end
			end

			if translatedAngle then
				TickProfiler.BeginSection("CM:SimProj")
				local projpath, hit, fullSim, projtimetable =
					SimulateProj(entity, lastPos, firePos, translatedAngle, info, plocal:GetTeamNumber(), time, charge)
				TickProfiler.EndSection("CM:SimProj")

				-- Zero Trust: Assert SimulateProj returns
				assert(projpath, "Main: SimulateProj returned nil projpath")
				assert(type(fullSim) == "boolean", "Main: SimulateProj fullSim must be boolean")
				assert(projtimetable, "Main: SimulateProj returned nil projtimetable")

				if fullSim then
					local distance = (entityCenter - localPos):Length()
					local confidence =
						CalculateHitchance(entity, projpath, hit, distance, speed, gravity, time, cfg.MaxDistance)
					if confidence >= cfg.MinConfidence then
						local secondaryFire = doSecondaryFiretbl[weaponID]
						local noSilent = noSilentTbl[weaponID]

						-- Store ephemeral aim state for this tick
						state.target = entity
						state.angle = translatedAngle
						state.charge = charge
						state.charges = info.m_bCharges
						state.secondaryfire = secondaryFire
						state.silent = not noSilent

						-- Store persistent visual data in player tracker
						PlayerTracker.Update(entity, {
							path = path,
							projpath = projpath,
							timetable = timetable,
							projtimetable = projtimetable,
							multipointPos = multipointPos,
							confidence = confidence,
						})

						-- Found valid target, apply aim
						break
					end
				end
			end
		end
	end
	TickProfiler.EndSection("CM:PredictionLoop")

	-- If no angle calculated, nothing to do
	if not state.angle then
		TickProfiler.EndSection("CM:Total")
		return
	end

	if state.charge > 1.0 then
		state.charge = 0
	end

	if state.charges and state.charge < 0.1 then
		cmd.buttons = cmd.buttons | IN_ATTACK
		TickProfiler.EndSection("CM:Total")
		return
	end

	if state.charges then
		cmd.buttons = cmd.buttons & ~IN_ATTACK
	else
		if state.secondaryfire then
			cmd.buttons = cmd.buttons | IN_ATTACK2
		else
			cmd.buttons = cmd.buttons | IN_ATTACK
		end
	end

	local method = getAimMethod()

	if state.silent and method == "silent +" then
		cmd.sendpacket = false
	end

	if method ~= "silent +" and method ~= "silent" then
		engine.SetViewAngles(state.angle)
	end

	cmd.viewangles = Vector3(state.angle:Unpack())

	TickProfiler.EndSection("CM:Total")
end

local function getKeyName()
	local value = G.Menu.Aimbot.AimKey
	for name, v in pairs(E_ButtonCode) do
		if v == value then
			return name
		end
	end
	return "NONE"
end

-- Self-init (optional) ---
printc(150, 255, 150, 255, "[Projectile Aimbot] Loaded successfully")
printc(100, 200, 255, 255, "[Projectile Aimbot] FOV: " .. G.Menu.Aimbot.AimFOV, "Aim Key: " .. getKeyName())

-- Callbacks -----
callbacks.Register("Draw", "PROJ_AIMBOT_DRAW", onDraw)
callbacks.Register("CreateMove", "PROJ_AIMBOT_CM", onCreateMove)
-- No unload callback - environment handles cleanup automatically
