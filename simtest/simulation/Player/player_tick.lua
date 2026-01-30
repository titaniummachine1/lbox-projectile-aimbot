local GameConstants = require("constants.game_constants")

---@class PlayerTick
local PlayerTick = {}

---@class Vector3
---@field x number
---@field y number
---@field z number
---@field Dot fun(self: Vector3, other: Vector3): number
---@field Length fun(self: Vector3): number
---@field LengthSqr fun(self: Vector3): number
---@field Unpack fun(self: Vector3): number, number, number
---@field Normalized fun(self: Vector3): Vector3
---@field Angles fun(self: Vector3): EulerAngles

---@class EulerAngles
---@field x number
---@field y number
---@field z number
---@field Forward fun(self: EulerAngles): Vector3

-- ============================================================================
-- SECTION 0: WATER DETECTION
-- ============================================================================

---Get water level at a position
---@param origin Vector3 Player position
---@param mins Vector3 Player bbox mins
---@param maxs Vector3 Player bbox maxs
---@param viewOffset Vector3 View offset
---@return number Water level
local function getWaterLevel(origin, mins, maxs, viewOffset)
	local point = Vector3(origin.x + (mins.x + maxs.x) * 0.5, origin.y + (mins.y + maxs.y) * 0.5, origin.z + mins.z + 1)

	local cont = engine.GetPointContents(point, 0)
	if not cont or (cont & GameConstants.MASK_WATER) == 0 then
		return GameConstants.WaterLevel.NotInWater
	end

	point.z = origin.z + (mins.z + maxs.z) * 0.5
	cont = engine.GetPointContents(point, 1)
	if (cont & GameConstants.MASK_WATER) == 0 then
		return GameConstants.WaterLevel.Feet
	end

	point.z = origin.z + (viewOffset and viewOffset.z or 64)
	cont = engine.GetPointContents(point, 2)
	if (cont & GameConstants.MASK_WATER) == 0 then
		return GameConstants.WaterLevel.Waist
	end

	return GameConstants.WaterLevel.Eyes
end

PlayerTick.getWaterLevel = getWaterLevel

-- ============================================================================
-- SECTION 0.5: UTILITIES
-- ============================================================================

---Normalize a 2D vector in-place, returns original length
---@param vec Vector3
---@return number Original 2D length
local function normalize2DInPlace(vec)
	local len = math.sqrt(vec.x * vec.x + vec.y * vec.y)
	if len <= 0.0001 then
		vec.x, vec.y, vec.z = 0, 0, 0
		return 0
	end
	vec.x = vec.x / len
	vec.y = vec.y / len
	vec.z = 0
	return len
end

---Get 2D length of a vector
---@param vec Vector3
---@return number 2D length
local function length2D(vec)
	return math.sqrt(vec.x * vec.x + vec.y * vec.y)
end

---Rotate a 2D direction vector by angle in degrees
---@param dir Vector3
---@param angleDeg number
local function rotateDirByAngle(dir, angleDeg)
	local currentAngle = math.atan(dir.y, dir.x) * GameConstants.RAD2DEG
	local newAngle = (currentAngle + angleDeg) * GameConstants.DEG2RAD
	dir.x = math.cos(newAngle)
	dir.y = math.sin(newAngle)
	dir.z = 0
end

---Get yaw angle from direction vector
---@param dir Vector3
---@return number Yaw in degrees
local function dirToYaw(dir)
	return math.atan(dir.y, dir.x) * GameConstants.RAD2DEG
end

---Get direction vector from yaw angle
---@param yaw number
---@return Vector3
local function yawToDir(yaw)
	local rad = yaw * GameConstants.DEG2RAD
	return Vector3(math.cos(rad), math.sin(rad), 0)
end

PlayerTick.normalize2DInPlace = normalize2DInPlace
PlayerTick.length2D = length2D
PlayerTick.rotateDirByAngle = rotateDirByAngle
PlayerTick.dirToYaw = dirToYaw
PlayerTick.yawToDir = yawToDir

local function relativeToWorldWishDir(relWishDir, yaw)
	local yawRad = yaw * GameConstants.DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	-- Source: Forward = [cos, sin], Left = [-sin, cos]
	-- world_wishdir = world_forward * relX + world_left * relY
	local worldX = cosYaw * relWishDir.x - sinYaw * relWishDir.y
	local worldY = sinYaw * relWishDir.x + cosYaw * relWishDir.y

	local len = math.sqrt(worldX * worldX + worldY * worldY)
	if len > 0.001 then
		return Vector3(worldX / len, worldY / len, 0)
	end
	return Vector3(0, 0, 0)
end

-- ============================================================================
-- SECTION 2: GROUND MOVEMENT (Friction + Acceleration)
-- ============================================================================

---Apply Source engine friction
---@param velocity Vector3
---@param is_on_ground boolean
---@param frametime number
---@param sv_friction number
---@param sv_stopspeed number
---@param surface_friction number?
local function friction(velocity, is_on_ground, frametime, sv_friction, sv_stopspeed, surface_friction)
	surface_friction = surface_friction or 1.0
	local speed = velocity:Length()
	if speed < 0.1 then
		return
	end

	local drop = 0
	if is_on_ground then
		local control = (speed < sv_stopspeed) and sv_stopspeed or speed
		drop = control * sv_friction * surface_friction * frametime
	end

	local newspeed = math.max(0, speed - drop)
	if newspeed ~= speed then
		newspeed = newspeed / speed
		velocity.x = velocity.x * newspeed
		velocity.y = velocity.y * newspeed
		velocity.z = velocity.z * newspeed
	end
end

---Apply ground acceleration
---@param velocity Vector3
---@param wishdir Vector3
---@param wishspeed number
---@param accel number
---@param frametime number
---@param surface_friction number?
local function accelerate(velocity, wishdir, wishspeed, accel, frametime, surface_friction)
	surface_friction = surface_friction or 1.0
	local currentspeed = velocity:Dot(wishdir)
	local addspeed = wishspeed - currentspeed

	if addspeed <= 0 then
		return
	end

	local accelspeed = math.min(accel * frametime * wishspeed * surface_friction, addspeed)
	velocity.x = velocity.x + wishdir.x * accelspeed
	velocity.y = velocity.y + wishdir.y * accelspeed
	velocity.z = velocity.z + wishdir.z * accelspeed
end

-- ============================================================================
-- SECTION 3: AIR MOVEMENT
-- ============================================================================

---Get air speed cap based on player conditions
---@param target Entity
---@return number
local function getAirSpeedCap(target)
	local m_hGrapplingHookTarget = target:GetPropEntity("m_hGrapplingHookTarget")
	if m_hGrapplingHookTarget then
		if target:GetCarryingRuneType() == GameConstants.RuneTypes.RUNE_AGILITY then
			local m_iClass = target:GetPropInt("m_iClass")
			local c = GameConstants.TF_Class
			return (m_iClass == c.Soldier or m_iClass == c.Heavy) and 850 or 950
		end
		local _, tf_grapplinghook_move_speed = client.GetConVar("tf_grapplinghook_move_speed")
		return tf_grapplinghook_move_speed or 750
	elseif target:InCond(GameConstants.TF_Cond.Charging) then
		local _, tf_max_charge_speed = client.GetConVar("tf_max_charge_speed")
		return tf_max_charge_speed or 750
	else
		local flCap = 30.0
		if target:InCond(GameConstants.TF_Cond.ParachuteDeployed) then
			local _, tf_parachute_aircontrol = client.GetConVar("tf_parachute_aircontrol")
			flCap = flCap * (tf_parachute_aircontrol or 1.0)
		end
		if target:InCond(GameConstants.TF_Cond.HalloweenKart) then
			if target:InCond(GameConstants.TF_Cond.HalloweenKartDash) then
				local _, tf_halloween_kart_dash_speed = client.GetConVar("tf_halloween_kart_dash_speed")
				return tf_halloween_kart_dash_speed or 1200
			end
			local _, tf_halloween_kart_aircontrol = client.GetConVar("tf_halloween_kart_aircontrol")
			flCap = flCap * (tf_halloween_kart_aircontrol or 1.0)
		end
		return flCap * (target:AttributeHookFloat("mod_air_control") or 1.0)
	end
end

---Apply air acceleration
---@param v Vector3
---@param wishdir Vector3
---@param wishspeed number
---@param accel number
---@param dt number
---@param surf number
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

-- ============================================================================
-- SECTION 4: COLLISION & GROUND DETECTION
-- ============================================================================

local function checkVelocity(velocity, maxvelocity)
	maxvelocity = maxvelocity or GameConstants.SV_MAXVELOCITY
	velocity.x = math.max(-maxvelocity, math.min(maxvelocity, velocity.x))
	velocity.y = math.max(-maxvelocity, math.min(maxvelocity, velocity.y))
	velocity.z = math.max(-maxvelocity, math.min(maxvelocity, velocity.z))
end

local function checkIsOnGround(origin, velocity, mins, maxs, index)
	if velocity and velocity.z > GameConstants.NON_JUMP_VELOCITY then
		return false
	end

	local down = Vector3(origin.x, origin.y, origin.z - GameConstants.GROUND_CHECK_OFFSET)
	local trace = engine.TraceHull(origin, down, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)

	return trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
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
	local MAX_CLIP_PLANES = GameConstants.DEFAULT_MAX_CLIP_PLANES
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

		local trace = engine.TraceHull(origin, end_pos, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
			return ent:GetIndex() ~= index
		end)

		if trace.fraction > 0 then
			origin.x, origin.y, origin.z = trace.endpos.x, trace.endpos.y, trace.endpos.z
			numplanes = 0
		end

		if trace.fraction == 1 then
			break
		end
		time_left = time_left - time_left * trace.fraction

		if trace.plane and numplanes < MAX_CLIP_PLANES then
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
					if j ~= i and velocity:Dot(planes[j]) < 0 then
						break
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
					velocity.x, velocity.y, velocity.z = dir.x * d, dir.y * d, dir.z * d
				end
				if velocity:Dot(planes[0]) < 0 then
					velocity.x, velocity.y, velocity.z = 0, 0, 0
					break
				end
			end
		else
			break
		end
	end
	return origin
end

local function stepMove(origin, velocity, mins, maxs, index, tickinterval, stepheight)
	local original_pos = Vector3(origin.x, origin.y, origin.z)
	local original_vel = Vector3(velocity.x, velocity.y, velocity.z)

	tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)
	local down_pos = Vector3(origin.x, origin.y, origin.z)
	local down_vel = Vector3(velocity.x, velocity.y, velocity.z)

	origin.x, origin.y, origin.z = original_pos.x, original_pos.y, original_pos.z
	velocity.x, velocity.y, velocity.z = original_vel.x, original_vel.y, original_vel.z

	local step_up_dest = Vector3(origin.x, origin.y, origin.z + stepheight + GameConstants.DIST_EPSILON)
	local step_trace = engine.TraceHull(origin, step_up_dest, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)

	if not step_trace.startsolid and not step_trace.allsolid then
		origin.x, origin.y, origin.z = step_trace.endpos.x, step_trace.endpos.y, step_trace.endpos.z
		tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)

		local step_down_dest = Vector3(origin.x, origin.y, origin.z - stepheight - GameConstants.DIST_EPSILON)
		local step_down_trace = engine.TraceHull(
			origin,
			step_down_dest,
			mins,
			maxs,
			GameConstants.MASK_PLAYERSOLID,
			function(ent)
				return ent:GetIndex() ~= index
			end
		)

		if step_down_trace.plane and step_down_trace.plane.z < 0.7 then
			origin.x, origin.y, origin.z = down_pos.x, down_pos.y, down_pos.z
			velocity.x, velocity.y, velocity.z = down_vel.x, down_vel.y, down_vel.z
			return origin
		end

		if not step_down_trace.startsolid and not step_down_trace.allsolid then
			origin.x, origin.y, origin.z = step_down_trace.endpos.x, step_down_trace.endpos.y, step_down_trace.endpos.z
		end

		local up_pos = Vector3(origin.x, origin.y, origin.z)
		local down_dist = (down_pos.x - original_pos.x) ^ 2 + (down_pos.y - original_pos.y) ^ 2
		local up_dist = (up_pos.x - original_pos.x) ^ 2 + (up_pos.y - original_pos.y) ^ 2

		if down_dist > up_dist then
			origin.x, origin.y, origin.z = down_pos.x, down_pos.y, down_pos.z
			velocity.x, velocity.y, velocity.z = down_vel.x, down_vel.y, down_vel.z
		else
			velocity.z = down_vel.z
		end
	else
		origin.x, origin.y, origin.z = down_pos.x, down_pos.y, down_pos.z
		velocity.x, velocity.y, velocity.z = down_vel.x, down_vel.y, down_vel.z
	end
	return origin
end

local function stayOnGround(origin, mins, maxs, stepheight, index)
	local start_pos = Vector3(origin.x, origin.y, origin.z + 2)
	local up_trace = engine.TraceHull(origin, start_pos, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)
	local end_pos = Vector3(up_trace.endpos.x, up_trace.endpos.y, origin.z - stepheight)
	local down_trace = engine.TraceHull(
		up_trace.endpos,
		end_pos,
		mins,
		maxs,
		GameConstants.MASK_PLAYERSOLID,
		function(ent)
			return ent:GetIndex() ~= index
		end
	)
	if
		down_trace.fraction > 0
		and down_trace.fraction < 1.0
		and not down_trace.startsolid
		and down_trace.plane
		and down_trace.plane.z >= 0.7
	then
		if math.abs(origin.z - down_trace.endpos.z) > 0.5 then
			origin.x, origin.y, origin.z = down_trace.endpos.x, down_trace.endpos.y, down_trace.endpos.z
			return true
		end
	end
	return false
end

-- ============================================================================
-- SECTION 6: PUBLIC API
-- ============================================================================

---@class PlayerContext
---@field entity Entity
---@field origin Vector3
---@field velocity Vector3
---@field mins Vector3
---@field maxs Vector3
---@field index integer
---@field maxspeed number
---@field yaw number
---@field yawDeltaPerTick number
---@field relativeWishDir Vector3
---@field strafeDir Vector3?

---@class SimulationContext
---@field tickinterval number
---@field sv_gravity number
---@field sv_friction number
---@field sv_stopspeed number
---@field sv_accelerate number
---@field sv_airaccelerate number
---@field curtime number?

---Simulate one tick
---@param playerCtx PlayerContext
---@param simCtx SimulationContext
---@return Vector3 newOrigin
function PlayerTick.simulateTick(playerCtx, simCtx)
	local tickinterval = simCtx.tickinterval
	local yawDelta = playerCtx.yawDeltaPerTick or 0

	-- Phase 1: Ground Detection (entity flag + trace)
	local entity_flags = playerCtx.entity:GetPropInt("m_fFlags") or 0
	local entity_says_onground = (entity_flags & GameConstants.FL_ONGROUND) ~= 0

	local trace_says_onground =
		checkIsOnGround(playerCtx.origin, playerCtx.velocity, playerCtx.mins, playerCtx.maxs, playerCtx.index)

	-- Trust entity flag primarily, trace as secondary validation
	local is_on_ground = entity_says_onground and trace_says_onground

	-- Clamp vertical velocity when on ground BEFORE friction
	if is_on_ground and playerCtx.velocity.z < 0 then
		playerCtx.velocity.z = 0
	end

	playerCtx.onGround = is_on_ground

	friction(playerCtx.velocity, is_on_ground, tickinterval, simCtx.sv_friction, simCtx.sv_stopspeed)
	checkVelocity(playerCtx.velocity)

	-- Phase 2: Wishdir & Acceleration
	local wishdir = relativeToWorldWishDir(playerCtx.relativeWishDir, playerCtx.yaw)

	if not is_on_ground then
		playerCtx.velocity.z = playerCtx.velocity.z - (simCtx.sv_gravity * 0.5 * tickinterval)
	end

	if is_on_ground then
		accelerate(playerCtx.velocity, wishdir, playerCtx.maxspeed, simCtx.sv_accelerate, tickinterval)
	else
		airAccelerate(
			playerCtx.velocity,
			wishdir,
			playerCtx.maxspeed,
			simCtx.sv_airaccelerate,
			tickinterval,
			1.0,
			playerCtx.entity
		)
	end

	-- Phase 3: Strafe Prediction (Velocity Rotation)
	-- "strafe pred only rotates current vector of velocity it does nothing else"
	if math.abs(yawDelta) > 0.001 then
		local speed2d = length2D(playerCtx.velocity)
		if speed2d > 0.1 then
			local velYaw = math.atan(playerCtx.velocity.y, playerCtx.velocity.x)
			local newVelYaw = velYaw + (yawDelta * GameConstants.DEG2RAD)
			playerCtx.velocity.x = math.cos(newVelYaw) * speed2d
			playerCtx.velocity.y = math.sin(newVelYaw) * speed2d
		end
		-- Update yaw for next tick's wishdir rotation
		playerCtx.yaw = playerCtx.yaw + yawDelta
	end

	-- Phase 4: Movement (Collision)
	local was_on_ground = is_on_ground
	if is_on_ground then
		playerCtx.origin = stepMove(
			playerCtx.origin,
			playerCtx.velocity,
			playerCtx.mins,
			playerCtx.maxs,
			playerCtx.index,
			tickinterval,
			18
		)
		stayOnGround(playerCtx.origin, playerCtx.mins, playerCtx.maxs, 18, playerCtx.index)
	else
		playerCtx.origin = tryPlayerMove(
			playerCtx.origin,
			playerCtx.velocity,
			playerCtx.mins,
			playerCtx.maxs,
			playerCtx.index,
			tickinterval
		)
	end

	-- Phase 5: Post-movement ground state re-check and final gravity
	local entity_flags_after = playerCtx.entity:GetPropInt("m_fFlags") or 0
	local entity_says_onground_after = (entity_flags_after & GameConstants.FL_ONGROUND) ~= 0

	local trace_says_onground_after =
		checkIsOnGround(playerCtx.origin, playerCtx.velocity, playerCtx.mins, playerCtx.maxs, playerCtx.index)

	local new_on_ground = entity_says_onground_after and trace_says_onground_after

	if not new_on_ground then
		-- In air: apply second half of gravity
		playerCtx.velocity.z = playerCtx.velocity.z - (simCtx.sv_gravity * 0.5 * tickinterval)
		playerCtx.onGround = false
	else
		-- On ground: clamp downward velocity
		if playerCtx.velocity.z < 0 then
			playerCtx.velocity.z = 0
		end
		playerCtx.onGround = true
	end

	return Vector3(playerCtx.origin:Unpack())
end

function PlayerTick.simulatePath(playerCtx, simCtx, time_seconds)
	local path = {}
	local timetable = {}
	local clock = 0.0
	local tickinterval = simCtx.tickinterval

	path[1] = Vector3(playerCtx.origin.x, playerCtx.origin.y, playerCtx.origin.z)
	timetable[1] = (simCtx.curtime or globals.CurTime())
	local lastOrigin = path[1]
	-- Always simulate path as requested for debugging/visual clarity

	while clock < time_seconds do
		local newOrigin = PlayerTick.simulateTick(playerCtx, simCtx)
		lastOrigin = newOrigin
		clock = clock + tickinterval
		path[#path + 1] = newOrigin
		timetable[#timetable + 1] = (simCtx.curtime or globals.CurTime()) + clock
	end

	return path, lastOrigin, timetable
end

return PlayerTick
