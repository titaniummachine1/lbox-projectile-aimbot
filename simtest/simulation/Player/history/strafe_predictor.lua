-- StrafePredictor - Optimized version with pooling and circular buffers
local GameConstants = require("constants.game_constants")

local StrafePredictor = {}

-- [[ Vector Pool for Reusability ]]
local vectorPool = {}
local function getPooledVector(x, y, z)
	local v = table.remove(vectorPool)
	if v then
		v.x, v.y, v.z = x, y, z
		return v
	end
	return Vector3(x, y, z)
end

local function releaseVector(v)
	if v then
		table.insert(vectorPool, v)
	end
end

-- Circular Buffer based History
-- state[idx] = {
--    samples = { {x,y,z}, ... },
--    head = 1,
--    count = 0,
--    lastWishX, lastWishY,
--    maxSize = 10
-- }
local velocityHistory = {}

function StrafePredictor.recordVelocity(entityIndex, velocity, maxSamples, relativeWishdir)
	maxSamples = maxSamples or 10
	if not velocityHistory[entityIndex] then
		velocityHistory[entityIndex] = {
			samples = {}, -- We store raw numbers for maximum efficiency
			head = 1,
			count = 0,
			lastWishX = nil,
			lastWishY = nil,
		}
	end

	local s = velocityHistory[entityIndex]

	-- Check for significant wishdir change (> 90 degrees)
	if relativeWishdir and s.lastWishX then
		-- Dot product: relX*lastX + relY*lastY
		local dot = relativeWishdir.x * s.lastWishX + relativeWishdir.y * s.lastWishY
		if dot < -0.01 then
			s.count = 0 -- Reset history on sharp turn
		end
	end

	-- Update last wishdir (store as primitives)
	if relativeWishdir then
		s.lastWishX, s.lastWishY = relativeWishdir.x, relativeWishdir.y
	else
		s.lastWishX, s.lastWishY = nil, nil
	end

	-- Store velocity sample (circularly)
	local idx = s.head
	if not s.samples[idx] then
		s.samples[idx] = { 0, 0, 0 }
	end
	local sample = s.samples[idx]
	sample[1], sample[2], sample[3] = velocity:Unpack()

	s.head = (s.head % maxSamples) + 1
	if s.count < maxSamples then
		s.count = s.count + 1
	end
end

function StrafePredictor.clearHistory(entityIndex)
	velocityHistory[entityIndex] = nil
end

function StrafePredictor.clearAllHistory()
	velocityHistory = {}
end

function StrafePredictor.cleanupStalePlayers(fastPlayers)
	local players = fastPlayers and fastPlayers.GetAll() or entities.FindByClass("CTFPlayer")
	local active = {}
	for i = 1, #players do
		active[players[i]:GetIndex()] = true
	end
	for idx in pairs(velocityHistory) do
		if not active[idx] then
			velocityHistory[idx] = nil
		end
	end
end

function StrafePredictor.calculateAverageYawChange(entityIndex, minSamples)
	local s = velocityHistory[entityIndex]
	if not s or s.count < (minSamples or 3) then
		return nil
	end

	local totalYawChange = 0
	local samples = 0
	local maxS = #s.samples

	-- Iterate backwards from head-1
	local current = s.head - 1
	if current < 1 then
		current = s.count
	end

	for i = 1, s.count - 1 do
		local prev = current - 1
		if prev < 1 then
			prev = s.count
		end

		local v1 = s.samples[current]
		local v2 = s.samples[prev]

		-- Use primitives to avoid Length2D temp vectors
		local lenSq1 = v1[1] * v1[1] + v1[2] * v1[2]
		local lenSq2 = v2[1] * v2[1] + v2[2] * v2[2]

		if lenSq1 > 100 and lenSq2 > 100 then
			local yaw1 = math.atan(v1[2], v1[1])
			local yaw2 = math.atan(v2[2], v2[1])

			local diff = yaw1 - yaw2
			-- Normalize angle diff (-pi to pi)
			diff = (diff + math.pi) % (2 * math.pi) - math.pi

			if math.abs(diff) < (math.pi / 2) then
				totalYawChange = totalYawChange + diff
				samples = samples + 1
			end
		end
		current = prev
	end

	if samples == 0 then
		return nil
	end
	return totalYawChange / samples
end

function StrafePredictor.predictStrafeDirection(entityIndex, currentYaw)
	local avg = StrafePredictor.calculateAverageYawChange(entityIndex, 3)
	if not avg then
		return nil
	end
	local predYaw = currentYaw + avg
	return getPooledVector(math.cos(predYaw), math.sin(predYaw), 0)
end

function StrafePredictor.getYawDeltaPerTickDegrees(entityIndex, minSamples)
	local avg = StrafePredictor.calculateAverageYawChange(entityIndex, minSamples or 3)
	if not avg then
		return 0
	end
	return avg * GameConstants.RAD2DEG
end

return StrafePredictor
