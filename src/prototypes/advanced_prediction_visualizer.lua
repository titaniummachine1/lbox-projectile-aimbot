--[[
	Advanced Prediction Path Visualizer (prototype)
	- Faithful Source-style movement physics
	- Optional per-tick override of viewangle and wishdir (relative to view)
	- Simplified: no future wishdir prediction/Markov; holds last observed wishdir
]]

-- Config
local PREDICT_TICKS = 66
local DOT_SIZE = 4

-- Constants
local FL_ONGROUND = (1 << 0)
local IN_FORWARD = (1 << 3)
local IN_BACK = (1 << 4)
local IN_MOVELEFT = (1 << 9)
local IN_MOVERIGHT = (1 << 10)

-- Server cvars (client.GetConVar returns ok, value)
local _, sv_gravity = client.GetConVar("sv_gravity")
local _, sv_stepsize = client.GetConVar("sv_stepsize")
local _, sv_friction = client.GetConVar("sv_friction")
local _, sv_stopspeed = client.GetConVar("sv_stopspeed")
local _, sv_accelerate = client.GetConVar("sv_accelerate")
local _, sv_airaccelerate = client.GetConVar("sv_airaccelerate")

local gravity = sv_gravity or 800
local stepSize = sv_stepsize or 18
local friction = sv_friction or 4
local stopSpeed = sv_stopspeed or 100
local accelerate = sv_accelerate or 10
local airAccelerate = sv_airaccelerate or 10

-- Strafe tracking (EXACTLY like simple visualizer)
local lastVelocityAngles = {}
local strafeRates = {}

-- External per-tick overrides: tickInputs[tick] = { viewangles = EulerAngles, wishdir = Vector3 (relative to view) }
local tickInputs = nil

local DEG2RAD = math.pi / 180

-- Physics helpers
local function Accelerate(velocity, wishdir, wishspeed, accel, frametime)
	local currentspeed = velocity:Dot(wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end
	local accelspeed = accel * frametime * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end
	velocity.x = velocity.x + wishdir.x * accelspeed
	velocity.y = velocity.y + wishdir.y * accelspeed
	velocity.z = velocity.z + wishdir.z * accelspeed
end

local function GetAirSpeedCap(target)
	if target:InCond(76) then -- TFCond_Charging
		local _, tf_max_charge_speed = client.GetConVar("tf_max_charge_speed")
		return tf_max_charge_speed or 750
	end
	return 30.0 * (target:AttributeHookFloat("mod_air_control") or 1.0)
end

local function AirAccelerate(v, wishdir, wishspeed, accel, dt, surf, target)
	wishspeed = math.min(wishspeed, GetAirSpeedCap(target))
	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end
	local accelspeed = math.min(accel * wishspeed * dt * surf, addspeed)
	v.x = v.x + accelspeed * wishdir.x
	v.y = v.y + accelspeed * wishdir.y
	v.z = v.z + accelspeed * wishdir.z
end

local function CheckIsOnGround(origin, mins, maxs, index)
	local down = Vector3(origin.x, origin.y, origin.z - 18)
	local trace = engine.TraceHull(origin, down, mins, maxs, MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)
	return trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
end

local function StayOnGround(origin, mins, maxs, step_size, index)
	local vstart = Vector3(origin.x, origin.y, origin.z + 2)
	local vend = Vector3(origin.x, origin.y, origin.z - step_size)
	local trace = engine.TraceHull(vstart, vend, mins, maxs, MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)
	if trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7 then
		local delta = math.abs(origin.z - trace.endpos.z)
		if delta > 0.5 then
			origin.x = trace.endpos.x
			origin.y = trace.endpos.y
			origin.z = trace.endpos.z
			return true
		end
	end
	return false
end

local function Friction(velocity, is_on_ground, frametime)
	local speed = velocity:LengthSqr()
	if speed < 0.01 then
		return
	end
	local drop = 0
	if is_on_ground then
		local control = speed < stopSpeed and stopSpeed or speed
		drop = drop + control * friction * frametime
	end
	local newspeed = speed - drop
	if newspeed ~= speed then
		newspeed = newspeed / speed
		velocity.x = velocity.x * newspeed
		velocity.y = velocity.y * newspeed
		velocity.z = velocity.z * newspeed
	end
end

local function ClipVelocity(velocity, normal, overbounce)
	local backoff = velocity:Dot(normal) * overbounce
	velocity.x = velocity.x - normal.x * backoff
	velocity.y = velocity.y - normal.y * backoff
	velocity.z = velocity.z - normal.z * backoff
	if math.abs(velocity.x) < 0.01 then
		velocity.x = 0
	end
	if math.abs(velocity.y) < 0.01 then
		velocity.y = 0
	end
	if math.abs(velocity.z) < 0.01 then
		velocity.z = 0
	end
end

local function TryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)
	local MAX_CLIP_PLANES = 5
	local time_left = tickinterval
	local planes = {}
	local numplanes = 0

	for bumpcount = 0, 3 do
		if time_left <= 0 then
			break
		end

		local end_pos = Vector3(
			origin.x + velocity.x * time_left,
			origin.y + velocity.y * time_left,
			origin.z + velocity.z * time_left
		)

		local trace = engine.TraceHull(origin, end_pos, mins, maxs, MASK_PLAYERSOLID, function(ent)
			return ent:GetIndex() ~= index
		end)

		if trace.fraction > 0 then
			origin.x = trace.endpos.x
			origin.y = trace.endpos.y
			origin.z = trace.endpos.z
			numplanes = 0
		end

		if trace.fraction == 1 then
			break
		end

		time_left = time_left - time_left * trace.fraction

		if trace.plane and numplanes < MAX_CLIP_PLANES then
			planes[numplanes] = trace.plane
			numplanes = numplanes + 1
		end

		if trace.plane then
			if trace.plane.z > 0.7 and velocity.z < 0 then
				velocity.z = 0
			end

			local i = 0
			while i < numplanes do
				ClipVelocity(velocity, planes[i], 1.0)

				local j = 0
				while j < numplanes do
					if j ~= i then
						local dot = velocity:Dot(planes[j])
						if dot < 0 then
							break
						end
					end
					j = j + 1
				end

				if j == numplanes then
					break
				end

				i = i + 1
			end

			if i == numplanes then
				if numplanes >= 2 then
					local dir = Vector3(
						planes[0].y * planes[1].z - planes[0].z * planes[1].y,
						planes[0].z * planes[1].x - planes[0].x * planes[1].z,
						planes[0].x * planes[1].y - planes[0].y * planes[1].x
					)
					local d = dir:Dot(velocity)
					velocity.x = dir.x * d
					velocity.y = dir.y * d
					velocity.z = dir.z * d
				end

				local dot = velocity:Dot(planes[0])
				if dot < 0 then
					velocity.x = 0
					velocity.y = 0
					velocity.z = 0
					break
				end
			end
		else
			break
		end
	end

	return origin
end

-- Tracking: EXACTLY like simple visualizer
local function UpdateTracking(entity)
	if not entity then
		return
	end

	local vel = entity:EstimateAbsVelocity()
	if not vel or vel:Length() < 10 then
		return
	end

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

-- Public setter for per-tick inputs
function SetPredictionInputs(inputs)
	-- inputs: array indexed from 1..N { viewangles = EulerAngles?, wishdir = Vector3? (relative to view) }
	tickInputs = inputs
end

-- Prediction
local function PredictPath(player, ticks)
	assert(player, "PredictPath: nil player")

	local path = {}
	local velocity = player:GetPropVector("localdata", "m_vecVelocity[0]") or player:EstimateAbsVelocity()
	local origin = player:GetAbsOrigin() + Vector3(0, 0, 1)

	if not velocity or velocity:Length() <= 0.01 then
		path[0] = origin
		return path
	end

	local maxspeed = player:GetPropFloat("m_flMaxspeed") or 450
	local tickinterval = globals.TickInterval()
	local mins, maxs = player:GetMins(), player:GetMaxs()
	local index = player:GetIndex()

	-- Get strafe rate (matches simple visualizer)
	local strafeRate = strafeRates[index] or 0

	path[0] = Vector3(origin.x, origin.y, origin.z)
	local currentVel = Vector3(velocity.x, velocity.y, velocity.z)

	for tick = 1, ticks do
		-- Check for per-tick override
		local override = tickInputs and tickInputs[tick]
		local wishdir

		if override then
			-- If override provided, use it
			if override.viewangles and override.viewangles.y then
				local yaw = override.viewangles.y
				if override.wishdir then
					-- Wishdir relative to override yaw
					local relAngle = math.atan(override.wishdir.y, override.wishdir.x) * (180 / math.pi)
					local worldAngle = (yaw + relAngle) * DEG2RAD
					wishdir = Vector3(math.cos(worldAngle), math.sin(worldAngle), 0)
				else
					-- Default forward
					wishdir = Vector3(math.cos(yaw * DEG2RAD), math.sin(yaw * DEG2RAD), 0)
				end
			elseif override.wishdir then
				-- Wishdir provided without yaw - use current velocity yaw
				local velYaw = math.atan(currentVel.y, currentVel.x) * (180 / math.pi)
				local relAngle = math.atan(override.wishdir.y, override.wishdir.x) * (180 / math.pi)
				local worldAngle = (velYaw + relAngle) * DEG2RAD
				wishdir = Vector3(math.cos(worldAngle), math.sin(worldAngle), 0)
			end
		end

		if not wishdir then
			-- Default: rotate velocity by strafe rate (EXACTLY like simple visualizer)
			local ang = currentVel:Angles()
			ang.y = ang.y + strafeRate
			local speed = currentVel:Length()
			currentVel = ang:Forward() * speed

			-- Wishdir = normalized velocity
			local len = currentVel:Length()
			if len > 0.01 then
				wishdir = currentVel / len
			else
				wishdir = Vector3(1, 0, 0)
			end
		end

		-- Physics simulation
		local is_on_ground = CheckIsOnGround(origin, mins, maxs, index)
		Friction(currentVel, is_on_ground, tickinterval)

		if is_on_ground then
			Accelerate(currentVel, wishdir, maxspeed, accelerate, tickinterval)
			currentVel.z = 0
		else
			AirAccelerate(currentVel, wishdir, maxspeed, airAccelerate, tickinterval, 0, player)
			currentVel.z = currentVel.z - gravity * tickinterval
		end

		origin = TryPlayerMove(origin, currentVel, mins, maxs, index, tickinterval)

		if is_on_ground then
			StayOnGround(origin, mins, maxs, stepSize, index)
		end

		path[tick] = Vector3(origin.x, origin.y, origin.z)
	end

	return path
end

-- Drawing helpers
local function DrawPath(path)
	for i = 0, PREDICT_TICKS - 1 do
		local pos1 = path[i]
		local pos2 = path[i + 1]
		if not pos1 or not pos2 then
			break
		end
		local screen1 = client.WorldToScreen(pos1)
		local screen2 = client.WorldToScreen(pos2)
		if screen1 and screen2 then
			local t = i / PREDICT_TICKS
			local r = math.floor(255 * t)
			local g = math.floor(255 * (1 - t * 0.5))
			draw.Color(r, g, 0, 200)
			draw.Line(screen1[1], screen1[2], screen2[1], screen2[2])
		end
	end
end

local function DrawDots(path)
	for i = 0, PREDICT_TICKS do
		local pos = path[i]
		if not pos then
			break
		end
		local screen = client.WorldToScreen(pos)
		if screen then
			local t = i / PREDICT_TICKS
			local r = math.floor(255 * t)
			local g = math.floor(255 * (1 - t * 0.5))
			draw.Color(r, g, 0, 255)
			draw.FilledRect(
				screen[1] - DOT_SIZE / 2,
				screen[2] - DOT_SIZE / 2,
				screen[1] + DOT_SIZE / 2,
				screen[2] + DOT_SIZE / 2
			)
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

-- Callbacks
local function OnCreateMove()
	local me = entities.GetLocalPlayer()
	if not me or not me:IsAlive() then
		return
	end
	UpdateTracking(me)
end

local function OnDraw()
	local me = entities.GetLocalPlayer()
	if not me or not me:IsAlive() then
		return
	end

	-- Keep enemy yaw tracking updated
	for _, player in ipairs(entities.FindByClass("CTFPlayer")) do
		if player ~= me and player:IsAlive() then
			UpdateTracking(player)
		end
	end

	local path = PredictPath(me, PREDICT_TICKS)
	if not path then
		return
	end

	DrawPath(path)
	DrawDots(path)
end

-- API: external scripts can call SetPredictionInputs to provide per-tick overrides
_G.AdvancedPredictionVisualizer_SetInputs = SetPredictionInputs

callbacks.Unregister("CreateMove", "AdvancedPredictionVisualizer_CM")
callbacks.Unregister("Draw", "AdvancedPredictionVisualizer_Draw")
callbacks.Register("CreateMove", "AdvancedPredictionVisualizer_CM", OnCreateMove)
callbacks.Register("Draw", "AdvancedPredictionVisualizer_Draw", OnDraw)

print("[Advanced Prediction Visualizer] Loaded (prototype, per-tick overrides enabled)")
