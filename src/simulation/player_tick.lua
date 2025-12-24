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
---From TF2 source: CGameMovement::Friction()
---@param velocity Vector3 Current velocity (modified in-place)
---@param is_on_ground boolean Whether player is on ground
---@param frametime number Tick interval
---@param sv_friction number Server friction cvar
---@param sv_stopspeed number Server stopspeed cvar
---@param surface_friction number Surface friction multiplier (default 1.0)
local function friction(velocity, is_on_ground, frametime, sv_friction, sv_stopspeed, surface_friction)
	surface_friction = surface_friction or 1.0

	-- Calculate actual speed (not squared!)
	local speed = velocity:Length()

	-- If too slow, return
	if speed < 0.1 then
		return
	end

	local drop = 0

	-- Apply ground friction (TF2: control * sv_friction * surfaceFriction * frametime)
	if is_on_ground then
		-- Bleed off some speed, but if we have less than the bleed
		-- threshold, bleed the threshold amount (TF2 source)
		local control = (speed < sv_stopspeed) and sv_stopspeed or speed
		drop = control * sv_friction * surface_friction * frametime
	end

	-- Scale the velocity
	local newspeed = speed - drop
	if newspeed < 0 then
		newspeed = 0
	end

	if newspeed ~= speed then
		-- Determine proportion of old speed we are using
		newspeed = newspeed / speed
		-- Adjust velocity according to proportion
		velocity.x = velocity.x * newspeed
		velocity.y = velocity.y * newspeed
		velocity.z = velocity.z * newspeed
	end
end

---Apply ground acceleration
---From TF2 source: CGameMovement::Accelerate()
---@param velocity Vector3 Current velocity (modified in-place)
---@param wishdir Vector3 Direction to accelerate
---@param wishspeed number Target speed
---@param accel number Acceleration multiplier
---@param frametime number Tick interval
---@param surface_friction number Surface friction multiplier (default 1.0)
local function accelerate(velocity, wishdir, wishspeed, accel, frametime, surface_friction)
	surface_friction = surface_friction or 1.0

	local currentspeed = velocity:Dot(wishdir)
	local addspeed = wishspeed - currentspeed

	if addspeed <= 0 then
		return
	end

	-- TF2: accelspeed = accel * frametime * wishspeed * surfaceFriction
	local accelspeed = accel * frametime * wishspeed * surface_friction
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
-- SECTION 4: SIMPLE GROUND DETECTION (Like user's working code)
-- ============================================================================

-- TF2 movement constants
local NON_JUMP_VELOCITY = 140.0 -- If moving up faster than this, not on ground
local GROUND_CHECK_OFFSET = 2.0 -- TF2 uses 2 units for ground detection
local DIST_EPSILON = 0.03125 -- Source engine epsilon for step traces
local SV_MAXVELOCITY = 3500 -- Default sv_maxvelocity

---TF2 CheckVelocity - clamps velocity components to sv_maxvelocity
---From TF2 source: CGameMovement::CheckVelocity()
---@param velocity Vector3 Velocity (modified in-place)
---@param maxvelocity number Max velocity (default 3500)
local function checkVelocity(velocity, maxvelocity)
	maxvelocity = maxvelocity or SV_MAXVELOCITY

	-- Clamp each component
	if velocity.x > maxvelocity then
		velocity.x = maxvelocity
	end
	if velocity.x < -maxvelocity then
		velocity.x = -maxvelocity
	end
	if velocity.y > maxvelocity then
		velocity.y = maxvelocity
	end
	if velocity.y < -maxvelocity then
		velocity.y = -maxvelocity
	end
	if velocity.z > maxvelocity then
		velocity.z = maxvelocity
	end
	if velocity.z < -maxvelocity then
		velocity.z = -maxvelocity
	end
end

---TF2 CategorizePosition ground check
---From TF2 source: checks if player is on walkable ground
---@param origin Vector3 Player position
---@param velocity Vector3 Player velocity (for jump detection)
---@param mins Vector3 Player bbox mins
---@param maxs Vector3 Player bbox maxs
---@param index integer Player entity index
---@return boolean True if on ground
local function checkIsOnGround(origin, velocity, mins, maxs, index)
	-- TF2: If moving up rapidly, not on ground (jumping)
	if velocity and velocity.z > NON_JUMP_VELOCITY then
		return false
	end

	-- TF2: Trace down by 2 units to check for ground
	local down = Vector3(origin.x, origin.y, origin.z - GROUND_CHECK_OFFSET)
	local trace = engine.TraceHull(origin, down, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)

	-- Must hit something with walkable slope (normal.z >= 0.7)
	if trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7 then
		return true
	end

	return false
end

---TF2 StayOnGround - keeps walking player on ground when running down slopes
---From TF2 source: trace UP 2 units first to find safe position, then DOWN by stepSize
---@param origin Vector3 Player position (modified in-place)
---@param mins Vector3 Player bbox mins
---@param maxs Vector3 Player bbox maxs
---@param stepheight number Max step height (18 units)
---@param index integer Player entity index
---@return boolean True if ground snapping occurred
local function stayOnGround(origin, mins, maxs, stepheight, index)
	-- TF2 algorithm: First trace UP to find safe starting position
	local start_pos = Vector3(origin.x, origin.y, origin.z + 2)
	local end_pos = Vector3(origin.x, origin.y, origin.z - stepheight)

	-- See how far up we can go without getting stuck
	local up_trace = engine.TraceHull(origin, start_pos, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)

	-- Use the safe elevated position as start
	local safe_start = up_trace.endpos

	-- Now trace down from the safe position
	local down_trace = engine.TraceHull(safe_start, end_pos, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)

	-- Check if we found valid ground
	if
		down_trace.fraction > 0 -- must go somewhere
		and down_trace.fraction < 1.0 -- must hit something
		and not down_trace.startsolid -- can't be embedded in solid
		and down_trace.plane
		and down_trace.plane.z >= 0.7
	then -- must be walkable slope
		local delta = math.abs(origin.z - down_trace.endpos.z)

		-- Only snap if significant difference (TF2 uses 0.5 * COORD_RESOLUTION)
		if delta > 0.5 then
			origin.x = down_trace.endpos.x
			origin.y = down_trace.endpos.y
			origin.z = down_trace.endpos.z
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

---Move player with collision detection (improved reference implementation)
---@param origin Vector3 Starting position (modified in-place)
---@param velocity Vector3 Current velocity (modified in-place)
---@param mins Vector3 Player bbox mins
---@param maxs Vector3 Player bbox maxs
---@param index integer Player entity index
---@param tickinterval number Time to move
---@return Vector3 Final position
local function tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)
	local MAX_CLIP_PLANES = 5
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

---TF2 StepMove - handles both up and down stepping (from TF2 source)
---@param origin Vector3 Starting position (modified in-place)
---@param velocity Vector3 Current velocity (modified in-place)
---@param mins Vector3 Player bbox mins
---@param maxs Vector3 Player bbox maxs
---@param index integer Player entity index
---@param tickinterval number Time to move
---@param stepheight number Step height (18 units)
---@return Vector3 Final position
local function stepMove(origin, velocity, mins, maxs, index, tickinterval, stepheight)
	-- Store original position and velocity
	local original_pos = Vector3(origin.x, origin.y, origin.z)
	local original_vel = Vector3(velocity.x, velocity.y, velocity.z)

	-- Try normal slide movement first (the "down" path)
	tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)

	-- Store down path results
	local down_pos = Vector3(origin.x, origin.y, origin.z)
	local down_vel = Vector3(velocity.x, velocity.y, velocity.z)

	-- Reset to original position and velocity
	origin.x = original_pos.x
	origin.y = original_pos.y
	origin.z = original_pos.z
	velocity.x = original_vel.x
	velocity.y = original_vel.y
	velocity.z = original_vel.z

	-- Try step-up path: Move up by step height + epsilon (TF2 source)
	local step_up_dest = Vector3(origin.x, origin.y, origin.z + stepheight + DIST_EPSILON)

	local step_trace = engine.TraceHull(origin, step_up_dest, mins, maxs, GameConstants.MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)

	-- If we can step up, try movement from elevated position
	if not step_trace.startsolid and not step_trace.allsolid then
		-- Move to elevated position
		origin.x = step_trace.endpos.x
		origin.y = step_trace.endpos.y
		origin.z = step_trace.endpos.z

		-- Try movement from elevated position
		tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)

		-- Step back down to ground level + epsilon (TF2 source)
		local step_down_dest = Vector3(origin.x, origin.y, origin.z - stepheight - DIST_EPSILON)

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

		-- If we hit a steep slope stepping down, use down path instead
		if step_down_trace.plane and step_down_trace.plane.z < 0.7 then
			origin.x = down_pos.x
			origin.y = down_pos.y
			origin.z = down_pos.z
			velocity.x = down_vel.x
			velocity.y = down_vel.y
			velocity.z = down_vel.z
			return origin
		end

		-- Step down to final position
		if not step_down_trace.startsolid and not step_down_trace.allsolid then
			origin.x = step_down_trace.endpos.x
			origin.y = step_down_trace.endpos.y
			origin.z = step_down_trace.endpos.z
		end

		-- Store up path results
		local up_pos = Vector3(origin.x, origin.y, origin.z)

		-- Compare horizontal distances traveled
		local down_dist = (down_pos.x - original_pos.x) * (down_pos.x - original_pos.x)
			+ (down_pos.y - original_pos.y) * (down_pos.y - original_pos.y)
		local up_dist = (up_pos.x - original_pos.x) * (up_pos.x - original_pos.x)
			+ (up_pos.y - original_pos.y) * (up_pos.y - original_pos.y)

		-- Use whichever path went farther horizontally
		if down_dist > up_dist then
			-- Down path was better
			origin.x = down_pos.x
			origin.y = down_pos.y
			origin.z = down_pos.z
			velocity.x = down_vel.x
			velocity.y = down_vel.y
			velocity.z = down_vel.z
		else
			-- Up path was better, but preserve Z velocity from down path
			velocity.z = down_vel.z
		end
	else
		-- Couldn't step up, use down path results
		origin.x = down_pos.x
		origin.y = down_pos.y
		origin.z = down_pos.z
		velocity.x = down_vel.x
		velocity.y = down_vel.y
		velocity.z = down_vel.z
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
		local horizLen = playerCtx.velocity:Length()
		if horizLen > 0.001 then
			wishdir = Vector3(playerCtx.velocity.x / horizLen, playerCtx.velocity.y / horizLen, 0)
		else
			wishdir = Vector3(1, 0, 0)
		end
	end

	wishdir.z = 0

	-- Step 3: Simple ground check (like user's working code)
	local is_on_ground =
		checkIsOnGround(playerCtx.origin, playerCtx.velocity, playerCtx.mins, playerCtx.maxs, playerCtx.index)

	-- Step 3.5: CRITICAL ground velocity management (like working visualizer)
	if is_on_ground and playerCtx.velocity.z < 0 then
		playerCtx.velocity.z = 0
	end

	-- Step 4: Apply friction
	friction(playerCtx.velocity, is_on_ground, tickinterval, simCtx.sv_friction, simCtx.sv_stopspeed)

	-- Step 4.5: CheckVelocity - clamp to max velocity (TF2 source)
	checkVelocity(playerCtx.velocity)

	-- Step 5: StartGravity - apply half gravity BEFORE movement (TF2 source)
	if not is_on_ground then
		-- TF2: "Add gravity so they'll be in the correct position during movement"
		-- "yes, this 0.5 looks wrong, but it's not"
		playerCtx.velocity.z = playerCtx.velocity.z - (simCtx.sv_gravity * 0.5 * tickinterval)
	end

	-- Step 6: Accelerate
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
			1.0, -- surface friction for air
			playerCtx.entity
		)
	end

	-- Step 7: Move with proper TF2 movement logic
	if is_on_ground then
		-- Ground movement uses StepMove for stair handling
		playerCtx.origin = stepMove(
			playerCtx.origin,
			playerCtx.velocity,
			playerCtx.mins,
			playerCtx.maxs,
			playerCtx.index,
			tickinterval,
			playerCtx.stepheight or 18
		)

		-- TF2: Call StayOnGround AFTER movement to keep on ground when going downhill
		stayOnGround(playerCtx.origin, playerCtx.mins, playerCtx.maxs, playerCtx.stepheight or 18, playerCtx.index)
	else
		-- In air, just do regular collision movement
		playerCtx.origin = tryPlayerMove(
			playerCtx.origin,
			playerCtx.velocity,
			playerCtx.mins,
			playerCtx.maxs,
			playerCtx.index,
			tickinterval
		)
	end

	-- Step 8: Re-categorize position after movement (like TF2 FullWalkMove)
	local new_ground_state =
		checkIsOnGround(playerCtx.origin, playerCtx.velocity, playerCtx.mins, playerCtx.maxs, playerCtx.index)

	-- Step 9: FinishGravity - apply remaining half gravity AFTER movement (TF2 source)
	if not new_ground_state then
		-- TF2: "Get the correct velocity for the end of the dt"
		playerCtx.velocity.z = playerCtx.velocity.z - (simCtx.sv_gravity * 0.5 * tickinterval)
	end

	-- If on ground after movement, zero downward velocity
	if new_ground_state and playerCtx.velocity.z < 0 then
		playerCtx.velocity.z = 0
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
