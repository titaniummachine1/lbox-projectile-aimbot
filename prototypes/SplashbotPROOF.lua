--spalsh bot proof of concept by terminator or titaniummachine1(https://github.com/titaniummachine1)

local TickProfiler = require("tick_profiler")

-- Local constants
local HITBOX_COLOR = { 255, 255, 0, 255 } -- Yellow color for hitbox
local CENTER_COLOR = { 0, 255, 0, 255 } -- Green color for center square
local CENTER_SIZE = 12 -- Size of the center square (increased for visibility)
local LINE_COLOR = { 255, 255, 255, 255 } -- White color for lines

local CARDINAL_DOT_SIZE = 3 -- Size of cardinal direction dots
local TRACE_COLLISION_COLOR = { 255, 0, 0, 255 } -- Red color for trace collision points

local TRACE_DOT_SIZE = 4 -- Size of trace dots
local TRACE_COLLISION_DOT_SIZE = 8 -- Size of collision dots (2x bigger)
local CLOSEST_VISIBLE_COLOR = { 0, 255, 255, 255 } -- Cyan color for closest visible point
local CLOSEST_VISIBLE_SIZE = 8 -- Size of closest visible point (same as center)
local SECOND_COLOR = { 0, 64, 255, 255 } -- Blue color for best invisible point
local SECOND_SIZE = 6 -- Size of blue point
local BINSEARCH_COLOR = { 255, 165, 0, 255 } -- Orange color for binary search result
local BINSEARCH_SIZE = 10 -- Size of orange square
local BINARY_SEARCH_ITERATIONS = 8 -- Increased from 7 for higher precision
local RADIUS_TOLERANCE = 1.0
local NORMAL_TOLERANCE = 0.1 -- Reduced from 0.1 for more precise normal grouping
local POSITION_EPSILON = 1.0 -- 1 unit precision for position comparisons
local VISIBILITY_THRESHOLD = 0.99 -- Increased from 0.99 for stricter visibility checks
local CARDINAL_HULL_MINS = Vector3(-2, -2, -2)
local CARDINAL_HULL_MAXS = Vector3(2, 2, 2)
local MAX_SEGMENT_RADIUS = 1024

-- circle helper - REDUCED to 4 segments for performance (90 degree separation)
local CIRCLE_RADIUS = 181 -- units from centre‑of‑player to sample
local CIRCLE_SEGMENTS = 4 -- 4 segments at 90 degree intervals (was 24)

-- No precomputed cos/sin - we'll align dynamically to shooter-target direction

-- composite cost tuning
local DAMAGE_WT = 0.75 -- 75% weight on damage proximity (distance to target)
local DISTANCE_WT = 0.25 -- 25% weight on shooter distance
local CIRCLE_DOT_SIZE = 2 -- pixels; was TRACE_DOT_SIZE (=4)

-- explicit dot colors
local GRID_DOT_COLOR = { 255, 255, 255, 255 } -- white
local CIRCLE_DOT_COLOR = { 255, 0, 0, 255 } -- red

local DEBUG_DRAW_SEGMENT_SAMPLES = false
local SEGMENT_SAMPLE_COLOR = { 255, 255, 255, 120 }
local SEGMENT_SAMPLE_SIZE = 4

local function scoreSplash(distTarget, distView)
	return DAMAGE_WT * distTarget + DISTANCE_WT * distView
end

------------------------------------------------------------------
--  Keep a point only when the hit surface faces the eye
--     n  … trace.plane   (already unit length)
--     P  … trace.endpos  (impact point)
--     E  … local‑player eye position
--  Surface faces us when normal points toward our eye
--  n·(E-P) > 0 means normal points toward eye = surface faces us
------------------------------------------------------------------
local function PlaneFacesPlayer(normal, eyePos, hitPos)
	return normal:Dot(eyePos - hitPos) > 0
end

-- Cached radii for each direction and segment (persists between ticks)
local cachedRadii = {} -- [playerIndex][directionIndex][segmentIndex] = radius

local cachedProjectileInfoResolver = nil
local cachedBlastRadiusWeaponId = nil
local cachedBlastRadiusValue = 169

local EXTRA_TRACE_REACH = 77
local cachedSplashData = {}

local cachedSegmentRadii = {}
local PLANE_NORMAL_SIMILARITY = 0.95
local RADIUS_HYSTERESIS = 1.5
local SEGMENT_SEARCH_ITERATIONS = 6
local SEGMENT_SEARCH_EPSILON = 1.0
local cachedBlueprint = {}

-- Function to check if entity should be hit (ignore target player and teammates)
local function shouldHitEntityFun(entity, targetPlayer, ignoreEntities)
	if not entity or not targetPlayer then
		return false
	end

	-- ignore target player early (before any contents checks)
	if entity:GetName() == targetPlayer:GetName() then
		return false
	end

	-- Ignore all players; we only need brushes/props for splash prediction
	if entity:IsPlayer() then
		return false
	end

	-- Ignore entities from the ignore list
	if ignoreEntities then
		for _, ignoreEntity in ipairs(ignoreEntities) do
			if entity:GetClass() == ignoreEntity then
				return false
			end
		end
	end

	local pos = entity:GetAbsOrigin() + Vector3(0, 0, 1)
	local contents = engine.GetPointContents(pos)
	if contents ~= 0 then
		return true
	end
	return true
end

-- Function to check if two normals are approximately equal
local function AreNormalsEqual(normal1, normal2)
	local diff = normal1 - normal2
	return vector.Length(diff) < NORMAL_TOLERANCE
end

-- Function to check if two positions are approximately equal
local function ArePositionsEqual(pos1, pos2, epsilon)
	epsilon = epsilon or POSITION_EPSILON
	local diff = pos1 - pos2
	return vector.Length(diff) < epsilon
end

-- Function to find closest point on AABB to a given point
local function GetClosestPointOnAABB(aabbMin, aabbMax, point)
	return Vector3(
		math.max(aabbMin.x, math.min(point.x, aabbMax.x)),
		math.max(aabbMin.y, math.min(point.y, aabbMax.y)),
		math.max(aabbMin.z, math.min(point.z, aabbMax.z))
	)
end

local function GetPlayerCOM(player)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	if not mins or not maxs then
		return nil
	end
	return player:GetAbsOrigin() + (mins + maxs) / 2
end

local function GetPlayerWorldAABB(player)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	if not mins or not maxs then
		return nil
	end
	local pos = player:GetAbsOrigin()
	return pos + mins, pos + maxs
end

local function CanSplashDamagePlayerFromPoint(pointPos, targetPlayer, blastRadius)
	if not pointPos or not targetPlayer or not blastRadius then
		return false
	end

	local aabbMin, aabbMax = GetPlayerWorldAABB(targetPlayer)
	if not aabbMin or not aabbMax then
		return false
	end

	local closest = GetClosestPointOnAABB(aabbMin, aabbMax, pointPos)
	if (pointPos - closest):Length() > blastRadius then
		return false
	end

	local start = pointPos
	local dir = closest - pointPos
	local dist = dir:Length()
	if dist > 0 then
		start = pointPos + (dir / dist) * 0.5
	end
	local tr = engine.TraceLine(start, closest, MASK_SHOT + CONTENTS_GRATE)
	return tr.entity and tr.entity:GetIndex() == targetPlayer:GetIndex()
end

local function CanSplashFromPoint(pointPos, targetCOM, targetPlayer, blastRadius)
	if not pointPos or not targetCOM or not targetPlayer then
		return false
	end

	local delta = targetCOM - pointPos
	local dist = delta:Length()
	if dist == 0 then
		return false
	end

	local dir = delta / dist
	local segEnd = pointPos + dir * math.min(dist, blastRadius)
	local tr = engine.TraceLine(pointPos, segEnd, MASK_SHOT + CONTENTS_GRATE)
	return tr.entity and tr.entity:GetIndex() == targetPlayer:GetIndex()
end

local GetWeaponBlastRadius
local CanDamageFrom

local function ComputeSplashDataForPlayer(targetPlayer, localPlayer, prevData)
	TickProfiler.BeginSection("ComputeSplashDataForPlayer")
	assert(targetPlayer, "ComputeSplashDataForPlayer: missing targetPlayer")
	assert(localPlayer, "ComputeSplashDataForPlayer: missing localPlayer")

	local viewOffset = localPlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
	if not viewOffset then
		return nil
	end
	local eye = localPlayer:GetAbsOrigin() + viewOffset

	local com = GetPlayerCOM(targetPlayer)
	if not com then
		return nil
	end

	local blastRadius = GetWeaponBlastRadius()
	local maxProbeDist = blastRadius + EXTRA_TRACE_REACH

	local shouldHitEntity = function(entity, _contentsMask)
		return shouldHitEntityFun(entity, targetPlayer, nil)
	end

	local traceMask = MASK_SHOT + CONTENTS_GRATE

	local playerIdx = targetPlayer:GetIndex()
	cachedRadii[playerIdx] = cachedRadii[playerIdx] or {}
	cachedBlueprint[playerIdx] = cachedBlueprint[playerIdx] or {}

	local function BuildBasis(n)
		local tmp = (math.abs(n.z) < 0.9) and Vector3(0, 0, 1) or Vector3(1, 0, 0)
		local u = vector.Normalize(tmp:Cross(n))
		local v = n:Cross(u)
		return u, v
	end

	local axisDirs = {
		-- 6 faces
		Vector3(1, 0, 0), -- 1: +X (right)
		Vector3(-1, 0, 0), -- 2: -X (left)
		Vector3(0, 1, 0), -- 3: +Y (forward)
		Vector3(0, -1, 0), -- 4: -Y (back)
		Vector3(0, 0, 1), -- 5: +Z (up)
		Vector3(0, 0, -1), -- 6: -Z (down)
		-- 12 edges
		vector.Normalize(Vector3(1, 1, 0)), -- 7: +X+Y
		vector.Normalize(Vector3(1, -1, 0)), -- 8: +X-Y
		vector.Normalize(Vector3(-1, 1, 0)), -- 9: -X+Y
		vector.Normalize(Vector3(-1, -1, 0)), -- 10: -X-Y
		vector.Normalize(Vector3(1, 0, 1)), -- 11: +X+Z
		vector.Normalize(Vector3(1, 0, -1)), -- 12: +X-Z
		vector.Normalize(Vector3(-1, 0, 1)), -- 13: -X+Z
		vector.Normalize(Vector3(-1, 0, -1)), -- 14: -X-Z
		vector.Normalize(Vector3(0, 1, 1)), -- 15: +Y+Z
		vector.Normalize(Vector3(0, 1, -1)), -- 16: +Y-Z
		vector.Normalize(Vector3(0, -1, 1)), -- 17: -Y+Z
		vector.Normalize(Vector3(0, -1, -1)), -- 18: -Y-Z
		-- 8 corners
		vector.Normalize(Vector3(1, 1, 1)), -- 19: +X+Y+Z
		vector.Normalize(Vector3(1, 1, -1)), -- 20: +X+Y-Z
		vector.Normalize(Vector3(1, -1, 1)), -- 21: +X-Y+Z
		vector.Normalize(Vector3(1, -1, -1)), -- 22: +X-Y-Z
		vector.Normalize(Vector3(-1, 1, 1)), -- 23: -X+Y+Z
		vector.Normalize(Vector3(-1, 1, -1)), -- 24: -X+Y-Z
		vector.Normalize(Vector3(-1, -1, 1)), -- 25: -X-Y+Z
		vector.Normalize(Vector3(-1, -1, -1)), -- 26: -X-Y-Z
	}

	-- Neighbor relationships: each direction's adjacent directions
	local dirNeighbors = {
		{ 5, 11, 19, 21, 3, 7, 4, 8 }, -- 1: +X neighbors
		{ 5, 13, 23, 25, 3, 9, 4, 10 }, -- 2: -X neighbors
		{ 5, 15, 19, 23, 1, 7, 2, 9 }, -- 3: +Y neighbors
		{ 5, 17, 21, 25, 1, 8, 2, 10 }, -- 4: -Y neighbors
		{ 1, 11, 13, 3, 15, 4, 17, 2 }, -- 5: +Z neighbors
		{ 1, 12, 14, 3, 16, 4, 18, 2 }, -- 6: -Z neighbors
		{ 1, 3, 5, 11, 15, 19 }, -- 7: +X+Y neighbors
		{ 1, 4, 5, 11, 17, 21 }, -- 8: +X-Y neighbors
		{ 2, 3, 5, 13, 15, 23 }, -- 9: -X+Y neighbors
		{ 2, 4, 5, 13, 17, 25 }, -- 10: -X-Y neighbors
		{ 1, 5, 7, 8, 19, 21 }, -- 11: +X+Z neighbors
		{ 1, 6, 7, 8, 20, 22 }, -- 12: +X-Z neighbors
		{ 2, 5, 9, 10, 23, 25 }, -- 13: -X+Z neighbors
		{ 2, 6, 9, 10, 24, 26 }, -- 14: -X-Z neighbors
		{ 3, 5, 7, 9, 19, 23 }, -- 15: +Y+Z neighbors
		{ 3, 6, 7, 9, 20, 24 }, -- 16: +Y-Z neighbors
		{ 4, 5, 8, 10, 21, 25 }, -- 17: -Y+Z neighbors
		{ 4, 6, 8, 10, 22, 26 }, -- 18: -Y-Z neighbors
		{ 1, 3, 5, 7, 11, 15 }, -- 19: +X+Y+Z neighbors
		{ 1, 3, 6, 7, 12, 16 }, -- 20: +X+Y-Z neighbors
		{ 1, 4, 5, 8, 11, 17 }, -- 21: +X-Y+Z neighbors
		{ 1, 4, 6, 8, 12, 18 }, -- 22: +X-Y-Z neighbors
		{ 2, 3, 5, 9, 13, 15 }, -- 23: -X+Y+Z neighbors
		{ 2, 3, 6, 9, 14, 16 }, -- 24: -X+Y-Z neighbors
		{ 2, 4, 5, 10, 13, 17 }, -- 25: -X-Y+Z neighbors
		{ 2, 4, 6, 10, 14, 18 }, -- 26: -X-Y-Z neighbors
	}

	-- Bottom 9 directions (have -Z component): always check these
	local bottomDirs = { 6, 12, 14, 16, 18, 20, 22, 24, 26 }

	local out = prevData or {}
	local points = out.points or {}
	for i = #points, 1, -1 do
		points[i] = nil
	end
	local step = (2 * math.pi) / CIRCLE_SEGMENTS

	-- First pass: trace all 26 directions for hit/miss detection
	-- Use plane ONLY for backface culling, no caching
	local directionHits = {}
	for planeId = 1, #axisDirs do
		local axis = axisDirs[planeId]
		local seedTr = engine.TraceLine(com, com + axis * maxProbeDist, traceMask, shouldHitEntity)
		if seedTr and seedTr.fraction < 1.0 and seedTr.endpos and seedTr.plane then
			-- Check backface culling - only accept if plane faces player
			if PlaneFacesPlayer(seedTr.plane, eye, seedTr.endpos) then
				directionHits[planeId] = true
			else
				directionHits[planeId] = false
			end
		else
			directionHits[planeId] = false
		end
	end

	-- Helper: check if direction is in bottom 9
	local function IsBottomDir(planeId)
		for _, bottomId in ipairs(bottomDirs) do
			if bottomId == planeId then
				return true
			end
		end
		return false
	end

	-- Helper: check if direction and all neighbors missed
	local function ShouldSkipDirection(planeId)
		if IsBottomDir(planeId) then
			return false -- never skip bottom directions
		end
		if directionHits[planeId] then
			return false -- hit something, don't skip
		end
		-- Check if any neighbor hit
		local neighbors = dirNeighbors[planeId]
		if neighbors then
			for _, neighborId in ipairs(neighbors) do
				if directionHits[neighborId] then
					return false -- neighbor hit, don't skip
				end
			end
		end
		return true -- this direction and all neighbors missed
	end

	for planeId = 1, #axisDirs do
		TickProfiler.BeginSection("PlaneIteration")
		repeat
			local axis, seedTr, planeLocked, planePoint, planeNormal, hub
			local toCom, planeBlueprint, useCache, hubDelta, dirs
			local RebuildDirs

			-- Early termination: skip if direction and neighbors all missed
			if ShouldSkipDirection(planeId) then
				break
			end
			axis = axisDirs[planeId]
			-- Trace for this plane (accepts duplicate trace for memory savings)
			seedTr = engine.TraceLine(com, com + axis * maxProbeDist, traceMask, shouldHitEntity)
			planeLocked = false
			planePoint = nil
			planeNormal = nil
			hub = nil
			if seedTr and seedTr.fraction < 1.0 and seedTr.endpos and seedTr.plane then
				planePoint = seedTr.endpos
				planeNormal = seedTr.plane
				if PlaneFacesPlayer(planeNormal, eye, planePoint) then
					toCom = com - planePoint
					hub = com - planeNormal * toCom:Dot(planeNormal)
					planeLocked = true
				end
			end
			if not planeLocked then
				-- fallback: assume an orientation plane at max range
				planePoint = com + axis * maxProbeDist
				planeNormal = axis * -1
				hub = planePoint
				cachedBlueprint[playerIdx][planeId] = nil
			end

			planeBlueprint = planeLocked and cachedBlueprint[playerIdx][planeId] or nil
			useCache = false
			if planeBlueprint and planeBlueprint.normal and planeBlueprint.hub and planeBlueprint.maxProbeDist then
				if planeBlueprint.maxProbeDist == maxProbeDist then
					hubDelta = hub - planeBlueprint.hub
					if hubDelta:Length() <= 1.0 and planeBlueprint.normal:Dot(planeNormal) >= 0.999 then
						useCache = true
					end
				end
			end

			RebuildDirs = function()
				local u, v = BuildBasis(planeNormal)
				-- Align first segment toward shooter (eye position)
				local toEye = eye - hub
				local toEyeFlat = toEye - planeNormal * toEye:Dot(planeNormal)
				local toEyeLen = toEyeFlat:Length()

				local newDirs = {}
				if toEyeLen > 0.01 then
					-- Align u to point toward shooter
					u = toEyeFlat / toEyeLen
					v = planeNormal:Cross(u)
				end

				-- 4 segments at 0, 90, 180, 270 degrees
				newDirs[0] = u -- toward shooter
				newDirs[1] = v -- 90 degrees
				newDirs[2] = u * -1 -- 180 degrees (away from shooter)
				newDirs[3] = v * -1 -- 270 degrees
				return newDirs
			end

			if useCache then
				dirs = planeBlueprint.dirs
			else
				dirs = RebuildDirs()
				if planeLocked then
					cachedBlueprint[playerIdx][planeId] = {
						normal = planeNormal,
						hub = hub,
						maxProbeDist = maxProbeDist,
						dirs = dirs,
					}
				end
			end

			cachedRadii[playerIdx][planeId] = cachedRadii[playerIdx][planeId] or {}
			cachedSegmentRadii[playerIdx] = cachedSegmentRadii[playerIdx] or {}
			cachedSegmentRadii[playerIdx][planeId] = cachedSegmentRadii[playerIdx][planeId] or {}

			for seg = 0, CIRCLE_SEGMENTS - 1 do
				TickProfiler.BeginSection("SegmentSearch")
				repeat
					local dirPlane = dirs[seg]
					local segCache = cachedSegmentRadii[playerIdx][planeId][seg]
					if not segCache then
						segCache = { buf = {}, head = 1, count = 0 }
						cachedSegmentRadii[playerIdx][planeId][seg] = segCache
					end
					local function PushSample(sample)
						local idx = segCache.head
						segCache.buf[idx] = sample
						segCache.head = idx + 1
						if segCache.head > 22 then
							segCache.head = 1
						end
						if segCache.count < 22 then
							segCache.count = segCache.count + 1
						end
					end

					local traceOut = 16
					local traceIn = 64
					local function TraceSurface(radius)
						TickProfiler.BeginSection("TraceSurface")
						local sample = hub + dirPlane * radius
						PushSample(sample)
						local start = sample + planeNormal * traceOut
						local stop = sample - planeNormal * traceIn
						local tr = engine.TraceLine(start, stop, traceMask, shouldHitEntity)
						if (not tr) or tr.fraction >= 1.0 or not tr.endpos or not tr.plane then
							return nil
						end
						if tr.plane:Dot(planeNormal) < PLANE_NORMAL_SIMILARITY then
							return nil
						end
						if not PlaneFacesPlayer(tr.plane, eye, tr.endpos) then
							return nil
						end
						TickProfiler.EndSection("TraceSurface")
						return tr
					end
					local function EvalRadius(radius)
						local tr = TraceSurface(radius)
						if not tr then
							return false
						end
						if not CanDamageFrom(tr.endpos, com, targetPlayer, blastRadius) then
							return false
						end
						return true, tr.endpos, tr.fraction, tr.plane
					end
					local function EvalTrace(tr)
						if not tr then
							return false
						end
						if not CanDamageFrom(tr.endpos, com, targetPlayer, blastRadius) then
							return false
						end
						return true, tr.endpos, tr.fraction, tr.plane
					end

					local cached = cachedRadii[playerIdx][planeId][seg]
					local minR = 8
					local maxR = math.min(maxProbeDist, MAX_SEGMENT_RADIUS)
					local prevR, trPrev, trMax, trMin, low, high
					local bestR, bestPos, bestFrac, bestN
					local okMax, posMax, fracMax, nMax
					local okMin, posMin, fracMin, nMin
					local midR, okMid, posMid, fracMid, nMid
					local iterCount, mid
					local okPrev, posPrev, fracPrev, nPrev
					local okPrevR, posPrevR, fracPrevR, nPrevR

					if maxR <= minR then
						break
					end

					prevR = cached and cached.radius
					trPrev = nil
					if prevR and prevR >= minR and prevR <= maxR then
						trPrev = TraceSurface(prevR)
					end
					trMax = TraceSurface(maxR)
					trMin = nil
					if (not trPrev) and not trMax then
						trMin = TraceSurface(minR)
						if not trMin then
							break
						end
					end
					low = minR
					high = maxR
					if cached and cached.low and cached.high then
						low = math.max(minR, cached.low)
						high = math.min(maxR, cached.high)
					end

					bestR = nil
					bestPos = nil
					bestFrac = nil
					bestN = nil

					if trPrev and prevR and prevR >= minR and prevR <= maxR then
						okPrevR, posPrevR, fracPrevR, nPrevR = EvalTrace(trPrev)
						if okPrevR then
							bestR, bestPos, bestFrac, bestN = prevR, posPrevR, fracPrevR, nPrevR
							low = prevR
						end
					end

					okMax, posMax, fracMax, nMax = EvalTrace(trMax)
					if okMax then
						bestR, bestPos, bestFrac, bestN = maxR, posMax, fracMax, nMax
					else
						if not bestR then
							if not trMin then
								trMin = TraceSurface(minR)
							end
							okMin, posMin, fracMin, nMin = EvalTrace(trMin)
							if okMin then
								bestR, bestPos, bestFrac, bestN = minR, posMin, fracMin, nMin
								low = minR
							else
								midR = (minR + maxR) * 0.5
								okMid, posMid, fracMid, nMid = EvalRadius(midR)
								if okMid then
									bestR, bestPos, bestFrac, bestN = midR, posMid, fracMid, nMid
									low = midR
								else
									break
								end
							end
						end
						high = maxR
						iterCount = math.min(SEGMENT_SEARCH_ITERATIONS, 4)
						for _ = 1, iterCount do
							if (high - low) <= SEGMENT_SEARCH_EPSILON then
								break
							end
							mid = (low + high) * 0.5
							okMid, posMid, fracMid, nMid = EvalRadius(mid)
							if okMid then
								bestR, bestPos, bestFrac, bestN = mid, posMid, fracMid, nMid
								low = mid
							else
								high = mid
							end
						end
					end

					if not bestR or bestR < 10 then
						break
					end

					if prevR and math.abs(bestR - prevR) < RADIUS_HYSTERESIS then
						okPrev, posPrev, fracPrev, nPrev = EvalRadius(prevR)
						if okPrev then
							bestR, bestPos, bestFrac, bestN = prevR, posPrev, fracPrev, nPrev
						end
					end
					cachedRadii[playerIdx][planeId][seg] = {
						radius = bestR,
						low = bestR - RADIUS_TOLERANCE,
						high = bestR + RADIUS_TOLERANCE,
					}

					table.insert(points, {
						pos = bestPos,
						fraction = bestFrac or 1.0,
						radius = bestR,
						normal = bestN or planeNormal,
						segmentIndex = seg,
						planeId = planeId,
					})

				until true
				TickProfiler.EndSection("SegmentSearch")
			end

		until true
		TickProfiler.EndSection("PlaneIteration")
	end

	out.playerIndex = targetPlayer:GetIndex()
	out.com = com
	out.blastRadius = blastRadius
	out.eye = eye
	out.points = points
	TickProfiler.EndSection("ComputeSplashDataForPlayer")
	return out
end

-- Function to check if an explosion at pointPos will splash the player's COM
GetWeaponBlastRadius = function()
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then
		return 169
	end -- fallback

	local weapon = localPlayer:GetPropEntity("m_hActiveWeapon")
	if not weapon then
		return cachedBlastRadiusValue
	end

	if not cachedProjectileInfoResolver then
		local success, projectileInfo = pcall(function()
			return require("projectile_info")
		end)
		if success and projectileInfo then
			cachedProjectileInfoResolver = projectileInfo
		end
	end

	local weaponId = weapon:GetPropInt("m_iItemDefinitionIndex")
	if not weaponId then
		weaponId = 0
	end
	if weaponId and cachedBlastRadiusWeaponId == weaponId then
		return cachedBlastRadiusValue
	end

	local blastRadius = 169
	if cachedProjectileInfoResolver and weaponId then
		local info = cachedProjectileInfoResolver(weaponId)
		if info and info.m_flDamageRadius then
			blastRadius = info.m_flDamageRadius
		end
	end

	cachedBlastRadiusWeaponId = weaponId
	cachedBlastRadiusValue = blastRadius
	return blastRadius
end

CanDamageFrom = function(pointPos, targetCOM, targetPlayer, blastRadius)
	local BLAST_RADIUS = blastRadius or GetWeaponBlastRadius()
	return CanSplashFromPoint(pointPos, targetCOM, targetPlayer, BLAST_RADIUS)
end

-- Function to perform binary search toward AABB closest point on the same plane
-- Precision improvements:
-- - Increased iterations from 7 to 10 for finer search
-- - Early termination when search range < 1mm
-- - Stricter visibility threshold (0.995 vs 0.99)
-- - Consistent epsilon values throughout
local function BinarySearchTowardAABB(visiblePt, targetAABBPoint, planeNormal, viewPos, shouldHitEntity)
	local A = visiblePt.pos

	-- Project direction from visible point to AABB point onto the plane
	local rawDir = targetAABBPoint - A
	local projDir = rawDir - planeNormal * rawDir:Dot(planeNormal) -- remove normal component
	local dir = vector.Normalize(projDir)

	-- Total distance we can go in that direction
	local maxDist = projDir:Length()

	local best = visiblePt
	local low, high = 0, maxDist

	for _ = 1, BINARY_SEARCH_ITERATIONS do
		local mid = (low + high) * 0.5
		local M = A + dir * mid

		-- Early termination if search range is very small
		if (high - low) < POSITION_EPSILON then
			break
		end

		-- Trace to find the actual wall point
		local tr = engine.TraceLine(A, M, MASK_SHOT, shouldHitEntity)
		if tr.fraction < 1.0 then
			M = tr.endpos
		end

		-- Visibility check from player's POV (more precise)
		local visOK = engine.TraceLine(viewPos, M, MASK_SHOT + CONTENTS_GRATE).fraction > VISIBILITY_THRESHOLD
		if visOK then
			best = { pos = M, screen = client.WorldToScreen(M), normal = visiblePt.normal }
			low = mid
		else
			high = mid
		end
	end

	return best
end

-- Function to draw AABB collision bounds around a player
local function DrawPlayerAABB(player, localPlayer, blastRadius, eye)
	TickProfiler.BeginSection("DrawPlayerAABB")
	if not player or not player:IsAlive() then
		TickProfiler.EndSection("DrawPlayerAABB")
		return
	end

	local shouldHitEntity = function(entity, _contentsMask)
		return shouldHitEntityFun(entity, player, nil)
	end

	-- Get player collision bounds (AABB)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	if not mins or not maxs then
		return
	end
	local playerPos = player:GetAbsOrigin()

	-- Calculate world space bounds
	local worldMins = playerPos + mins
	local worldMaxs = playerPos + maxs

	-- Calculate vertices of the AABB (world space)
	local worldVertices = {
		Vector3(worldMins.x, worldMins.y, worldMins.z), -- Bottom-back-left
		Vector3(worldMins.x, worldMaxs.y, worldMins.z), -- Bottom-front-left
		Vector3(worldMaxs.x, worldMaxs.y, worldMins.z), -- Bottom-front-right
		Vector3(worldMaxs.x, worldMins.y, worldMins.z), -- Bottom-back-right
		Vector3(worldMins.x, worldMins.y, worldMaxs.z), -- Top-back-left
		Vector3(worldMins.x, worldMaxs.y, worldMaxs.z), -- Top-front-left
		Vector3(worldMaxs.x, worldMaxs.y, worldMaxs.z), -- Top-front-right
		Vector3(worldMaxs.x, worldMins.y, worldMaxs.z), -- Top-back-right
	}

	-- Convert 3D coordinates to 2D screen coordinates
	local vertices = {}
	for i, vertex in ipairs(worldVertices) do
		vertices[i] = client.WorldToScreen(vertex)
	end

	-- Draw lines between vertices to visualize the box
	if
		vertices[1]
		and vertices[2]
		and vertices[3]
		and vertices[4]
		and vertices[5]
		and vertices[6]
		and vertices[7]
		and vertices[8]
	then
		-- Set color for AABB
		draw.Color(table.unpack(HITBOX_COLOR))

		-- Draw front face
		draw.Line(vertices[1][1], vertices[1][2], vertices[2][1], vertices[2][2])
		draw.Line(vertices[2][1], vertices[2][2], vertices[3][1], vertices[3][2])
		draw.Line(vertices[3][1], vertices[3][2], vertices[4][1], vertices[4][2])
		draw.Line(vertices[4][1], vertices[4][2], vertices[1][1], vertices[1][2])

		-- Draw back face
		draw.Line(vertices[5][1], vertices[5][2], vertices[6][1], vertices[6][2])
		draw.Line(vertices[6][1], vertices[6][2], vertices[7][1], vertices[7][2])
		draw.Line(vertices[7][1], vertices[7][2], vertices[8][1], vertices[8][2])
		draw.Line(vertices[8][1], vertices[8][2], vertices[5][1], vertices[5][2])

		-- Draw connecting lines
		draw.Line(vertices[1][1], vertices[1][2], vertices[5][1], vertices[5][2])
		draw.Line(vertices[2][1], vertices[2][2], vertices[6][1], vertices[6][2])
		draw.Line(vertices[3][1], vertices[3][2], vertices[7][1], vertices[7][2])
		draw.Line(vertices[4][1], vertices[4][2], vertices[8][1], vertices[8][2])

		-- Calculate center of the AABB
		local center = playerPos + (mins + maxs) / 2
		local BLAST_RADIUS = blastRadius or GetWeaponBlastRadius()
		local centerScreen = client.WorldToScreen(center)

		-- Variable to store the binary search result for green square
		local binarySearchResult = nil

		-- Only proceed if center is visible on screen
		if centerScreen then
			-- Draw extended points for all directions (cardinal, diagonal, and edge midpoints)

			-- Cardinal directions (up, down, left, right, forward, back)
			local cardinalDirections = {
				Vector3(0, 0, 1), -- Up
				Vector3(0, 0, -1), -- Down
				Vector3(-1, 0, 0), -- Left
				Vector3(1, 0, 0), -- Right
				Vector3(0, 1, 0), -- Forward
				Vector3(0, -1, 0), -- Back
			}

			-- Collect all collision points for sorting and grouping
			local collisionPoints = {}
			local normalGroups = {} -- Group points by surface normal
			local generatedPlaneKeys = {}

			local function SignedDistanceToPlane(planeNormal, planePoint, point)
				assert(planeNormal, "SignedDistanceToPlane: missing planeNormal")
				assert(planePoint, "SignedDistanceToPlane: missing planePoint")
				assert(point, "SignedDistanceToPlane: missing point")
				return (point - planePoint):Dot(planeNormal)
			end

			local function TraceSplashPointOnPlane(hub, planeNormal, dirInPlane, radius)
				assert(hub, "TraceSplashPointOnPlane: missing hub")
				assert(planeNormal, "TraceSplashPointOnPlane: missing planeNormal")
				assert(dirInPlane, "TraceSplashPointOnPlane: missing dirInPlane")
				assert(radius, "TraceSplashPointOnPlane: missing radius")

				local start = hub + planeNormal * 0.5
				local desired = hub + dirInPlane * radius
				local tr = engine.TraceLine(start, desired, MASK_SHOT + CONTENTS_GRATE, shouldHitEntity)
				if tr.fraction >= 1.0 then
					return nil
				end

				if not PlaneFacesPlayer(tr.plane, eye, tr.endpos) then
					return nil
				end
				if not CanDamageFrom(tr.endpos, center, player, BLAST_RADIUS) then
					return nil
				end

				return tr
			end

			----------------------------------------------------------------
			-- 1‑D binary search along one in‑plane axis to get d_max
			--     hub        : point on the plane (Vector3)
			--     n          : plane normal       (Vector3, unit)
			--     targetCOM  : enemy centre‑of‑mass
			--     targetPlayer : enemy entity (for CanDamageFrom)
			----------------------------------------------------------------
			local function FindMaxSplashRadius(hub, n, targetCOM, targetPlayer)
				assert(hub, "FindMaxSplashRadius: missing hub")
				assert(n, "FindMaxSplashRadius: missing n")
				assert(targetCOM, "FindMaxSplashRadius: missing targetCOM")
				assert(targetPlayer, "FindMaxSplashRadius: missing targetPlayer")

				local dir = Vector3(1, 0, 0)
				dir = dir - n * dir:Dot(n)
				if dir:Length() < 0.01 then
					dir = Vector3(0, 1, 0) - n * n.y
				end
				dir = vector.Normalize(dir)

				local lo, hi = 0, BLAST_RADIUS
				for _ = 1, 12 do
					if (hi - lo) < POSITION_EPSILON then
						break
					end
					local mid = (lo + hi) * 0.5
					local test = hub + dir * mid
					if CanDamageFrom(test, targetCOM, targetPlayer, BLAST_RADIUS) then
						lo = mid
					else
						hi = mid
					end
				end
				return lo - POSITION_EPSILON
			end

			local function FindMaxRadiusOnPlaneRay(hub, planeNormal, dirInPlane, radiusGuess)
				assert(hub, "FindMaxRadiusOnPlaneRay: missing hub")
				assert(planeNormal, "FindMaxRadiusOnPlaneRay: missing planeNormal")
				assert(dirInPlane, "FindMaxRadiusOnPlaneRay: missing dirInPlane")
				assert(radiusGuess, "FindMaxRadiusOnPlaneRay: missing radiusGuess")

				radiusGuess = math.max(0, math.min(radiusGuess, BLAST_RADIUS))
				local lo, hi = 0, BLAST_RADIUS
				local bestTr = nil
				local bestRadius = 0

				-- Use guess to shrink the initial interval (fewer iterations most of the time)
				local trGuess = TraceSplashPointOnPlane(hub, planeNormal, dirInPlane, radiusGuess)
				if trGuess then
					bestTr = trGuess
					bestRadius = radiusGuess
					lo = radiusGuess
				else
					hi = radiusGuess
				end

				for _ = 1, BINARY_SEARCH_ITERATIONS do
					if (hi - lo) <= RADIUS_TOLERANCE then
						break
					end
					local mid = (lo + hi) * 0.5
					local trMid = TraceSplashPointOnPlane(hub, planeNormal, dirInPlane, mid)
					if trMid then
						bestTr = trMid
						bestRadius = mid
						lo = mid
					else
						hi = mid
					end
				end

				if not bestTr then
					return nil, 0
				end

				local safeRadius = math.max(0, bestRadius - RADIUS_TOLERANCE)
				local trSafe = TraceSplashPointOnPlane(hub, planeNormal, dirInPlane, safeRadius)
				return trSafe or bestTr, safeRadius
			end

			local function AddIrregularCirclePointsOnPlane(planeNormal, planePoint)
				assert(planeNormal, "AddIrregularCirclePointsOnPlane: missing planeNormal")
				assert(planePoint, "AddIrregularCirclePointsOnPlane: missing planePoint")

				if not PlaneFacesPlayer(planeNormal, eye, planePoint) then
					return
				end

				local planeD = planeNormal:Dot(planePoint)
				local planeKey =
					string.format("%.3f,%.3f,%.3f,%.1f", planeNormal.x, planeNormal.y, planeNormal.z, planeD)
				if generatedPlaneKeys[planeKey] then
					return
				end
				generatedPlaneKeys[planeKey] = true

				local toCom = center - planePoint
				local hub = center - planeNormal * toCom:Dot(planeNormal)

				-- Align to shooter direction for smart sampling
				local toEye = eye - hub
				local toEyeFlat = toEye - planeNormal * toEye:Dot(planeNormal)
				local toEyeLen = toEyeFlat:Length()

				local u, v
				if toEyeLen > 0.01 then
					u = toEyeFlat / toEyeLen
					v = planeNormal:Cross(u)
				else
					local tmp = (math.abs(planeNormal.z) < 0.9) and Vector3(0, 0, 1) or Vector3(1, 0, 0)
					u = vector.Normalize(tmp:Cross(planeNormal))
					v = planeNormal:Cross(u)
				end

				-- 4 aligned directions
				local dirs = { u, v, u * -1, v * -1 }
				local prevRadius = math.min(BLAST_RADIUS - RADIUS_TOLERANCE, CIRCLE_RADIUS)

				for i = 1, 4 do
					local dirInPlane = dirs[i]

					local trBest, safeRadius = FindMaxRadiusOnPlaneRay(hub, planeNormal, dirInPlane, prevRadius)
					prevRadius = safeRadius
					if trBest then
						local p = {
							pos = trBest.endpos,
							fraction = trBest.fraction,
							normal = trBest.plane,
							screen = client.WorldToScreen(trBest.endpos),
							planeDist = SignedDistanceToPlane(planeNormal, planePoint, trBest.endpos),
						}
						table.insert(collisionPoints, p)
						local key = string.format("%.3f,%.3f,%.3f", p.normal.x, p.normal.y, p.normal.z)
						normalGroups[key] = normalGroups[key] or {}
						table.insert(normalGroups[key], p)
					end
				end
			end

			----------------------------------------------------------------
			--  Draw a red sample ring on *any* plane that just splashed
			----------------------------------------------------------------
			local function AddCirclePointsOnPlane(planeNormal, planePoint, directionIndex)
				TickProfiler.BeginSection("AddCirclePointsOnPlane")
				-- 0) make sure the plane still faces us
				if not PlaneFacesPlayer(planeNormal, eye, planePoint) then
					TickProfiler.EndSection("AddCirclePointsOnPlane")
					return
				end

				-- 1) hub = projection of enemy COM onto that plane
				local toCom = center - planePoint
				local hub = center - planeNormal * toCom:Dot(planeNormal)

				-- 2) Align basis to shooter direction for smart sampling
				local toEye = eye - hub
				local toEyeFlat = toEye - planeNormal * toEye:Dot(planeNormal)
				local toEyeLen = toEyeFlat:Length()

				local u, v
				if toEyeLen > 0.01 then
					u = toEyeFlat / toEyeLen
					v = planeNormal:Cross(u)
				else
					local tmp = (math.abs(planeNormal.z) < 0.9) and Vector3(0, 0, 1) or Vector3(1, 0, 0)
					u = vector.Normalize(tmp:Cross(planeNormal))
					v = planeNormal:Cross(u)
				end

				-- Initialize radius cache for this player/direction if needed
				local playerIdx = player:GetIndex()
				cachedRadii[playerIdx] = cachedRadii[playerIdx] or {}
				cachedRadii[playerIdx][directionIndex] = cachedRadii[playerIdx][directionIndex] or {}

				-- 3) for each of 4 segments, binary search for max radius
				local CIRCLE_SEARCH_ITERATIONS = 7
				local CIRCLE_TRACE_OUT = 8
				local CIRCLE_TRACE_IN = 32
				local circlePoints = {}
				local traceMask = MASK_SHOT + CONTENTS_GRATE

				-- Calculate dynamic max radius based on target AABB
				local aabbSize = (worldMaxs - worldMins):Length()
				local dynamicMaxRadius = BLAST_RADIUS + (aabbSize * 2) + 20

				-- 4 aligned directions: toward shooter, 90deg, away, 270deg
				local dirs = { u, v, u * -1, v * -1 }

				for i = 1, 4 do
					local dir = dirs[i]

					-- Get cached data as starting guess (or default)
					local cachedData = cachedRadii[playerIdx][directionIndex][i]
					local cachedR = cachedData and cachedData.radius or CIRCLE_RADIUS

					-- Binary search for max radius that can hit target
					local minR = 8
					local bestR = nil
					local bestPos = nil
					local bestFraction = nil

					-- bracket [lowOk, highFail] by expanding outward until we fail
					local lowOk = nil
					local highFail = nil
					local function EvalRadius(radius)
						local samplePos = hub + dir * radius
						local start = samplePos + planeNormal * CIRCLE_TRACE_OUT
						local stop = samplePos - planeNormal * CIRCLE_TRACE_IN
						local tr = engine.TraceLine(start, stop, traceMask, shouldHitEntity)
						if tr.fraction >= 1.0 then
							return false
						end
						if not CanDamageFrom(tr.endpos, center, player, BLAST_RADIUS) then
							return false
						end
						return true, tr.endpos, tr.fraction
					end

					-- 1) ensure we have a known-good low bound
					local okMin, impactMin, fracMin = EvalRadius(minR)
					local expandR -- declare before any goto
					if okMin then
						lowOk = minR
						bestR = minR
						bestPos = impactMin
						bestFraction = fracMin
					else
						-- segment never valid
						cachedRadii[playerIdx][directionIndex][i] = {
							radius = minR,
							low = minR,
							high = minR,
						}
						break
					end

					-- 2) expand upward starting from cachedR (but never below minR)
					-- If we have cached bounds, start from the cached high bound
					if cachedData and cachedData.high then
						expandR = math.max(minR, math.min(cachedData.high, dynamicMaxRadius))
					else
						expandR = math.max(minR, cachedR)
					end
					if expandR > lowOk then
						local okProbe, impactProbe, fracProbe = EvalRadius(expandR)
						if okProbe then
							lowOk = expandR
							bestR = expandR
							bestPos = impactProbe
							bestFraction = fracProbe
						else
							highFail = expandR
						end
					else
						expandR = lowOk
					end

					-- continue expanding until first fail
					while (not highFail) and expandR < dynamicMaxRadius do
						local nextR = expandR * 1.25 + 8
						if nextR > dynamicMaxRadius then
							nextR = dynamicMaxRadius
						end
						local ok, impact, frac = EvalRadius(nextR)
						if ok then
							lowOk = nextR
							bestR = nextR
							bestPos = impact
							bestFraction = frac
							expandR = nextR
							if expandR >= dynamicMaxRadius then
								highFail = dynamicMaxRadius
							end
						else
							highFail = nextR
						end
						if highFail == lowOk then
							break
						end
					end

					-- 3) binary search between last ok and first fail
					if highFail and highFail > lowOk then
						local low = lowOk
						local high = highFail
						for _ = 1, CIRCLE_SEARCH_ITERATIONS do
							local midR = (low + high) * 0.5
							local ok, impact, frac = EvalRadius(midR)
							if ok then
								bestR = midR
								bestPos = impact
								bestFraction = frac
								low = midR
							else
								high = midR
							end
							if (high - low) < RADIUS_TOLERANCE then
								break
							end
						end
					end

					-- Cache the found radius and bounds for next tick
					if bestR then
						cachedRadii[playerIdx][directionIndex][i] = {
							radius = bestR,
							low = math.max(minR, bestR - RADIUS_TOLERANCE),
							high = math.min(dynamicMaxRadius, bestR + RADIUS_TOLERANCE),
						}
					else
						cachedRadii[playerIdx][directionIndex][i] = {
							radius = minR,
							low = minR,
							high = minR + RADIUS_TOLERANCE,
						}
					end

					-- Add point if valid
					if bestPos then
						local s = client.WorldToScreen(bestPos)
						local p = {
							pos = bestPos,
							fraction = bestFraction or 1.0,
							radius = bestR,
							normal = planeNormal,
							screen = s,
							segmentIndex = i,
						}
						table.insert(circlePoints, p)
						table.insert(collisionPoints, p)
						local key = string.format("%.3f,%.3f,%.3f", planeNormal.x, planeNormal.y, planeNormal.z)
						normalGroups[key] = normalGroups[key] or {}
						table.insert(normalGroups[key], p)

						-- Draw circle point (green = valid hit point)
						if s then
							draw.Color(0, 255, 0, 255) -- Green for valid splash points
							draw.FilledRect(s[1] - 3, s[2] - 3, s[1] + 3, s[2] + 3)
						end
					end
				end

				TickProfiler.EndSection("AddCirclePointsOnPlane")
				return circlePoints
			end

			local function DrawDirectionDot(direction, directionIndex)
				TickProfiler.BeginSection("DrawDirectionDot")
				-- Normalize direction
				local dir = vector.Normalize(direction)
				local aimPoint = center + dir * BLAST_RADIUS -- raw white dot

				----------------------------------------------------------------
				-- visual: white grid dot
				----------------------------------------------------------------
				local aim2D = client.WorldToScreen(aimPoint)
				if aim2D then
					draw.Color(table.unpack(GRID_DOT_COLOR))
					local h = CIRCLE_DOT_SIZE / 2
					draw.FilledRect(aim2D[1] - h, aim2D[2] - h, aim2D[1] + h, aim2D[2] + h)
				end

				----------------------------------------------------------------
				-- first trace centre → aimPoint (mask = HULL)
				----------------------------------------------------------------
				local tr = engine.TraceHull(
					center,
					aimPoint,
					CARDINAL_HULL_MINS,
					CARDINAL_HULL_MAXS,
					MASK_SHOT + CONTENTS_GRATE,
					shouldHitEntity
				)
				if tr.fraction >= 1.0 then
					return -- nothing hit
				end

				-- Early backface culling - if surface faces away, skip all processing
				if not PlaneFacesPlayer(tr.plane, eye, tr.endpos) then
					return -- cull before any further work
				end

				local hitPos = tr.endpos
				local dmgOK = CanDamageFrom(hitPos, center, player, BLAST_RADIUS)

				----------------------------------------------------------------
				-- If too far, pull the point back to exactly BLAST_RADIUS
				----------------------------------------------------------------
				if not dmgOK then
					local d = (hitPos - center):Length()
					if d > BLAST_RADIUS + 0.1 then -- purely range issue
						local newPos = center + dir * (BLAST_RADIUS - 0.01)
						local tr2 = engine.TraceHull(
							center,
							newPos,
							CARDINAL_HULL_MINS,
							CARDINAL_HULL_MAXS,
							MASK_SHOT + CONTENTS_GRATE,
							shouldHitEntity
						)
						if tr2.fraction < 1.0 then
							hitPos = tr2.endpos
							dmgOK = CanDamageFrom(hitPos, center, player, BLAST_RADIUS)
						end
					end
				end
				if not dmgOK then
					return -- still useless, cull
				end

				AddCirclePointsOnPlane(tr.plane, hitPos, directionIndex)

				----------------------------------------------------------------
				-- red collision dot (guaranteed splash‑valid now)
				----------------------------------------------------------------
				local hit2D = client.WorldToScreen(hitPos)
				if hit2D then
					draw.Color(table.unpack(TRACE_COLLISION_COLOR))
					local h = TRACE_COLLISION_DOT_SIZE / 2
					draw.FilledRect(hit2D[1] - h, hit2D[2] - h, hit2D[1] + h, hit2D[2] + h)
				end

				----------------------------------------------------------------
				-- push into data structures for later processing
				----------------------------------------------------------------
				local surfN = tr.plane
				local pointT = { pos = hitPos, fraction = tr.fraction, normal = surfN, screen = hit2D }
				table.insert(collisionPoints, pointT)
				local key = string.format("%.3f,%.3f,%.3f", surfN.x, surfN.y, surfN.z)
				normalGroups[key] = normalGroups[key] or {}
				table.insert(normalGroups[key], pointT)
				TickProfiler.EndSection("DrawDirectionDot")
			end

			-- Draw all cardinal direction dots
			for dirIdx, direction in ipairs(cardinalDirections) do
				DrawDirectionDot(direction, dirIdx)
			end

			----------------------------------------------------------------
			--  add splash ring beneath / above the player for each floor/ceiling hit
			----------------------------------------------------------------

			-- Also generate a ground circle specifically
			local function GenerateGroundCircle()
				print("GenerateGroundCircle: Starting...")
				local groundNormal = Vector3(0, 0, 1) -- Ground normal pointing up
				local groundPoint = center + Vector3(0, 0, -1) -- Slightly below center

				-- Find ground level
				local groundStart = center + Vector3(0, 0, 50) -- Start above
				local groundEnd = center + Vector3(0, 0, -50) -- End below
				print("GenerateGroundCircle: Tracing from", groundStart.z, "to", groundEnd.z)
				local groundTr = engine.TraceLine(groundStart, groundEnd, MASK_SHOT + CONTENTS_GRATE)

				if groundTr.fraction < 1.0 then
					local groundLevel = groundTr.endpos
					local hub = Vector3(center.x, center.y, groundLevel.z) -- Project center onto ground

					-- Build orthonormal basis for ground plane
					local u = Vector3(1, 0, 0) -- X axis
					local v = Vector3(0, 1, 0) -- Y axis

					-- Find radius that still splashes
					print("GenerateGroundCircle: Finding max splash radius...")
					local radius = FindMaxSplashRadius(hub, groundNormal, center, player)
					print("GenerateGroundCircle: Calculated radius:", radius)
					if radius < 8 then
						print("GenerateGroundCircle: Radius too small, returning")
						return
					end

					print("Generating ground circle with radius:", radius)

					-- Generate circle points
					local step = (2 * math.pi) / CIRCLE_SEGMENTS
					local pointsAdded = 0
					for i = 0, CIRCLE_SEGMENTS - 1 do
						local ang = i * step
						local dir = u * math.cos(ang) + v * math.sin(ang)
						local pos = hub + dir * radius

						-- Trace from ground level to circle position
						local tr = engine.TraceLine(groundLevel, pos, MASK_SHOT + CONTENTS_GRATE, shouldHitEntity)
						if tr.fraction < 1.0 then
							local s = client.WorldToScreen(tr.endpos)
							local p = {
								pos = tr.endpos,
								fraction = tr.fraction,
								normal = groundNormal,
								screen = s,
							}
							table.insert(collisionPoints, p)
							local key = string.format("%.3f,%.3f,%.3f", groundNormal.x, groundNormal.y, groundNormal.z)
							normalGroups[key] = normalGroups[key] or {}
							table.insert(normalGroups[key], p)
							pointsAdded = pointsAdded + 1
						end
					end
					print("GenerateGroundCircle: Added", pointsAdded, "ground circle points")
					if pointsAdded > 0 then
						local groundKey =
							string.format("%.3f,%.3f,%.3f", groundNormal.x, groundNormal.y, groundNormal.z)
						print("Ground points added to group:", groundKey)
						if normalGroups[groundKey] then
							print("Ground group now has", #normalGroups[groundKey], "total points")
						end
					end
				end
			end

			-- Generate ground circle
			if false then
				GenerateGroundCircle()
			end

			if false then
				local circleCount = 0
				for _, group in pairs(normalGroups) do
					if group[1] then
						print("Processing group with normal:", group[1].normal.x, group[1].normal.y, group[1].normal.z)
						AddCirclePointsOnPlane(group[1].normal, group[1].pos)
						circleCount = circleCount + 1
					end
				end
				print("Generated circles for", circleCount, "surfaces")
			end

			-- Always draw test circle to verify drawing works
			local testCenter = center + Vector3(0, 0, 50) -- Above the player
			local testScreen = client.WorldToScreen(testCenter)
			if testScreen then
				draw.Color(255, 0, 255, 255) -- Magenta for test
				draw.FilledRect(testScreen[1] - 10, testScreen[2] - 10, testScreen[1] + 10, testScreen[2] + 10)
			end

			-- Sort collision points by fraction (closest to furthest)
			table.sort(collisionPoints, function(a, b)
				local fa = (a and a.fraction) or 1.0
				local fb = (b and b.fraction) or 1.0
				return fa < fb
			end)

			-- Get view position for visibility checks
			local viewPos = entities.GetLocalPlayer():GetAbsOrigin()
				+ entities.GetLocalPlayer():GetPropVector("localdata", "m_vecViewOffset[0]")

			-- Precision constants for position comparisons
			local POSITION_COMPARISON_EPSILON = 0.001 -- 1mm for position equality checks

			-- Find best visible point on each surface and perform binary search toward AABB
			local closestVisiblePoint = nil
			local optimizedPoints = {}

			-- Get target position (center of target player)
			local targetPos = player:GetAbsOrigin()
			local targetMins = player:GetMins()
			local targetMaxs = player:GetMaxs()
			local targetAABBMin = targetPos + targetMins
			local targetAABBMax = targetPos + targetMaxs

			-- Backface cull groups and find best overall point
			local bestOverall = nil
			local visibleGroups = {}
			local allCandidates = {} -- Store all valid candidates for fallback

			-- Function to validate rocket trajectory (deferred validation)
			local function ValidateRocketTrajectory(splashPoint, targetPos, surfaceNormal)
				assert(splashPoint, "ValidateRocketTrajectory: missing splashPoint")
				assert(targetPos, "ValidateRocketTrajectory: missing targetPos")
				assert(surfaceNormal, "ValidateRocketTrajectory: missing surfaceNormal")

				-- Check if shooter can actually hit the splash point
				local eye = entities.GetLocalPlayer():GetAbsOrigin()
					+ entities.GetLocalPlayer():GetPropVector("localdata", "m_vecViewOffset[0]")

				-- Trace from shooter's eye to splash point
				local shootTrace = engine.TraceLine(eye, splashPoint, MASK_SHOT + CONTENTS_GRATE, shouldHitEntity)

				-- If we can't see the splash point, it's invalid
				if shootTrace.fraction < 0.99 then
					return false
				end

				-- Verify the splash point is on solid geometry (rocket should impact)
				local fromSplash = splashPoint + surfaceNormal * 1 -- Start slightly away from surface
				local toSplash = splashPoint - surfaceNormal * 5 -- Trace back toward surface
				local groundCheck = engine.TraceLine(fromSplash, toSplash, MASK_SHOT + CONTENTS_GRATE)

				-- Should hit geometry close to the splash point
				if groundCheck.fraction >= 1.0 or (groundCheck.endpos - splashPoint):Length() > 2 then
					return false
				end

				-- Already validated that splash can damage target during generation
				return true
			end

			-- Step 1: Backface cull groups and calculate average points
			for normalKey, points in pairs(normalGroups) do
				repeat
					if #points == 0 then
						break
					end

					-- Calculate average point for this group
					local avgPoint = Vector3(0, 0, 0)
					for _, point in ipairs(points) do
						avgPoint = avgPoint + point.pos
					end
					avgPoint = avgPoint / #points

					-- Check if this group faces the camera (use camera position)
					local surfaceNormal = points[1].normal
					-- Use camera position for backface culling (consistent within frame)
					if PlaneFacesPlayer(surfaceNormal, viewPos, avgPoint) then
						visibleGroups[normalKey] = points
						print("Group faces camera:", normalKey, "with", #points, "points")
					else
						print("Group faces away:", normalKey, "with", #points, "points")
					end

				until true
			end

			-- Step 2: Process only visible groups
			for normalKey, points in pairs(visibleGroups) do
				-- Find best visible point on this surface
				local bestVisible = nil
				local bestDistance = math.huge

				for _, point in ipairs(points) do
					-- Check visibility from view position
					local visibilityTrace = engine.TraceLine(viewPos, point.pos, MASK_SHOT + CONTENTS_GRATE)
					local isVisible = visibilityTrace.fraction > VISIBILITY_THRESHOLD

					if isVisible then
						-- Get closest point on target AABB to this collision point
						local closestTargetPoint = GetClosestPointOnAABB(targetAABBMin, targetAABBMax, point.pos)
						local distance = (point.pos - closestTargetPoint):Length()

						if distance < bestDistance then
							bestVisible = point
							bestDistance = distance
						end
					end
				end

				-- If we found a visible point, do binary search toward AABB
				if bestVisible then
					-- Get the closest AABB point to our visible point
					local targetAABBPoint = GetClosestPointOnAABB(targetAABBMin, targetAABBMax, bestVisible.pos)

					-- Do binary search from visible point toward AABB point
					local best = BinarySearchTowardAABB(
						bestVisible,
						targetAABBPoint,
						bestVisible.normal,
						viewPos,
						shouldHitEntity
					)

					-- Calculate distance to target for sorting
					local nearOpt = GetClosestPointOnAABB(targetAABBMin, targetAABBMax, best.pos)
					best.distTarget = (best.pos - nearOpt):Length()
					best.distView = (best.pos - viewPos):Length()
					best.score = scoreSplash(best.distTarget, best.distView)
					best.firstVis = bestVisible
					best.secondInv = nil

					-- Store candidate for deferred validation
					table.insert(allCandidates, best)

					if (not bestOverall) or best.score < bestOverall.score then
						bestOverall = best
					end
				end
			end

			if not bestOverall then
				return
			end

			-- Sort all candidates by score (best first)
			table.sort(allCandidates, function(a, b)
				return a.score < b.score
			end)

			-- Deferred validation: check best candidate first, fallback if needed
			local validatedCandidate = nil
			for _, candidate in ipairs(allCandidates) do
				if ValidateRocketTrajectory(candidate.pos, center, candidate.normal) then
					validatedCandidate = candidate
					break
				end
			end

			-- Store the validated result
			binarySearchResult = validatedCandidate
			closestVisiblePoint = validatedCandidate and validatedCandidate.firstVis

			-- Draw orange square for binary search result
			if binarySearchResult and binarySearchResult.screen then
				draw.Color(table.unpack(BINSEARCH_COLOR))
				local halfSize = BINSEARCH_SIZE / 2
				draw.FilledRect(
					math.floor(binarySearchResult.screen[1] - halfSize),
					math.floor(binarySearchResult.screen[2] - halfSize),
					math.floor(binarySearchResult.screen[1] + halfSize),
					math.floor(binarySearchResult.screen[2] + halfSize)
				)
			else
			end

			-- Draw cyan dot for closest visible point
			if closestVisiblePoint and closestVisiblePoint.screen then
				draw.Color(table.unpack(CLOSEST_VISIBLE_COLOR))
				local halfSize = CLOSEST_VISIBLE_SIZE / 2
				draw.FilledRect(
					math.floor(closestVisiblePoint.screen[1] - halfSize),
					math.floor(closestVisiblePoint.screen[2] - halfSize),
					math.floor(closestVisiblePoint.screen[1] + halfSize),
					math.floor(closestVisiblePoint.screen[2] + halfSize)
				)
			end

			-- Draw blue dot for target AABB point (for reference)
			if binarySearchResult and binarySearchResult.firstVis then
				local targetAABBPoint =
					GetClosestPointOnAABB(targetAABBMin, targetAABBMax, binarySearchResult.firstVis.pos)
				local targetScreen = client.WorldToScreen(targetAABBPoint)
				if targetScreen then
					draw.Color(table.unpack(SECOND_COLOR))
					local halfSize = SECOND_SIZE / 2
					draw.FilledRect(
						math.floor(targetScreen[1] - halfSize),
						math.floor(targetScreen[2] - halfSize),
						math.floor(targetScreen[1] + halfSize),
						math.floor(targetScreen[2] + halfSize)
					)
				end
			end

			-- Draw only points from visible groups
			local circlePointsDrawn = 0
			for _, points in pairs(visibleGroups) do
				for _, point in ipairs(points) do
					if point.screen then
						draw.Color(table.unpack(CIRCLE_DOT_COLOR))
						draw.FilledRect(
							math.floor(point.screen[1] - 5),
							math.floor(point.screen[2] - 5),
							math.floor(point.screen[1] + 5),
							math.floor(point.screen[2] + 5)
						)
						circlePointsDrawn = circlePointsDrawn + 1
					end
				end
			end
		end
	end
end

-- Visual helper: draw a yellow line only when the point you are aiming at
-- could splash the enemy's COM within 169 u.
local function CheckAimPointAndVisualize(localPlayer, targetPlayer)
	if not localPlayer or not targetPlayer then
		return
	end

	local eye = localPlayer:GetAbsOrigin() + localPlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
	local aimDir = engine.GetViewAngles():Forward()
	local aimPos = eye + aimDir * 1000 -- long look‑ray

	-- where your crosshair ray first hits the world
	local aimHit = engine.TraceLine(eye, aimPos, MASK_SHOT + CONTENTS_GRATE).endpos
	if not aimHit then
		return
	end -- shouldn't happen

	-- enemy centre (AABB center)
	local mins = targetPlayer:GetMins()
	local maxs = targetPlayer:GetMaxs()
	local com = targetPlayer:GetAbsOrigin() + (mins + maxs) / 2

	-- build a capped segment: length = min(dist(COM), BLAST_RADIUS)
	local BLAST_RADIUS = GetWeaponBlastRadius()
	local delta = com - aimHit
	local dist = delta:Length()
	if dist == 0 then
		return
	end -- already inside player
	local dir = delta / dist
	local segEnd = aimHit + dir * math.min(dist, BLAST_RADIUS)

	-- trace along that capped segment
	local splash = engine.TraceLine(aimHit, segEnd, MASK_SHOT + CONTENTS_GRATE)

	if splash.entity and splash.entity:GetIndex() == targetPlayer:GetIndex() then
		local sA = client.WorldToScreen(aimHit)
		local sB = client.WorldToScreen(splash.endpos) -- first hull touch
		if sA and sB then
			draw.Color(255, 255, 0, 255)
			draw.Line(sA[1], sA[2], sB[1], sB[2])
			local d = 6
			draw.FilledRect(sA[1] - d / 2, sA[2] - d / 2, sA[1] + d / 2, sA[2] + d / 2)
		end
	end
end

-- Main paint hook to draw AABB bounds
local function OnPaint()
	TickProfiler.BeginSection("OnPaint")
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then
		TickProfiler.EndSection("OnPaint")
		return
	end

	local localTeam = localPlayer:GetTeamNumber()

	-- Find all players using entities.FindByClass
	local players = entities.FindByClass("CTFPlayer")
	for _, player in pairs(players) do
		if player and player:IsAlive() then
			local playerTeam = player:GetTeamNumber()

			-- Draw AABB for enemies (adjust this logic as needed)
			if playerTeam ~= localTeam then
				local data = cachedSplashData[player:GetIndex()]
				if data and data.points then
					for _, point in ipairs(data.points) do
						local s = client.WorldToScreen(point.pos)
						if s then
							draw.Color(table.unpack(CIRCLE_DOT_COLOR))
							draw.FilledRect(
								math.floor(s[1] - 3),
								math.floor(s[2] - 3),
								math.floor(s[1] + 3),
								math.floor(s[2] + 3)
							)
						end
					end
					if DEBUG_DRAW_SEGMENT_SAMPLES then
						local idx = player:GetIndex()
						local perPlane = cachedSegmentRadii[idx]
						if perPlane then
							draw.Color(table.unpack(SEGMENT_SAMPLE_COLOR))
							for _, perSeg in pairs(perPlane) do
								if perSeg then
									for _, segCache in pairs(perSeg) do
										if segCache and segCache.buf and segCache.count and segCache.count > 0 then
											for i = 1, segCache.count do
												local samplePos = segCache.buf[i]
												if samplePos then
													local ss = client.WorldToScreen(samplePos)
													if ss then
														draw.FilledRect(
															math.floor(ss[1] - SEGMENT_SAMPLE_SIZE),
															math.floor(ss[2] - SEGMENT_SAMPLE_SIZE),
															math.floor(ss[1] + SEGMENT_SAMPLE_SIZE),
															math.floor(ss[2] + SEGMENT_SAMPLE_SIZE)
														)
													end
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	TickProfiler.EndSection("OnPaint")
end

local function OnCreateMove(_cmd)
	TickProfiler.BeginSection("OnCreateMove")
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsAlive() then
		TickProfiler.EndSection("OnCreateMove")
		return
	end

	-- Only compute when F key is held
	if not input.IsButtonDown(KEY_F) then
		TickProfiler.EndSection("OnCreateMove")
		return
	end

	local localTeam = localPlayer:GetTeamNumber()
	local players = entities.FindByClass("CTFPlayer")
	local present = {}
	for _, player in pairs(players) do
		if player and player:IsAlive() and player:GetTeamNumber() ~= localTeam then
			local idx = player:GetIndex()
			present[idx] = true
			local data = ComputeSplashDataForPlayer(player, localPlayer, cachedSplashData[idx])
			if data then
				cachedSplashData[idx] = data
			end
		end
	end

	for idx, _ in pairs(cachedSplashData) do
		if not present[idx] then
			cachedSplashData[idx] = nil
		end
	end
	for idx, _ in pairs(cachedRadii) do
		if not present[idx] then
			cachedRadii[idx] = nil
		end
	end
	for idx, _ in pairs(cachedBlueprint) do
		if not present[idx] then
			cachedBlueprint[idx] = nil
		end
	end
	for idx, _ in pairs(cachedSegmentRadii) do
		if not present[idx] then
			cachedSegmentRadii[idx] = nil
		end
	end
	TickProfiler.EndSection("OnCreateMove")
end

-- Register the paint hook
callbacks.Register("Draw", OnPaint)
callbacks.Register("CreateMove", OnCreateMove)
