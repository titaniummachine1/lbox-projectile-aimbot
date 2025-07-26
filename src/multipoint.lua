-- Constants
local FL_DUCKING = 1

---@class Multipoint
---@field private pLocal Entity
---@field private pTarget Entity
---@field private pWeapon Entity
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

local function SafeNormalize(vec)
        if not vec then
                return nil
        end

	local length = vec:Length()
	if length < 0.001 then
		return nil -- Vector is too small to normalize
	end

	-- Try the built-in Normalize method first
	local normalized = vec:Normalize()
	if normalized then
		return normalized
	end

	-- Fallback: manual normalization
	local inv_length = 1.0 / length
	return Vector3(vec.x * inv_length, vec.y * inv_length, vec.z * inv_length)
end

function multipoint:CanShootToPoint(target_pos)
        if not target_pos then
                return false
        end

        local vecMins, vecMaxs = self.weapon_info.m_vecMins, self.weapon_info.m_vecMaxs

        local function shouldHit(ent)
                if not ent then
                        return false
                end

                if ent:GetIndex() == self.pLocal:GetIndex() then
                        return false
                end

                if self.bAimTeamMate then
                        return ent:GetTeamNumber() == self.pTarget:GetTeamNumber()
                else
                        return ent:GetTeamNumber() ~= self.pTarget:GetTeamNumber()
                end
        end

        local viewpos = self.pLocal:GetAbsOrigin() + self.pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
        local aim_dir = self.math_utils.NormalizeVector(target_pos - viewpos)
        if not aim_dir then
                return false
        end

        local muzzle_offset = self.weapon_info:GetOffset(
                (self.pLocal:GetPropInt("m_fFlags") & FL_DUCKING) ~= 0,
                self.pWeapon:IsViewModelFlipped()
        )
        local vecWeaponFirePos =
                viewpos
                + self.math_utils.RotateOffsetAlongDirection(muzzle_offset, aim_dir)
                + self.weapon_info.m_vecAbsoluteOffset

        local trace = engine.TraceHull(vecWeaponFirePos, target_pos, vecMins, vecMaxs, MASK_SHOT_HULL, shouldHit)
        return trace and trace.fraction >= 1
end

function multipoint:GetCandidatePoints()
        local maxs = self.pTarget:GetMaxs()
        local mins = self.pTarget:GetMins()

        local target_height = maxs.z - mins.z
        local target_width = maxs.x - mins.x
        local target_depth = maxs.y - mins.y

        local is_on_ground = (self.pTarget:GetPropInt("m_fFlags") & FL_ONGROUND) ~= 0

        local head_pos = self.ent_utils.GetBones and self.ent_utils.GetBones(self.pTarget)[1] or nil
        local center_pos = self.vecPredictedPos + Vector3(0, 0, target_height / 2)
        local feet_pos = self.vecPredictedPos

        local fallback_points = {
                Vector3(-target_width / 2, -target_depth / 2, 0),
                Vector3(target_width / 2, -target_depth / 2, 0),
                Vector3(-target_width / 2, target_depth / 2, 0),
                Vector3(target_width / 2, target_depth / 2, 0),

                Vector3(-target_width / 2, -target_depth / 2, target_height / 2),
                Vector3(target_width / 2, -target_depth / 2, target_height / 2),
                Vector3(-target_width / 2, target_depth / 2, target_height / 2),
                Vector3(target_width / 2, target_depth / 2, target_height / 2),

                Vector3(0, -target_depth / 2, target_height / 2),
                Vector3(0, target_depth / 2, target_height / 2),
                Vector3(-target_width / 2, 0, target_height / 2),
                Vector3(target_width / 2, 0, target_height / 2),

                Vector3(0, -target_depth / 2, 0),
                Vector3(0, target_depth / 2, 0),
                Vector3(-target_width / 2, 0, 0),
                Vector3(target_width / 2, 0, 0),

                Vector3(-target_width / 2, -target_depth / 2, target_height),
                Vector3(target_width / 2, -target_depth / 2, target_height),
                Vector3(-target_width / 2, target_depth / 2, target_height),
                Vector3(target_width / 2, target_depth / 2, target_height),

                Vector3(0, -target_depth / 2, target_height),
                Vector3(0, target_depth / 2, target_height),
                Vector3(-target_width / 2, 0, target_height),
                Vector3(target_width / 2, 0, target_height),
        }

        local points = {}

        if self.bIsHuntsman then
                if self.settings.hitparts.head and head_pos then
                        points[#points + 1] = head_pos
                end
                points[#points + 1] = center_pos
                if self.settings.hitparts.feet and is_on_ground then
                        points[#points + 1] = feet_pos
                end
        else
                if self.bIsSplash and self.settings.hitparts.feet and is_on_ground then
                        points[#points + 1] = feet_pos
                end
                points[#points + 1] = center_pos
        end

        for _, pos in ipairs(fallback_points) do
                points[#points + 1] = self.vecPredictedPos + pos
        end

        return points
end

---@return Vector3?
function multipoint:GetBestHitPoint()
        for _, pos in ipairs(self:GetCandidatePoints()) do
                if self:CanShootToPoint(pos) then
                        return pos
                end
        end
        return nil
end

---@param pLocal Entity
---@param pWeapon Entity
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
	pWeapon,
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
	self.pWeapon = pWeapon
	self.pTarget = pTarget
	self.bIsHuntsman = bIsHuntsman
	self.bAimTeamMate = bAimTeamMate
	self.vecHeadPos = vecHeadPos
	self.vecShootPos = vecHeadPos -- Use view position as base
	self.weapon_info = weapon_info
	self.math_utils = math_utils
	self.iMaxDistance = iMaxDistance
	self.vecPredictedPos = vecPredictedPos
	self.bIsSplash = bIsSplash
	self.ent_utils = ent_utils
	self.settings = settings
end

return multipoint
