local GameConstants = require("constants.game_constants")

local StrafePrediction = {}

local HISTORY_SIZE = 66
local STRAIGHT_FUZZY_VALUE_GROUND = 10.0
local STRAIGHT_FUZZY_VALUE_AIR = 5.0
local MAX_CHANGES_GROUND = 2
local MAX_CHANGES_AIR = 4
local MIN_STRAFES = 6

local history = {}

local function sign(x)
	if x > 0 then
		return 1
	end
	if x < 0 then
		return -1
	end
	return 0
end

local function normalizeAngle(angle)
	while angle > 180 do
		angle = angle - 360
	end
	while angle < -180 do
		angle = angle + 360
	end
	return angle
end

local function vectorToYaw(vec)
	return math.atan(vec.y, vec.x) * GameConstants.RAD2DEG
end

function StrafePrediction.recordMovement(entityIndex, origin, velocity, mode, simTime, maxSpeed)
	assert(entityIndex, "StrafePrediction.recordMovement: entityIndex missing")

	if not history[entityIndex] then
		history[entityIndex] = {}
	end

	local records = history[entityIndex]

	local dirX, dirY = velocity.x, velocity.y
	local len = math.sqrt(dirX * dirX + dirY * dirY)
	if len > 0.1 then
		dirX = dirX / len
		dirY = dirY / len
	else
		dirX, dirY = 0, 0
	end

	table.insert(records, 1, {
		origin = { x = origin.x, y = origin.y, z = origin.z },
		velocity = { x = velocity.x, y = velocity.y, z = velocity.z },
		direction = { x = dirX, y = dirY, z = 0 },
		mode = mode,
		simTime = simTime,
		speed = len,
	})

	while #records > HISTORY_SIZE do
		table.remove(records)
	end
end

function StrafePrediction.clearHistory(entityIndex)
	history[entityIndex] = nil
end

local function getYawDifference(record1, record2, isGround, maxSpeed)
	local yaw1 = vectorToYaw(record1.direction)
	local yaw2 = vectorToYaw(record2.direction)

	local deltaTime = record1.simTime - record2.simTime
	local ticks = math.max(math.floor(deltaTime / GameConstants.TICK_INTERVAL), 1)

	local yawDelta = normalizeAngle(yaw1 - yaw2)

	if maxSpeed and maxSpeed > 0 and record1.mode ~= 1 then
		local speedRatio = math.min(record1.speed / maxSpeed, 1.0)
		yawDelta = yawDelta * speedRatio
	end

	return yawDelta, ticks
end

local function isStraightMovement(yawDelta, speed, ticks, isGround)
	local fuzzyValue = isGround and STRAIGHT_FUZZY_VALUE_GROUND or STRAIGHT_FUZZY_VALUE_AIR
	return math.abs(yawDelta) * speed * ticks < fuzzyValue
end

function StrafePrediction.calculateAverageYaw(entityIndex, maxSpeed, minSamples)
	local records = history[entityIndex]
	if not records or #records < MIN_STRAFES then
		return nil
	end

	minSamples = minSamples or 4
	local isGround = records[1].mode ~= 1
	local maxChanges = isGround and MAX_CHANGES_GROUND or MAX_CHANGES_AIR

	local totalYaw = 0
	local totalTicks = 0
	local changes = 0
	local lastSign = 0
	local lastWasZero = false
	local validStrafes = 0

	for i = 2, math.min(#records, 30) do
		local r1 = records[i - 1]
		local r2 = records[i]

		if r1.mode ~= r2.mode then
			break
		end

		local yawDelta, ticks = getYawDifference(r1, r2, isGround, maxSpeed)
		local isStraight = isStraightMovement(yawDelta, r1.speed, ticks, isGround)

		if math.abs(yawDelta) > 45 then
			break
		end

		local currSign = sign(yawDelta)
		local currZero = math.abs(yawDelta) < 0.1

		if i > 2 then
			if currSign ~= lastSign or (currZero and lastWasZero) or isStraight then
				changes = changes + 1
				if changes > maxChanges then
					break
				end
			end
		end

		lastSign = currSign
		lastWasZero = currZero

		totalYaw = totalYaw + yawDelta
		totalTicks = totalTicks + ticks
		validStrafes = validStrafes + 1
	end

	if validStrafes < minSamples then
		return nil
	end

	local avgYaw = totalYaw / math.max(totalTicks, minSamples)

	if math.abs(avgYaw) < 0.36 then
		return nil
	end

	return avgYaw
end

function StrafePrediction.applyYawCorrection(playerCtx, simCtx, avgYaw)
	assert(playerCtx, "applyYawCorrection: playerCtx missing")
	assert(simCtx, "applyYawCorrection: simCtx missing")

	if not avgYaw or math.abs(avgYaw) < 0.01 then
		return
	end

	local isAir = playerCtx.velocity.z ~= 0 or not playerCtx.onGround

	local correction = 0
	if isAir then
		correction = 90 * sign(avgYaw)
	end

	playerCtx.yaw = playerCtx.yaw + avgYaw + correction
end

return StrafePrediction
