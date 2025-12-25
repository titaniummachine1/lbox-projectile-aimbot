-- fast_players.lua - Cached player list, updated once per tick
-- Eliminates redundant entities.FindByClass("CTFPlayer") calls

local FastPlayers = {}

-- Cache state
local cachedAllPlayers = {}
local cachedEnemies = {}
local cachedTeammates = {}
local cachedLocal = nil
local cachedLocalTeam = nil
local lastUpdateTick = -1

-- Flags for derived caches
local enemiesUpdated = false
local teammatesUpdated = false

--- Update the player cache if needed (call once per tick at start of CreateMove)
function FastPlayers.Update()
	local currentTick = globals.TickCount()
	if currentTick == lastUpdateTick then
		return -- Already updated this tick
	end

	-- Clear caches
	cachedAllPlayers = {}
	cachedEnemies = {}
	cachedTeammates = {}
	enemiesUpdated = false
	teammatesUpdated = false

	-- Get local player
	cachedLocal = entities.GetLocalPlayer()
	cachedLocalTeam = cachedLocal and cachedLocal:GetTeamNumber() or nil

	-- Single scan of all players
	local players = entities.FindByClass("CTFPlayer")
	if players then
		for _, ent in pairs(players) do
			if ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant() then
				cachedAllPlayers[#cachedAllPlayers + 1] = ent
			end
		end
	end

	lastUpdateTick = currentTick
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
