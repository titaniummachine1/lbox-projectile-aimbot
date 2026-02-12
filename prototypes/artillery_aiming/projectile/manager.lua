local Manager = {}

local Config = require("config")
local Simulation = require("projectile/simulation")
local Kalman = require("kalman")
local Visuals = require("visuals")

local tracked = {}

function Manager.Startup()
	tracked = {}
end

function Manager.Shutdown()
	tracked = {}
end

function Manager.Update()
	if not Config.visual.live_projectiles.enabled then
		return
	end

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then
		return
	end

	-- Mark all as not seen
	for _, proj in pairs(tracked) do
		proj.seenThisFrame = false
	end

	-- Iterate standard projectile classes
	local classes = {
		"CTFProjectile_Rocket",
		"tf_projectile_rocket",
		"CTFGrenadePipebombProjectile",
		"CTFProjectile_Jar",
		"CTFProjectile_Flare",
	}

	for _, className in ipairs(classes) do
		local ents = entities.FindByClass(className)
		for _, ent in pairs(ents) do
			if ent:IsValid() and not ent:IsDormant() then
				local idx = ent:GetIndex()
				local proj = tracked[idx]

				if not proj then
					-- Initialize new projectile tracking
					proj = {
						entity = ent,
						lastPos = ent:GetAbsOrigin(),
						lastVel = ent:EstimateAbsVelocity(),
						radius = Simulation.resolveRadius(ent),
						color = Config.visual.polygon.live_color or { 255, 255, 255, 255 },
						filter = Kalman.VectorKalman.new(3, 0.001, Vector3(0, 0, 0)),
						pointCount = 0,
					}
					tracked[idx] = proj
				end

				proj.seenThisFrame = true
				proj.origin = ent:GetAbsOrigin()

				-- Prediction
				local path, count, impactPos, impactPlane = Simulation.predict(ent, 150)
				proj.predictedPath = path
				proj.impactPos = impactPos
				proj.impactPlane = impactPlane
			end
		end
	end

	-- Cleanup
	local toRemove = {}
	for idx, proj in pairs(tracked) do
		if not proj.seenThisFrame then
			table.insert(toRemove, idx)
		end
	end
	for _, idx in ipairs(toRemove) do
		tracked[idx] = nil
	end
end

function Manager.Draw()
	if not Config.visual.live_projectiles.enabled then
		return
	end

	for _, proj in pairs(tracked) do
		if proj.predictedPath then
			-- Call our new visual hook
			if Visuals.drawTrackerTrajectory then
				Visuals.drawTrackerTrajectory(proj)
			end
		end
	end
end

return Manager
