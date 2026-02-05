local FastPlayers = {}

-- [[ 1. SAFE PRE-ALLOCATION ]]
local cachedAllPlayers = {}
local cachedEnemies = {}
local cachedTeammates = {}

-- State
local cachedLocal = nil
local cachedLocalTeam = nil
local lastHighestIndex = -1

-- Tick callback to check for entity index changes
local function onCreateMove()
	local currentHighestIndex = entities.GetHighestEntityIndex()
	if currentHighestIndex ~= lastHighestIndex then
		lastHighestIndex = currentHighestIndex
		FastPlayers.Update()
		print(currentHighestIndex)
	end
end
local function onPlayerEvent(event)
	local eventName = event:GetName()
	if
		eventName == "player_death"
		or eventName == "player_spawn"
		or eventName == "player_team"
		or eventName == "player_connect_client"
	then
		FastPlayers.Update()
		print(eventName)
	end
end

-- [[ 3. SMART UPDATE LOGIC ]]
function FastPlayers.Update()
	cachedLocal = entities.GetLocalPlayer()
	local newTeam = cachedLocal and cachedLocal:GetTeamNumber() or nil

	if newTeam ~= cachedLocalTeam then
		cachedLocalTeam = newTeam
	end

	-- Clear all cached arrays first
	for i = 1, globals.MaxClients() do
		cachedAllPlayers[i] = nil
		cachedEnemies[i] = nil
		cachedTeammates[i] = nil
	end

	-- Add valid players and populate filtered arrays
	local writeIdx = 0
	local enemyWriteIdx = 0
	local teammateWriteIdx = 0

	for _, ent in pairs(entities.FindByClass("CTFPlayer")) do
		if ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant() then
			writeIdx = writeIdx + 1
			cachedAllPlayers[writeIdx] = ent

			-- Populate filtered arrays during update
			if cachedLocalTeam then
				if ent:GetTeamNumber() == cachedLocalTeam then
					teammateWriteIdx = teammateWriteIdx + 1
					cachedTeammates[teammateWriteIdx] = ent
				else
					enemyWriteIdx = enemyWriteIdx + 1
					cachedEnemies[enemyWriteIdx] = ent
				end
			end
		end
	end
end

-- [[ GETTERS ]]

function FastPlayers.GetAll()
	return cachedAllPlayers
end

function FastPlayers.GetEnemies()
	return cachedEnemies
end

function FastPlayers.GetTeammates()
	return cachedTeammates
end

function FastPlayers.GetLocal()
	return cachedLocal
end

-- [[ CALLBACK HOOKS ]]

-- [[ CALLBACK REGISTRATION ]]
callbacks.Unregister("FireGameEvent", "FastPlayers_Events")
callbacks.Unregister("CreateMove", "FastPlayers_Update")
callbacks.Register("FireGameEvent", "FastPlayers_Events", onPlayerEvent)
callbacks.Register("CreateMove", "FastPlayers_Update", onCreateMove)

return FastPlayers
