---@module strafe_rotation
---Strafe rotation using ONLY velocity direction delta
---Viewangle is anchor for initialization, never used for actual strafe calc

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

---Initialize strafe rotation with anchor yaw (viewangle)
---This is ONLY used as starting reference, not for calculations
function StrafeRotation.initState(entityIndex, anchorYaw, velocity, yawDeltaPerTick)
	local velYaw = getVelocityYaw(velocity)

	rotationState[entityIndex] = {
		accumulatedYawDelta = 0,
		baseVelocityYaw = velYaw,
		anchorYaw = anchorYaw,
		yawDeltaPerTick = yawDeltaPerTick or 0,
		lastVelocityYaw = velYaw,
		lastSpeed2D = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y),
	}
end

---Apply strafe rotation based on velocity direction delta ONLY
---Returns the rotated velocity vector
function StrafeRotation.applyRotation(entityIndex, velocity)
	local state = rotationState[entityIndex]
	if not state or math.abs(state.yawDeltaPerTick) < 0.001 then
		return velocity
	end

	local currentVelYaw = getVelocityYaw(velocity)
	local currentSpeed2D = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

	-- Accumulate yawDelta based on velocity direction changes only
	state.accumulatedYawDelta = state.accumulatedYawDelta + state.yawDeltaPerTick

	local expectedYaw = state.baseVelocityYaw + state.accumulatedYawDelta

	-- Check for collision: compare actual velocity change vs expected
	local actualDeltaFromBase = normalizeAngleDeg(currentVelYaw - state.baseVelocityYaw)
	local tolerance = 10 -- degrees

	if math.abs(actualDeltaFromBase) > math.abs(state.accumulatedYawDelta) + tolerance then
		-- Collision detected - reset base to current velocity
		state.baseVelocityYaw = currentVelYaw
		state.accumulatedYawDelta = 0
		state.lastVelocityYaw = currentVelYaw
		state.lastSpeed2D = currentSpeed2D
		return velocity
	end

	-- Apply rotation to velocity direction (keep same magnitude)
	if currentSpeed2D > 0.1 then
		local expectedYawRad = expectedYaw * (math.pi / 180)
		velocity.x = math.cos(expectedYawRad) * currentSpeed2D
		velocity.y = math.sin(expectedYawRad) * currentSpeed2D
	end

	state.lastVelocityYaw = expectedYaw
	state.lastSpeed2D = currentSpeed2D

	return velocity
end

function StrafeRotation.getAccumulatedYawDelta(entityIndex)
	local state = rotationState[entityIndex]
	return state and state.accumulatedYawDelta or 0
end

function StrafeRotation.clear(entityIndex)
	rotationState[entityIndex] = nil
end

function StrafeRotation.clearAll()
	rotationState = {}
end

return StrafeRotation
