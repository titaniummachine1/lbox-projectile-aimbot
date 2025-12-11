--[[
    Prediction Path Visualizer
    Shows predicted movement path for local player
]]

-- Config
local PREDICT_TICKS = 120
local DOT_SIZE = 4

-- Constants
local FL_ONGROUND = (1 << 0)

-- Get server cvars
local sv_gravity = client.GetConVar("sv_gravity")
local sv_stepsize = client.GetConVar("sv_stepsize")
local sv_friction = client.GetConVar("sv_friction")
local sv_stopspeed = client.GetConVar("sv_stopspeed")

local gravity = sv_gravity or 800
local stepSize = sv_stepsize or 18
local friction = sv_friction or 4
local stopSpeed = sv_stopspeed or 100

-- TF2 class max speeds
local MAX_SPEEDS = {
	[1] = 400, -- Scout
	[2] = 300, -- Sniper
	[3] = 240, -- Soldier
	[4] = 280, -- Demoman
	[5] = 320, -- Medic
	[6] = 230, -- Heavy
	[7] = 300, -- Pyro
	[8] = 300, -- Spy
	[9] = 300, -- Engineer
}

-- Check if entity is on ground via flags
local function IsEntityOnGround(entity)
	local flags = entity:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

-- Ground check via trace
local function IsOnGroundTrace(pos, mins, maxs)
	local down = pos - Vector3(0, 0, 2)
	local trace = engine.TraceHull(pos, down, mins, maxs, MASK_PLAYERSOLID)
	return trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
end

-- Strafe tracking
local lastVelocityAngles = {}
local strafeRates = {}

local function UpdateStrafeTracking(entity)
	if not entity then
		return
	end

	local vel = entity:EstimateAbsVelocity()
	if not vel or vel:Length() < 10 then
		return
	end -- Ignore if not moving

	local currentAngle = vel:Angles()
	local idx = entity:GetIndex()

	if lastVelocityAngles[idx] then
		local angleDelta = currentAngle.y - lastVelocityAngles[idx].y

		-- Normalize angle delta to -180 to 180
		while angleDelta > 180 do
			angleDelta = angleDelta - 360
		end
		while angleDelta < -180 do
			angleDelta = angleDelta + 360
		end

		strafeRates[idx] = (strafeRates[idx] or 0) * 0.8 + angleDelta * 0.2
	end

	lastVelocityAngles[idx] = currentAngle
end

-- Update strafe tracking every frame
local function OnCreateMove(cmd)
	local me = entities.GetLocalPlayer()
	if me and me:IsAlive() then
		UpdateStrafeTracking(me)
	end
end

-- Predict movement
local function PredictPath(entity, ticks)
	assert(entity, "PredictPath: nil entity")

	local mins, maxs = entity:GetMins(), entity:GetMaxs()
	local vUp = Vector3(0, 0, 1)
	local vStep = Vector3(0, 0, stepSize)

	local positions = { [0] = entity:GetAbsOrigin() }
	local vel = entity:EstimateAbsVelocity()

	if not vel then
		return positions
	end

	local class = entity:GetPropInt("m_iClass")
	local maxSpeed = MAX_SPEEDS[class] or 300
	local onGround = IsEntityOnGround(entity)

	for tick = 1, ticks do
		local pos = positions[tick - 1]

		-- Apply strafe angle
		local strafeRate = strafeRates[entity:GetIndex()]
		if strafeRate then
			local ang = vel:Angles()
			ang.y = ang.y + strafeRate
			vel = ang:Forward() * vel:Length()
		end

		-- Calculate new position
		local newPos = pos + vel * globals.TickInterval()

		-- Forward collision
		local trace = engine.TraceHull(pos + vStep, newPos + vStep, mins, maxs, MASK_PLAYERSOLID)

		if trace.fraction < 1 then
			local normal = trace.plane
			local angle = math.deg(math.acos(normal:Dot(vUp)))

			local dot = vel:Dot(normal)
			vel = vel - normal * dot

			newPos.x = trace.endpos.x
			newPos.y = trace.endpos.y
		end

		-- Ground collision
		local downStep = onGround and vStep or Vector3()
		local groundTrace = engine.TraceHull(newPos + vStep, newPos - downStep, mins, maxs, MASK_PLAYERSOLID)

		if groundTrace.fraction < 1 then
			local normal = groundTrace.plane
			local angle = math.deg(math.acos(normal:Dot(vUp)))

			if angle < 55 then
				newPos = groundTrace.endpos
				onGround = true
			else
				local dot = vel:Dot(normal)
				vel = vel - normal * dot
				onGround = true
			end
		else
			onGround = false
		end

		-- Gravity
		if not onGround then
			vel.z = vel.z - gravity * globals.TickInterval()
		end

		-- Clamp speed
		local speed = vel:Length()
		if speed > maxSpeed then
			local scale = maxSpeed / speed
			vel.x = vel.x * scale
			vel.y = vel.y * scale
		end

		onGround = IsOnGroundTrace(newPos, mins, maxs)
		positions[tick] = newPos
	end

	return positions
end

-- Draw callback
local function OnDraw()
	local me = entities.GetLocalPlayer()
	if not me or not me:IsAlive() then
		return
	end

	-- Predict path
	local path = PredictPath(me, PREDICT_TICKS)
	if not path then
		return
	end

	-- Draw path
	-- First pass: draw lines connecting all points
	for i = 0, PREDICT_TICKS - 1 do
		local pos1 = path[i]
		local pos2 = path[i + 1]
		if not pos1 or not pos2 then
			break
		end

		local screen1 = client.WorldToScreen(pos1)
		local screen2 = client.WorldToScreen(pos2)

		if screen1 and screen2 then
			-- Calculate color for this segment (green -> yellow -> red)
			local t = i / PREDICT_TICKS
			local r = math.floor(255 * t)
			local g = math.floor(255 * (1 - t * 0.5))

			draw.Color(r, g, 0, 200)
			draw.Line(screen1[1], screen1[2], screen2[1], screen2[2])
		end
	end

	-- Second pass: draw dots on top of lines
	for i = 0, PREDICT_TICKS do
		local pos = path[i]
		if not pos then
			break
		end

		local screen = client.WorldToScreen(pos)
		if screen then
			-- Calculate color (green -> yellow -> red)
			local t = i / PREDICT_TICKS
			local r = math.floor(255 * t)
			local g = math.floor(255 * (1 - t * 0.5))

			-- Draw dot with outline
			draw.Color(r, g, 0, 255)
			draw.FilledRect(
				screen[1] - DOT_SIZE / 2,
				screen[2] - DOT_SIZE / 2,
				screen[1] + DOT_SIZE / 2,
				screen[2] + DOT_SIZE / 2
			)

			-- Draw outline for better visibility
			draw.Color(0, 0, 0, 255)
			draw.OutlinedRect(
				screen[1] - DOT_SIZE / 2,
				screen[2] - DOT_SIZE / 2,
				screen[1] + DOT_SIZE / 2,
				screen[2] + DOT_SIZE / 2
			)
		end
	end
end

-- Register callbacks
callbacks.Unregister("CreateMove", "PredictionVisualizer_Strafe")
callbacks.Unregister("Draw", "PredictionVisualizer")
callbacks.Register("CreateMove", "PredictionVisualizer_Strafe", OnCreateMove)
callbacks.Register("Draw", "PredictionVisualizer", OnDraw)

print("[Prediction Visualizer] Loaded - Drawing " .. PREDICT_TICKS .. " tick path with strafe prediction")
