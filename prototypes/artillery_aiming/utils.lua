local Utils = {}

local vectorDivide = vector.Divide
local vectorLength = vector.Length
local vectorDistance = vector.Distance

function Utils.clamp(value, minVal, maxVal)
	return math.max(minVal, math.min(maxVal, value))
end

function Utils.cross2D(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end

function Utils.vecRot(localVec, angles)
	return (angles:Forward() * localVec.x) + (angles:Right() * localVec.y) + (angles:Up() * localVec.z)
end

function Utils.lerpAngle(a, b, t)
	local diff = (b - a + 180) % 360 - 180
	return a + diff * t
end

function Utils.lerpVector(startVector, endVector, interpolationFactor)
	return startVector + (endVector - startVector) * interpolationFactor
end

function Utils.velocityToAngles(vel)
	local speed = vel:Length()
	if speed < 0.001 then
		return EulerAngles(0, 0, 0)
	end
	local pitch = -math.deg(math.asin(vel.z / speed))
	local yaw = math.deg(math.atan(vel.y, vel.x))
	return EulerAngles(pitch, yaw, 0)
end

function Utils.surfaceFacesDown(plane, threshold)
	return plane.z < -threshold
end

function Utils.normalize(vec)
	return vectorDivide(vec, vectorLength(vec))
end

function Utils.dot(a, b)
	return a:Dot(b)
end

function Utils.cross(a, b)
	return a:Cross(b)
end

function Utils.length2D(vec)
	return vec:Length2D()
end

function Utils.distance2D(a, b)
	return (a - b):Length2D()
end

function Utils.distance3D(a, b)
	return (a - b):Length()
end

function Utils.anglesFromVector(vec)
	return vec:Angles()
end

local ZeroVector = Vector3(0, 0, 0)

function Utils.TraceHit(Result)
	return Result.plane ~= ZeroVector and Result.fraction > 0.99
end

return Utils
