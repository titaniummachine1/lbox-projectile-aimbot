--[[
	Advanced Prediction Path Visualizer (prototype)
	- Tick-by-tick Source-style-ish movement simulation (collision + ground snap)
	- Yaw seed: real eye/view yaw (local player view)
	- Yaw delta per tick: derived from velocity heading changes (EMA), frozen during simulation
	- Wishdir: held constant relative-to-yaw (cmd when available; else motion-derived)
]]

-- Config
local PREDICT_TICKS = 66
local DOT_SIZE = 4
local USE_CMD_WISHDIR = false -- set true to drive sim with current input; false to test guessed/stable wishdir

-- Constants
local FL_ONGROUND = (1 << 0)
local IN_FORWARD = (1 << 3)
local IN_BACK = (1 << 4)
local IN_MOVELEFT = (1 << 9)
local IN_MOVERIGHT = (1 << 10)

local DEG2RAD = math.pi / 180
local RAD2DEG = 180 / math.pi

-- Server cvars (client.GetConVar returns ok, value)
local function getConVarNumber(name, fallback)
	assert(name, "getConVarNumber: name is nil")

	local ok, value = client.GetConVar(name)
	if ok and type(value) == "number" then
		return value
	end

	return fallback
end

local gravity = getConVarNumber("sv_gravity", 800)
local stepSize = getConVarNumber("sv_stepsize", 18)
local friction = getConVarNumber("sv_friction", 4)
local stopSpeed = getConVarNumber("sv_stopspeed", 100)
local accelerate = getConVarNumber("sv_accelerate", 10)
local airAccelerate = getConVarNumber("sv_airaccelerate", 10)

-- Local constants / utilities -----

local function normalizeAngle(angle)
	assert(type(angle) == "number", "normalizeAngle: angle must be a number")
	return ((angle + 180) % 360) - 180
end

local function length2D(vec)
	assert(vec, "length2D: vec is nil")
	return math.sqrt(vec.x * vec.x + vec.y * vec.y)
end

local function normalize2DInPlace(vec)
	assert(vec, "normalize2DInPlace: vec is nil")

	local len = length2D(vec)
	if len <= 0.0001 then
		vec.x, vec.y, vec.z = 0, 0, 0
		return 0
	end

	vec.x = vec.x / len
	vec.y = vec.y / len
	vec.z = 0
	return len
end

local function dot3(vecA, vecB)
	assert(vecA, "dot3: vecA is nil")
	assert(vecB, "dot3: vecB is nil")
	return (vecA.x * vecB.x) + (vecA.y * vecB.y) + (vecA.z * vecB.z)
end

local function normalize3DInPlace(vec)
	assert(vec, "normalize3DInPlace: vec is nil")

	local len = math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
	if len <= 0.0001 then
		vec.x, vec.y, vec.z = 0, 0, 0
		return 0
	end

	vec.x = vec.x / len
	vec.y = vec.y / len
	vec.z = vec.z / len
	return len
end

local function copyVector3(dest, src)
	assert(dest, "copyVector3: dest is nil")
	assert(src, "copyVector3: src is nil")
	dest.x = src.x
	dest.y = src.y
	dest.z = src.z
end

local function tryGetYaw(anyAngles)
	if anyAngles == nil then
		return nil
	end

	local t = type(anyAngles)
	if t == "number" then
		return anyAngles
	end
	if t == "table" then
		return anyAngles.yaw or anyAngles.y or anyAngles[2]
	end

	-- userdata/cdata: safest to pcall for field access
	local ok, val = pcall(function()
		return anyAngles.yaw
	end)
	if ok and type(val) == "number" then
		return val
	end

	ok, val = pcall(function()
		return anyAngles.y
	end)
	if ok and type(val) == "number" then
		return val
	end

	ok, val = pcall(function()
		return anyAngles[2]
	end)
	if ok and type(val) == "number" then
		return val
	end

	return nil
end

local function getYawBasis(yaw)
	assert(type(yaw) == "number", "getYawBasis: yaw must be a number")

	-- Use engine-provided basis vectors to avoid left/right sign mistakes.
	local angles = EulerAngles(0, yaw, 0)
	local forward, right = vector.AngleVectors(angles)
	assert(forward and right, "getYawBasis: vector.AngleVectors returned nil")

	forward.z = 0
	right.z = 0
	normalize2DInPlace(forward)
	normalize2DInPlace(right)

	return forward, right
end

-- Convert world-space wish direction to yaw-relative (forward/right basis)
local function worldToRelativeWishDir(worldWishDir, yaw)
	assert(worldWishDir, "worldToRelativeWishDir: worldWishDir is nil")
	assert(type(yaw) == "number", "worldToRelativeWishDir: yaw must be a number")

	local forward, right = getYawBasis(yaw)
	local relX = dot3(worldWishDir, forward)
	local relY = dot3(worldWishDir, right)
	return Vector3(relX, relY, 0)
end

-- Convert yaw-relative wish direction (forward/right basis) to world-space
local function relativeToWorldWishDir(relWishDir, yaw)
	assert(relWishDir, "relativeToWorldWishDir: relWishDir is nil")
	assert(type(yaw) == "number", "relativeToWorldWishDir: yaw must be a number")

	local forward, right = getYawBasis(yaw)
	local worldX = forward.x * relWishDir.x + right.x * relWishDir.y
	local worldY = forward.y * relWishDir.x + right.y * relWishDir.y
	return Vector3(worldX, worldY, 0)
end

-- Private helpers -----

local StrafeTracker = {}
StrafeTracker.__index = StrafeTracker

function StrafeTracker.new()
	local self = setmetatable({}, StrafeTracker)
	self.lastEyeYaw = {} -- idx -> yaw degrees
	self.lastVelocityYaw = {} -- idx -> yaw degrees
	self.yawDeltaPerTick = {} -- idx -> deg/tick (EMA)
	return self
end

local function getEntityEyeYaw(entity)
	assert(entity, "getEntityEyeYaw: entity is nil")

	-- Some builds expose direct eye yaw property
	local eyeYaw = entity:GetPropFloat("m_angEyeAngles[1]")
	if type(eyeYaw) == "number" then
		return eyeYaw
	end

	-- Some builds expose m_angEyeAngles as vector
	if entity.GetPropVector and type(entity.GetPropVector) == "function" then
		local eyeVec = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles")
		if eyeVec and type(eyeVec.y) == "number" then
			return eyeVec.y
		end
	end

	return nil
end

local function getCmdViewYaw(cmd)
	assert(cmd, "getCmdViewYaw: cmd is nil")

	if not (cmd.GetViewAngles and type(cmd.GetViewAngles) == "function") then
		return nil
	end

	-- Many environments return (pitch, yaw, roll). Take yaw explicitly.
	local _, yaw = cmd:GetViewAngles()
	if type(yaw) == "number" then
		return yaw
	end

	-- Fallback: some return a single EulerAngles/table object.
	local angles = cmd:GetViewAngles()
	return tryGetYaw(angles)
end

local function getLocalViewYaw(cmd)
	if cmd then
		local cmdYaw = getCmdViewYaw(cmd)
		if type(cmdYaw) == "number" then
			return cmdYaw
		end
	end

	local viewAngles = engine.GetViewAngles()
	return tryGetYaw(viewAngles)
end

local function pickRelativeWishDirFromCmd(fwd, side, stable, prev)
	assert(type(fwd) == "number", "pickRelativeWishDirFromCmd: fwd must be a number")
	assert(type(side) == "number", "pickRelativeWishDirFromCmd: side must be a number")

	local rel1 = Vector3(fwd, side, 0)
	if normalize2DInPlace(rel1) <= 0 then
		return nil
	end

	-- If we have any reference direction, pick the best sign combination.
	local ref = stable or prev
	if not ref then
		return rel1
	end

	local best = rel1
	local bestDot = dot3(rel1, ref)

	local rel2 = Vector3(fwd, -side, 0)
	if normalize2DInPlace(rel2) > 0 then
		local d = dot3(rel2, ref)
		if d > bestDot then
			best, bestDot = rel2, d
		end
	end

	local rel3 = Vector3(-fwd, side, 0)
	if normalize2DInPlace(rel3) > 0 then
		local d = dot3(rel3, ref)
		if d > bestDot then
			best, bestDot = rel3, d
		end
	end

	local rel4 = Vector3(-fwd, -side, 0)
	if normalize2DInPlace(rel4) > 0 then
		local d = dot3(rel4, ref)
		if d > bestDot then
			best, bestDot = rel4, d
		end
	end

	return best
end

function StrafeTracker.updateEyeYaw(self, entity, cmd)
	assert(self, "StrafeTracker.updateEyeYaw: self is nil")
	assert(entity, "StrafeTracker.updateEyeYaw: entity is nil")

	local idx = entity:GetIndex()
	assert(idx, "StrafeTracker.updateEyeYaw: idx is nil")

	local yaw = nil
	if entity == entities.GetLocalPlayer() then
		yaw = getLocalViewYaw(cmd)
	else
		yaw = getEntityEyeYaw(entity)
	end

	if type(yaw) == "number" then
		self.lastEyeYaw[idx] = yaw
	end
end

function StrafeTracker.updateFromVelocity(self, entity)
	assert(self, "StrafeTracker.updateFromVelocity: self is nil")
	assert(entity, "StrafeTracker.updateFromVelocity: entity is nil")

	local idx = entity:GetIndex()
	assert(idx, "StrafeTracker.updateFromVelocity: idx is nil")

	local vel = entity:EstimateAbsVelocity()
	if not vel then
		return
	end

	-- Skip yaw deltas when barely moving (avoid noise)
	local speed2DSqr = vel.x * vel.x + vel.y * vel.y
	local minSpeed = 10
	if speed2DSqr < (minSpeed * minSpeed) then
		self.lastVelocityYaw[idx] = math.atan(vel.y, vel.x) * RAD2DEG
		return
	end

	local velYaw = math.atan(vel.y, vel.x) * RAD2DEG
	local lastYaw = self.lastVelocityYaw[idx]

	if type(lastYaw) == "number" then
		local angleDelta = normalizeAngle(velYaw - lastYaw)
		local prev = self.yawDeltaPerTick[idx] or 0
		self.yawDeltaPerTick[idx] = prev * 0.8 + angleDelta * 0.2
	end

	self.lastVelocityYaw[idx] = velYaw
end

function StrafeTracker.getYawSeed(self, idx)
	assert(self, "StrafeTracker.getYawSeed: self is nil")
	assert(idx, "StrafeTracker.getYawSeed: idx is nil")
	return self.lastEyeYaw[idx] or 0
end

function StrafeTracker.getYawDeltaPerTick(self, idx)
	assert(self, "StrafeTracker.getYawDeltaPerTick: self is nil")
	assert(idx, "StrafeTracker.getYawDeltaPerTick: idx is nil")
	return self.yawDeltaPerTick[idx] or 0
end

local WishDirTracker = {}
WishDirTracker.__index = WishDirTracker

function WishDirTracker.new()
	local self = setmetatable({}, WishDirTracker)
	self.cmdWishDir = {} -- idx -> Vector3 (relative-to-yaw, unit)
	self.stableWishDir = {} -- idx -> Vector3 (relative-to-yaw, unit)
	self.lastOrigin = {} -- idx -> Vector3 (world)
	return self
end

function WishDirTracker.updateFromCmd(self, entity, cmd)
	assert(self, "WishDirTracker.updateFromCmd: self is nil")
	assert(entity, "WishDirTracker.updateFromCmd: entity is nil")

	local idx = entity:GetIndex()
	assert(idx, "WishDirTracker.updateFromCmd: idx is nil")

	if not cmd then
		return
	end

	local fwd = cmd:GetForwardMove()
	local side = cmd:GetSideMove()

	-- Ignore minimal movements
	if math.abs(fwd) < 5 and math.abs(side) < 5 then
		self.cmdWishDir[idx] = nil
		return
	end

	local rel = pickRelativeWishDirFromCmd(fwd, side, self.stableWishDir[idx], self.cmdWishDir[idx])
	if not rel then
		self.cmdWishDir[idx] = nil
		return
	end

	self.cmdWishDir[idx] = rel
end

function WishDirTracker.updateFromMotion(self, entity, yaw)
	assert(self, "WishDirTracker.updateFromMotion: self is nil")
	assert(entity, "WishDirTracker.updateFromMotion: entity is nil")
	assert(type(yaw) == "number", "WishDirTracker.updateFromMotion: yaw must be a number")

	local idx = entity:GetIndex()
	assert(idx, "WishDirTracker.updateFromMotion: idx is nil")

	local currentPos = entity:GetAbsOrigin()
	if not currentPos then
		return
	end

	local lastPos = self.lastOrigin[idx]
	if lastPos then
		local delta = currentPos - lastPos
		delta.z = 0

		local dist = length2D(delta)
		if dist > 0.1 then
			delta.x = delta.x / dist
			delta.y = delta.y / dist
			delta.z = 0

			local relWish = worldToRelativeWishDir(delta, yaw)
			normalize2DInPlace(relWish)
			self.stableWishDir[idx] = relWish
		end
	end

	self.lastOrigin[idx] = Vector3(currentPos.x, currentPos.y, currentPos.z)
end

function WishDirTracker.getRelativeWishDir(self, idx)
	assert(self, "WishDirTracker.getRelativeWishDir: self is nil")
	assert(idx, "WishDirTracker.getRelativeWishDir: idx is nil")

	local cmdDir = self.cmdWishDir[idx]
	if USE_CMD_WISHDIR and cmdDir then
		return cmdDir
	end

	return self.stableWishDir[idx]
end

-- Physics helpers (in-place) -----

local function accelerateInPlace(velocity, wishdir, wishspeed, accel, frametime)
	assert(velocity, "accelerateInPlace: velocity is nil")
	assert(wishdir, "accelerateInPlace: wishdir is nil")
	assert(type(wishspeed) == "number", "accelerateInPlace: wishspeed must be a number")
	assert(type(accel) == "number", "accelerateInPlace: accel must be a number")
	assert(type(frametime) == "number", "accelerateInPlace: frametime must be a number")

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

local function getAirSpeedCap(target)
	assert(target, "getAirSpeedCap: target is nil")

	if target:InCond(76) then -- TFCond_Charging
		return getConVarNumber("tf_max_charge_speed", 750)
	end

	-- Base cap ~30 HU/s scaled by air control attribute
	local airControl = target:AttributeHookFloat("mod_air_control") or 1.0
	return 30.0 * airControl
end

local function airAccelerateInPlace(v, wishdir, wishspeed, accel, dt, surf, target)
	assert(v, "airAccelerateInPlace: v is nil")
	assert(wishdir, "airAccelerateInPlace: wishdir is nil")
	assert(type(wishspeed) == "number", "airAccelerateInPlace: wishspeed must be a number")
	assert(type(accel) == "number", "airAccelerateInPlace: accel must be a number")
	assert(type(dt) == "number", "airAccelerateInPlace: dt must be a number")
	assert(type(surf) == "number", "airAccelerateInPlace: surf must be a number")
	assert(target, "airAccelerateInPlace: target is nil")

	wishspeed = math.min(wishspeed, getAirSpeedCap(target))

	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end

	local accelspeed = math.min(accel * wishspeed * dt * surf, addspeed)
	v.x = v.x + wishdir.x * accelspeed
	v.y = v.y + wishdir.y * accelspeed
	v.z = v.z + wishdir.z * accelspeed
end

local function checkIsOnGround(origin, mins, maxs, index)
	assert(origin, "checkIsOnGround: origin is nil")
	assert(mins, "checkIsOnGround: mins is nil")
	assert(maxs, "checkIsOnGround: maxs is nil")
	assert(index, "checkIsOnGround: index is nil")

	local down = Vector3(origin.x, origin.y, origin.z - 18)
	local trace = engine.TraceHull(origin, down, mins, maxs, MASK_PLAYERSOLID, function(ent)
		return ent:GetIndex() ~= index
	end)

	return trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
end

local function stayOnGround(origin, mins, maxs, step_size, index)
	assert(origin, "stayOnGround: origin is nil")
	assert(mins, "stayOnGround: mins is nil")
	assert(maxs, "stayOnGround: maxs is nil")
	assert(type(step_size) == "number", "stayOnGround: step_size must be a number")
	assert(index, "stayOnGround: index is nil")

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

local function applyFrictionInPlace(velocity, isOnGround, frametime)
	assert(velocity, "applyFrictionInPlace: velocity is nil")
	assert(type(isOnGround) == "boolean", "applyFrictionInPlace: isOnGround must be a boolean")
	assert(type(frametime) == "number", "applyFrictionInPlace: frametime must be a number")

	local speed = length2D(velocity)
	if speed < 0.1 then
		return
	end

	local drop = 0
	if isOnGround then
		local control = speed < stopSpeed and stopSpeed or speed
		drop = drop + control * friction * frametime
	end

	local newSpeed = speed - drop
	if newSpeed < 0 then
		newSpeed = 0
	end

	if newSpeed ~= speed then
		local scale = newSpeed / speed
		velocity.x = velocity.x * scale
		velocity.y = velocity.y * scale
	end
end

local function clipVelocityInPlace(velocity, normal, overbounce)
	assert(velocity, "clipVelocityInPlace: velocity is nil")
	assert(normal, "clipVelocityInPlace: normal is nil")
	assert(type(overbounce) == "number", "clipVelocityInPlace: overbounce must be a number")

	local backoff = dot3(velocity, normal) * overbounce
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

local function tryPlayerMoveInPlace(origin, velocity, mins, maxs, index, tickinterval)
	assert(origin, "tryPlayerMoveInPlace: origin is nil")
	assert(velocity, "tryPlayerMoveInPlace: velocity is nil")
	assert(mins, "tryPlayerMoveInPlace: mins is nil")
	assert(maxs, "tryPlayerMoveInPlace: maxs is nil")
	assert(index, "tryPlayerMoveInPlace: index is nil")
	assert(type(tickinterval) == "number", "tryPlayerMoveInPlace: tickinterval must be a number")

	local MAX_CLIP_PLANES = 5
	local timeLeft = tickinterval
	local planes = {}
	local numPlanes = 0

	for _ = 1, 4 do
		if timeLeft <= 0 then
			break
		end

		local endPos = Vector3(
			origin.x + velocity.x * timeLeft,
			origin.y + velocity.y * timeLeft,
			origin.z + velocity.z * timeLeft
		)

		local trace = engine.TraceHull(origin, endPos, mins, maxs, MASK_PLAYERSOLID, function(ent)
			return ent:GetIndex() ~= index
		end)

		if trace.fraction > 0 then
			copyVector3(origin, trace.endpos)
			numPlanes = 0
		end

		if trace.fraction == 1 then
			break
		end

		timeLeft = timeLeft - timeLeft * trace.fraction

		if trace.plane and numPlanes < MAX_CLIP_PLANES then
			numPlanes = numPlanes + 1
			planes[numPlanes] = trace.plane
		end

		if not trace.plane then
			break
		end

		if trace.plane.z > 0.7 and velocity.z < 0 then
			velocity.z = 0
		end

		local i = 1
		while i <= numPlanes do
			clipVelocityInPlace(velocity, planes[i], 1.0)

			local j = 1
			while j <= numPlanes do
				if j ~= i then
					if dot3(velocity, planes[j]) < 0 then
						break
					end
				end
				j = j + 1
			end

			if j > numPlanes then
				break
			end

			i = i + 1
		end

		if i > numPlanes then
			if numPlanes >= 2 then
				local dir = Vector3(
					planes[1].y * planes[2].z - planes[1].z * planes[2].y,
					planes[1].z * planes[2].x - planes[1].x * planes[2].z,
					planes[1].x * planes[2].y - planes[1].y * planes[2].x
				)

				if normalize3DInPlace(dir) <= 0 then
					velocity.x, velocity.y, velocity.z = 0, 0, 0
					break
				end

				local d = dot3(dir, velocity)
				velocity.x, velocity.y, velocity.z = dir.x * d, dir.y * d, dir.z * d
			end

			if dot3(velocity, planes[1]) < 0 then
				velocity.x, velocity.y, velocity.z = 0, 0, 0
				break
			end
		end
	end
end

local PlayerMoveSim = {}
PlayerMoveSim.__index = PlayerMoveSim

function PlayerMoveSim.newFromPlayer(player, yawSeed, yawDeltaPerTick, relativeWishDir)
	assert(player, "PlayerMoveSim.newFromPlayer: player is nil")
	assert(type(yawSeed) == "number", "PlayerMoveSim.newFromPlayer: yawSeed must be a number")
	assert(type(yawDeltaPerTick) == "number", "PlayerMoveSim.newFromPlayer: yawDeltaPerTick must be a number")

	local self = setmetatable({}, PlayerMoveSim)

	local tickinterval = globals.TickInterval()
	assert(tickinterval and tickinterval > 0, "PlayerMoveSim.newFromPlayer: invalid tickinterval")

	local origin = player:GetAbsOrigin()
	assert(origin, "PlayerMoveSim.newFromPlayer: player:GetAbsOrigin() returned nil")

	local velocity = player:GetPropVector("localdata", "m_vecVelocity[0]")
		or player:EstimateAbsVelocity()
		or Vector3(0, 0, 0)

	self.origin = Vector3(origin.x, origin.y, origin.z + 1)
	self.velocity = Vector3(velocity.x, velocity.y, velocity.z)
	self.mins = player:GetMins()
	self.maxs = player:GetMaxs()
	self.index = player:GetIndex()

	self.maxspeed = player:GetPropFloat("m_flMaxspeed") or 450
	self.tickinterval = tickinterval

	self.yaw = yawSeed
	self.yawDeltaPerTick = yawDeltaPerTick

	if relativeWishDir then
		self.relativeWishDir = Vector3(relativeWishDir.x, relativeWishDir.y, 0)
		normalize2DInPlace(self.relativeWishDir)
	else
		self.relativeWishDir = nil
	end

	return self
end

function PlayerMoveSim.stepTick(self, playerEntity)
	assert(self, "PlayerMoveSim.stepTick: self is nil")
	assert(playerEntity, "PlayerMoveSim.stepTick: playerEntity is nil")

	self.yaw = self.yaw + self.yawDeltaPerTick

	local wishdirWorld = nil
	if self.relativeWishDir then
		wishdirWorld = relativeToWorldWishDir(self.relativeWishDir, self.yaw)
		normalize2DInPlace(wishdirWorld)
	end

	local isOnGround = checkIsOnGround(self.origin, self.mins, self.maxs, self.index)

	if isOnGround and self.velocity.z < 0 then
		self.velocity.z = 0
	end

	applyFrictionInPlace(self.velocity, isOnGround, self.tickinterval)

	if wishdirWorld then
		local wishspeed = self.maxspeed -- (as requested: assume full maxspeed)

		if isOnGround then
			accelerateInPlace(self.velocity, wishdirWorld, wishspeed, accelerate, self.tickinterval)
			self.velocity.z = 0
		else
			airAccelerateInPlace(
				self.velocity,
				wishdirWorld,
				wishspeed,
				airAccelerate,
				self.tickinterval,
				1,
				playerEntity
			)
			self.velocity.z = self.velocity.z - gravity * self.tickinterval
		end
	else
		-- No input: only gravity in-air.
		if not isOnGround then
			self.velocity.z = self.velocity.z - gravity * self.tickinterval
		else
			self.velocity.z = 0
		end
	end

	tryPlayerMoveInPlace(self.origin, self.velocity, self.mins, self.maxs, self.index, self.tickinterval)

	if isOnGround then
		stayOnGround(self.origin, self.mins, self.maxs, stepSize, self.index)
	end
end

function PlayerMoveSim.simulateTicks(self, playerEntity, ticks)
	assert(self, "PlayerMoveSim.simulateTicks: self is nil")
	assert(playerEntity, "PlayerMoveSim.simulateTicks: playerEntity is nil")
	assert(type(ticks) == "number", "PlayerMoveSim.simulateTicks: ticks must be a number")

	local path = {}
	path[0] = Vector3(self.origin.x, self.origin.y, self.origin.z)

	for tick = 1, ticks do
		self:stepTick(playerEntity)
		path[tick] = Vector3(self.origin.x, self.origin.y, self.origin.z)
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
			-- Ensure integer screen coords for draw.Line
			local x1 = math.floor(screen1[1])
			local y1 = math.floor(screen1[2])
			local x2 = math.floor(screen2[1])
			local y2 = math.floor(screen2[2])
			local t = i / PREDICT_TICKS
			local r = math.floor(255 * t)
			local g = math.floor(255 * (1 - t * 0.5))
			draw.Color(r, g, 0, 200)
			if x1 == x1 and y1 == y1 and x2 == x2 and y2 == y2 then
				draw.Line(x1, y1, x2, y2)
			end
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
			local sx = math.floor(screen[1])
			local sy = math.floor(screen[2])
			local t = i / PREDICT_TICKS
			local r = math.floor(255 * t)
			local g = math.floor(255 * (1 - t * 0.5))
			draw.Color(r, g, 0, 255)
			if sx == sx and sy == sy then
				draw.FilledRect(sx - DOT_SIZE / 2, sy - DOT_SIZE / 2, sx + DOT_SIZE / 2, sy + DOT_SIZE / 2)
				draw.Color(0, 0, 0, 255)
				draw.OutlinedRect(sx - DOT_SIZE / 2, sy - DOT_SIZE / 2, sx + DOT_SIZE / 2, sy + DOT_SIZE / 2)
			end
		end
	end
end

-- Self-init (optional) ---

local strafeTracker = StrafeTracker.new()
local wishDirTracker = WishDirTracker.new()

-- Callbacks -----

local function OnCreateMove(cmd)
	local me = entities.GetLocalPlayer()
	if not me or not me:IsAlive() then
		return
	end

	local meIdx = me:GetIndex()
	assert(meIdx, "OnCreateMove: meIdx is nil")

	strafeTracker:updateEyeYaw(me, cmd)
	strafeTracker:updateFromVelocity(me)
	wishDirTracker:updateFromCmd(me, cmd)

	local yawSeed = strafeTracker:getYawSeed(meIdx)
	wishDirTracker:updateFromMotion(me, yawSeed)
end

local function OnDraw()
	local me = entities.GetLocalPlayer()
	if not me or not me:IsAlive() then
		return
	end

	local meIdx = me:GetIndex()
	assert(meIdx, "OnDraw: meIdx is nil")

	-- Keep enemy tracking updated (for later extensions)
	for _, player in ipairs(entities.FindByClass("CTFPlayer")) do
		if player and player ~= me and player:IsAlive() then
			local idx = player:GetIndex()
			if idx then
				strafeTracker:updateEyeYaw(player, nil)
				strafeTracker:updateFromVelocity(player)
				wishDirTracker:updateFromMotion(player, strafeTracker:getYawSeed(idx))
			end
		end
	end

	local yawSeed = strafeTracker:getYawSeed(meIdx)
	local yawDeltaPerTick = strafeTracker:getYawDeltaPerTick(meIdx)
	local relWishDir = wishDirTracker:getRelativeWishDir(meIdx)

	local sim = PlayerMoveSim.newFromPlayer(me, yawSeed, yawDeltaPerTick, relWishDir)
	local path = sim:simulateTicks(me, PREDICT_TICKS)
	if not path then
		return
	end

	DrawPath(path)
	DrawDots(path)
end

callbacks.Unregister("CreateMove", "AdvancedPredictionVisualizer_CM")
callbacks.Unregister("Draw", "AdvancedPredictionVisualizer_Draw")
callbacks.Register("CreateMove", "AdvancedPredictionVisualizer_CM", OnCreateMove)
callbacks.Register("Draw", "AdvancedPredictionVisualizer_Draw", OnDraw)
