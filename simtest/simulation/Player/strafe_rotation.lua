---@module strafe_rotation
---Smart strafe rotation with accumulated yawDelta and collision detection
---Rotates velocity vector by accumulated yawDelta, resets base on collision

local StrafeRotation = {}

local rotationState = {}

local function normalizeAngleDeg(angle)
	while angle > 180 do
		angle = angle - 360
	end
	while angle < -180 do
		angle = angle + 360
	end
	return angle
end

local function getVelocityYaw(velocity)
	return math.atan(velocity.y, velocity.x) * (180 / math.pi)
end

---Initialize strafe rotation state for an entity
---@param entityIndex integer Entity index
---@param initialYaw number Initial view yaw
---@param velocity Vector3 Initial velocity
---@param yawDeltaPerTick number Yaw delta per tick from strafe prediction
function StrafeRotation.initState(entityIndex, initialYaw, velocity, yawDeltaPerTick)
	local velYaw = getVelocityYaw(velocity)

	rotationState[entityIndex] = {
		accumulatedYawDelta = 0,
		baseVelocityYaw = velYaw,
		initialYaw = initialYaw,
		yawDeltaPerTick = yawDeltaPerTick or 0,
	}
end

---Apply smart strafe rotation to velocity
---Accumulates yawDelta and rotates velocity, but resets if collision changes angle too much
---@param entityIndex integer Entity index
---@param velocity Vector3 Current velocity (will be modified)
---@return boolean true if rotation was applied, false if reset due to collision
function StrafeRotation.applyRotation(entityIndex, velocity)
	local state = rotationState[entityIndex]
	if not state or math.abs(state.yawDeltaPerTick) < 0.001 then
		return false
	end

	-- Accumulate yawDelta for this tick
	state.accumulatedYawDelta = state.accumulatedYawDelta + state.yawDeltaPerTick

	local currentVelYaw = getVelocityYaw(velocity)
	local expectedYaw = state.baseVelocityYaw + state.accumulatedYawDelta

	-- Check if collision pushed angle beyond our accumulated limit
	local actualDeltaFromBase = normalizeAngleDeg(currentVelYaw - state.baseVelocityYaw)
	local tolerance = 5 -- degrees of tolerance

	if math.abs(actualDeltaFromBase) > math.abs(state.accumulatedYawDelta) + tolerance then
		-- Collision reset - velocity angle changed too much
		-- Update base to current and clear accumulated delta
		state.baseVelocityYaw = currentVelYaw
		state.accumulatedYawDelta = 0
		return false
	end

	-- Apply rotation to velocity vector
	local speed2d = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if speed2d > 0.1 then
		local expectedYawRad = expectedYaw * (math.pi / 180)
		velocity.x = math.cos(expectedYawRad) * speed2d
		velocity.y = math.sin(expectedYawRad) * speed2d
	end

	return true
end

---Get the current accumulated yaw delta for strafe visualization
---@param entityIndex integer Entity index
---@return number accumulated yaw delta in degrees
function StrafeRotation.getAccumulatedYawDelta(entityIndex)
	local state = rotationState[entityIndex]
	return state and state.accumulatedYawDelta or 0
end

---Get the base velocity yaw (for debugging)
---@param entityIndex integer Entity index
---@return number base velocity yaw in degrees
function StrafeRotation.getBaseVelocityYaw(entityIndex)
	local state = rotationState[entityIndex]
	return state and state.baseVelocityYaw or 0
end

---Get the current yaw delta per tick setting
---@param entityIndex integer Entity index
---@return number yaw delta per tick in degrees
function StrafeRotation.getYawDeltaPerTick(entityIndex)
	local state = rotationState[entityIndex]
	return state and state.yawDeltaPerTick or 0
end

function StrafeRotation.clear(entityIndex)
	rotationState[entityIndex] = nil
end

function StrafeRotation.clearAll()
	rotationState = {}
end

return StrafeRotation
