-- Imports
local PredictionContext = require("core.prediction_context")
local PlayerTick = require("core.player_tick")

---Backward-compatible wrapper using new tick-based architecture
---@param player Entity
---@param time_seconds number
---@param lazyness number
---@return Vector3[], Vector3, number[]
local function Run(player, time_seconds, lazyness)
	assert(player, "playersim: player is nil")
	assert(time_seconds, "playersim: time_seconds is nil")
	
	-- Create contexts using new architecture
	local simCtx = PredictionContext.createContext()
	local playerCtx = PredictionContext.createPlayerContext(player, lazyness or 10)
	
	-- Use new tick-based simulation
	return PlayerTick.simulatePath(playerCtx, simCtx, time_seconds)
end

return Run