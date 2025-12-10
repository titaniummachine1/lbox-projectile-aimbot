-- Imports
local GameConstants = require("constants.game_constants")
local VectorMath = require("utils.math.vector")

-- Module declaration
local Ballistics = {}

---Solves ballistic arc for low trajectory
---@param p0 Vector3 -- start position
---@param p1 Vector3 -- target position
---@param speed number -- projectile speed
---@param gravity number -- gravity constant
---@return EulerAngles?, number? -- Euler angles (pitch, yaw, 0)
function Ballistics.solveBallisticArc(p0, p1, speed, gravity)
	local diff = p1 - p0
	local dx = diff:Length2D()
	local dy = diff.z
	local speed2 = speed * speed
	local g = gravity
	
	local root = speed2 * speed2 - g * (g * dx * dx + 2 * dy * speed2)
	if root < 0 then
		return nil
	end
	
	local sqrt_root = math.sqrt(root)
	local angle = math.atan((speed2 - sqrt_root) / (g * dx))
	
	local yaw = (math.atan(diff.y, diff.x)) * GameConstants.RAD2DEG
	local pitch = -angle * GameConstants.RAD2DEG
	
	return EulerAngles(pitch, yaw, 0)
end

---Returns both low and high arc EulerAngles when gravity > 0
---@param p0 Vector3
---@param p1 Vector3
---@param speed number
---@param gravity number
---@return EulerAngles|nil lowArc, EulerAngles|nil highArc
function Ballistics.solveBallisticArcBoth(p0, p1, speed, gravity)
	local diff = p1 - p0
	local dx = math.sqrt(diff.x * diff.x + diff.y * diff.y)
	if dx == 0 then
		return nil, nil
	end
	
	local dy = diff.z
	local g = gravity
	local speed2 = speed * speed
	
	local root = speed2 * speed2 - g * (g * dx * dx + 2 * dy * speed2)
	if root < 0 then
		return nil, nil
	end
	
	local sqrt_root = math.sqrt(root)
	local theta_low = math.atan((speed2 - sqrt_root) / (g * dx))
	local theta_high = math.atan((speed2 + sqrt_root) / (g * dx))
	
	local yaw = math.atan(diff.y, diff.x) * GameConstants.RAD2DEG
	
	local pitch_low = -theta_low * GameConstants.RAD2DEG
	local pitch_high = -theta_high * GameConstants.RAD2DEG
	
	local low = EulerAngles(pitch_low, yaw, 0)
	local high = EulerAngles(pitch_high, yaw, 0)
	return low, high
end

---Estimates projectile travel time
---@param shootPos Vector3
---@param targetPos Vector3
---@param speed number
---@return number
function Ballistics.estimateTravelTime(shootPos, targetPos, speed)
	local distance = (targetPos - shootPos):Length2D()
	return distance / speed
end

---Gets ballistic flight time
function Ballistics.getBallisticFlightTime(p0, p1, speed, gravity)
	local diff = p1 - p0
	local dx = math.sqrt(diff.x ^ 2 + diff.y ^ 2)
	local dy = diff.z
	local speed2 = speed * speed
	local g = gravity
	
	local discriminant = speed2 * speed2 - g * (g * dx * dx + 2 * dy * speed2)
	if discriminant < 0 then
		return nil
	end
	
	local sqrt_discriminant = math.sqrt(discriminant)
	local angle = math.atan((speed2 - sqrt_discriminant) / (g * dx))
	
	local vz = speed * math.sin(angle)
	local flight_time = (vz + math.sqrt(vz * vz + 2 * g * dy)) / g
	
	return flight_time
end

return Ballistics

