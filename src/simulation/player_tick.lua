-- ============================================================================
-- PLAYER MOVEMENT PREDICTION - Source Engine Physics Simulation
-- ============================================================================
-- This module simulates TF2 player movement tick-by-tick using Source engine physics.
-- It predicts where a player will be in the future by simulating:
--   - Ground/air movement with friction and acceleration
--   - Gravity when airborne
--   - Collision detection with world geometry
--   - Ground snapping
--
-- FLOW:
--   1. main.lua calls createPlayerContext() to snapshot current player state
--   2. main.lua calls simulateTick() in a loop to step simulation forward
--   3. Each tick updates velocity and position based on Source engine rules
--
-- KEY CONCEPTS:
--   - PlayerContext: Current player state (position, velocity, bbox, etc.)
--   - SimulationContext: Game constants (gravity, friction, tick rate, etc.)
--   - wishdir: Direction player wants to move (derived from current velocity)
-- ============================================================================

local GameConstants = require("constants.game_constants")

local PlayerTick = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local DEG2RAD = math.pi / 180

-- ============================================================================
-- SECTION 1: MOVEMENT DIRECTION
-- ============================================================================

---Convert yaw-relative wishdir to world-space wishdir
---@param relWishDir Vector3 Relative wishdir (forward/side basis)
---@param yaw number Yaw angle in degrees
---@return Vector3 World-space wishdir (always horizontal, z=0)
local function relativeToWorldWishDir(relWishDir, yaw)
	local yawRad = yaw * DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local worldX = cosYaw * relWishDir.x + sinYaw * relWishDir.y
	local worldY = sinYaw * relWishDir.x - cosYaw * relWishDir.y

	local len = math.sqrt(worldX * worldX + worldY * worldY)
	if len > 0.001 then
		return Vector3(worldX / len, worldY / len, 0)
	end

	return Vector3(cosYaw, sinYaw, 0)
end

-- ============================================================================
-- SECTION 2: GROUND MOVEMENT (Friction + Acceleration)
-- ============================================================================

---Apply Source engine friction (only when on ground)
---@param velocity Vector3 Current velocity (modified in-place)
---@param is_on_ground boolean Whether player is on ground
---@param frametime number Tick interval
---@param sv_friction number Server friction cvar
---@param sv_stopspeed number Server stopspeed cvar
local function friction(velocity, is_on_ground, frametime, sv_friction, sv_stopspeed)
	local speed = velocity:LengthSqr()
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
	if newspeed ~= speed then
		newspeed = newspeed / speed
		velocity.x = velocity.x * newspeed
		velocity.y = velocity.y * newspeed
		velocity.z = velocity.z * newspeed
	end
end

---Apply ground acceleration
---@param velocity Vector3 Current velocity (modified in-place)
---@param wishdir Vector3 Direction to accelerate
---@param wishspeed number Target speed
---@param accel number Acceleration multiplier
---@param frametime number Tick interval
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

-- ============================================================================
-- SECTION 3: AIR MOVEMENT (Limited acceleration + special conditions)
-- ============================================================================

---Get air speed cap based on player conditions
---@param target Entity Player entity
---@return number Air speed cap
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

---Apply air acceleration (limited compared to ground)
---@param v Vector3 Velocity (modified in-place)
---@param wishdir Vector3 Direction to accelerate
---@param wishspeed number Target speed
---@param accel number Acceleration multiplier
---@param dt number Tick interval
---@param surf number Surface type (0 = not surfing)
---@param target Entity Player entity
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
-- SECTION 4: GROUND STATE MANAGEMENT (Persistent State Machine)
-- ============================================================================

-- Per-player ground state persistence (like swing prediction)
local playerGroundStates = {}

---Clean up stale ground state entries for disconnected players
---@param validPlayerIndices table<integer, boolean> Set of valid player indices
function PlayerTick.cleanupGroundStates(validPlayerIndices)
	for index in pairs(playerGroundStates) do
		if not validPlayerIndices[index] then
			playerGroundStates[index] = nil
		end
	end
end

---Update ground state based on collision detection (preserves state between ticks)
---@param playerCtx PlayerContext Player context with current state
---@param tickinterval number Time for this tick
---@return boolean Current ground state after collision resolution
local function updateGroundState(playerCtx, tickinterval)
	local index = playerCtx.index
	local lastGroundState = playerGroundStates[index]
	if lastGroundState == nil then
		local flags = playerCtx.entity:GetPropInt("m_fFlags")
		lastGroundState = (flags & GameConstants.FL_ONGROUND) ~= 0
		playerGroundStates[index] = lastGroundState
	end

	local currentGroundState = lastGroundState
	local vStep = Vector3(0, 0, playerCtx.stepheight)
	local vUp = Vector3(0, 0, 1)

	local downStep = currentGroundState and vStep or Vector3(0, 0, 0)

	local groundTrace = engine.TraceHull(
		playerCtx.origin + vStep,
		playerCtx.origin - downStep,
		playerCtx.mins,
		playerCtx.maxs,
		GameConstants.MASK_PLAYERSOLID,
		function(ent, contentsMask)
			return ent:GetIndex() ~= index
		end
	)

	if groundTrace and groundTrace.fraction < 1.0 and not groundTrace.startsolid and groundTrace.plane then
		local normal = groundTrace.plane
		local angle = math.deg(math.acos(math.min(1.0, math.max(-1.0, normal:Dot(vUp)))))

		if angle < 45.0 then
			currentGroundState = true
		elseif angle >= 55.0 then
			currentGroundState = false
		end
	else
		currentGroundState = false
	end

	playerGroundStates[index] = currentGroundState
	return currentGroundState
end

---Snap player to ground surface when on ground
---@param origin Vector3 Player position (modified in-place)
---@param mins Vector3 Player bbox mins
---@param maxs Vector3 Player bbox maxs
---@param step_size number Max step height
---@param index integer Player entity index
---@return boolean True if snapped to ground
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

-- ============================================================================
-- SECTION 5: COLLISION DETECTION (Wall sliding, clipping planes)
-- ============================================================================

---Clip velocity against collision plane
---@param velocity Vector3 Velocity (modified in-place)
---@param normal Vector3 Plane normal
---@param overbounce number Bounce multiplier (usually 1.0)
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

---Move player with collision detection (Source engine multi-bump algorithm)
---@param origin Vector3 Starting position (modified in-place)
---@param velocity Vector3 Current velocity (modified in-place)
---@param mins Vector3 Player bbox mins
---@param maxs Vector3 Player bbox maxs
---@param index integer Player entity index
---@param tickinterval number Time to move
---@return Vector3 Final position
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

-- ============================================================================
-- SECTION 6: PUBLIC API - Main Simulation Functions
-- ============================================================================

---Simulates a single tick of player movement
---This is the CORE function called repeatedly to predict player position
---
---STEPS PER TICK:
---  1. Update player yaw (strafing angle change)
---  2. Calculate movement direction (wishdir)
---  3. Check if on ground
---  4. Apply friction (ground only)
---  5. Apply acceleration (ground) or air acceleration (air)
---  6. Apply gravity (air only)
---  7. Move with collision detection
---  8. Snap to ground if needed
---
---@param playerCtx PlayerContext Player state (position, velocity, bbox, etc.)
---@param simCtx SimulationContext Game constants (gravity, friction, etc.)
---@return Vector3 newOrigin New position after simulating one tick
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

	-- Step 1: Update yaw (strafe prediction)
	playerCtx.yaw = (playerCtx.yaw or 0) + (playerCtx.yawDeltaPerTick or 0)

	-- Step 2: Calculate movement direction
	local wishdir = nil
	if playerCtx.relativeWishDir then
		wishdir = relativeToWorldWishDir(playerCtx.relativeWishDir, playerCtx.yaw)
	else
		local horizLen = playerCtx.velocity:Length2D()
		if horizLen > 0.001 then
			wishdir = Vector3(playerCtx.velocity.x / horizLen, playerCtx.velocity.y / horizLen, 0)
		else
			wishdir = Vector3(1, 0, 0)
		end
	end

	wishdir.z = 0

	-- Step 3: Update persistent ground state
	local is_on_ground = updateGroundState(playerCtx, tickinterval)

	-- Step 4: Apply friction
	friction(playerCtx.velocity, is_on_ground, tickinterval, simCtx.sv_friction, simCtx.sv_stopspeed)

	-- Step 5 & 6: Accelerate and apply gravity
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
			0,
			playerCtx.entity
		)
		playerCtx.velocity.z = playerCtx.velocity.z - simCtx.sv_gravity * tickinterval
	end

	-- Step 7: Move with collision
	playerCtx.origin = tryPlayerMove(
		playerCtx.origin,
		playerCtx.velocity,
		playerCtx.mins,
		playerCtx.maxs,
		playerCtx.index,
		tickinterval
	)

	-- Step 8: Ground snapping (only for truly grounded players)
	if is_on_ground then
		local is_airborne = playerCtx.velocity.z > 0.1 or playerCtx.velocity.z < -250.0
		if not is_airborne then
			stayOnGround(playerCtx.origin, playerCtx.mins, playerCtx.maxs, playerCtx.stepheight, playerCtx.index)
		end
	end

	return Vector3(playerCtx.origin:Unpack())
end

---Simulates multiple ticks and returns full path
---Used for visualization and debugging
---@param playerCtx PlayerContext Player state
---@param simCtx SimulationContext Game constants
---@param time_seconds number How long to simulate
---@return Vector3[] path All positions during simulation
---@return Vector3 lastOrigin Final position
---@return number[] timetable Timestamps for each position
function PlayerTick.simulatePath(playerCtx, simCtx, time_seconds)
	assert(playerCtx, "PlayerTick: playerCtx is nil")
	assert(simCtx, "PlayerTick: simCtx is nil")
	assert(time_seconds, "PlayerTick: time_seconds is nil")

	local path = {}
	local timetable = {}
	local clock = 0.0
	local tickinterval = simCtx.tickinterval
	local lastOrigin = nil

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
		clock = clock + tickinterval
		path[#path + 1] = newOrigin
		timetable[#timetable + 1] = simCtx.curtime + clock
	end

	if not lastOrigin then
		lastOrigin = Vector3(playerCtx.origin:Unpack())
	end

	return path, lastOrigin, timetable
end

return PlayerTick
