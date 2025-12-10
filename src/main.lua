-- Imports
local G = require("globals")
local Config = require("config")
local Menu = require("menu")
local Visuals = require("visuals")
local multipoint = require("multipoint")
local GetProjectileInfo = require("projectile_info")
local SimulatePlayer = require("playersim")
local SimulateProj = require("projectilesim")

-- Local constants / utilities -----
local DEFAULT_MAX_DISTANCE = 3000

local utils = {}
utils.math = require("utils.math")
utils.weapon = require("utils.weapon_utils")

---@class State
---@field target Entity?
---@field angle EulerAngles?
---@field path Vector3[]?
---@field storedpath {path: Vector3[]?, projpath: Vector3[]?, projtimetable: number[]?, timetable: number[]?}
---@field charge number
---@field charges boolean
---@field silent boolean
---@field secondaryfire boolean
---@field confidence number?
---@field multipointPos Vector3?
local state = {
	target = nil,
	angle = nil,
	path = nil,
	storedpath = { path = nil, projpath = nil, projtimetable = nil, timetable = nil },
	charge = 0,
	charges = false,
	silent = true,
	secondaryfire = false,
	confidence = nil,
	multipointPos = nil,
}

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
	if not pathtbl or not timetbl or #pathtbl ~= #timetbl or #pathtbl < 2 then
		return nil, nil
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
		if #projpath > 50 then
			score = score - 10
		elseif #projpath > 100 then
			score = score - 20
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
	if len < 0.0001 then
		return 0
	end
	
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

	--- Reset our state table
	state.angle = nil
	state.path = nil
	state.target = nil
	state.charge = 0
	state.charges = false
	state.confidence = nil
	state.multipointPos = nil

	local cfg = G.Menu.Aimbot

	-- Guard clause: Check if aimbot is enabled
	if not cfg.Enabled then
		if origProjValue ~= nil and gui.GetValue("projectile aimbot") ~= origProjValue then
			gui.SetValue("projectile aimbot", origProjValue)
		end
		return
	end

	-- Disable built-in projectile aimbot
	if gui.GetValue("projectile aimbot") ~= "none" then
		origProjValue = gui.GetValue("projectile aimbot")
		gui.SetValue("projectile aimbot", 0)
	end

	-- Guard clauses
	local netchannel = clientstate.GetNetChannel()
	if not netchannel then
		return
	end

	if clientstate.GetClientSignonState() <= E_SignonState.SIGNONSTATE_SPAWN then
		return
	end

	if state.storedpath.path and state.storedpath.timetable then
		local cleanedpath, cleanedtime = CleanTimeTable(state.storedpath.path, state.storedpath.timetable)
		state.storedpath.path = cleanedpath
		state.storedpath.timetable = cleanedtime
	end

	if state.storedpath.projpath and state.storedpath.projtimetable then
		local cleanedprojpath, cleanedprojtime =
			CleanTimeTable(state.storedpath.projpath, state.storedpath.projtimetable)
		state.storedpath.projpath = cleanedprojpath
		state.storedpath.projtimetable = cleanedprojtime
	end

	-- Draw advanced visualizations
	Visuals.draw({
		path = state.storedpath.path,
		projpath = state.storedpath.projpath,
		multipointPos = state.multipointPos,
		target = state.target,
	})

	-- Draw confidence score
	local vis = G.Menu.Visuals
	if vis.ShowConfidence and state.confidence then
		local screenW, screenH = draw.GetScreenSize()
		local text = string.format("Confidence: %.1f%%", state.confidence)
		
		-- Color based on confidence
		local r, g, b = 255, 255, 255
		if state.confidence >= 70 then
			r, g, b = 100, 255, 100  -- Green
		elseif state.confidence >= 50 then
			r, g, b = 255, 255, 100  -- Yellow
		else
			r, g, b = 255, 100, 100  -- Red
		end
		
		draw.Color(r, g, b, 255)
		draw.SetFont(fonts.Create("Tahoma", 16, 700))
		local textW, textH = draw.GetTextSize(text)
		draw.Text(screenW / 2 - textW / 2, screenH / 2 + 30, text)
	end

	-- Guard clause: Check aim key
	if cfg.AimKey ~= 0 and not input.IsButtonDown(cfg.AimKey) then
		return
	end

	-- Guard clause: Check if we can shoot
	if not utils.weapon.CanShoot() then
		return
	end

	-- Guard clause: Get local player
	local plocal = entities.GetLocalPlayer()
	if not plocal then
		return
	end

	-- Guard clause: Get weapon
	local weapon = plocal:GetPropEntity("m_hActiveWeapon")
	if not weapon then
		return
	end

	-- Guard clause: Get projectile info
	local info = GetProjectileInfo(weapon:GetPropInt("m_iItemDefinitionIndex"))
	if not info then
		return
	end

	local enemyTeam = plocal:GetTeamNumber() == 2 and 3 or 2
	local localPos = plocal:GetAbsOrigin()

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

	-- Guard clause: Check if we have targets
	if #entitylist == 0 then
		return
	end

	local eyePos = localPos + plocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	local viewangle = engine.GetViewAngles()

	local charge = info.m_bCharges and weapon:GetCurrentCharge() or 0.0
	local speed = info:GetVelocity(charge):Length2D()
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravity = sv_gravity * 0.5 * info:GetGravity(charge)
	local weaponID = weapon:GetWeaponID()

	local sortedEntities = {}
	local RAD2DEG = 180 / math.pi
	for _, entity in ipairs(entitylist) do
		local entityCenter = entity:GetAbsOrigin() + (entity:GetMins() + entity:GetMaxs()) * 0.5
		local dirToEntity = (entityCenter - eyePos)
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

	-- Guard clause: Check if we have targets in FOV
	if #sortedEntities == 0 then
		return
	end

	for _, entData in ipairs(sortedEntities) do
		local entity = entData.entity
		local distance = (localPos - entity:GetAbsOrigin() + (entity:GetMins() + entity:GetMaxs()) * 0.5):Length()
		local time = (distance / speed) + netchannel:GetLatency(E_Flows.FLOW_INCOMING)
		local lazyness = cfg.MinAccuracy
			+ (cfg.MaxAccuracy - cfg.MinAccuracy) * (math.min(distance / cfg.MaxDistance, 1.0) ^ 1.5)

		local path, lastPos, timetable = SimulatePlayer(entity, time, lazyness)
		local drop = gravity * time * time

		local _, multipointPos = multipoint.Run(entity, weapon, info, eyePos, lastPos, drop)
		if multipointPos then
			lastPos = multipointPos
			state.multipointPos = multipointPos
		end

		local angle = utils.math.SolveBallisticArc(eyePos, lastPos, speed, gravity)
		if angle then
			--- check visibility
			local firePos = info:GetFirePosition(plocal, eyePos, angle, weapon:IsViewModelFlipped())
			local translatedAngle = utils.math.SolveBallisticArc(firePos, lastPos, speed, gravity)

			if translatedAngle then
				local projpath, hit, fullSim, projtimetable =
					SimulateProj(entity, lastPos, firePos, translatedAngle, info, plocal:GetTeamNumber(), time, charge)

				if fullSim then
					local confidence =
						CalculateHitchance(entity, projpath, fullSim, distance, speed, gravity, time, cfg.MaxDistance)
					if confidence >= cfg.MinConfidence then
						local secondaryFire = doSecondaryFiretbl[weaponID]
						local noSilent = noSilentTbl[weaponID]

						state.target = entity
						state.path = path
						state.angle = angle
						state.storedpath.path = path
						state.storedpath.projpath = projpath
						state.storedpath.timetable = timetable
						state.storedpath.projtimetable = projtimetable
						state.charge = charge
						state.charges = info.m_bCharges
						state.secondaryfire = secondaryFire
						state.silent = not noSilent
						state.confidence = confidence
						return
					end
				end
			end
		end
	end

	--- no valid target found
end

---@param cmd UserCmd
local function onCreateMove(cmd)
	-- Zero Trust: Assert config exists
	assert(G.Menu, "main: G.Menu is nil")
	assert(G.Menu.Aimbot, "main: G.Menu.Aimbot is nil")

	local cfg = G.Menu.Aimbot

	-- Guard clauses
	if not cfg.Enabled then
		return
	end
	if not utils.weapon.CanShoot() then
		return
	end
	if cfg.AimKey ~= 0 and not input.IsButtonDown(cfg.AimKey) then
		return
	end
	if not state.angle then
		return
	end

	if state.charge > 1.0 then
		state.charge = 0
	end

	if state.charges and state.charge < 0.1 then
		cmd.buttons = cmd.buttons | IN_ATTACK
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
