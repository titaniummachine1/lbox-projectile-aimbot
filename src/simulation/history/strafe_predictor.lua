-- Imports
local GameConstants = require("constants.game_constants")

-- Module declaration
local StrafePredictor = {}

-- Velocity history storage (global per-player)
local velocityHistory = {}

---Records velocity sample for a player
---@param entityIndex integer
---@param velocity Vector3
---@param maxSamples integer
---@param relativeWishdir Vector3? Optional current relative wishdir
function StrafePredictor.recordVelocity(entityIndex, velocity, maxSamples, relativeWishdir)
	assert(entityIndex, "StrafePredictor: entityIndex is nil")
	assert(velocity, "StrafePredictor: velocity is nil")

	if not velocityHistory[entityIndex] then
		velocityHistory[entityIndex] = {
			history = {},
			lastWishdir = nil,
		}
	end

	local state = velocityHistory[entityIndex]
	local history = state.history

	-- Check for significant wishdir change (> 90 degrees)
	if relativeWishdir and state.lastWishdir then
		local dot = relativeWishdir:Dot(state.lastWishdir)
		-- Dot product < 0 means angle > 90 degrees
		if dot < -0.01 then
			-- Clear history on sudden direction change
			state.history = {}
			history = state.history
		end
	end

	-- Update last wishdir
	if relativeWishdir then
		state.lastWishdir = Vector3(relativeWishdir:Unpack())
	end

	-- Add to front of list
	table.insert(history, 1, Vector3(velocity:Unpack()))

	-- Trim to max samples
	maxSamples = maxSamples or 10
	while #history > maxSamples do
		table.remove(history)
	end
end

---Clears velocity history for a player
---@param entityIndex integer
function StrafePredictor.clearHistory(entityIndex)
	velocityHistory[entityIndex] = nil
end

---Clears all velocity history
function StrafePredictor.clearAllHistory()
	velocityHistory = {}
end

-- Cleans up stale history entries (players no longer in game)
-- Call this once per tick to prevent memory leaks
-- Pass FastPlayers module to avoid redundant entity scans
---@param fastPlayers table? Optional FastPlayers module with GetAll()
function StrafePredictor.cleanupStalePlayers(fastPlayers)
	local validIndices = {}
	local players = fastPlayers and fastPlayers.GetAll() or entities.FindByClass("CTFPlayer")
	for _, player in pairs(players) do
		if player and player.GetIndex then
			validIndices[player:GetIndex()] = true
		end
	end

	for entityIndex in pairs(velocityHistory) do
		if not validIndices[entityIndex] then
			velocityHistory[entityIndex] = nil
		end
	end
end

---Calculates average yaw change from velocity history
---@param entityIndex integer
---@param minSamples integer Minimum samples required
---@return number? avgYawChange Average yaw change in radians (nil if insufficient data)
function StrafePredictor.calculateAverageYawChange(entityIndex, minSamples)
	local state = velocityHistory[entityIndex]
	if not state or not state.history or #state.history < (minSamples or 3) then
		return nil
	end

	local history = state.history

	local totalYawChange = 0
	local samples = 0

	for i = 1, #history - 1 do
		local vel1 = history[i]
		local vel2 = history[i + 1]

		-- Only process if velocities are significant (not standing still)
		if vel1:Length2D() >= 10 and vel2:Length2D() >= 10 then
			local yaw1 = math.atan(vel1.y, vel1.x)
			local yaw2 = math.atan(vel2.y, vel2.x)

			-- Calculate angle difference (handle wraparound)
			local diff = yaw1 - yaw2
			while diff > math.pi do
				diff = diff - 2 * math.pi
			end
			while diff < -math.pi do
				diff = diff + 2 * math.pi
			end

			-- Ignore samples with delta > 90 degrees (not a smooth strafe)
			if math.abs(diff) < (math.pi / 2) then
				totalYawChange = totalYawChange + diff
				samples = samples + 1
			end
		end
	end

	if samples == 0 then
		return nil
	end

	return totalYawChange / samples
end

---Predicts future strafe direction based on velocity history
---@param entityIndex integer
---@param currentYaw number Current yaw in radians
---@return Vector3? Predicted direction vector (nil if insufficient data)
function StrafePredictor.predictStrafeDirection(entityIndex, currentYaw)
	local avgYawChange = StrafePredictor.calculateAverageYawChange(entityIndex, 3)
	if not avgYawChange then
		return nil
	end

	-- Apply predicted yaw change
	local predictedYaw = currentYaw + avgYawChange

	-- Convert back to direction vector
	local dirX = math.cos(predictedYaw)
	local dirY = math.sin(predictedYaw)

	return Vector3(dirX, dirY, 0)
end

---Gets yaw delta per tick in DEGREES for use in simulation
---@param entityIndex integer
---@param minSamples integer Minimum samples required (default 3)
---@return number yawDeltaPerTick Yaw change in degrees per tick (0 if insufficient data)
function StrafePredictor.getYawDeltaPerTickDegrees(entityIndex, minSamples)
	local avgYawChangeRad = StrafePredictor.calculateAverageYawChange(entityIndex, minSamples or 3)
	if not avgYawChangeRad then
		return 0
	end
	return avgYawChangeRad * GameConstants.RAD2DEG
end

---Clears all velocity history
function StrafePredictor.clearAllHistory()
	velocityHistory = {}
end

return StrafePredictor
