local Config = require("config")

local PhysicsEnv = {}
PhysicsEnv.__index = PhysicsEnv

function PhysicsEnv:new()
	assert(physics and physics.CreateEnvironment, "PhysicsEnv:new: physics API not available")
	local env = physics.CreateEnvironment()
	assert(env, "PhysicsEnv:new: failed to create physics environment")
	env:SetGravity(Vector3(0, 0, -Config.physics.sticky_gravity))
	env:SetAirDensity(2.0)
	env:SetSimulationTimestep(1 / 66)
	self = setmetatable({
		env = env,
		objects = {},
		activeKey = "",
	}, PhysicsEnv)
	return self
end

function PhysicsEnv:getObject(modelPath)
	assert(modelPath and #modelPath > 0, "PhysicsEnv:getObject: modelPath required")

	local obj = self.objects[modelPath]
	if self.activeKey == modelPath then
		return obj
	end

	local activeObj = self.objects[self.activeKey]
	if activeObj then
		activeObj:Sleep()
	end

	if not obj then
		local solid, model = physics.ParseModelByName(modelPath)
		if not solid or not model then
			print("[ArtilleryAiming] Failed to parse model: " .. modelPath)
			return nil
		end

		obj = self.env:CreatePolyObject(model, solid:GetSurfacePropName(), solid:GetObjectParameters())
		if not obj then
			print("[ArtilleryAiming] Failed to create physics object: " .. modelPath)
			return nil
		end

		self.objects[modelPath] = obj
	end

	self.activeKey = modelPath
	obj:Wake()
	return obj
end

function PhysicsEnv:simulate(dt)
	self.env:Simulate(dt)
end

function PhysicsEnv:reset()
	self.env:ResetSimulationClock()
end

function PhysicsEnv:destroy()
	if not self.env then
		return
	end
	self.activeKey = ""
	for _, obj in pairs(self.objects) do
		if obj then
			self.env:DestroyObject(obj)
		end
	end
	self.objects = {}
	physics.DestroyEnvironment(self.env)
	self.env = nil
end

local instance = nil

local PhysicsEnvModule = {}

function PhysicsEnvModule.get()
	if not instance then
		instance = PhysicsEnv:new()
	end
	return instance
end

function PhysicsEnvModule.destroy()
	if instance then
		instance:destroy()
		instance = nil
	end
end

return PhysicsEnvModule
