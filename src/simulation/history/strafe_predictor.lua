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
function StrafePredictor.recordVelocity(entityIndex, velocity, maxSamples)
	assert(entityIndex, "StrafePredictor: entityIndex is nil")
	assert(velocity, "StrafePredictor: velocity is nil")

	if not velocityHistory[entityIndex] then
		velocityHistory[entityIndex] = {}
	end

	local history = velocityHistory[entityIndex]

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
function StrafePredictor.cleanupStalePlayers()
	local validIndices = {}
	for _, player in pairs(entities.FindByClass("CTFPlayer")) do
		if player then
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
	local history = velocityHistory[entityIndex]
	if not history or #history < (minSamples or 3) then
		return nil
	end

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

			totalYawChange = totalYawChange + diff
			samples = samples + 1
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

---Updates velocity history for all active players
---@param entities table List of entities to track
---@param maxSamples integer
function StrafePredictor.updateAll(entities, maxSamples)
	StrafePredictor.cleanupStalePlayers()

	for _, entity in pairs(entities) do
		if entity:IsAlive() and not entity:IsDormant() then
			local velocity = entity:EstimateAbsVelocity()
			if velocity and velocity:Length2D() > 1 then
				StrafePredictor.recordVelocity(entity:GetIndex(), velocity, maxSamples)
			end
		else
			-- Clear history for dead/dormant players
			StrafePredictor.clearHistory(entity:GetIndex())
		end
	end
end

return StrafePredictor
