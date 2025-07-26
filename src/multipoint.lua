---@class Multipoint
---@field private pLocal Entity
---@field private pTarget Entity
---@field private bIsHuntsman boolean
---@field private bIsSplash boolean
---@field private vecAimDir Vector3
---@field private vecPredictedPos Vector3
---@field private bAimTeamMate boolean
---@field private vecHeadPos Vector3
---@field private weapon_info WeaponInfo
---@field private math_utils MathLib
---@field private iMaxDistance integer
local multipoint = {}

local offset_multipliers = {
	splash = {
		{ "legs",           { { 0, 0, 0 }, { 0, 0, 0.2 } } },
		{ "chest",          { { 0, 0, 0.5 } } },
		{ "right_shoulder", { { 0.6, 0, 0.5 } } },
		{ "left_shoulder",  { { -0.6, 0, 0.5 } } },
		{ "head",           { { 0, 0, 0.9 } } },
	},
	huntsman = {
		{ "chest",          { { 0, 0, 0.5 } } },
		{ "right_shoulder", { { 0.6, 0, 0.5 } } },
		{ "left_shoulder",  { { -0.6, 0, 0.5 } } },
		{ "legs",           { { 0, 0, 0.2 } } },
	},
	normal = {
		{ "chest",          { { 0, 0, 0.5 } } },
		{ "right_shoulder", { { 0.6, 0, 0.5 } } },
		{ "left_shoulder",  { { -0.6, 0, 0.5 } } },
		{ "head",           { { 0, 0, 0.9 } } },
		{ "legs",           { { 0, 0, 0.2 } } },
	},
}

---@return Vector3?
function multipoint:GetBestHitPoint()
	local maxs = self.pTarget:GetMaxs()
	local mins = self.pTarget:GetMins()
	local origin = self.pTarget:GetAbsOrigin()

	local target_height = maxs.z - mins.z
	local target_width = maxs.x - mins.x
	local target_depth = maxs.y - mins.y

	local is_on_ground = (self.pTarget:GetPropInt("m_fFlags") & FL_ONGROUND) ~= 0
	local vecMins, vecMaxs = self.weapon_info.m_vecMins, self.weapon_info.m_vecMaxs

	local function shouldHit(ent)
		if ent:GetIndex() == self.pLocal:GetIndex() then return false end
		return ent:GetTeamNumber() ~= self.pTarget:GetTeamNumber()
	end

	-- Check if we can shoot from our position to the target point using projectile simulation logic
	local function canShootToPoint(target_pos)
		-- First do a line trace to check visibility
		local line_trace = engine.TraceLine(self.vecHeadPos, target_pos, MASK_SHOT_HULL, shouldHit)
		if not line_trace or line_trace.fraction < 1 then
			return false
		end

		-- Then do a hull trace to check if projectile can reach the point
		local hull_trace = engine.TraceHull(self.vecHeadPos, target_pos, vecMins, vecMaxs, MASK_SHOT_HULL, shouldHit)
		if not hull_trace or hull_trace.fraction < 1 then
			return false
		end

		return true
	end

	local head_pos = self.ent_utils.GetBones and self.ent_utils.GetBones(self.pTarget)[1] or nil
	local center_pos = self.vecPredictedPos + Vector3(0, 0, target_height / 2)
	local feet_pos = self.vecPredictedPos

	local fallback_points = {
		-- AABB corners (all 8 corners of the bounding box)
		{ pos = Vector3(-target_width / 2, -target_depth / 2, 0),           name = "bottom_corner_1" },
		{ pos = Vector3(target_width / 2, -target_depth / 2, 0),            name = "bottom_corner_2" },
		{ pos = Vector3(-target_width / 2, target_depth / 2, 0),            name = "bottom_corner_3" },
		{ pos = Vector3(target_width / 2, target_depth / 2, 0),             name = "bottom_corner_4" },
		{ pos = Vector3(-target_width / 2, -target_depth / 2, target_height), name = "top_corner_1" },
		{ pos = Vector3(target_width / 2, -target_depth / 2, target_height), name = "top_corner_2" },
		{ pos = Vector3(-target_width / 2, target_depth / 2, target_height), name = "top_corner_3" },
		{ pos = Vector3(target_width / 2, target_depth / 2, target_height), name = "top_corner_4" },

		-- Mid-height corners (body level)
		{ pos = Vector3(-target_width / 2, -target_depth / 2, target_height / 2), name = "mid_corner_1" },
		{ pos = Vector3(target_width / 2, -target_depth / 2, target_height / 2), name = "mid_corner_2" },
		{ pos = Vector3(-target_width / 2, target_depth / 2, target_height / 2), name = "mid_corner_3" },
		{ pos = Vector3(target_width / 2, target_depth / 2, target_height / 2), name = "mid_corner_4" },

		-- Mid-points on edges
		{ pos = Vector3(0, -target_depth / 2, target_height / 2),           name = "mid_front" },
		{ pos = Vector3(0, target_depth / 2, target_height / 2),            name = "mid_back" },
		{ pos = Vector3(-target_width / 2, 0, target_height / 2),           name = "mid_left" },
		{ pos = Vector3(target_width / 2, 0, target_height / 2),            name = "mid_right" },

		-- Bottom mid-points (legs level)
		{ pos = Vector3(0, -target_depth / 2, 0),                           name = "bottom_front" },
		{ pos = Vector3(0, target_depth / 2, 0),                            name = "bottom_back" },
		{ pos = Vector3(-target_width / 2, 0, 0),                           name = "bottom_left" },
		{ pos = Vector3(target_width / 2, 0, 0),                            name = "bottom_right" },

		-- Top mid-points (head level)
		{ pos = Vector3(0, -target_depth / 2, target_height),               name = "top_front" },
		{ pos = Vector3(0, target_depth / 2, target_height),                name = "top_back" },
		{ pos = Vector3(-target_width / 2, 0, target_height),               name = "top_left" },
		{ pos = Vector3(target_width / 2, 0, target_height),                name = "top_right" },
	}

	-- 1. Bows/headshot weapons
	if self.bIsHuntsman then
		if self.settings.hitparts.head and head_pos and canShootToPoint(head_pos) then
			printc(0, 255, 0, 255, "[MULTIPOINT] Selected head (bow)")
			return head_pos
		end
		if canShootToPoint(center_pos) then
			printc(0, 255, 0, 255, "[MULTIPOINT] Selected center (bow)")
			return center_pos
		end
		if self.settings.hitparts.feet and is_on_ground and canShootToPoint(feet_pos) then
			printc(0, 255, 0, 255, "[MULTIPOINT] Selected feet (bow)")
			return feet_pos
		end
		for _, point in ipairs(fallback_points) do
			local test_pos = self.vecPredictedPos + point.pos
			if canShootToPoint(test_pos) then
				printc(0, 255, 0, 255, string.format("[MULTIPOINT] Selected fallback %s (bow)", point.name))
				return test_pos
			end
		end
		return nil
	end

	-- 2. Explosive projectiles: feet first if enabled and on ground
	if self.bIsSplash and self.settings.hitparts.feet and is_on_ground and canShootToPoint(feet_pos) then
		printc(0, 255, 0, 255, "[MULTIPOINT] Selected feet (explosive)")
		return feet_pos
	end
	-- Center next
	if canShootToPoint(center_pos) then
		printc(0, 255, 0, 255, "[MULTIPOINT] Selected center (projectile)")
		return center_pos
	end
	for _, point in ipairs(fallback_points) do
		local test_pos = self.vecPredictedPos + point.pos
		if canShootToPoint(test_pos) then
			printc(0, 255, 0, 255, string.format("[MULTIPOINT] Selected fallback %s (projectile)", point.name))
			return test_pos
		end
	end
	return nil
end

---@param pLocal Entity
---@param pTarget Entity
---@param bIsHuntsman boolean
---@param bAimTeamMate boolean
---@param vecHeadPos Vector3
---@param vecPredictedPos Vector3
---@param weapon_info WeaponInfo
---@param math_utils MathLib
---@param iMaxDistance integer
---@param bIsSplash boolean
---@param ent_utils table
---@param settings table
function multipoint:Set(
	pLocal,
	pTarget,
	bIsHuntsman,
	bAimTeamMate,
	vecHeadPos,
	vecPredictedPos,
	weapon_info,
	math_utils,
	iMaxDistance,
	bIsSplash,
	ent_utils,
	settings
)
	self.pLocal = pLocal
	self.pTarget = pTarget
	self.bIsHuntsman = bIsHuntsman
	self.bAimTeamMate = bAimTeamMate
	self.vecHeadPos = vecHeadPos
	self.weapon_info = weapon_info
	self.math_utils = math_utils
	self.iMaxDistance = iMaxDistance
	self.vecPredictedPos = vecPredictedPos
	self.bIsSplash = bIsSplash
	self.ent_utils = ent_utils
	self.settings = settings
end

return multipoint
