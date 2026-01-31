local GameConstants = require("constants.game_constants")
local MovementSim = require("simulation.Player.movement_sim")

local WishdirDebug = {}

local LINE_LENGTH = 15
local MAX_INPUT = 450

local DIRECTIONS = {
	{ name = "F", dir = { 1, 0 }, angle = 0 },
	{ name = "FR", dir = { 0.707, -0.707 }, angle = 45 },
	{ name = "R", dir = { 0, -1 }, angle = 90 },
	{ name = "BR", dir = { -0.707, -0.707 }, angle = 135 },
	{ name = "B", dir = { -1, 0 }, angle = 180 },
	{ name = "BL", dir = { -0.707, 0.707 }, angle = 225 },
	{ name = "L", dir = { 0, 1 }, angle = 270 },
	{ name = "FL", dir = { 0.707, 0.707 }, angle = 315 },
	{ name = "C", dir = { 0, 0 }, angle = nil },
}

-- Store last tick's simulations for comparison
local lastTickResults = {}

local function dirToRawWishdir(dirInfo)
	local d = dirInfo.dir
	if dirInfo.name == "C" then
		return { x = 0, y = 0, z = 0 }
	else
		return { x = d[1] * MAX_INPUT, y = d[2] * MAX_INPUT, z = 0 }
	end
end

local function getVelocityYaw(velocity)
	return math.atan(velocity.y, velocity.x) * (180 / math.pi)
end

---Simulate one tick with specific wishdir
function WishdirDebug.simulateDirection(state, simCtx, relDir)
	local testState = {
		origin = { x = state.origin.x, y = state.origin.y, z = state.origin.z },
		velocity = { x = state.velocity.x, y = state.velocity.y, z = state.velocity.z },
		yaw = state.yaw,
		mins = state.mins,
		maxs = state.maxs,
		index = state.index,
		maxspeed = state.maxspeed,
		relativeWishDir = { x = relDir.x, y = relDir.y, z = 0 },
		onGround = state.onGround,
	}

	MovementSim.simulateTick(testState, simCtx)

	return {
		origin = testState.origin,
		velocity = testState.velocity,
		onGround = testState.onGround,
	}
end

---Simulate all 9 directions
function WishdirDebug.simulateAll9(state, simCtx)
	local results = {}
	for i, dirInfo in ipairs(DIRECTIONS) do
		local rawDir = dirToRawWishdir(dirInfo)
		results[i] = {
			dirInfo = dirInfo,
			result = WishdirDebug.simulateDirection(state, simCtx, rawDir),
		}
	end
	return results
end

---Find closest match by velocity direction AND magnitude
function WishdirDebug.findClosestByVelocity(actualVel, prevResults)
	if not prevResults or #prevResults == 0 then
		return nil
	end

	local actualYaw = getVelocityYaw(actualVel)
	local actualSpeed = math.sqrt(actualVel.x * actualVel.x + actualVel.y * actualVel.y)

	local bestMatch = nil
	local bestScore = math.huge

	for i, data in ipairs(prevResults) do
		local simVel = data.result.velocity
		local simSpeed = math.sqrt(simVel.x * simVel.x + simVel.y * simVel.y)
		local simYaw = getVelocityYaw(simVel)

		-- Calculate angle difference
		local yawDiff = actualYaw - simYaw
		while yawDiff > 180 do
			yawDiff = yawDiff - 360
		end
		while yawDiff < -180 do
			yawDiff = yawDiff + 360
		end

		-- Calculate speed difference
		local speedDiff = math.abs(actualSpeed - simSpeed)

		-- Combined score: angle weighted more heavily
		local score = math.abs(yawDiff) * 2 + speedDiff * 0.1

		if score < bestScore then
			bestScore = score
			bestMatch = data
		end
	end

	return bestMatch
end

---Draw 9-direction visualization with 15-unit velocity lines
function WishdirDebug.draw9Directions(entity, results, tickInterval)
	if not results or #results == 0 then
		return
	end

	local origin = entity:GetAbsOrigin()
	local playerPos = client.WorldToScreen(origin)
	if not playerPos then
		return
	end

	-- Set font for text labels
	local font = draw.CreateFont("Consolas", 12, 500)
	draw.SetFont(font)

	-- Draw 15-unit velocity lines for each direction
	for i, data in ipairs(results) do
		local vel = data.result.velocity
		local speed2D = math.sqrt(vel.x * vel.x + vel.y * vel.y)

		-- Normalize to LINE_LENGTH
		local drawVel = { x = 0, y = 0, z = 0 }
		if speed2D > 0.1 then
			local scale = LINE_LENGTH / speed2D
			drawVel.x = vel.x * scale
			drawVel.y = vel.y * scale
			drawVel.z = vel.z * scale
		end

		local endPos = Vector3(origin.x + drawVel.x, origin.y + drawVel.y, origin.z + drawVel.z)
		local endScreen = client.WorldToScreen(endPos)

		if endScreen then
			-- Color: Green=ground, Yellow=air, Gray=coast, White=best match
			if data.isBestMatch then
				draw.Color(255, 255, 255, 255) -- White for best match
			elseif data.dirInfo.name == "C" then
				draw.Color(150, 150, 150, 180)
			elseif data.result.onGround then
				draw.Color(100, 255, 100, 200)
			else
				draw.Color(255, 255, 100, 200)
			end

			draw.Line(playerPos[1], playerPos[2], endScreen[1], endScreen[2])

			-- Label at end
			draw.Color(255, 255, 255, 255)
			draw.Text(endScreen[1] + 3, endScreen[2] - 5, data.dirInfo.name)
		end
	end

	-- Draw actual velocity arrow (red)
	local actualVel = entity:EstimateAbsVelocity()
	if actualVel then
		local speed2D = actualVel:Length2D()
		if speed2D > 0.1 then
			local scale = LINE_LENGTH / speed2D
			local actualEnd =
				Vector3(origin.x + actualVel.x * scale, origin.y + actualVel.y * scale, origin.z + actualVel.z * scale)
			local actualScreen = client.WorldToScreen(actualEnd)
			if actualScreen then
				draw.Color(255, 50, 50, 255)
				draw.Line(playerPos[1], playerPos[2], actualScreen[1], actualScreen[2])
				draw.Text(actualScreen[1] + 3, actualScreen[2] - 5, "ACTUAL")
			end
		end
	end
end

---Update with current entity state - find best match from last tick, simulate new 9
function WishdirDebug.update(entity, state, simCtx)
	local entityIndex = entity:GetIndex()

	-- Find closest match from last tick's simulations
	local actualVel = entity:EstimateAbsVelocity()
	local bestMatch = nil
	if actualVel and lastTickResults[entityIndex] then
		bestMatch = WishdirDebug.findClosestByVelocity(actualVel, lastTickResults[entityIndex])
	end

	-- Simulate all 9 directions for this tick
	local results = WishdirDebug.simulateAll9(state, simCtx)

	-- Mark best match
	if bestMatch then
		for i, data in ipairs(results) do
			if data.dirInfo.name == bestMatch.dirInfo.name then
				data.isBestMatch = true
				break
			end
		end
	end

	-- Store for next tick
	lastTickResults[entityIndex] = results

	return results
end

function WishdirDebug.clear(entityIndex)
	lastTickResults[entityIndex] = nil
end

return WishdirDebug
