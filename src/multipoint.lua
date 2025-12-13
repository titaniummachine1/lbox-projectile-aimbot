local multipoint = {}

-- Imports
local G = require("globals")
local WeaponOffsets = require("constants.weapon_offsets")
local utils = {}
utils.math = require("utils.math")

-- Constants
local BINARY_SEARCH_ITERATIONS = 5
local VISIBILITY_THRESHOLD = 0.99

-- Debug state for visuals (exported for drawing)
multipoint.debugState = {
	corners = nil, -- All 8 corners
	visibleCorners = nil, -- Which corners are shootable
	searchPath = nil, -- Binary search path for visualization
	bestPoint = nil, -- Final selected point
	aabbCenter = nil, -- Center of AABB
	closestFace = nil, -- The face we're targeting
	faceCenter = nil, -- Center of the closest face
}

---Normalize vector (handles zero-length)
---@param v Vector3
---@return Vector3
local function normalize(v)
	return v / v:Length()
end

---Get 8 corners of player AABB in world space
---@param targetPos Vector3 predicted target position
---@param mins Vector3
---@param maxs Vector3
---@return Vector3[] corners indexed 1-8
local function getAABBCorners(targetPos, mins, maxs)
	local worldMins = targetPos + mins
	local worldMaxs = targetPos + maxs
	return {
		Vector3(worldMins.x, worldMins.y, worldMins.z), -- 1: bottom-back-left
		Vector3(worldMins.x, worldMaxs.y, worldMins.z), -- 2: bottom-front-left
		Vector3(worldMaxs.x, worldMaxs.y, worldMins.z), -- 3: bottom-front-right
		Vector3(worldMaxs.x, worldMins.y, worldMins.z), -- 4: bottom-back-right
		Vector3(worldMins.x, worldMins.y, worldMaxs.z), -- 5: top-back-left
		Vector3(worldMins.x, worldMaxs.y, worldMaxs.z), -- 6: top-front-left
		Vector3(worldMaxs.x, worldMaxs.y, worldMaxs.z), -- 7: top-front-right
		Vector3(worldMaxs.x, worldMins.y, worldMaxs.z), -- 8: top-back-right
	}
end

---Check if a point can be shot at (visibility + projectile path clear)
local function createCanShootAt(
	pLocal,
	pTarget,
	pWeapon,
	weaponInfo,
	viewPos,
	speed,
	gravity,
	hullMins,
	hullMaxs,
	traceMask
)
	assert(pLocal, "createCanShootAt: missing pLocal")
	assert(pTarget, "createCanShootAt: missing pTarget")
	assert(pWeapon, "createCanShootAt: missing pWeapon")
	assert(weaponInfo, "createCanShootAt: missing weaponInfo")
	assert(viewPos, "createCanShootAt: missing viewPos")
	assert(type(speed) == "number", "createCanShootAt: speed must be number")
	assert(type(gravity) == "number", "createCanShootAt: gravity must be number")
	assert(hullMins, "createCanShootAt: missing hullMins")
	assert(hullMaxs, "createCanShootAt: missing hullMaxs")
	assert(type(traceMask) == "number", "createCanShootAt: traceMask must be number")

	local pLocalIndex = pLocal:GetIndex()
	assert(pLocalIndex, "createCanShootAt: pLocal:GetIndex() returned nil")
	local pTargetIndex = pTarget:GetIndex()
	assert(pTargetIndex, "createCanShootAt: pTarget:GetIndex() returned nil")

	local weaponDefIndex = pWeapon:GetPropInt("m_iItemDefinitionIndex")
	assert(weaponDefIndex, "createCanShootAt: pWeapon:GetPropInt('m_iItemDefinitionIndex') returned nil")

	local isFlipped = pWeapon.IsViewModelFlipped and pWeapon:IsViewModelFlipped() or false

	local function shouldHitEntity(ent, contentsMask)
		if not ent then
			return false
		end
		local idx = ent.GetIndex and ent:GetIndex() or nil
		if idx == pLocalIndex then
			return false
		end
		return true
	end

	local hasHull = (hullMins:Length() > 0.01 or hullMaxs:Length() > 0.01)

	return function(targetPoint)
		assert(targetPoint, "canShootAt: missing targetPoint")

		local aimAngle = utils.math.SolveBallisticArc(viewPos, targetPoint, speed, gravity)
		if not aimAngle then
			return false
		end

		local firePos = weaponInfo:GetFirePosition(pLocal, viewPos, aimAngle, isFlipped)
		if not firePos then
			return false
		end

		local weaponOffset = WeaponOffsets.getFirePosition(pLocal, viewPos, aimAngle, weaponDefIndex)
		if weaponOffset then
			firePos = weaponOffset
		end

		local translatedAngle = utils.math.SolveBallisticArc(firePos, targetPoint, speed, gravity)
		if not translatedAngle then
			return false
		end

		local trace
		if hasHull then
			trace = engine.TraceHull(firePos, targetPoint, hullMins, hullMaxs, traceMask, shouldHitEntity)
		else
			trace = engine.TraceLine(firePos, targetPoint, traceMask, shouldHitEntity)
		end

		if not trace then
			return false
		end

		if trace.fraction > VISIBILITY_THRESHOLD then
			return true
		end

		local hitEnt = trace.entity
		if hitEnt and hitEnt.GetIndex and hitEnt:GetIndex() == pTargetIndex then
			return true
		end

		return false
	end
end

---Find the furthest corner from shooter (to exclude)
---@param corners Vector3[]
---@param shootPos Vector3
---@return number furthestIndex
local function findFurthestCorner(corners, shootPos)
	local maxDist = -1
	local maxIdx = 1
	for i, corner in ipairs(corners) do
		local dist = (corner - shootPos):Length()
		if dist > maxDist then
			maxDist = dist
			maxIdx = i
		end
	end
	return maxIdx
end

---Get AABB center at predicted position
---@param targetPos Vector3
---@param mins Vector3
---@param maxs Vector3
---@return Vector3
local function getAABBCenter(targetPos, mins, maxs)
	return targetPos + (mins + maxs) * 0.5
end

---Get center of mass height (roughly 0.5 of standing height)
---@param targetPos Vector3
---@param mins Vector3
---@param maxs Vector3
---@return number comZ world Z coordinate
local function getCOMHeight(targetPos, mins, maxs)
	local worldMins = targetPos + mins
	local worldMaxs = targetPos + maxs
	return (worldMins.z + worldMaxs.z) * 0.5
end

---Determine which face of AABB is closest to shooter
---Returns 4 corner indices representing a face of the box
---@param corners Vector3[]
---@param shootPos Vector3
---@return number[] faceIndices {bl, br, tl, tr} corner indices for closest face
---@return Vector3 faceCenter center of that face
local function findClosestFace(corners, shootPos)
	-- The 4 vertical faces of the AABB:
	-- Face 1 (back):  corners 1,4,5,8 (y = min)
	-- Face 2 (front): corners 2,3,6,7 (y = max)
	-- Face 3 (left):  corners 1,2,5,6 (x = min)
	-- Face 4 (right): corners 3,4,7,8 (x = max)
	local faces = {
		{ 1, 4, 5, 8 }, -- back (bl, br, tl, tr)
		{ 2, 3, 6, 7 }, -- front
		{ 1, 2, 5, 6 }, -- left
		{ 4, 3, 8, 7 }, -- right
	}

	local closestDist = math.huge
	local closestFace = faces[1]
	local closestCenter = corners[1]

	for _, face in ipairs(faces) do
		local faceCenter = (corners[face[1]] + corners[face[2]] + corners[face[3]] + corners[face[4]]) * 0.25
		local dist = (faceCenter - shootPos):Length()
		if dist < closestDist then
			closestDist = dist
			closestFace = face
			closestCenter = faceCenter
		end
	end

	return closestFace, closestCenter
end

---Binary search vertically to find shootable point, prioritizing feet or center
---@param shootPos Vector3
---@param topPoint Vector3
---@param bottomPoint Vector3
---@param targetZ number target Z height to aim for (feet or center)
---@param hullMins Vector3
---@param hullMaxs Vector3
---@param traceMask number
---@return Vector3? bestPoint
---@return boolean hitTarget true if we hit the targetZ height
local function binarySearchVertical(canShootAtPoint, topPoint, bottomPoint, targetZ)
	assert(type(canShootAtPoint) == "function", "binarySearchVertical: canShootAtPoint must be function")
	local targetPoint = Vector3(bottomPoint.x, bottomPoint.y, targetZ)
	if canShootAtPoint(targetPoint) then
		return targetPoint, true
	end

	local bottomVisible = canShootAtPoint(bottomPoint)
	local topVisible = canShootAtPoint(topPoint)

	if not bottomVisible and not topVisible then
		return nil, false
	end

	-- Binary search from visible end towards target
	local best = nil
	local low, high

	if bottomVisible then
		-- Search from bottom up towards target
		low = bottomPoint
		high = topPoint
		best = bottomPoint
	else
		-- Search from top down towards target
		low = bottomPoint
		high = topPoint
		best = topPoint
	end

	for _ = 1, BINARY_SEARCH_ITERATIONS do
		local mid = (high + low) * 0.5

		if canShootAtPoint(mid) then
			best = mid
			-- Move toward target Z
			if mid.z > targetZ then
				high = mid -- Go lower
			else
				low = mid -- Go higher
			end
		else
			-- Move away from obstruction
			if bottomVisible then
				high = mid
			else
				low = mid
			end
		end
	end

	local hitTarget = best and math.abs(best.z - targetZ) < 10
	return best, hitTarget
end

---Binary search horizontally towards center line of face
---@param shootPos Vector3
---@param startPoint Vector3 point on the edge we found
---@param faceCenter Vector3 center of the face (target)
---@param hullMins Vector3
---@param hullMaxs Vector3
---@param traceMask number
---@param hullSize number projectile hull radius
---@return Vector3 bestPoint
local function binarySearchHorizontal(canShootAtPoint, viewPos, startPoint, faceCenter, hullSize)
	assert(type(canShootAtPoint) == "function", "binarySearchHorizontal: canShootAtPoint must be function")
	-- Target is the center line of the face at our Z height
	local targetXY = Vector3(faceCenter.x, faceCenter.y, startPoint.z)

	-- Check if we can shoot directly at center line
	if canShootAtPoint(targetXY) then
		-- Move slightly away from center by hull size for safety
		if hullSize > 0 then
			local dir = normalize(targetXY - viewPos)
			return targetXY - dir * hullSize
		end
		return targetXY
	end

	-- Binary search from start point towards center
	local outer = startPoint
	local inner = targetXY
	local best = startPoint

	for _ = 1, BINARY_SEARCH_ITERATIONS do
		local mid = (outer + inner) * 0.5

		if canShootAtPoint(mid) then
			best = mid
			outer = mid -- Go towards center
		else
			inner = mid -- Stay towards edge
		end
	end

	-- Offset by hull size from the edge we found
	if hullSize > 0 and best ~= startPoint then
		local edgeDir = normalize(startPoint - faceCenter)
		best = best + edgeDir * hullSize
	end

	return best
end

---@param pTarget Entity
---@param pWeapon Entity
---@param weaponInfo WeaponInfo
---@param vHeadPos Vector3 shooter eye position
---@param vecPredictedPos Vector3 predicted target position
---@param drop number gravity drop compensation
---@param speed number
---@param gravity number
---@return boolean visible, Vector3? finalPos
function multipoint.Run(pTarget, pWeapon, weaponInfo, vHeadPos, vecPredictedPos, drop, speed, gravity)
	assert(pTarget, "multipoint.Run: missing pTarget")
	assert(pWeapon, "multipoint.Run: missing pWeapon")
	assert(weaponInfo, "multipoint.Run: missing weaponInfo")
	assert(vHeadPos, "multipoint.Run: missing vHeadPos")
	assert(vecPredictedPos, "multipoint.Run: missing vecPredictedPos")
	assert(type(drop) == "number", "multipoint.Run: drop must be number")
	assert(type(speed) == "number", "multipoint.Run: speed must be number")
	assert(type(gravity) == "number", "multipoint.Run: gravity must be number")

	-- Get config settings
	local cfg = G.Config and G.Config.Aimbot or {}
	local preferFeet = cfg.PreferFeet ~= false -- default true
	local feetHeight = cfg.FeetHeight or 5
	local feetFallback = cfg.FeetFallback or 10

	local pLocal = entities.GetLocalPlayer()
	assert(pLocal, "multipoint.Run: entities.GetLocalPlayer() returned nil")

	-- Get target bounds
	local mins = pTarget:GetMins()
	local maxs = pTarget:GetMaxs()
	assert(mins and maxs, "multipoint.Run: target has no bounds")

	-- Apply gravity drop to predicted position
	local adjustedPos = vecPredictedPos + Vector3(0, 0, drop)

	-- Get AABB data
	local corners = getAABBCorners(adjustedPos, mins, maxs)
	local aabbCenter = getAABBCenter(adjustedPos, mins, maxs)
	local groundZ = (adjustedPos + mins).z -- bottom of AABB
	local topZ = (adjustedPos + maxs).z

	-- Get projectile info
	local hullMins = weaponInfo.m_vecMins or Vector3(0, 0, 0)
	local hullMaxs = weaponInfo.m_vecMaxs or Vector3(0, 0, 0)
	local traceMask = weaponInfo.m_iTraceMask or MASK_SHOT
	local hullSize = math.max(hullMaxs.x, hullMaxs.y, hullMaxs.z)
	local canShootAtPoint =
		createCanShootAt(pLocal, pTarget, pWeapon, weaponInfo, vHeadPos, speed, gravity, hullMins, hullMaxs, traceMask)

	-- Find furthest corner to exclude
	local furthestIdx = findFurthestCorner(corners, vHeadPos)

	-- Check which corners are shootable (7 corners, excluding furthest)
	local visibleCorners = {}
	for i = 1, 8 do
		if i ~= furthestIdx then
			visibleCorners[i] = canShootAtPoint(corners[i])
		else
			visibleCorners[i] = false
		end
	end

	-- Find closest face to shooter
	local closestFace, faceCenter = findClosestFace(corners, vHeadPos)
	local bl, br, tl, tr = closestFace[1], closestFace[2], closestFace[3], closestFace[4]

	-- Store debug state for visuals
	multipoint.debugState.corners = corners
	multipoint.debugState.visibleCorners = visibleCorners
	multipoint.debugState.aabbCenter = aabbCenter
	multipoint.debugState.closestFace = closestFace
	multipoint.debugState.faceCenter = faceCenter
	multipoint.debugState.searchPath = {}

	-- Calculate target heights
	local feetTargetZ = groundZ + feetHeight -- ~5 units above ground
	local centerTargetZ = (groundZ + topZ) * 0.5 -- center of AABB

	-- Get bottom and top points of closest face (center of bottom/top edges)
	local bottomCenter = (corners[bl] + corners[br]) * 0.5
	local topCenter = (corners[tl] + corners[tr]) * 0.5

	-- Phase 1: Vertical search - find best Z height
	local bestVerticalPoint = nil
	local hitFeet = false

	if preferFeet then
		-- Try to hit feet first (~5 units above ground)
		bestVerticalPoint, hitFeet = binarySearchVertical(canShootAtPoint, topCenter, bottomCenter, feetTargetZ)

		-- If we couldn't hit within feetFallback of ground, aim at center instead
		if bestVerticalPoint and not hitFeet then
			local distFromGround = bestVerticalPoint.z - groundZ
			if distFromGround > feetFallback then
				-- Can't hit feet, try center instead
				local centerPoint, _ = binarySearchVertical(canShootAtPoint, topCenter, bottomCenter, centerTargetZ)
				if centerPoint then
					bestVerticalPoint = centerPoint
				end
			end
		end
	else
		-- Not preferring feet, aim at center
		bestVerticalPoint, _ = binarySearchVertical(canShootAtPoint, topCenter, bottomCenter, centerTargetZ)
	end

	-- Fallback: try any visible corner on the face
	if not bestVerticalPoint then
		for _, idx in ipairs(closestFace) do
			if visibleCorners[idx] then
				bestVerticalPoint = corners[idx]
				break
			end
		end
	end

	-- Last resort: try any visible corner
	if not bestVerticalPoint then
		for i = 1, 8 do
			if visibleCorners[i] then
				bestVerticalPoint = corners[i]
				break
			end
		end
	end

	if not bestVerticalPoint then
		multipoint.debugState.bestPoint = nil
		return false, nil
	end

	table.insert(multipoint.debugState.searchPath, bestVerticalPoint)

	-- Phase 2: Horizontal search - move toward center line of face
	local finalPoint = binarySearchHorizontal(canShootAtPoint, vHeadPos, bestVerticalPoint, faceCenter, hullSize)

	table.insert(multipoint.debugState.searchPath, finalPoint)
	multipoint.debugState.bestPoint = finalPoint

	return true, finalPoint
end

return multipoint
