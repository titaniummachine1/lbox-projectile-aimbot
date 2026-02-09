
--- Normalize vector (fastest method)
function Normalize(vec)
	return vectorDivide(vec, vectorLength(vec))
end

--- Distance 2D using vector Length2D
function Distance2D(a, b)
	return (a - b):Length2D()
end

--- Distance 3D (fastest possible in Lua)
function Distance3D(a, b)
	return vectorDistance(a, b)
end

--- Cross product of two vectors
function Cross(a, b)
	return a:Cross(b)
end

--- Dot product of two vectors
function Dot(a, b)
	return a:Dot(b)
end

--- 2D vector length (horizontal only)
function Length2D(vec)
	return vec:Length2D()
end