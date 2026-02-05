local FastPlayers = {}

-- [[ 1. SAFE PRE-ALLOCATION ]]
local max_capacity = 64
local cachedAllPlayers = {}
local cachedEnemies = {}
local cachedTeammates = {}

for i = 1, max_capacity do
	cachedAllPlayers[i] = nil
	cachedEnemies[i] = nil
	cachedTeammates[i] = nil
end

-- State
local cachedLocal = nil
local cachedLocalTeam = nil
local lastHighestIndex = -1
local dirty = true

-- Flags to prevent rebuilding derived tables 10x a frame
local enemiesDirty = true
local teammatesDirty = true

-- [[ 2. PRECISE EVENT LISTENERS ]]
local function onPlayerEvent(event)
	local eventName = event:GetName()
	if eventName == "player_connect" or eventName == "player_disconnect" or eventName == "player_team" then
		dirty = true
	end
end

-- Cleanup interactions
local function onUnload()
	callbacks.Unregister("FireGameEvent", "FastPlayers_Events")
end

-- [[ 3. SMART UPDATE LOGIC ]]
function FastPlayers.Update()
	cachedLocal = entities.GetLocalPlayer()
	local newTeam = cachedLocal and cachedLocal:GetTeamNumber() or nil

	if newTeam ~= cachedLocalTeam then
		cachedLocalTeam = newTeam
		enemiesDirty = true
		teammatesDirty = true
	end

	local currentHighestIndex = entities.GetHighestEntityIndex()

	if dirty or currentHighestIndex ~= lastHighestIndex then
		-- Clear all players first
		for i = 1, max_capacity do
			cachedAllPlayers[i] = nil
		end

		-- Add valid players using pairs iteration
		local writeIdx = 0
		for _, ent in pairs(entities.FindByClass("CTFPlayer") or {}) do
			if ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant() then
				writeIdx = writeIdx + 1
				cachedAllPlayers[writeIdx] = ent
			end
		end

		enemiesDirty = true
		teammatesDirty = true
		lastHighestIndex = currentHighestIndex
		dirty = false
	end
end

-- [[ GETTERS ]]

function FastPlayers.GetAll()
	return cachedAllPlayers
end

function FastPlayers.GetEnemies()
	if enemiesDirty then
		local writeIdx = 0
		if cachedLocalTeam then
			for i = 1, max_capacity do
				local ent = cachedAllPlayers[i]
				if not ent then
					break
				end
				if ent:GetTeamNumber() ~= cachedLocalTeam then
					writeIdx = writeIdx + 1
					cachedEnemies[writeIdx] = ent
				end
			end
		end
		for i = writeIdx + 1, max_capacity do
			cachedEnemies[i] = nil
		end
		enemiesDirty = false
	end
	return cachedEnemies
end

function FastPlayers.GetTeammates()
	if teammatesDirty then
		local writeIdx = 0
		if cachedLocalTeam then
			for i = 1, max_capacity do
				local ent = cachedAllPlayers[i]
				if not ent then
					break
				end
				if ent:GetTeamNumber() == cachedLocalTeam then
					writeIdx = writeIdx + 1
					cachedTeammates[writeIdx] = ent
				end
			end
		end
		for i = writeIdx + 1, max_capacity do
			cachedTeammates[i] = nil
		end
		teammatesDirty = false
	end
	return cachedTeammates
end

function FastPlayers.GetLocal()
	return cachedLocal
end

-- [[ CALLBACK REGISTRATION ]]
callbacks.Unregister("FireGameEvent", "FastPlayers_Events")
callbacks.Register("FireGameEvent", "FastPlayers_Events", onPlayerEvent)
callbacks.Register("Unload", onUnload)

return FastPlayers
