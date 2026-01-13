local Pool = {}

local vectorPool = {}
local tablePool = {}

function Pool.GetVector(x, y, z)
	local v = table.remove(vectorPool)
	if v then
		v.x, v.y, v.z = x, y, z
		return v
	end
	return Vector3(x, y, z)
end

function Pool.ReleaseVector(v)
	if v then
		table.insert(vectorPool, v)
	end
end

function Pool.GetTable()
	local t = table.remove(tablePool)
	if t then
		return t
	end
	return {}
end

function Pool.ReleaseTable(t, deep)
	if not t then
		return
	end

	for k, v in pairs(t) do
		if deep then
			if type(v) == "table" then
				Pool.ReleaseTable(v, true)
			elseif v.Unpack then -- Vector3 likely
				Pool.ReleaseVector(v)
			end
		end
		t[k] = nil
	end

	table.insert(tablePool, t)
end

function Pool.ReleaseArray(arr, deep)
	if not arr then
		return
	end
	for i = 1, #arr do
		local v = arr[i]
		if deep then
			if type(v) == "table" then
				Pool.ReleaseTable(v, true)
			elseif v.Unpack then
				Pool.ReleaseVector(v)
			end
		end
		arr[i] = nil
	end
	table.insert(tablePool, arr)
end

return Pool
