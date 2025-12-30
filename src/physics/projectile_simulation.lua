local TRACE_HULL = engine.TraceHull
local floor = math.floor

local PhysicsEnvironment = physics.CreateEnvironment()
PhysicsEnvironment:SetGravity(Vector3(0, 0, -800))
PhysicsEnvironment:SetAirDensity(2.0)
PhysicsEnvironment:SetSimulationTimestep(1 / 66)

local GetPhysicsObject = {}
do
	GetPhysicsObject.m_mapObjects = {}
	GetPhysicsObject.m_sActiveObject = ""

	function GetPhysicsObject:Shutdown()
		self.m_sActiveObject = ""

		for sKey, pObject in pairs(self.m_mapObjects) do
			PhysicsEnvironment:DestroyObject(pObject)
		end
		self.m_mapObjects = {}
	end

	setmetatable(GetPhysicsObject, {
		__call = function(self, sRequestedObject)
			local pObject = self.m_mapObjects[sRequestedObject]
			if self.m_sActiveObject == sRequestedObject then
				return pObject
			end

			local pActiveObject = self.m_mapObjects[self.m_sActiveObject]
			if pActiveObject then
				pActiveObject:Sleep()
			end

			if not pObject and sRequestedObject:len() > 0 then
				local solid, model = physics.ParseModelByName(sRequestedObject)
				if not solid or not model then
					error(string.format('Invalid object path "%s"!', sRequestedObject))
				end

				self.m_mapObjects[sRequestedObject] =
					PhysicsEnvironment:CreatePolyObject(model, solid:GetSurfacePropName(), solid:GetObjectParameters())
				pObject = self.m_mapObjects[sRequestedObject]
			end

			self.m_sActiveObject = sRequestedObject
			pObject:Wake()
			return pObject
		end,
	})
end

local function DoBasicProjectileTrace(vecSource, vecForward, vecMins, vecMaxs, stepInterval, flagInterval)
	local resultTrace = TRACE_HULL(vecSource, vecSource + (vecForward * 10000), vecMins, vecMaxs, 100679691)
	local points = {}

	if resultTrace.startsolid then
		return resultTrace, points
	end

	local iSegments = floor((resultTrace.endpos - resultTrace.startpos):Length() / flagInterval)
	for i = 1, iSegments do
		points[#points + 1] = vecForward * (i * flagInterval) + vecSource
	end

	points[#points + 1] = resultTrace.endpos
	return resultTrace, points
end

local function DoPseudoProjectileTrace(vecSource, vecVelocity, flGravity, flDrag, vecMins, vecMaxs, stepInterval)
	local flGravity = flGravity * 400
	local vecPosition = vecSource
	local resultTrace
	local points = {}

	-- Initial point? snippet doesn't add it explicitly in loop, but TrajectoryLine:Insert adds each step.
	-- Snippet loop: i = 0.01515, 5, stepInterval

	for i = 0.01515, 5, stepInterval do
		local flScalar = (flDrag == 0) and i or ((1 - math.exp(-flDrag * i)) / flDrag)

		resultTrace = TRACE_HULL(
			vecPosition,
			Vector3(
				vecVelocity.x * flScalar + vecSource.x,
				vecVelocity.y * flScalar + vecSource.y,
				(vecVelocity.z - flGravity * i) * flScalar + vecSource.z
			),
			vecMins,
			vecMaxs,
			100679691
		)

		vecPosition = resultTrace.endpos
		points[#points + 1] = resultTrace.endpos

		if resultTrace.fraction ~= 1 then
			break
		end
	end

	return resultTrace, points
end

local function DoSimulProjectileTrace(pObject, vecMins, vecMaxs, stepInterval)
	local resultTrace
	local points = {}

	for i = 1, 330 do
		local vecStart = pObject:GetPosition()
		PhysicsEnvironment:Simulate(stepInterval)

		resultTrace = TRACE_HULL(vecStart, pObject:GetPosition(), vecMins, vecMaxs, 100679691)
		points[#points + 1] = resultTrace.endpos

		if resultTrace.fraction ~= 1 then
			break
		end

		if i == 330 then
			-- Hit end of simulation time
		end
	end

	PhysicsEnvironment:ResetSimulationClock()
	return resultTrace, points
end

return {
	PhysicsEnvironment = PhysicsEnvironment,
	GetPhysicsObject = GetPhysicsObject,
	DoBasicProjectileTrace = DoBasicProjectileTrace,
	DoPseudoProjectileTrace = DoPseudoProjectileTrace,
	DoSimulProjectileTrace = DoSimulProjectileTrace,
}
