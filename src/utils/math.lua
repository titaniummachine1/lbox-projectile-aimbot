local Math = {}

--- Pasted from Lnx00's LnxLib
local function isNaN(x)
	return x ~= x
end

local M_RADPI = 180 / math.pi

-- Calculates the angle between two vectors
---@param source Vector3
---@param dest Vector3
---@return EulerAngles angles
function Math.PositionAngles(source, dest)
	local delta = source - dest

	local pitch = math.atan(delta.z / delta:Length2D()) * M_RADPI
	local yaw = math.atan(delta.y / delta.x) * M_RADPI

	if delta.x >= 0 then
		yaw = yaw + 180
	end

	if isNaN(pitch) then
		pitch = 0
	end
	if isNaN(yaw) then
		yaw = 0
	end

	return EulerAngles(pitch, yaw, 0)
end

-- Calculates the FOV between two angles
---@param vFrom EulerAngles
---@param vTo EulerAngles
---@return number fov
function Math.AngleFov(vFrom, vTo)
	local vSrc = vFrom:Forward()
	local vDst = vTo:Forward()

	local fov = math.deg(math.acos(vDst:Dot(vSrc) / vDst:LengthSqr()))
	if isNaN(fov) then
		fov = 0
	end

	return fov
end

local function NormalizeVector(vec)
	return vec / vec:Length()
end

---@param p0 Vector3
---@param p1 Vector3
---@param speed number
---@param gravity number
---@return Vector3|nil
function Math.SolveBallisticArc(p0, p1, speed, gravity)
	local diff = p1 - p0
	local dx = math.sqrt(diff.x ^ 2 + diff.y ^ 2)
	local dy = diff.z
	local speed2 = speed * speed
	local g = gravity

	local root = speed2 * speed2 - g * (g * dx * dx + 2 * dy * speed2)
	if root < 0 then
		return nil -- no solution
	end

	local sqrt_root = math.sqrt(root)
	local angle

	angle = math.atan((speed2 - sqrt_root) / (g * dx)) -- low arc

	local dir_xy = NormalizeVector(Vector3(diff.x, diff.y, 0))
	local aim = Vector3(dir_xy.x * math.cos(angle), dir_xy.y * math.cos(angle), math.sin(angle))
	return NormalizeVector(aim)
end

---@param shootPos Vector3
---@param targetPos Vector3
---@param speed number
---@return number
function Math.EstimateTravelTime(shootPos, targetPos, speed)
	local distance = (targetPos - shootPos):Length2D()
	return distance / speed
end

---@param val number
---@param min number
---@param max number
function Math.clamp(val, min, max)
	return math.max(min, math.min(val, max))
end

function Math.GetBallisticFlightTime(p0, p1, speed, gravity)
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

	-- Flight time calculation
	local vz = speed * math.sin(angle)
	local flight_time = (vz + math.sqrt(vz * vz + 2 * g * dy)) / g

	return flight_time
end

function Math.DirectionToAngles(direction)
	local pitch = math.asin(-direction.z) * (180 / math.pi)
	local yaw = math.atan(direction.y, direction.x) * (180 / math.pi)
	return Vector3(pitch, yaw, 0)
end

---@param offset Vector3
---@param direction Vector3
function Math.RotateOffsetAlongDirection(offset, direction)
	local forward = NormalizeVector(direction)
	local up = Vector3(0, 0, 1)
	local right = NormalizeVector(forward:Cross(up))
	up = NormalizeVector(right:Cross(forward))

	return forward * offset.x + right * offset.y + up * offset.z
end

-- New function to calculate ballistic trajectory with upward velocity
---@param p0 Vector3 Starting position
---@param p1 Vector3 Target position
---@param forward_speed number Forward velocity component
---@param upward_speed number Upward velocity component
---@param gravity number Gravity value
---@return Vector3|nil Aim direction
function Math.SolveBallisticArcWithUpwardVelocity(p0, p1, forward_speed, upward_speed, gravity)
	local diff = p1 - p0
	local dx = math.sqrt(diff.x ^ 2 + diff.y ^ 2)
	local dy = diff.z

	-- Calculate the angle needed to hit the target with given upward velocity
	local g = gravity
	local v0z = upward_speed
	local v0xy = forward_speed

	-- Time of flight equation: dy = v0z * t - 0.5 * g * t^2
	-- Horizontal distance: dx = v0xy * t
	-- Solve for t from horizontal: t = dx / v0xy
	-- Substitute into vertical equation: dy = v0z * (dx/v0xy) - 0.5 * g * (dx/v0xy)^2

	local t = dx / v0xy
	local expected_dy = v0z * t - 0.5 * g * t * t

	-- If the expected vertical position doesn't match target, adjust the aim
	local vertical_diff = dy - expected_dy

	-- Calculate the angle adjustment needed
	local angle_adjustment = math.atan(vertical_diff / dx)

	-- Create the aim direction
	local dir_xy = NormalizeVector(Vector3(diff.x, diff.y, 0))
	local aim = Vector3(
		dir_xy.x * math.cos(angle_adjustment),
		dir_xy.y * math.cos(angle_adjustment),
		math.sin(angle_adjustment)
	)

	return NormalizeVector(aim)
end

-- New function to calculate flight time with upward velocity
---@param p0 Vector3 Starting position
---@param p1 Vector3 Target position
---@param forward_speed number Forward velocity component
---@param upward_speed number Upward velocity component
---@param gravity number Gravity value
---@return number|nil Flight time
function Math.GetBallisticFlightTimeWithUpwardVelocity(p0, p1, forward_speed, upward_speed, gravity)
	local diff = p1 - p0
	local dx = math.sqrt(diff.x ^ 2 + diff.y ^ 2)
	local dy = diff.z

	local g = gravity
	local v0z = upward_speed
	local v0xy = forward_speed

	-- Time from horizontal distance
	local t_horizontal = dx / v0xy

	-- Check if this time gives us the right vertical position
	local expected_dy = v0z * t_horizontal - 0.5 * g * t_horizontal * t_horizontal

	if math.abs(expected_dy - dy) < 1.0 then
		return t_horizontal
	end

	-- If not, solve the quadratic equation for vertical motion
	-- dy = v0z * t - 0.5 * g * t^2
	-- 0.5 * g * t^2 - v0z * t + dy = 0

	local a = 0.5 * g
	local b = -v0z
	local c = dy

	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then
		return nil -- No solution
	end

	local sqrt_discriminant = math.sqrt(discriminant)
	local t1 = (-b + sqrt_discriminant) / (2 * a)
	local t2 = (-b - sqrt_discriminant) / (2 * a)

	-- Return the positive time
	return math.max(t1, t2)
end

Math.NormalizeVector = NormalizeVector
return Math
