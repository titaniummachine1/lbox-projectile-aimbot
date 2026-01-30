---@module strafe_rotation
---Tracks velocity direction changes and maintains offset between yaw and velocity
---Rotates yaw by velocity direction delta while preserving initial offset

local StrafeRotation = {}

local rotationState = {}

local function getVelocityYaw(velocity)
	return math.atan(velocity.y, velocity.x) * (180 / math.pi)
end

function StrafeRotation.initState(entityIndex, initialYaw, velocity)
	local velYaw = getVelocityYaw(velocity)
	local initialOffset = initialYaw - velYaw

	rotationState[entityIndex] = {
		initialYaw = initialYaw,
		initialVelYaw = velYaw,
		initialOffset = initialOffset,
		lastVelYaw = velYaw,
		currentYaw = initialYaw,
	}
end

function StrafeRotation.applyRotation(entityIndex, velocity)
	local state = rotationState[entityIndex]
	if not state then
		return
	end

	local currentVelYaw = getVelocityYaw(velocity)

	-- Calculate how much velocity direction has rotated since last tick
	local velDelta = currentVelYaw - state.lastVelYaw

	-- Normalize angle delta to [-180, 180]
	while velDelta > 180 do
		velDelta = velDelta - 360
	end
	while velDelta < -180 do
		velDelta = velDelta + 360
	end

	-- Rotate yaw by velocity direction change
	state.currentYaw = state.currentYaw + velDelta

	-- Calculate current offset
	local currentOffset = state.currentYaw - currentVelYaw
	while currentOffset > 180 do
		currentOffset = currentOffset - 360
	end
	while currentOffset < -180 do
		currentOffset = currentOffset + 360
	end

	-- If offset exceeds initial offset (wall collision increased rotation), clamp it
	if math.abs(currentOffset) > math.abs(state.initialOffset) then
		state.currentYaw = currentVelYaw + state.initialOffset
	end

	state.lastVelYaw = currentVelYaw
end

function StrafeRotation.getCurrentYaw(entityIndex)
	local state = rotationState[entityIndex]
	return state and state.currentYaw or 0
end

function StrafeRotation.clear(entityIndex)
	rotationState[entityIndex] = nil
end

function StrafeRotation.clearAll()
	rotationState = {}
end

return StrafeRotation
