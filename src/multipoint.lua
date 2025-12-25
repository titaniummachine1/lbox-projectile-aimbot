local multipoint = {}

-- Imports
local G = require("globals")
local WeaponOffsets = require("constants.weapon_offsets")
local utils = {}
utils.math = require("utils.math")

-- Constants
local BINARY_SEARCH_ITERATIONS = 5
local VISIBILITY_THRESHOLD = 0.999
local PREFER_FEET_HEIGHT = 5
local PREFER_FEET_FALLBACK = 10

-- Debug state for visuals (exported for drawing)
multipoint.debugState = {
	corners = nil, -- All 8 corners
	visibleCorners = nil, -- Which corners are shootable
	searchPath = nil, -- Binary search path for visualization
	bestPoint = nil, -- Final selected point
	aabbCenter = nil, -- Center of AABB
	closestFace = nil, -- The face we're targeting
	faceCenter = nil, -- Center of the closest face
	intersectPoint = nil,
	intersectNormal = nil,
}

multipoint.debugPersist = {
	time = 0,
	state = nil,
}

---Normalize vector (handles zero-length)
---@param v Vector3
---@return Vector3
local function normalize(v)
	return v / v:Length()
end

local function clampNumber(value, minValue, maxValue)
	return math.max(minValue, math.min(value, maxValue))
end

local function copyVec3(v)
	if not v then
		return nil
	end
	return Vector3(v.x, v.y, v.z)
end

local function copyDebugState(dbg)
	if not dbg then
		return nil
	end

	local out = {
		corners = nil,
		visibleCorners = nil,
		searchPath = nil,
		bestPoint = copyVec3(dbg.bestPoint),
		aabbCenter = copyVec3(dbg.aabbCenter),
		closestFace = nil,
		faceCenter = copyVec3(dbg.faceCenter),
		intersectPoint = copyVec3(dbg.intersectPoint),
		intersectNormal = copyVec3(dbg.intersectNormal),
	}

	if dbg.corners then
		out.corners = {}
		for i = 1, 8 do
			out.corners[i] = copyVec3(dbg.corners[i])
		end
	end

	if dbg.visibleCorners then
		out.visibleCorners = {}
		for i = 1, 8 do
			out.visibleCorners[i] = dbg.visibleCorners[i] == true
		end
	end

	if dbg.searchPath then
		out.searchPath = {}
		for i = 1, #dbg.searchPath do
			out.searchPath[i] = copyVec3(dbg.searchPath[i])
		end
	end

	if dbg.closestFace then
		out.closestFace = { dbg.closestFace[1], dbg.closestFace[2], dbg.closestFace[3], dbg.closestFace[4] }
	end

	return out
end

local function persistDebugState(dbg)
	local now = (globals and globals.RealTime and globals.RealTime()) or 0
	multipoint.debugPersist.time = now
	multipoint.debugPersist.state = copyDebugState(dbg)
end

local function rayAABBClosestFaceHit(rayOrigin, rayTarget, worldMins, worldMaxs, verticalFacesOnly)
	assert(rayOrigin, "rayAABBClosestFaceHit: missing rayOrigin")
	assert(rayTarget, "rayAABBClosestFaceHit: missing rayTarget")
	assert(worldMins and worldMaxs, "rayAABBClosestFaceHit: missing bounds")

	local dir = rayTarget - rayOrigin
	local eps = 1e-6

	local bestT = math.huge
	local bestPoint = nil
	local bestAxis = nil
	local bestPlane = nil
	local bestNormal = nil

	local function tryAxis(axis)
		local originAxis
		local dirAxis
		local minAxis
		local maxAxis

		if axis == "x" then
			originAxis = rayOrigin.x
			dirAxis = dir.x
			minAxis = worldMins.x
			maxAxis = worldMaxs.x
		elseif axis == "y" then
			originAxis = rayOrigin.y
			dirAxis = dir.y
			minAxis = worldMins.y
			maxAxis = worldMaxs.y
		else
			originAxis = rayOrigin.z
			dirAxis = dir.z
			minAxis = worldMins.z
			maxAxis = worldMaxs.z
		end

		if math.abs(dirAxis) < eps then
			return
		end

		local planeAxis
		local normalSign
		if dirAxis > 0 then
			planeAxis = minAxis
			normalSign = -1
		else
			planeAxis = maxAxis
			normalSign = 1
		end

		local t = (planeAxis - originAxis) / dirAxis
		if t <= 1e-4 or t >= bestT then
			return
		end

		local hit = rayOrigin + (dir * t)
		local isInside = true
		if axis ~= "x" and (hit.x < worldMins.x or hit.x > worldMaxs.x) then
			isInside = false
		elseif axis ~= "y" and (hit.y < worldMins.y or hit.y > worldMaxs.y) then
			isInside = false
		elseif axis ~= "z" and (hit.z < worldMins.z or hit.z > worldMaxs.z) then
			isInside = false
		end

		if not isInside then
			return
		end

		bestT = t
		bestPoint = hit
		bestAxis = axis
		bestPlane = planeAxis
		if axis == "x" then
			bestNormal = Vector3(normalSign, 0, 0)
		elseif axis == "y" then
			bestNormal = Vector3(0, normalSign, 0)
		else
			bestNormal = Vector3(0, 0, normalSign)
		end
	end

	tryAxis("x")
	tryAxis("y")
	if not verticalFacesOnly then
		tryAxis("z")
	end

	return bestPoint, bestAxis, bestPlane, bestNormal
end

local function binarySearchTowardTarget(canShootAtPoint, startPoint, targetPoint, hullSize)
	assert(type(canShootAtPoint) == "function", "binarySearchTowardTarget: canShootAtPoint must be function")
	assert(startPoint, "binarySearchTowardTarget: missing startPoint")
	assert(targetPoint, "binarySearchTowardTarget: missing targetPoint")
	assert(type(hullSize) == "number", "binarySearchTowardTarget: hullSize must be number")

	if canShootAtPoint(targetPoint) then
		local best = targetPoint
		if hullSize > 0 then
			local dir = normalize(targetPoint - startPoint)
			best = best - dir * hullSize
		end
		return best
	end

	local best = startPoint
	local low = 0.0
	local high = 1.0

	for _ = 1, BINARY_SEARCH_ITERATIONS do
		local mid = (low + high) * 0.5
		local p = startPoint + (targetPoint - startPoint) * mid
		if canShootAtPoint(p) then
			best = p
			low = mid
		else
			high = mid
		end
	end

	if hullSize > 0 and best ~= startPoint then
		local dir = normalize(targetPoint - startPoint)
		best = best - dir * hullSize
	end

	return best
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

---Quick visibility pre-check using traceline (rocket assumption - no ballistic solve)
---Use this before expensive ballistic checks to skip completely occluded targets
local function createQuickVisCheck(pLocal, pTarget, firePos, traceMask)
	local pLocalIndex = pLocal:GetIndex()
	local pTargetIndex = pTarget:GetIndex()

	local function shouldHitEntity(ent, contentsMask)
		if not ent then
			return false
		end
		local idx = ent.GetIndex and ent:GetIndex() or nil
		if idx == pLocalIndex then
			return false
		end
		if idx == pTargetIndex then
			return true
		end
		return false
	end

	return function(targetPoint)
		local trace = engine.TraceLine(firePos, targetPoint, traceMask, shouldHitEntity)
		if not trace then
			return false
		end
		if trace.startsolid or trace.allsolid then
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

---Check if a point can be shot at (visibility + projectile path clear)
local function createCanShootAt(pLocal, pTarget, firePos, speed, gravity, hullMins, hullMaxs, traceMask)
	assert(pLocal, "createCanShootAt: missing pLocal")
	assert(pTarget, "createCanShootAt: missing pTarget")
	assert(firePos, "createCanShootAt: missing firePos")
	assert(type(speed) == "number", "createCanShootAt: speed must be number")
	assert(type(gravity) == "number", "createCanShootAt: gravity must be number")
	assert(hullMins, "createCanShootAt: missing hullMins")
	assert(hullMaxs, "createCanShootAt: missing hullMaxs")
	assert(type(traceMask) == "number", "createCanShootAt: traceMask must be number")

	local pLocalIndex = pLocal:GetIndex()
	assert(pLocalIndex, "createCanShootAt: pLocal:GetIndex() returned nil")
	local pTargetIndex = pTarget:GetIndex()
	assert(pTargetIndex, "createCanShootAt: pTarget:GetIndex() returned nil")

	local function shouldHitEntity(ent, contentsMask)
		if not ent then
			return false
		end
		local idx = ent.GetIndex and ent:GetIndex() or nil
		if idx == pLocalIndex then
			return false
		end
		if idx == pTargetIndex then
			return true
		end
		return false
	end

	local hasHull = (hullMins:Length() > 0.01 or hullMaxs:Length() > 0.01)
	local hasGravity = math.abs(gravity) > 1e-8

	return function(targetPoint)
		assert(targetPoint, "canShootAt: missing targetPoint")

		-- For ballistic projectiles, verify we can solve the arc
		if hasGravity then
			local aimAngle = utils.math.SolveBallisticArc(firePos, targetPoint, speed, gravity)
			if not aimAngle then
				return false
			end
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
		if trace.startsolid or trace.allsolid then
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
---@param canShootAtPoint function
---@param topPoint Vector3
---@param bottomPoint Vector3
---@param targetZ number target Z height to aim for (feet or center)
---@return Vector3? bestPoint
---@return boolean hitTarget true if we hit the targetZ height
local function binarySearchVertical(canShootAtPoint, topPoint, bottomPoint, targetZ)
	assert(type(canShootAtPoint) == "function", "binarySearchVertical: canShootAtPoint must be function")
	local targetPoint = Vector3(bottomPoint.x, bottomPoint.y, targetZ)
	if canShootAtPoint(targetPoint) then
		return targetPoint, true
	end

	-- Find ANY visible point on the vertical line
	local startPoint = nil
	if canShootAtPoint(bottomPoint) then
		startPoint = bottomPoint
	elseif canShootAtPoint(topPoint) then
		startPoint = topPoint
	else
		-- Sample more points to find any visible part of the player
		for z = bottomPoint.z + 5, topPoint.z - 5, 8 do
			local p = Vector3(bottomPoint.x, bottomPoint.y, z)
			if canShootAtPoint(p) then
				startPoint = p
				break
			end
		end
	end

	if not startPoint then
		return nil, false
	end

	-- Binary search from the visible point towards the target Z height
	local near = startPoint
	local far = targetPoint

	for _ = 1, BINARY_SEARCH_ITERATIONS do
		local mid = (near + far) * 0.5
		if canShootAtPoint(mid) then
			near = mid
		else
			far = mid
		end
	end

	local hitTarget = near and math.abs(near.z - targetZ) < 5
	return near, hitTarget
end

---Binary search horizontally towards center line of face
---@param canShootAtPoint function
---@param viewPos Vector3
---@param startPoint Vector3 point on the edge we found
---@param faceCenter Vector3 center of the face (target)
---@param hullSize number projectile hull radius
---@return Vector3 bestPoint
local function binarySearchHorizontal(canShootAtPoint, viewPos, startPoint, faceCenter, hullSize)
	assert(type(canShootAtPoint) == "function", "binarySearchHorizontal: canShootAtPoint must be function")
	-- Target is the center line of the face at our Z height
	local targetXY = Vector3(faceCenter.x, faceCenter.y, startPoint.z)

	local startVisible = canShootAtPoint(startPoint)
	local targetVisible = canShootAtPoint(targetXY)
	if not startVisible and not targetVisible then
		return startPoint
	end

	-- Check if we can shoot directly at center line
	if targetVisible then
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
		local edgeDir = normalize(Vector3(startPoint.x - faceCenter.x, startPoint.y - faceCenter.y, 0))
		best = best + edgeDir * hullSize
	end

	return best
end

---@param pTarget Entity
---@param pWeapon Entity
---@param weaponInfo WeaponInfo
---@param vHeadPos Vector3 shooter eye position
---@param vecPredictedPos Vector3 predicted target position (where target will be when projectile lands)
---@param speed number
---@param gravity number
---@return boolean visible, Vector3? finalPos
function multipoint.Run(pTarget, pWeapon, weaponInfo, vHeadPos, vecPredictedPos, speed, gravity)
	assert(pTarget, "multipoint.Run: missing pTarget")
	assert(pWeapon, "multipoint.Run: missing pWeapon")
	assert(weaponInfo, "multipoint.Run: missing weaponInfo")
	assert(vHeadPos, "multipoint.Run: missing vHeadPos")
	assert(vecPredictedPos, "multipoint.Run: missing vecPredictedPos")
	assert(type(speed) == "number", "multipoint.Run: speed must be number")
	assert(type(gravity) == "number", "multipoint.Run: gravity must be number")

	-- Get config settings
	local cfg = {}
	if G and G.Menu and G.Menu.Aimbot then
		cfg = G.Menu.Aimbot
	elseif G and G.Config and G.Config.Aimbot then
		cfg = G.Config.Aimbot
	end
	local preferFeet = (cfg.PreferFeet == nil) or (cfg.PreferFeet == true)
	local visCfg = (G and G.Menu and G.Menu.Visuals) or nil
	local shouldDebug = visCfg and visCfg.ShowMultipointDebug == true

	local pLocal = entities.GetLocalPlayer()
	assert(pLocal, "multipoint.Run: entities.GetLocalPlayer() returned nil")

	local isTargetOnGround = false
	do
		local okFlags, targetFlags = pcall(function()
			return pTarget:GetPropInt("m_fFlags")
		end)
		if okFlags and type(targetFlags) == "number" and type(FL_ONGROUND) == "number" then
			isTargetOnGround = (targetFlags & FL_ONGROUND) ~= 0
		end
	end

	-- Get target bounds
	local mins = pTarget:GetMins()
	local maxs = pTarget:GetMaxs()
	assert(mins and maxs, "multipoint.Run: target has no bounds")

	-- Use predicted position directly - ballistic solver handles gravity arc
	-- Do NOT add drop offset here; we want projectile to LAND at this position
	local adjustedPos = vecPredictedPos

	-- Get AABB data
	local corners = getAABBCorners(adjustedPos, mins, maxs)
	local aabbCenter = getAABBCenter(adjustedPos, mins, maxs)
	local comZ = getCOMHeight(adjustedPos, mins, maxs)
	local comPos = Vector3(aabbCenter.x, aabbCenter.y, comZ)
	local groundZ = (adjustedPos + mins).z -- bottom of AABB
	local topZ = (adjustedPos + maxs).z
	local worldMins = adjustedPos + mins
	local worldMaxs = adjustedPos + maxs

	-- Get projectile info
	local hullMins = weaponInfo.m_vecMins or Vector3(0, 0, 0)
	local hullMaxs = weaponInfo.m_vecMaxs or Vector3(0, 0, 0)
	local traceMask = weaponInfo.m_iTraceMask or MASK_SHOT
	local hullSize = math.max(hullMaxs.x, hullMaxs.y, hullMaxs.z)

	local referenceShootPos = vHeadPos
	local centerAimAngle = utils.math.SolveBallisticArc(vHeadPos, aabbCenter, speed, gravity)
	if centerAimAngle then
		local isFlipped = pWeapon.IsViewModelFlipped and pWeapon:IsViewModelFlipped() or false
		local weaponDefIndex = pWeapon:GetPropInt("m_iItemDefinitionIndex")
		assert(weaponDefIndex, "multipoint.Run: pWeapon:GetPropInt('m_iItemDefinitionIndex') returned nil")
		local isDucking = (pLocal:GetPropInt("m_fFlags") & FL_DUCKING) ~= 0
		local weaponOffset = WeaponOffsets.getOffset(weaponDefIndex, isDucking, isFlipped)

		local function computeReferenceFirePos(testAngle)
			if weaponOffset then
				local offsetPos = vHeadPos
					+ (testAngle:Forward() * weaponOffset.x)
					+ (testAngle:Right() * weaponOffset.y)
					+ (testAngle:Up() * weaponOffset.z)
				local resultTrace =
					engine.TraceHull(vHeadPos, offsetPos, -Vector3(8, 8, 8), Vector3(8, 8, 8), MASK_SHOT_HULL)
				if not resultTrace or resultTrace.startsolid then
					return nil
				end
				return resultTrace.endpos
			end

			return weaponInfo:GetFirePosition(pLocal, vHeadPos, testAngle, isFlipped)
		end

		local referenceFirePos = computeReferenceFirePos(centerAimAngle)
		if referenceFirePos then
			local angle1 = utils.math.SolveBallisticArc(referenceFirePos, aabbCenter, speed, gravity)
			if angle1 then
				local pos1 = computeReferenceFirePos(angle1)
				if pos1 then
					referenceFirePos = pos1
					local angle2 = utils.math.SolveBallisticArc(referenceFirePos, aabbCenter, speed, gravity)
					if angle2 then
						local pos2 = computeReferenceFirePos(angle2)
						if pos2 then
							referenceFirePos = pos2
						end
					end
				end
			end
			referenceShootPos = referenceFirePos
		end
	end

	local canShootAtPoint =
		createCanShootAt(pLocal, pTarget, referenceShootPos, speed, gravity, hullMins, hullMaxs, traceMask)

	-- Find furthest corner to exclude
	local furthestIdx = findFurthestCorner(corners, referenceShootPos)

	-- Check which corners are shootable (7 corners, excluding furthest)
	local visibleCorners = {}
	for i = 1, 8 do
		if i ~= furthestIdx then
			visibleCorners[i] = canShootAtPoint(corners[i])
		else
			visibleCorners[i] = false
		end
	end

	local anyCornerShootable = false
	for i = 1, 8 do
		if visibleCorners[i] then
			anyCornerShootable = true
			break
		end
	end

	-- Find closest face to shooter
	local closestFace, faceCenter = findClosestFace(corners, referenceShootPos)
	local bl, br, tl, tr = closestFace[1], closestFace[2], closestFace[3], closestFace[4]

	local intersectPoint, intersectAxis, intersectPlaneValue = nil, nil, nil
	local hasVerticalRayHit = false
	local hitPoint, hitAxis, hitPlane, hitNormal = rayAABBClosestFaceHit(vHeadPos, comPos, worldMins, worldMaxs, true)
	if hitPoint then
		hasVerticalRayHit = true
		intersectPoint = hitPoint
		intersectAxis = hitAxis
		intersectPlaneValue = hitPlane
	end
	if not intersectPoint then
		intersectPoint = faceCenter
		intersectAxis = "x"
		intersectPlaneValue = faceCenter.x
	end

	if shouldDebug then
		multipoint.debugState.corners = corners
		multipoint.debugState.visibleCorners = visibleCorners
		multipoint.debugState.aabbCenter = aabbCenter
		multipoint.debugState.closestFace = closestFace
		multipoint.debugState.faceCenter = faceCenter
		multipoint.debugState.intersectPoint = intersectPoint
		multipoint.debugState.intersectNormal = hitNormal
		multipoint.debugState.searchPath = {}
	end

	-- Calculate target heights
	local feetTargetZ = groundZ + PREFER_FEET_HEIGHT -- ~5 units above ground
	local centerTargetZ = (groundZ + topZ) * 0.5 -- center of AABB
	local defaultTargetZ = clampNumber(intersectPoint.z, groundZ, topZ)

	-- For explosives (gravity > 0), always prefer feet when target is on ground
	local isExplosive = math.abs(gravity) > 1e-8
	local preferFeetActive = preferFeet and isTargetOnGround and (hasVerticalRayHit or isExplosive)
	local feetPointShootable = false
	if preferFeetActive then
		local feetPoint = Vector3(intersectPoint.x, intersectPoint.y, feetTargetZ)
		feetPointShootable = canShootAtPoint(feetPoint)
		if feetPointShootable then
			if shouldDebug then
				multipoint.debugState.bestPoint = feetPoint
				table.insert(multipoint.debugState.searchPath, feetPoint)
				persistDebugState(multipoint.debugState)
			end
			return true, feetPoint
		end
	end

	local intersectPointShootable = canShootAtPoint(intersectPoint)
	if intersectPointShootable then
		if shouldDebug then
			multipoint.debugState.bestPoint = intersectPoint
			table.insert(multipoint.debugState.searchPath, intersectPoint)
			persistDebugState(multipoint.debugState)
		end
		return true, intersectPoint
	end

	if (not anyCornerShootable) and not feetPointShootable and not intersectPointShootable then
		if shouldDebug then
			multipoint.debugState.bestPoint = nil
		end
		return false, nil
	end

	local baseX = intersectPoint.x
	local baseY = intersectPoint.y
	local facePlane = intersectPlaneValue
	local faceAxis = intersectAxis

	local function makeFacePoint(coord, z)
		if faceAxis == "x" then
			return Vector3(facePlane, coord, z)
		end
		return Vector3(coord, facePlane, z)
	end

	local function isVerticalLineViable(coord)
		for z = groundZ, topZ, 8 do
			if canShootAtPoint(makeFacePoint(coord, z)) then
				return true
			end
		end
		return canShootAtPoint(makeFacePoint(coord, topZ))
	end

	local function tryFindClosestViableCoordToTarget(targetCoord, minCoord, maxCoord)
		local minOk = isVerticalLineViable(minCoord)
		local maxOk = isVerticalLineViable(maxCoord)

		local startCoord = nil
		if minOk and maxOk then
			startCoord = (math.abs(targetCoord - minCoord) < math.abs(targetCoord - maxCoord)) and minCoord or maxCoord
		elseif minOk then
			startCoord = minCoord
		elseif maxOk then
			startCoord = maxCoord
		else
			return nil
		end

		local near = startCoord
		local far = targetCoord
		for _ = 1, BINARY_SEARCH_ITERATIONS do
			local mid = (near + far) * 0.5
			if isVerticalLineViable(mid) then
				near = mid
			else
				far = mid
			end
		end

		return near
	end

	if faceAxis == "x" then
		local targetCoord = baseY
		if not isVerticalLineViable(targetCoord) then
			local bestCoord = tryFindClosestViableCoordToTarget(targetCoord, worldMins.y, worldMaxs.y)
			if bestCoord then
				baseY = bestCoord
			end
		end
	else
		local targetCoord = baseX
		if not isVerticalLineViable(targetCoord) then
			local bestCoord = tryFindClosestViableCoordToTarget(targetCoord, worldMins.x, worldMaxs.x)
			if bestCoord then
				baseX = bestCoord
			end
		end
	end

	local bottomCenter = Vector3(baseX, baseY, groundZ)
	local topCenter = Vector3(baseX, baseY, topZ)

	-- Phase 1: Vertical search - find best Z height
	local bestVerticalPoint = nil
	local hitFeet = false
	preferFeetActive = preferFeet and isTargetOnGround and hasVerticalRayHit

	if preferFeetActive then
		local feetPoint = nil
		feetPoint, hitFeet = binarySearchVertical(canShootAtPoint, topCenter, bottomCenter, feetTargetZ)
		if hitFeet and feetPoint then
			bestVerticalPoint = feetPoint
		end

		local feetFallbackTargetZ = groundZ + PREFER_FEET_FALLBACK
		if (not hitFeet) and (feetFallbackTargetZ > feetTargetZ) then
			local fallbackPoint, hitFallback =
				binarySearchVertical(canShootAtPoint, topCenter, bottomCenter, feetFallbackTargetZ)
			if hitFallback and fallbackPoint then
				bestVerticalPoint = fallbackPoint
				hitFeet = true
			end
		end

		if not hitFeet then
			local normalPoint, _ = binarySearchVertical(canShootAtPoint, topCenter, bottomCenter, defaultTargetZ)
			if normalPoint then
				bestVerticalPoint = normalPoint
			end
		end
	else
		bestVerticalPoint, _ = binarySearchVertical(canShootAtPoint, topCenter, bottomCenter, defaultTargetZ)
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
		if shouldDebug then
			multipoint.debugState.bestPoint = nil
		end
		return false, nil
	end

	if shouldDebug then
		table.insert(multipoint.debugState.searchPath, bestVerticalPoint)
	end

	local finalPoint = bestVerticalPoint

	if shouldDebug then
		table.insert(multipoint.debugState.searchPath, finalPoint)
		multipoint.debugState.bestPoint = finalPoint
		persistDebugState(multipoint.debugState)
	end

	return true, finalPoint
end

---Quick visibility pre-check using traceline only (rocket assumption)
---Use this BEFORE expensive ballistic checks to skip completely occluded targets
---@param pTarget Entity
---@param vHeadPos Vector3 shooter eye position
---@param vecPredictedPos Vector3 predicted target position
---@return boolean anyCornerVisible true if any corner is visible via traceline
function multipoint.QuickVisibilityCheck(pTarget, vHeadPos, vecPredictedPos)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		return false
	end

	local mins = pTarget:GetMins()
	local maxs = pTarget:GetMaxs()
	if not (mins and maxs) then
		return false
	end

	local corners = getAABBCorners(vecPredictedPos, mins, maxs)
	if not corners then
		return false
	end

	local traceMask = MASK_SHOT
	local quickCheck = createQuickVisCheck(pLocal, pTarget, vHeadPos, traceMask)

	-- Check corners + center - if ANY is visible, target might be shootable
	for i = 1, 8 do
		if quickCheck(corners[i]) then
			return true
		end
	end

	-- Also check center
	local center = getAABBCenter(vecPredictedPos, mins, maxs)
	if quickCheck(center) then
		return true
	end

	return false
end

function multipoint.CanShootAnyCornerNow(pTarget, pWeapon, weaponInfo, vHeadPos, speed, gravity)
	assert(pTarget, "multipoint.CanShootAnyCornerNow: missing pTarget")
	assert(pWeapon, "multipoint.CanShootAnyCornerNow: missing pWeapon")
	assert(weaponInfo, "multipoint.CanShootAnyCornerNow: missing weaponInfo")
	assert(vHeadPos, "multipoint.CanShootAnyCornerNow: missing vHeadPos")
	assert(type(speed) == "number", "multipoint.CanShootAnyCornerNow: speed must be number")
	assert(type(gravity) == "number", "multipoint.CanShootAnyCornerNow: gravity must be number")

	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		return false
	end

	local mins = pTarget:GetMins()
	local maxs = pTarget:GetMaxs()
	if not (mins and maxs) then
		return false
	end

	local targetPos = pTarget.GetAbsOrigin and pTarget:GetAbsOrigin() or nil
	if not targetPos then
		return false
	end

	local corners = getAABBCorners(targetPos, mins, maxs)
	if not corners then
		return false
	end

	local hullMins = weaponInfo.m_vecMins or Vector3(0, 0, 0)
	local hullMaxs = weaponInfo.m_vecMaxs or Vector3(0, 0, 0)
	local traceMask = weaponInfo.m_iTraceMask or MASK_SHOT

	local canShootAtPoint = createCanShootAt(pLocal, pTarget, vHeadPos, speed, gravity, hullMins, hullMaxs, traceMask)

	for i = 1, 8 do
		if canShootAtPoint(corners[i]) then
			return true
		end
	end

	return false
end

return multipoint
