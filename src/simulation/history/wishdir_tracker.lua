-- Imports
local WishdirTracker = {}

-- Per-entity state
local state = {}
local MAX_TRACKED = 4
local EXPIRY_TICKS = 132 -- ~2 seconds at 66 tick

local DEG2RAD = math.pi / 180

local function normalize2DInPlace(v)
	if not v then return 0 end
	local len = math.sqrt(v.x * v.x + v.y * v.y)
	if len < 0.0001 then
		v.x, v.y, v.z = 0, 0, 0
		return 0
	end
	v.x, v.y, v.z = v.x / len, v.y / len, 0
	return len
end

local function getYawBasis(yaw)
	local angles = EulerAngles(0, yaw, 0)
	local forward, right = vector.AngleVectors(angles)
	forward.z, right.z = 0, 0
	normalize2DInPlace(forward)
	normalize2DInPlace(right)
	return forward, right
end

local function worldToRelative(dir, yaw)
	local f, r = getYawBasis(yaw)
	return Vector3(dir:Dot(f), dir:Dot(r), 0)
end

local function relativeToWorld(rel, yaw)
	local f, r = getYawBasis(yaw)
	return Vector3(f.x * rel.x + r.x * rel.y, f.y * rel.x + r.y * rel.y, 0)
end

local function getEntityYaw(entity)
	if not entity then return nil end
	local yaw = entity:GetPropFloat("m_angEyeAngles[1]")
	if yaw then return yaw end
	if entity.GetPropVector and type(entity.GetPropVector) == "function" then
		local eyeVec = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles")
		if eyeVec and eyeVec.y then return eyeVec.y end
	end
	local vel = entity:EstimateAbsVelocity()
	if vel and vel:Length2D() > 1 then
		local ang = vel:Angles()
		if ang and ang.y then return ang.y end
	end
	return nil
end

local function shouldPrune(entry)
	if not entry then return true end
	return (globals.TickCount() - entry.lastTick) > EXPIRY_TICKS
end

local function snapRelTo8(rel)
	if not rel then return nil end
	local ang = math.atan(rel.y, rel.x) * 180 / math.pi
	local idx = (math.floor((ang + 22.5) / 45) % 8 + 8) % 8
	local snapped = {
		[0] = { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 },
		{ -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 },
	}
	local dir = snapped[idx]
	local out = Vector3(dir[1], dir[2], 0)
	normalize2DInPlace(out)
	return out
end

---Update tracker for one entity using its movement delta.
---@param entity Entity
function WishdirTracker.update(entity)
	if not entity or not entity:IsAlive() or entity:IsDormant() then
		return
	end

	local idx = entity:GetIndex()
	if not state[idx] then
		state[idx] = {}
	end
	local s = state[idx]

	local yaw = getEntityYaw(entity)
	if not yaw then
		return
	end

	local pos = entity:GetAbsOrigin()
	if not pos then return end

	if s.lastPos then
		local delta = pos - s.lastPos
		delta.z = 0
		if normalize2DInPlace(delta) > 0.05 then
			local rel = worldToRelative(delta, yaw)
			normalize2DInPlace(rel)
			s.relWishdir = rel
		end
	end

	s.lastPos = Vector3(pos.x, pos.y, pos.z)
	s.lastYaw = yaw
	s.lastTick = globals.TickCount()
end

---Get world-space wishdir for entity if recent.
---@param entity Entity
---@return Vector3|nil
function WishdirTracker.getWorldWishdir(entity)
	if not entity then return nil end
	local idx = entity:GetIndex()
	local s = state[idx]
	if not s or shouldPrune(s) or not s.relWishdir or not s.lastYaw then
		return nil
	end
	return relativeToWorld(s.relWishdir, s.lastYaw)
end

---Update tracker for a provided, pre-sorted list of entities (nearest/top).
---@param pLocal Entity
---@param sortedEntities Entity[]
---@param maxTargets integer
function WishdirTracker.updateTop(pLocal, sortedEntities, maxTargets)
	if not pLocal or not sortedEntities then return end
	maxTargets = maxTargets or MAX_TRACKED

	local keep = {}
	for i = 1, math.min(maxTargets, #sortedEntities) do
		local ent = sortedEntities[i]
		if ent and ent:IsAlive() and not ent:IsDormant() and ent ~= pLocal then
			keep[ent:GetIndex()] = true
			WishdirTracker.update(ent)
		end
	end

	for idx, entry in pairs(state) do
		if not keep[idx] or shouldPrune(entry) then
			state[idx] = nil
		end
	end
end

return WishdirTracker

