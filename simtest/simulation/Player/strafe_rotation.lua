---@module strafe_rotation
---Amalgam-style strafe prediction: calculate average yaw from direction history
---Apply directly to viewangle each tick, no accumulation

local StrafeRotation = {}

local rotationState = {}

---Initialize strafe rotation state
function StrafeRotation.initState(entityIndex, anchorYaw, yawDeltaPerTick)
	local enabled = math.abs(yawDeltaPerTick or 0) > 0.36 -- Amalgam threshold
	rotationState[entityIndex] = {
		anchorYaw = anchorYaw,
		yawDeltaPerTick = yawDeltaPerTick or 0,
		enabled = enabled,
	}
end

---Apply Amalgam-style strafe rotation
---Directly rotates viewangle by averageYaw each tick (no accumulation)
---@return number new yaw angle
function StrafeRotation.applyRotation(entityIndex, currentYaw)
	local state = rotationState[entityIndex]
	if not state or not state.enabled then
		return currentYaw
	end

	-- Amalgam style: just add the average yaw to viewangle
	-- No accumulation, no velocity checking - simple and direct
	return currentYaw + state.yawDeltaPerTick
end

---Check if strafe prediction is active
function StrafeRotation.isActive(entityIndex)
	local state = rotationState[entityIndex]
	return state and state.enabled or false
end

function StrafeRotation.getYawDelta(entityIndex)
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
