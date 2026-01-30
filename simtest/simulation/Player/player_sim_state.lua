---@module player_sim_state
---Cached player simulation state management
---Caches static data (mins, maxs, index) per entity
---Caches cvars globally (updated every 1 second)
---Maintains per-player dynamic state between frames

local GameConstants = require("constants.game_constants")

local PlayerSimState = {}

-- Cache of simulation states per entity index
local stateCache = {}

-- Simulation context (cvars) - cached globally since they rarely change
local globalSimCtx = nil
local lastCvarUpdate = 0
local CVAR_UPDATE_INTERVAL = 1.0 -- Update cvars every 1 second

---@class SimState
---@field index integer
---@field entity Entity
---@field mins Vector3
---@field maxs Vector3
---@field stepheight number
---@field origin Vector3
---@field velocity Vector3
---@field yaw number
---@field maxspeed number
---@field yawDeltaPerTick number
---@field relativeWishDir table
---@field onGround boolean
---@field lastUpdateTime number

local function getOrCreateSimContext()
	local now = globals.RealTime()
	if not globalSimCtx or (now - lastCvarUpdate) > CVAR_UPDATE_INTERVAL then
		globalSimCtx = {
			tickinterval = globals.TickInterval() or GameConstants.TICK_INTERVAL,
			sv_gravity = client.GetConVar("sv_gravity") or GameConstants.SV_GRAVITY,
			sv_friction = client.GetConVar("sv_friction") or GameConstants.SV_FRICTION,
			sv_stopspeed = client.GetConVar("sv_stopspeed") or GameConstants.SV_STOPSPEED,
			sv_accelerate = client.GetConVar("sv_accelerate") or GameConstants.SV_ACCELERATE,
			sv_airaccelerate = client.GetConVar("sv_airaccelerate") or GameConstants.SV_AIRACCELERATE,
			curtime = now,
		}
		lastCvarUpdate = now
	else
		-- Just update curtime
		globalSimCtx.curtime = now
	end
	return globalSimCtx
end

---Initialize or get cached simulation state for entity
---@param entity Entity
---@return SimState|nil
function PlayerSimState.getOrCreate(entity)
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return nil
	end

	local index = entity:GetIndex()
	local now = globals.RealTime()

	local state = stateCache[index]

	-- Create new state if doesn't exist
	if not state then
		local mins, maxs = entity:GetMins(), entity:GetMaxs()
		if not mins or not maxs then
			return nil
		end

		state = {
			index = index,
			entity = entity,
			mins = mins,
			maxs = maxs,
			stepheight = 18,
			origin = Vector3(0, 0, 0),
			velocity = Vector3(0, 0, 0),
			yaw = 0,
			maxspeed = 320,
			yawDeltaPerTick = 0,
			relativeWishDir = { x = 0, y = 0, z = 0 },
			onGround = false,
			lastUpdateTime = 0,
		}
		stateCache[index] = state
	end

	-- Update dynamic data
	local origin = entity:GetAbsOrigin()
	local velocity = entity:EstimateAbsVelocity()

	if origin and velocity then
		-- Add small offset to prevent ground clipping
		state.origin.x = origin.x
		state.origin.y = origin.y
		state.origin.z = origin.z + 1

		state.velocity.x = velocity.x
		state.velocity.y = velocity.y
		state.velocity.z = velocity.z

		local maxspeed = entity:GetPropFloat("m_flMaxspeed")
		if maxspeed and maxspeed > 0 then
			state.maxspeed = maxspeed
		end

		-- Get yaw
		local localPlayer = entities.GetLocalPlayer()
		if localPlayer and index == localPlayer:GetIndex() then
			local angles = engine.GetViewAngles()
			if angles then
				state.yaw = angles.y
			end
		else
			local eyeYaw = entity:GetPropFloat("m_angEyeAngles[1]")
			if eyeYaw then
				state.yaw = eyeYaw
			end
		end

		state.lastUpdateTime = now
	end

	return state
end

---Get simulation context (cvars)
---@return table
function PlayerSimState.getSimContext()
	return getOrCreateSimContext()
end

---Clear cached state for entity
---@param index integer
function PlayerSimState.clear(index)
	stateCache[index] = nil
end

---Clear all cached states
function PlayerSimState.clearAll()
	stateCache = {}
end

---Cleanup stale states
function PlayerSimState.cleanup()
	local players = entities.FindByClass("CTFPlayer")
	local activeIndices = {}
	for _, ply in ipairs(players) do
		if ply and ply:IsValid() then
			activeIndices[ply:GetIndex()] = true
		end
	end

	for index, _ in pairs(stateCache) do
		if not activeIndices[index] then
			stateCache[index] = nil
		end
	end
end

return PlayerSimState
