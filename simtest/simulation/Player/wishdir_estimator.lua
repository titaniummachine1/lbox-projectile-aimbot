---@module wishdir_estimator
---Estimates player movement direction from velocity
---Does NOT use player's actual input - derives from observed movement
---Snaps to 8 directions for realistic prediction

local GameConstants = require("constants.game_constants")

local WishdirEstimator = {}

local STILL_SPEED_THRESHOLD = 50

local function normalizeAngle(angle)
	return ((angle + 180) % 360) - 180
end

---Estimate view-relative wishdir from velocity
---Snaps to 8 directions (forward, back, left, right, 4 diagonals)
---@param velocity Vector3 Player's current velocity
---@param yaw number Player's view yaw angle
---@return table {x, y, z} View-relative wishdir (normalized)
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

	local snapX = 0
	local snapY = 0

	if relForward > 0.3 then
		snapX = 1
	elseif relForward < -0.3 then
		snapX = -1
	end

	if relLeft > 0.3 then
		snapY = 1
	elseif relLeft < -0.3 then
		snapY = -1
	end

	local len = math.sqrt(snapX * snapX + snapY * snapY)
	if len > 0.0001 then
		snapX = snapX / len
		snapY = snapY / len
	else
		snapX = 0
		snapY = 0
	end

	return { x = snapX, y = snapY, z = 0 }
end

---Convert view-relative wishdir to world space
---@param relativeWishdir table {x, y, z} View-relative direction
---@param yaw number Player's view yaw angle
---@return table {x, y, z} World-space direction (normalized)
function WishdirEstimator.toWorldSpace(relativeWishdir, yaw)
	assert(relativeWishdir, "toWorldSpace: relativeWishdir missing")
	assert(yaw, "toWorldSpace: yaw missing")

	local yawRad = yaw * GameConstants.DEG2RAD
	local cosYaw = math.cos(yawRad)
	local sinYaw = math.sin(yawRad)

	local worldX = cosYaw * relativeWishdir.x - sinYaw * relativeWishdir.y
	local worldY = sinYaw * relativeWishdir.x + cosYaw * relativeWishdir.y

	local len = math.sqrt(worldX * worldX + worldY * worldY)
	if len > 0.001 then
		return { x = worldX / len, y = worldY / len, z = 0 }
	end

	return { x = 0, y = 0, z = 0 }
end

return WishdirEstimator
