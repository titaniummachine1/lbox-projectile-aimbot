-- Imports
local GameConstants = require("constants.game_constants")
local VectorMath = require("utils.math.vector")

-- Module declaration
local Angles = {}

---Calculates the angle between two vectors
---@param source Vector3
---@param dest Vector3
---@return EulerAngles angles
function Angles.positionAngles(source, dest)
	local delta = source - dest
	
	local pitch = math.atan(delta.z / delta:Length2D()) * GameConstants.RAD2DEG
	local yaw = math.atan(delta.y / delta.x) * GameConstants.RAD2DEG
	
	if delta.x >= 0 then
		yaw = yaw + 180
	end
	
	if VectorMath.isNaN(pitch) then
		pitch = 0
	end
	if VectorMath.isNaN(yaw) then
		yaw = 0
	end
	
	return EulerAngles(pitch, yaw, 0)
end

---Calculates the FOV between two angles
---@param vFrom EulerAngles
---@param vTo EulerAngles
---@return number fov
function Angles.angleFov(vFrom, vTo)
	local vSrc = vFrom:Forward()
	local vDst = vTo:Forward()
	
	local fov = GameConstants.RAD2DEG * math.acos(vDst:Dot(vSrc) / vDst:LengthSqr())
	if VectorMath.isNaN(fov) then
		fov = 0
	end
	
	return fov
end

---Converts direction vector to angles
---@param direction Vector3
---@return Vector3
function Angles.directionToAngles(direction)
	local pitch = math.asin(-direction.z) * GameConstants.RAD2DEG
	local yaw = math.atan(direction.y, direction.x) * GameConstants.RAD2DEG
	return Vector3(pitch, yaw, 0)
end

---Rotates an offset along a direction vector
---@param offset Vector3
---@param direction Vector3
---@return Vector3
function Angles.rotateOffsetAlongDirection(offset, direction)
	local forward = VectorMath.normalize(direction)
	local up = Vector3(0, 0, 1)
	local right = VectorMath.normalize(forward:Cross(up))
	up = VectorMath.normalize(right:Cross(forward))
	
	return forward * offset.x + right * offset.y + up * offset.z
end

return Angles

