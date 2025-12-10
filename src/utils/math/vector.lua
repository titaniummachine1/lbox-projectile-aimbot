-- Imports

-- Module declaration
local VectorMath = {}

---Normalizes a vector (divides by length)
---@param vec Vector3
---@return Vector3
function VectorMath.normalize(vec)
	local len = vec:Length()
	if len < 0.0001 then
		return Vector3(0, 0, 0)
	end
	return vec / len
end

---Normalizes a vector in-place and returns the original length
---@param vec Vector3
---@return number length
function VectorMath.normalizeInPlace(vec)
	local len = vec:Length()
	if len < 0.0001 then
		return 0
	end
	
	vec.x = vec.x / len
	vec.y = vec.y / len
	vec.z = vec.z / len
	
	return len
end

---Checks if a value is NaN
---@param x number
---@return boolean
function VectorMath.isNaN(x)
	return x ~= x
end

return VectorMath

