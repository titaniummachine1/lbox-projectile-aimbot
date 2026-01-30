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

local function accelerate(vel, wishdir, maxspeed, accel, tickInterval)
	local wishspeed = maxspeed
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

local function airAccelerate(vel, wishdir, maxspeed, accel, tickInterval)
	local wishspeed = maxspeed
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
		return { x = worldX / len, y = worldY / len, z = 0 }
	end
	return { x = 0, y = 0, z = 0 }
end

local function normalizeVector(vec)
	local len = math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
	if len < 0.0001 then
		return Vector3(0, 0, 0)
	end
	return Vector3(vec.x / len, vec.y / len, vec.z / len)
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
	local wishdir = relativeToWorldWishDir(state.relativeWishDir, state.yaw)

	if onGround then
		accelerate(vel, wishdir, state.maxspeed, simCtx.sv_accelerate, tickInterval)
	else
		airAccelerate(vel, wishdir, state.maxspeed, simCtx.sv_airaccelerate, tickInterval)
	end

	-- Phase 4: Strafe rotation (tracks velocity direction changes)
	StrafeRotation.applyRotation(state.index, vel)
	local newYaw = StrafeRotation.getCurrentYaw(state.index)
	if newYaw ~= 0 then
		state.yaw = newYaw
	end

	-- Phase 5: Movement with collision
	local lastPos = Vector3(state.origin.x, state.origin.y, state.origin.z)
	local pos =
		Vector3(lastPos.x + vel.x * tickInterval, lastPos.y + vel.y * tickInterval, lastPos.z + vel.z * tickInterval)

	local vStep = Vector3(0, 0, STEP_SIZE)

	-- Forward collision (wall trace)
	local wallTrace = engine.TraceHull(
		lastPos + vStep,
		pos + vStep,
		state.mins,
		state.maxs,
		MASK_PLAYERSOLID,
		function(ent)
			return shouldHitEntity(ent, state.index)
		end
	)

	if wallTrace.fraction < 1 then
		local normal = wallTrace.plane
		if normal then
			local angle = math.deg(math.acos(normal:Dot(vUp)))

			if angle > 55 then
				-- Wall too steep, clip velocity
				local dot = vel:Dot(normal)
				vel = vel - normal * dot
			end

			pos.x = wallTrace.endpos.x
			pos.y = wallTrace.endpos.y
		end
	end

	-- Ground collision
	local downStep = onGround and vStep or Vector3(0, 0, 0)

	local groundTrace = engine.TraceHull(
		pos + vStep,
		pos - downStep,
		state.mins,
		state.maxs,
		MASK_PLAYERSOLID,
		function(ent)
			return shouldHitEntity(ent, state.index)
		end
	)

	if groundTrace.fraction < 1 then
		local normal = groundTrace.plane
		if normal then
			local angle = math.deg(math.acos(normal:Dot(vUp)))

			if angle < 45 then
				pos = groundTrace.endpos
				onGround = true
			elseif angle < 55 then
				vel.x = 0
				vel.y = 0
				vel.z = 0
				onGround = false
			else
				local dot = vel:Dot(normal)
				vel = vel - normal * dot
				onGround = true
			end
		end
	else
		onGround = false
	end

	-- Phase 6: Gravity (second half if in air)
	if not onGround then
		vel.z = vel.z - (gravity * 0.5 * tickInterval)
	end

	-- Update state
	state.origin.x = pos.x
	state.origin.y = pos.y
	state.origin.z = pos.z

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
