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
	assert(simCtx, "playersim: createContext returned nil")
	assert(simCtx.sv_gravity, "playersim: simCtx.sv_gravity is nil")
	assert(simCtx.tickinterval, "playersim: simCtx.tickinterval is nil")
	
	local playerCtx = PredictionContext.createPlayerContext(player, lazyness or 10)
	assert(playerCtx, "playersim: createPlayerContext returned nil")
	assert(playerCtx.origin, "playersim: playerCtx.origin is nil")
	assert(playerCtx.velocity, "playersim: playerCtx.velocity is nil")
	assert(playerCtx.mins, "playersim: playerCtx.mins is nil")
	assert(playerCtx.maxs, "playersim: playerCtx.maxs is nil")
	
	-- Use new tick-based simulation
	local path, lastPos, timetable = PlayerTick.simulatePath(playerCtx, simCtx, time_seconds)
	assert(path, "playersim: PlayerTick.simulatePath returned nil path")
	assert(lastPos, "playersim: PlayerTick.simulatePath returned nil lastPos")
	assert(#path > 0, "playersim: PlayerTick.simulatePath returned empty path")
	
	return path, lastPos, timetable
end

return Run