local Simulation = {}

local Config = require("config")
local PhysicsEnvModule = require("physics_env")
local Utils = require("utils")

local TRACE_MASK = Config.TRACE_MASK or 0x4600400B
local GRAVITY = 800

local PROJECTILE_CLASSES = {
	CTFProjectile_Rocket = { radius = 146, speed = 1100, gravity = 0, drag = 0 },
	CTFProjectile_HealingBolt = { radius = 0, speed = 2400, gravity = 0.3, drag = 0 },
	CTFProjectile_Arrow = { radius = 10, speed = 2600, gravity = 0.3, drag = 0 },
	tf_projectile_rocket = { radius = 146, speed = 1100, gravity = 0, drag = 0 },
	CTFGrenadePipebombProjectile = { radius = 146, speed = 1216, gravity = 1.0, drag = 0.0, usePhysics = true },
	CTFProjectile_Jar = { radius = 200, speed = 1021, gravity = 1.0, drag = 0.0, usePhysics = false },
	CTFProjectile_Flare = { radius = 110, speed = 2000, gravity = 0.3, drag = 0.0 },
}

function Simulation.resolveRadius(entity)
	if not entity or not entity:IsValid() then
		return 146
	end
	local class = entity:GetClass()
	local velocity = entity:EstimateAbsVelocity()
	local speed = velocity:Length()

	if class == "CTFProjectile_Rocket" or class == "tf_projectile_rocket" then
		if speed > 1800 then
			return 44
		end
		return 146
	elseif class == "CTFGrenadePipebombProjectile" then
		if speed > 1480 then
			return 110
		end
		return 146
	elseif class == "CTFProjectile_Jar" then
		return 200
	end

	return 146
end

function Simulation.simulateMath(projectile, ticks, gravityScale, drag)
	local pos = projectile.origin
	local vel = projectile.velocity
	local positions = { pos }
	local interval = Config.computed.trace_interval or (1 / 66)
	local effectiveGravity = GRAVITY * (gravityScale or 1)

	for i = 1, ticks do
		-- Physics update
		if drag and drag > 0 then
			vel = vel * (1 - drag * interval)
		end
		vel = vel - Vector3(0, 0, effectiveGravity * interval)

		local nextPos = pos + (vel * interval)
		local tr = engine.TraceLine(pos, nextPos, TRACE_MASK)

		table.insert(positions, tr.endpos)
		if tr.fraction < 1 then
			return positions, #positions, tr.endpos, tr.plane
		end
		pos = nextPos
	end

	return positions, #positions, nil, nil
end

function Simulation.simulatePhysics(projectile, ticks)
	local pEnv = PhysicsEnvModule.get()
	if not pEnv then
		return Simulation.simulateMath(projectile, ticks, 1, 0)
	end

	local modelPath = "models/weapons/w_models/w_grenade_grenadelauncher.mdl"
	if projectile.isSticky then
		modelPath = "models/weapons/w_models/w_stickybomb.mdl"
	end

	local obj = pEnv:getObject(modelPath)
	if not obj then
		return Simulation.simulateMath(projectile, ticks, 1, 0)
	end

	obj:SetPosition(projectile.origin, projectile.velocity:Angles(), true)
	obj:SetVelocity(projectile.velocity, Vector3(0, 0, 0))
	obj:Wake()

	local positions = { projectile.origin }
	local interval = Config.computed.trace_interval or (1 / 66)
	local impactPos, impactPlane = nil, nil

	for i = 1, ticks do
		pEnv:simulate(interval)
		local newPos = obj:GetPosition()
		if not newPos then
			break
		end

		table.insert(positions, newPos)

		-- Check for impact
		local tr = engine.TraceLine(projectile.origin, newPos, TRACE_MASK)
		if tr.fraction < 1 then
			impactPos = tr.endpos
			impactPlane = tr.plane
			break
		end

		projectile.origin = newPos
	end

	return positions, #positions, impactPos, impactPlane
end

function Simulation.predict(entity, ticks)
	if not entity or not entity:IsValid() then
		return {}, 0, nil, nil
	end

	local origin = entity:GetAbsOrigin()
	local velocity = entity:EstimateAbsVelocity()
	local class = entity:GetClass()

	local projectile = {
		origin = origin,
		velocity = velocity,
		isSticky = class == "CTFGrenadePipebombProjectile"
	}

	local classInfo = PROJECTILE_CLASSES[class]
	if not classInfo then
		return Simulation.simulateMath(projectile, ticks, 1, 0)
	end

	if classInfo.usePhysics then
		return Simulation.simulatePhysics(projectile, ticks)
	else
		return Simulation.simulateMath(projectile, ticks, classInfo.gravity, classInfo.drag)
	end
end

return Simulation
