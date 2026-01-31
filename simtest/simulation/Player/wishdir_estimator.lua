---@module wishdir_estimator
---Estimates player movement direction from velocity
---Does NOT use player's actual input - derives from observed movement
---Snaps to 8 directions for realistic prediction

local GameConstants = require("constants.game_constants")

local WishdirEstimator = {}

local STILL_SPEED_THRESHOLD = 50

local MAX_SPEED_INPUT = 450
local DIAGONAL_INPUT = 450 / math.sqrt(2) -- ≈ 318.2

local function normalizeAngle(angle)
	return ((angle + 180) % 360) - 180
end

---Estimate view-relative wishdir from velocity
---Returns raw cmd-scale values (0-450), NOT normalized
---@param velocity Vector3 Player's current velocity
---@param yaw number Player's view yaw angle
---@return table {x, y, z} View-relative wishdir (raw cmd values)
function WishdirEstimator.estimateFromVelocity(velocity, yaw)
	assert(velocity, "estimateFromVelocity: velocity missing")
	assert(yaw, "estimateFromVelocity: yaw missing")

	local horizLen = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if horizLen < STILL_SPEED_THRESHOLD then
		return { x = 0, y = 0, z = 0 }
	end

	local yawRad = yaw * GameConstants.DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local velNormX = velocity.x / horizLen
	local velNormY = velocity.y / horizLen

	local relForward = cosYaw * velNormX + sinYaw * velNormY
	local relLeft = -sinYaw * velNormX + cosYaw * velNormY

	local rawX = 0
	local rawY = 0

	if relForward > 0.3 then
		rawX = MAX_SPEED_INPUT
	elseif relForward < -0.3 then
		rawX = -MAX_SPEED_INPUT
	end

	if relLeft > 0.3 then
		rawY = MAX_SPEED_INPUT
	elseif relLeft < -0.3 then
		rawY = -MAX_SPEED_INPUT
	end

	local len = math.sqrt(rawX * rawX + rawY * rawY)
	if len > 0.0001 then
		if len > MAX_SPEED_INPUT + 1 then
			local scale = MAX_SPEED_INPUT / len
			rawX = rawX * scale
			rawY = rawY * scale
		end
	else
		rawX = 0
		rawY = 0
	end

	return { x = rawX, y = rawY, z = 0 }
end

---Convert view-relative wishdir to world space
---Preserves magnitude (0-450) for proper acceleration math
---@param relativeWishdir table {x, y, z} View-relative direction (raw values)
---@param yaw number Player's view yaw angle
---@return table {x, y, z, magnitude} World-space direction (normalized) + magnitude
function WishdirEstimator.toWorldSpace(relativeWishdir, yaw)
	assert(relativeWishdir, "toWorldSpace: relativeWishdir missing")
	assert(yaw, "toWorldSpace: yaw missing")

	local yawRad = yaw * GameConstants.DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local worldX = cosYaw * relativeWishdir.x - sinYaw * relativeWishdir.y
	local worldY = sinYaw * relativeWishdir.x + cosYaw * relativeWishdir.y

	local magnitude = math.sqrt(worldX * worldX + worldY * worldY)
	if magnitude > 0.001 then
		return {
			x = worldX / magnitude,
			y = worldY / magnitude,
			z = 0,
			magnitude = magnitude,
		}
	end

	return { x = 0, y = 0, z = 0, magnitude = 0 }
end

return WishdirEstimator
