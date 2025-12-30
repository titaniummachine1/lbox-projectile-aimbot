-- Imports

-- Module declaration
local PlayerTracker = {}

-- Per-player persistent data storage
local playerData = {}
local activePlayerIndices = {}
local lastUpdateTick = -1

-- Data expiry time (ticks)
local DATA_EXPIRY_TICKS = 66 -- ~1 second at 66 tick

-- Private helpers -----
local function createPlayerData()
	return {
		-- Visual data
		path = nil,
		projpath = nil,
		timetable = nil,
		projtimetable = nil,
		predictedOrigin = nil,
		aimPos = nil,
		multipointPos = nil,
		shotTime = nil,
		confidence = nil,

		-- Metadata
		lastUpdateTick = 0,
		lastUpdateTime = 0,
		entity = nil,
	}
end

local function isDataValid(data, currentTick)
	if not data or not data.lastUpdateTick then
		return false
	end

	-- Data is valid if updated within expiry window
	return (currentTick - data.lastUpdateTick) <= DATA_EXPIRY_TICKS
end

-- Public API ----

---Get or create player data for an entity
---@param entity Entity
---@return table|nil playerData
function PlayerTracker.GetOrCreate(entity)
	if not entity then
		return nil
	end

	local index = entity:GetIndex()
	if not playerData[index] then
		playerData[index] = createPlayerData()
	end

	playerData[index].entity = entity
	return playerData[index]
end

---Get player data if it exists and is valid
---@param entity Entity|number Entity object or index
---@return table|nil playerData
function PlayerTracker.Get(entity)
	if not entity then
		return nil
	end

	local index = type(entity) == "number" and entity or entity:GetIndex()
	local data = playerData[index]

	if not data then
		return nil
	end

	local currentTick = globals.TickCount()
	if not isDataValid(data, currentTick) then
		return nil
	end

	return data
end

---Update player data with prediction results
---@param entity Entity
---@param predictionData table
function PlayerTracker.Update(entity, predictionData)
	assert(entity, "PlayerTracker: entity is nil")
	assert(predictionData, "PlayerTracker: predictionData is nil")

	local data = PlayerTracker.GetOrCreate(entity)
	if not data then
		return
	end

	local currentTick = globals.TickCount()
	local now = (globals and globals.RealTime and globals.RealTime()) or 0

	-- Update visual data
	if predictionData.path ~= nil then
		data.path = predictionData.path
	end
	if predictionData.projpath ~= nil then
		data.projpath = predictionData.projpath
	end
	if predictionData.timetable ~= nil then
		data.timetable = predictionData.timetable
	end
	if predictionData.projtimetable ~= nil then
		data.projtimetable = predictionData.projtimetable
	end
	if predictionData.predictedOrigin ~= nil then
		data.predictedOrigin = predictionData.predictedOrigin
	end
	if predictionData.aimPos ~= nil then
		data.aimPos = predictionData.aimPos
	end
	if predictionData.multipointPos ~= nil then
		data.multipointPos = predictionData.multipointPos
	end
	if predictionData.shotTime ~= nil then
		data.shotTime = predictionData.shotTime
	end
	if predictionData.confidence ~= nil then
		data.confidence = predictionData.confidence
	end

	-- Update metadata
	data.lastUpdateTick = currentTick
	data.lastUpdateTime = now
	data.entity = entity
end

---Get the best available target data (most recent valid)
---@param inputEntities Entity[] List of potential targets
---@return table|nil bestData
---@return Entity|nil bestEntity
function PlayerTracker.GetBestTarget(inputEntities)
	if not inputEntities or #inputEntities == 0 then
		return nil, nil
	end

	local currentTick = globals.TickCount()
	local bestData = nil
	local bestEntity = nil
	local bestTick = -1

	for _, entity in pairs(inputEntities) do
		local data = PlayerTracker.Get(entity)
		if data and data.lastUpdateTick > bestTick then
			bestData = data
			bestEntity = entity
			bestTick = data.lastUpdateTick
		end
	end

	return bestData, bestEntity
end

---Clean up data for players no longer in the game
---Called automatically when player list changes
function PlayerTracker.UpdatePlayerList()
	local currentTick = globals.TickCount()

	-- Only update once per tick
	if currentTick == lastUpdateTick then
		return
	end
	lastUpdateTick = currentTick

	-- Build set of current player indices from FastPlayers cache (already validated)
	local currentIndices = {}
	local FastPlayers = require("utils.fast_players")
	local players = FastPlayers.GetAll()
	for i = 1, #players do
		currentIndices[players[i]:GetIndex()] = true
	end

	-- Remove data for players who left
	for index, _ in pairs(playerData) do
		if not currentIndices[index] then
			playerData[index] = nil
		end
	end

	-- Update active set
	activePlayerIndices = currentIndices
end

---Clear all expired data
function PlayerTracker.CleanExpired()
	local currentTick = globals.TickCount()

	for index, data in pairs(playerData) do
		if not isDataValid(data, currentTick) then
			playerData[index] = nil
		end
	end
end

---Reset all player data (e.g., on map change)
function PlayerTracker.Reset()
	playerData = {}
	activePlayerIndices = {}
	lastUpdateTick = -1
end

---Get all valid player data
---@return table<number, table> Map of entity index to player data
function PlayerTracker.GetAll()
	local currentTick = globals.TickCount()
	local valid = {}

	for index, data in pairs(playerData) do
		if isDataValid(data, currentTick) then
			valid[index] = data
		end
	end

	return valid
end

return PlayerTracker
