---@module movement_sim
---Player movement simulation with friction, acceleration, and strafe rotation
---Properly handles wishdir to continue movement in same direction

local GameConstants = require("constants.game_constants")
local StrafeRotation = require("simulation.Player.strafe_rotation")

local MovementSim = {}

local vUp = Vector3(0, 0, 1)
local STEP_SIZE = 18
local MASK_PLAYERSOLID = GameConstants.MASK_PLAYERSOLID

local function length2D(vec)
	return math.sqrt(vec.x * vec.x + vec.y * vec.y)
end

local function friction(vel, onGround, tickInterval, sv_friction, sv_stopspeed)
	if not onGround then
		return
	end

	local speed = length2D(vel)
	if speed < 0.1 then
		return
	end

	local drop = 0
	local control = speed < sv_stopspeed and sv_stopspeed or speed
	drop = drop + control * sv_friction * tickInterval

	local newspeed = math.max(speed - drop, 0)
	if newspeed ~= speed then
		newspeed = newspeed / speed
		vel.x = vel.x * newspeed
		vel.y = vel.y * newspeed
	end
end

local function accelerate(vel, wishdir, wishspeed, accel, tickInterval)
	local currentspeed = vel.x * wishdir.x + vel.y * wishdir.y
	local addspeed = wishspeed - currentspeed

	if addspeed <= 0 then
		return
	end

	local accelspeed = accel * tickInterval * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end

	vel.x = vel.x + accelspeed * wishdir.x
	vel.y = vel.y + accelspeed * wishdir.y
end

local function airAccelerate(vel, wishdir, wishspeed, accel, tickInterval)
	-- Air acceleration caps effective wishspeed to 30 (sv_airaccelerate behavior)
	local AIR_CAP = 30
	if wishspeed > AIR_CAP then
		wishspeed = AIR_CAP
	end

	local currentspeed = vel.x * wishdir.x + vel.y * wishdir.y
	local addspeed = wishspeed - currentspeed

	if addspeed <= 0 then
		return
	end

	local accelspeed = accel * tickInterval * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end

	vel.x = vel.x + accelspeed * wishdir.x
	vel.y = vel.y + accelspeed * wishdir.y
end

local function relativeToWorldWishDir(relWishdir, yaw)
	local yawRad = yaw * GameConstants.DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local worldX = cosYaw * relWishdir.x - sinYaw * relWishdir.y
	local worldY = sinYaw * relWishdir.x + cosYaw * relWishdir.y

	local len = math.sqrt(worldX * worldX + worldY * worldY)
	if len > 0.001 then
		return {
			x = worldX / len,
			y = worldY / len,
			z = 0,
			magnitude = len,
		}
	end
	return { x = 0, y = 0, z = 0, magnitude = 0 }
end

local function normalizeVector(vec)
	return vec / vec:Lenght()
end

local function shouldHitEntity(entity, playerIndex)
	if not entity then
		return false
	end
	if entity:GetIndex() == playerIndex then
		return false
	end
	if entity:IsPlayer() then
		return false
	end

	local class = entity:GetClass()
	if class == "CTFAmmoPack" or class == "CTFDroppedWeapon" then
		return false
	end

	return true
end

-- ============================================================================
-- COLLISION SYSTEM (ported from src/player_tick.lua)
-- ============================================================================

local function dotProduct(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function clipVelocity(velocity, normal, overbounce)
	local backoff = dotProduct(velocity, normal) * overbounce
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
					if j ~= i and dotProduct(velocity, planes[j]) < 0 then
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
					local d = dotProduct(dir, velocity)
					velocity.x, velocity.y, velocity.z = dir.x * d, dir.y * d, dir.z * d
				end
				if dotProduct(velocity, planes[0]) < 0 then
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

---Simulate one tick of player movement
---@param state table Player state (from PlayerSimState.getOrCreate)
---@param simCtx table Simulation context (from PlayerSimState.getSimContext)
---@return Vector3 New origin position
function MovementSim.simulateTick(state, simCtx)
	assert(state, "simulateTick: state missing")
	assert(simCtx, "simulateTick: simCtx missing")

	local tickInterval = simCtx.tickinterval
	local gravity = simCtx.sv_gravity
	local yawDelta = state.yawDeltaPerTick or 0

	local vel = state.velocity
	local onGround = state.onGround

	-- Phase 1: Friction (only on ground)
	friction(vel, onGround, tickInterval, simCtx.sv_friction, simCtx.sv_stopspeed)

	-- Phase 2: Gravity (first half if in air)
	if not onGround then
		vel.z = vel.z - (gravity * 0.5 * tickInterval)
	end

	-- Phase 3: Wishdir acceleration
	-- Amalgam-style: apply strafe rotation to yaw BEFORE calculating wishdir
	local simYaw = StrafeRotation.applyRotation(state.index, state.yaw)
	local wishdirInfo = relativeToWorldWishDir(state.relativeWishDir, simYaw)
	local wishdir = { x = wishdirInfo.x, y = wishdirInfo.y, z = 0 }
	local inputMagnitude = wishdirInfo.magnitude

	if onGround then
		-- Ground: clamp wishspeed to maxspeed (class-specific cap)
		local wishspeed = math.min(inputMagnitude, state.maxspeed)
		accelerate(vel, wishdir, wishspeed, simCtx.sv_accelerate, tickInterval)
	else
		-- Air: airAccelerate caps to 30 internally
		airAccelerate(vel, wishdir, inputMagnitude, simCtx.sv_airaccelerate, tickInterval)
	end

	-- Phase 5: Movement with collision (using src collision system)
	local origin = Vector3(state.origin.x, state.origin.y, state.origin.z)

	if onGround then
		stepMove(origin, vel, state.mins, state.maxs, state.index, tickInterval, STEP_SIZE)
		stayOnGround(origin, state.mins, state.maxs, STEP_SIZE, state.index)
	else
		tryPlayerMove(origin, vel, state.mins, state.maxs, state.index, tickInterval)
	end

	-- Phase 6: Re-check ground state and final gravity
	onGround = checkIsOnGround(origin, vel, state.mins, state.maxs, state.index)

	if not onGround then
		vel.z = vel.z - (gravity * 0.5 * tickInterval)
	else
		if vel.z < 0 then
			vel.z = 0
		end
	end

	-- Update state
	state.origin.x = origin.x
	state.origin.y = origin.y
	state.origin.z = origin.z

	state.velocity.x = vel.x
	state.velocity.y = vel.y
	state.velocity.z = vel.z

	state.onGround = onGround

	return state.origin
end

---Simulate multiple ticks and return path
---@param state table Player state (from PlayerSimState.getOrCreate)
---@param simCtx table Simulation context (from PlayerSimState.getSimContext)
---@param numTicks integer Number of ticks to simulate
---@return Vector3[] Array of positions (path[1] = initial, path[numTicks+1] = final)
function MovementSim.simulatePath(state, simCtx, numTicks)
	assert(state, "simulatePath: state missing")
	assert(simCtx, "simulatePath: simCtx missing")

	local path = {}
	path[1] = Vector3(state.origin.x, state.origin.y, state.origin.z)

	for tick = 1, numTicks do
		MovementSim.simulateTick(state, simCtx)
		path[tick + 1] = Vector3(state.origin.x, state.origin.y, state.origin.z)
	end

	return path
end

return MovementSim
