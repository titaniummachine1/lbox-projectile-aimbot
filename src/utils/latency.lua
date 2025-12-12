-- Module: latency utilities

local Latency = {}

---Gets full network latency compensation value
---Includes: outgoing + incoming latency + lerp time
---@return number totalLatency
function Latency.getFullLatency()
	local netchannel = clientstate.GetNetChannel()
	if not netchannel then
		return 0
	end

	-- Get round-trip latency
	local outgoing = netchannel:GetLatency(E_Flows.FLOW_OUTGOING)
	local incoming = netchannel:GetLatency(E_Flows.FLOW_INCOMING)

	-- Get lerp time (interpolation delay)
	local _, cl_interp = client.GetConVar("cl_interp")
	local _, cl_interp_ratio = client.GetConVar("cl_interp_ratio")
	local _, cl_updaterate = client.GetConVar("cl_updaterate")

	-- Calculate lerp: max(cl_interp, cl_interp_ratio / cl_updaterate)
	local lerpTime = math.max(cl_interp or 0, (cl_interp_ratio or 1) / (cl_updaterate or 66))

	-- Total compensation = round-trip + lerp
	return outgoing + incoming + lerpTime
end

---Gets latency adjusted prediction time
---@param distance number Distance to target
---@param projectileSpeed number Projectile velocity
---@return number adjustedTime
function Latency.getAdjustedPredictionTime(distance, projectileSpeed)
	assert(projectileSpeed > 0, "Latency: projectileSpeed must be > 0")

	local flightTime = distance / projectileSpeed
	local netLatency = Latency.getFullLatency()

	-- Aim further into future to compensate for server spawn delay
	return flightTime + netLatency
end

return Latency

