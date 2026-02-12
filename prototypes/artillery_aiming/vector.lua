local Vector = {}

-- Vector operations extracted from utils.lua
local vectorLength = vector.Length
local vectorDistance = vector.Distance
local vectorDivide = vector.Divide

function Vector.clamp(value, minVal, maxVal)
	return math.max(minVal, math.min(maxVal, value))
end

function Vector.cross2D(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end

function Vector.vecRot(localVec, angles)
	return (angles:Forward() * localVec.x) + (angles:Right() * localVec.y) + (angles:Up() * localVec.z)
end

function Vector.lerpAngle(a, b, t)
	local diff = (b - a + 180) % 360 - 180
	return a + diff * t
end

function Vector.lerpVector(startVector, endVector, interpolationFactor)
	return startVector + (endVector - startVector) * interpolationFactor
end

function Vector.velocityToAngles(vel)
	local speed = vel:Length()
	if speed < 0.001 then
		return EulerAngles(0, 0, 0)
	end
	
	local pitch = math.deg(math.atan2(vel.z, math.sqrt(vel.x * vel.x + vel.y * vel.y)))
	local yaw = math.deg(math.atan2(vel.y, vel.x))
	
	return EulerAngles(pitch, yaw, 0)
end

function Vector.surfaceFacesDown(plane, threshold)
	return plane.z < -threshold
end

function Vector.normalize(vec)
	return vectorDivide(vec, vectorLength(vec))
end

function Vector.dot(a, b)
	return a:Dot(b)
end

function Vector.cross(a, b)
	return a:Cross(b)
end

function Vector.length2D(vec)
	return vec:Length2D()
end

function Vector.distance2D(a, b)
	return (a - b):Length2D()
end

function Vector.distance3D(a, b)
	return vectorDistance(a, b)
end

function Vector.anglesFromVector(vec)
	return vec:Angles()
end

function Vector.TraceHit(Result)
	return Result.fraction ~= 1
end

return Vector
