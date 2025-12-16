-- Imports
local GameConstants = require("constants.game_constants")

-- Module declaration
local PlayerTick = {}

-- Private helpers -----

---@param velocity Vector3
---@param wishdir Vector3
---@param wishspeed number
---@param accel number
---@param frametime number
local function accelerate(velocity, wishdir, wishspeed, accel, frametime)
	local currentspeed = velocity:Dot(wishdir)
	local addspeed = wishspeed - currentspeed

	if addspeed <= 0 then
		return
	end

	local accelspeed = accel * frametime * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end

	velocity.x = velocity.x + wishdir.x * accelspeed
	velocity.y = velocity.y + wishdir.y * accelspeed
	velocity.z = velocity.z + wishdir.z * accelspeed
end

---@param target Entity
---@return number
local function getAirSpeedCap(target)
	local m_hGrapplingHookTarget = target:GetPropEntity("m_hGrapplingHookTarget")
	if m_hGrapplingHookTarget then
		if target:GetCarryingRuneType() == GameConstants.RuneTypes.RUNE_AGILITY then
			local m_iClass = target:GetPropInt("m_iClass")
			return (m_iClass == E_Character.TF2_Soldier or m_iClass == E_Character.TF2_Heavy) and 850 or 950
		end
		local _, tf_grapplinghook_move_speed = client.GetConVar("tf_grapplinghook_move_speed")
		return tf_grapplinghook_move_speed
	elseif target:InCond(E_TFCOND.TFCond_Charging) then
		local _, tf_max_charge_speed = client.GetConVar("tf_max_charge_speed")
		return tf_max_charge_speed
	else
		local flCap = 30.0
		if target:InCond(E_TFCOND.TFCond_ParachuteDeployed) then
			local _, tf_parachute_aircontrol = client.GetConVar("tf_parachute_aircontrol")
			flCap = flCap * tf_parachute_aircontrol
		end
		if target:InCond(E_TFCOND.TFCond_HalloweenKart) then
			if target:InCond(E_TFCOND.TFCond_HalloweenKartDash) then
				local _, tf_halloween_kart_dash_speed = client.GetConVar("tf_halloween_kart_dash_speed")
				return tf_halloween_kart_dash_speed
			end
			local _, tf_halloween_kart_aircontrol = client.GetConVar("tf_halloween_kart_aircontrol")
			flCap = flCap * tf_halloween_kart_aircontrol
		end
		return flCap * target:AttributeHookFloat("mod_air_control")
	end
end

---@param v Vector3 Velocity
---@param wishdir Vector3
---@param wishspeed number
---@param accel number
---@param dt number globals.TickInterval()
---@param surf number Is currently surfing?
---@param target Entity
local function airAccelerate(v, wishdir, wishspeed, accel, dt, surf, target)
	wishspeed = math.min(wishspeed, getAirSpeedCap(target))
	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end

	local accelspeed = math.min(accel * wishspeed * dt * surf, addspeed)
	v.x = v.x + accelspeed * wishdir.x
	v.y = v.y + accelspeed * wishdir.y
	v.z = v.z + accelspeed * wishdir.z
end

local function checkIsOnGround(origin, mins, maxs, index)
	local down = Vector3(origin.x, origin.y, origin.z - 18)
	local trace = engine.TraceHull(origin, down, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent, contentsMask)
		return ent:GetIndex() ~= index
	end)

	return trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
end

local function stayOnGround(origin, mins, maxs, step_size, index)
	local vstart = Vector3(origin.x, origin.y, origin.z + 2)
	local vend = Vector3(origin.x, origin.y, origin.z - step_size)

	local trace = engine.TraceHull(vstart, vend, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent, contentsMask)
		return ent:GetIndex() ~= index
	end)

	if trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7 then
		local delta = math.abs(origin.z - trace.endpos.z)
		if delta > 0.5 then
			origin.x = trace.endpos.x
			origin.y = trace.endpos.y
			origin.z = trace.endpos.z
			return true
		end
	end

	return false
end

---@param velocity Vector3
---@param is_on_ground boolean
---@param frametime number
---@param sv_friction number
---@param sv_stopspeed number
local function friction(velocity, is_on_ground, frametime, sv_friction, sv_stopspeed)
	local speed = velocity:Length()
	if speed < 0.01 then
		return
	end

	local drop = 0

	if is_on_ground then
		local friction_val = sv_friction
		local control = speed < sv_stopspeed and sv_stopspeed or speed
		drop = drop + control * friction_val * frametime
	end

	local newspeed = speed - drop
	if newspeed < 0 then
		newspeed = 0
	end
	if newspeed ~= speed then
		newspeed = newspeed / speed
		velocity.x = velocity.x * newspeed
		velocity.y = velocity.y * newspeed
		velocity.z = velocity.z * newspeed
	end
end

local function clipVelocity(velocity, normal, overbounce)
	local backoff = velocity:Dot(normal) * overbounce

	velocity.x = velocity.x - normal.x * backoff
	velocity.y = velocity.y - normal.y * backoff
	velocity.z = velocity.z - normal.z * backoff

	if math.abs(velocity.x) < 0.01 then
		velocity.x = 0
	end
	if math.abs(velocity.y) < 0.01 then
		velocity.y = 0
	end
	if math.abs(velocity.z) < 0.01 then
		velocity.z = 0
	end
end

local function tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)
	local time_left = tickinterval
	local planes = {}
	local numplanes = 0

	for bumpcount = 0, 3 do
		if time_left <= 0 then
			break
		end

		local end_pos = Vector3(
			origin.x + velocity.x * time_left,
			origin.y + velocity.y * time_left,
			origin.z + velocity.z * time_left
		)

		local trace = engine.TraceHull(
			origin,
			end_pos,
			mins,
			maxs,
			GameConstants.MASK_PLAYERSOLID,
			function(ent, contentsMask)
				return ent:GetIndex() ~= index
			end
		)

		if trace.fraction > 0 then
			origin.x = trace.endpos.x
			origin.y = trace.endpos.y
			origin.z = trace.endpos.z
			numplanes = 0
		end

		if trace.fraction == 1 then
			break
		end

		time_left = time_left - time_left * trace.fraction

		if trace.plane and numplanes < GameConstants.DEFAULT_MAX_CLIP_PLANES then
			planes[numplanes] = trace.plane
			numplanes = numplanes + 1
		end

		if trace.plane then
			if trace.plane.z > 0.7 and velocity.z < 0 then
				velocity.z = 0
			end

			local i = 0
			while i < numplanes do
				clipVelocity(velocity, planes[i], 1.0)

				local j = 0
				while j < numplanes do
					if j ~= i then
						local dot = velocity:Dot(planes[j])
						if dot < 0 then
							break
						end
					end
					j = j + 1
				end

				if j == numplanes then
					break
				end

				i = i + 1
			end

			if i == numplanes then
				if numplanes >= 2 then
					local dir = Vector3(
						planes[0].y * planes[1].z - planes[0].z * planes[1].y,
						planes[0].z * planes[1].x - planes[0].x * planes[1].z,
						planes[0].x * planes[1].y - planes[0].y * planes[1].x
					)

					local d = dir:Dot(velocity)
					velocity.x = dir.x * d
					velocity.y = dir.y * d
					velocity.z = dir.z * d
				end

				local dot = velocity:Dot(planes[0])
				if dot < 0 then
					velocity.x = 0
					velocity.y = 0
					velocity.z = 0
					break
				end
			end
		else
			break
		end
	end

	return origin
end

-- Public API ----

---Simulates a single tick of player movement
---@param playerCtx PlayerContext
---@param simCtx SimulationContext
---@return Vector3 newOrigin
function PlayerTick.simulateTick(playerCtx, simCtx)
	assert(playerCtx, "PlayerTick: playerCtx is nil")
	assert(simCtx, "PlayerTick: simCtx is nil")
	assert(
		playerCtx.velocity and playerCtx.origin and playerCtx.mins and playerCtx.maxs,
		"PlayerTick: invalid playerCtx"
	)
	assert(playerCtx.entity and playerCtx.index and playerCtx.maxspeed, "PlayerTick: invalid playerCtx")
	assert(simCtx.tickinterval and simCtx.sv_gravity, "PlayerTick: invalid simCtx")
	assert(
		simCtx.sv_friction and simCtx.sv_stopspeed and simCtx.sv_accelerate and simCtx.sv_airaccelerate,
		"PlayerTick: invalid simCtx"
	)

	local tickinterval = simCtx.tickinterval
	local rawWishdir = Vector3(0, 0, 0)
	local horizLen = playerCtx.velocity:Length2D()
	if horizLen > 0.001 then
		rawWishdir = Vector3(playerCtx.velocity.x / horizLen, playerCtx.velocity.y / horizLen, 0)
	end

	local is_on_ground = checkIsOnGround(playerCtx.origin, playerCtx.mins, playerCtx.maxs, playerCtx.index)
	local wishdir = rawWishdir
	if is_on_ground then
		if horizLen > 0.001 then
			playerCtx.wishdir = rawWishdir
		else
			playerCtx.wishdir = Vector3(0, 0, 0)
		end
	else
		local cachedWishdir = playerCtx.wishdir
		if cachedWishdir and cachedWishdir:Length2D() > 0.001 then
			wishdir = cachedWishdir
		elseif horizLen > 0.001 then
			playerCtx.wishdir = rawWishdir
		end
	end

	friction(playerCtx.velocity, is_on_ground, tickinterval, simCtx.sv_friction, simCtx.sv_stopspeed)

	if is_on_ground then
		accelerate(playerCtx.velocity, wishdir, playerCtx.maxspeed, simCtx.sv_accelerate, tickinterval)
		playerCtx.velocity.z = 0
	else
		airAccelerate(
			playerCtx.velocity,
			wishdir,
			playerCtx.maxspeed,
			simCtx.sv_airaccelerate,
			tickinterval,
			1,
			playerCtx.entity
		)
		playerCtx.velocity.z = playerCtx.velocity.z - simCtx.sv_gravity * tickinterval
	end

	playerCtx.origin = tryPlayerMove(
		playerCtx.origin,
		playerCtx.velocity,
		playerCtx.mins,
		playerCtx.maxs,
		playerCtx.index,
		tickinterval
	)

	if is_on_ground then
		stayOnGround(playerCtx.origin, playerCtx.mins, playerCtx.maxs, playerCtx.stepheight, playerCtx.index)
	end

	return Vector3(playerCtx.origin:Unpack())
end

---Simulates multiple ticks and returns path
---@param playerCtx PlayerContext
---@param simCtx SimulationContext
---@param time_seconds number
---@return Vector3[], Vector3, number[]
function PlayerTick.simulatePath(playerCtx, simCtx, time_seconds)
	assert(playerCtx, "PlayerTick: playerCtx is nil")
	assert(simCtx, "PlayerTick: simCtx is nil")
	assert(time_seconds, "PlayerTick: time_seconds is nil")

	local path = {}
	local timetable = {}
	local clock = 0.0
	local tickinterval = simCtx.tickinterval
	local skip = math.max(1, math.floor(playerCtx.lazyness or 1))
	local tickCount = 0
	local lastOrigin = nil

	-- Early exit for stationary targets
	if playerCtx.velocity:Length() <= 0.01 then
		path[1] = Vector3(playerCtx.origin:Unpack())
		return path, path[1], { simCtx.curtime }
	end

	path[1] = Vector3(playerCtx.origin:Unpack())
	timetable[1] = simCtx.curtime
	lastOrigin = path[1]

	while clock < time_seconds do
		local newOrigin = PlayerTick.simulateTick(playerCtx, simCtx)
		lastOrigin = newOrigin
		tickCount = tickCount + 1
		clock = clock + tickinterval
		if (tickCount % skip) == 0 then
			path[#path + 1] = newOrigin
			timetable[#timetable + 1] = simCtx.curtime + clock
		end
	end

	if not lastOrigin then
		lastOrigin = Vector3(playerCtx.origin:Unpack())
	end

	return path, lastOrigin, timetable
end

return PlayerTick
