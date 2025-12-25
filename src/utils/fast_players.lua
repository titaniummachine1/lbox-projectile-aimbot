-- fast_players.lua - Cached player list, updated only when player list changes
-- Eliminates redundant entities.FindByClass("CTFPlayer") calls

local FastPlayers = {}

-- Cache state
local cachedAllPlayers = {}
local cachedEnemies = {}
local cachedTeammates = {}
local cachedLocal = nil
local cachedLocalTeam = nil
local lastUpdateTick = -1

-- Change detection state
local lastEntityIndices = {}
local lastEntityCount = 0
local forceRebuild = true -- Force rebuild on first call

-- Flags for derived caches
local enemiesUpdated = false
local teammatesUpdated = false

-- Build index set from current entities for fast comparison
local function buildIndexSet(players)
	local indices = {}
	local count = 0
	for _, ent in pairs(players) do
		if ent and ent:IsValid() then
			indices[ent:GetIndex()] = true
			count = count + 1
		end
	end
	return indices, count
end

-- Check if entity indices changed since last update
local function hasPlayerListChanged(newIndices, newCount)
	-- Count mismatch = definitely changed
	if newCount ~= lastEntityCount then
		return true
	end

	-- Check if any index is different
	for idx in pairs(newIndices) do
		if not lastEntityIndices[idx] then
			return true
		end
	end

	return false
end

--- Force a cache rebuild on next Update call (call after player_disconnect event)
function FastPlayers.Invalidate()
	forceRebuild = true
end

--- Update the player cache if needed (call once per tick at start of CreateMove)
--- Only rebuilds if player count or indices actually changed
function FastPlayers.Update()
	local currentTick = globals.TickCount()
	if currentTick == lastUpdateTick and not forceRebuild then
		return -- Already updated this tick
	end

	-- Get local player (always refresh)
	cachedLocal = entities.GetLocalPlayer()
	cachedLocalTeam = cachedLocal and cachedLocal:GetTeamNumber() or nil

	-- Get raw player list from engine
	local rawPlayers = entities.FindByClass("CTFPlayer") or {}

	-- Build index set to detect changes
	local newIndices, newCount = buildIndexSet(rawPlayers)

	-- Check if we actually need to rebuild
	local needsRebuild = forceRebuild or hasPlayerListChanged(newIndices, newCount)

	if not needsRebuild then
		-- Player list unchanged, just update tick marker
		lastUpdateTick = currentTick
		return
	end

	-- Rebuild the cached lists
	cachedAllPlayers = {}
	cachedEnemies = {}
	cachedTeammates = {}
	enemiesUpdated = false
	teammatesUpdated = false

	for _, ent in pairs(rawPlayers) do
		if ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant() then
			cachedAllPlayers[#cachedAllPlayers + 1] = ent
		end
	end

	-- Store current state for next comparison
	lastEntityIndices = newIndices
	lastEntityCount = newCount
	lastUpdateTick = currentTick
	forceRebuild = false
end

--- Get all valid players (alive, not dormant)
---@param excludeLocal boolean? Exclude local player from list
---@return Entity[]
function FastPlayers.GetAll(excludeLocal)
	if excludeLocal and cachedLocal then
		local localIdx = cachedLocal:GetIndex()
		local result = {}
		for i = 1, #cachedAllPlayers do
			local ent = cachedAllPlayers[i]
			if ent:GetIndex() ~= localIdx then
				result[#result + 1] = ent
			end
		end
		return result
	end
	return cachedAllPlayers
end

--- Get enemy players only
---@return Entity[]
function FastPlayers.GetEnemies()
	if not enemiesUpdated then
		cachedEnemies = {}
		if cachedLocalTeam then
			for i = 1, #cachedAllPlayers do
				local ent = cachedAllPlayers[i]
				if ent:GetTeamNumber() ~= cachedLocalTeam then
					cachedEnemies[#cachedEnemies + 1] = ent
				end
			end
		end
		enemiesUpdated = true
	end
	return cachedEnemies
end

--- Get teammate players only
---@param excludeLocal boolean? Exclude local player
---@return Entity[]
function FastPlayers.GetTeammates(excludeLocal)
	if not teammatesUpdated then
		cachedTeammates = {}
		local localIdx = cachedLocal and cachedLocal:GetIndex() or nil
		if cachedLocalTeam then
			for i = 1, #cachedAllPlayers do
				local ent = cachedAllPlayers[i]
				if ent:GetTeamNumber() == cachedLocalTeam then
					if not excludeLocal or ent:GetIndex() ~= localIdx then
						cachedTeammates[#cachedTeammates + 1] = ent
					end
				end
			end
		end
		teammatesUpdated = true
	end
	return cachedTeammates
end

--- Get local player (cached)
---@return Entity?
function FastPlayers.GetLocal()
	return cachedLocal
end

--- Get local player's team number
---@return integer?
function FastPlayers.GetLocalTeam()
	return cachedLocalTeam
end

--- Check if an entity index is in the current player list
---@param index integer
---@return boolean
function FastPlayers.IsValidPlayerIndex(index)
	for i = 1, #cachedAllPlayers do
		if cachedAllPlayers[i]:GetIndex() == index then
			return true
		end
	end
	return false
end

--- Get current tick (for checking if update needed externally)
---@return integer
function FastPlayers.GetLastUpdateTick()
	return lastUpdateTick
end

return FastPlayers
