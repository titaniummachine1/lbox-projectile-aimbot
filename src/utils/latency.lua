-- Module: latency utilities

local Latency = {}

---Gets client interpolation delay (lerp)
---@return number lerpTime
function Latency.getLerpTime()
	local _, cl_interp = client.GetConVar("cl_interp")
	local _, cl_interp_ratio = client.GetConVar("cl_interp_ratio")
	local _, cl_updaterate = client.GetConVar("cl_updaterate")

	return math.max(cl_interp or 0, (cl_interp_ratio or 1) / (cl_updaterate or 66))
end

---Gets one-way outgoing latency (client -> server)
---@return number outgoingLatency
function Latency.getOutgoingLatency()
	local netchannel = clientstate.GetNetChannel()
	if not netchannel then
		return 0
	end

	return netchannel:GetLatency(E_Flows.FLOW_OUTGOING) or 0
end

---Gets latency adjusted prediction time
---@param distance number Distance to target
---@param projectileSpeed number Projectile velocity
---@return number adjustedTime
function Latency.getAdjustedPredictionTime(distance, projectileSpeed)
	assert(projectileSpeed > 0, "Latency: projectileSpeed must be > 0")

	local flightTime = distance / projectileSpeed
	local outgoing = Latency.getOutgoingLatency()
	local lerp = Latency.getLerpTime()

	-- Predict into server-time: projectile spawns after outgoing delay;
	-- target origin we read is typically behind by lerp (interpolation)
	return flightTime + outgoing + lerp
end

return Latency
