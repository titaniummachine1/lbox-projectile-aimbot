---@diagnostic disable: duplicate-doc-field, missing-fields

local sim = {}

local MASK_SHOT_HULL = MASK_SHOT_HULL
local MASK_PLAYERSOLID = MASK_PLAYERSOLID
local DoTraceHull = engine.TraceHull
local TraceLine = engine.TraceLine
local Vector3 = Vector3
local math_deg = math.deg
local math_rad = math.rad
local math_atan = math.atan
local math_cos = math.cos
local math_sin = math.sin
local math_abs = math.abs
local math_acos = math.acos
local math_min = math.min
local math_max = math.max
local math_floor = math.floor
local math_pi = math.pi

local G = require("globals")
local TargetSelector = require("targeting.target_selector")
local WishdirTracker = require("simulation.history.wishdir_tracker")

-- constants
local MIN_SPEED = 25 -- HU/s
local MAX_ANGULAR_VEL = 360 -- deg/s
local WALKABLE_ANGLE = 55 -- degrees
local MIN_VELOCITY_Z = 0.1
local AIR_ACCELERATE = 10.0 -- Default air acceleration value
local GROUND_ACCELERATE = 10.0 -- Default ground acceleration value
local SURFACE_FRICTION = 1.0 -- Default surface friction

local MAX_CLIP_PLANES = 5
local DIST_EPSILON = 0.03125 -- Small epsilon for step calculations

local MAX_SAMPLES = 16 -- tuned window size
local SMOOTH_ALPHA_G = 0.392 -- tuned ground α
local SMOOTH_ALPHA_A = 0.127 -- tuned air α

local COORD_FRACTIONAL_BITS = 5
local COORD_DENOMINATOR = (1 << COORD_FRACTIONAL_BITS)
local COORD_RESOLUTION = (1.0 / COORD_DENOMINATOR)

local impact_planes = {}
local MAX_IMPACT_PLANES = 5

---@class Sample
---@field pos Vector3
---@field time number

---@type table<number, Sample[]>
local position_samples = {}

local zero_vector = Vector3(0, 0, 0)
local up_vector = Vector3(0, 0, 1)
local down_vector = Vector3()

---this "zero-GC" shit is killing me

local RuneTypes_t = {
	RUNE_NONE = -1,
	RUNE_STRENGTH = 0,
	RUNE_HASTE = 1,
	RUNE_REGEN = 2,
	RUNE_RESIST = 3,
	RUNE_VAMPIRE = 4,
	RUNE_REFLECT = 5,
	RUNE_PRECISION = 6,
	RUNE_AGILITY = 7,
	RUNE_KNOCKOUT = 8,
	RUNE_KING = 9,
	RUNE_PLAGUE = 10,
	RUNE_SUPERNOVA = 11,
	RUNE_TYPES_MAX = 12,
}

local function GetEntityOrigin(pEntity)
	return pEntity:GetPropVector("tflocaldata", "m_vecOrigin") or pEntity:GetAbsOrigin()
end

local function GetEntityYaw(pEntity)
	if not pEntity then
		return nil
	end
	local yaw = pEntity:GetPropFloat("m_angEyeAngles[1]")
	if yaw then
		return yaw
	end
	if pEntity.GetPropVector and type(pEntity.GetPropVector) == "function" then
		local eyeVec = pEntity:GetPropVector("tfnonlocaldata", "m_angEyeAngles")
		if eyeVec and eyeVec.y then
			return eyeVec.y
		end
	end
	local vel = pEntity:EstimateAbsVelocity()
	if vel and vel:Length2D() > 1 then
		local ang = vel:Angles()
		if ang and ang.y then
			return ang.y
		end
	end
	return nil
end

local function getYawBasis(yaw)
	local ang = EulerAngles(0, yaw, 0)
	local f, r = vector.AngleVectors(ang)
	f.z, r.z = 0, 0
	local flen = f:Length2D()
	local rlen = r:Length2D()
	if flen > 0 then
		f.x, f.y = f.x / flen, f.y / flen
	end
	if rlen > 0 then
		r.x, r.y = r.x / rlen, r.y / rlen
	end
	return f, r
end

local function worldToRelative(dir, yaw)
	local f, r = getYawBasis(yaw)
	return Vector3(dir:Dot(f), dir:Dot(r), 0)
end

local function relativeToWorld(rel, yaw)
	local f, r = getYawBasis(yaw)
	return Vector3(f.x * rel.x + r.x * rel.y, f.y * rel.x + r.y * rel.y, 0)
end

local function snapRelTo8(rel)
	if not rel then
		return nil
	end
	local ang = math_atan(rel.y, rel.x) * 180 / math_pi
	local idx = (math_floor((ang + 22.5) / 45) % 8 + 8) % 8
	local dirs = {
		[0] = { 1, 0 },
		{ 1, 1 },
		{ 0, 1 },
		{ -1, 1 },
		{ -1, 0 },
		{ -1, -1 },
		{ 0, -1 },
		{ 1, -1 },
	}
	local d = dirs[idx]
	local out = Vector3(d[1], d[2], 0)
	local len = out:Length()
	if len > 0 then
		out.x, out.y = out.x / len, out.y / len
	end
	return out
end

---@param vec Vector3
local function NormalizeVector(vec)
	local len = vec:Length()
	return len == 0 and vec or vec / len
end

return sim
