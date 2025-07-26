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

-- Robust normalization function that handles edge cases
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
		if not ent then
			return false
		end

		if ent:GetIndex() == self.pLocal:GetIndex() then
			return false
		end

		-- For rockets, we want to hit enemies (different team)
		-- For healing weapons, we want to hit teammates (same team)
		if self.bAimTeamMate then
			return ent:GetTeamNumber() == self.pTarget:GetTeamNumber()
		else
			return ent:GetTeamNumber() ~= self.pTarget:GetTeamNumber()
		end
	end

	-- Check if we can shoot from our position to the target point using projectile simulation logic
	local function canShootToPoint(target_pos)
		if not self.vecShootPos or not target_pos then
			printc(255, 0, 0, 255, "[MULTIPOINT] vecShootPos or target_pos is nil! vecShootPos:",
				tostring(self.vecShootPos), "target_pos:", tostring(target_pos))
			return false
		end

		-- For rockets (no volume), use simple visibility check
		local has_volume = vecMins.x ~= 0 or vecMins.y ~= 0 or vecMins.z ~= 0 or
			vecMaxs.x ~= 0 or vecMaxs.y ~= 0 or vecMaxs.z ~= 0

		if not has_volume then
			-- For rockets: get direction from viewpos to target, apply offset in that direction, then trace line
			local viewpos = self.pLocal:GetAbsOrigin() + self.pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")

			-- Debug: show the values
			printc(255, 255, 0, 255,
				string.format("[MULTIPOINT] viewpos: %s, target_pos: %s", tostring(viewpos), tostring(target_pos)))

			local diff_vector = target_pos - viewpos
			local diff_length = diff_vector:Length()

			-- Debug: show the diff vector and its length
			printc(255, 255, 0, 255,
				string.format("[MULTIPOINT] diff_vector: %s, diff_length: %s", tostring(diff_vector),
					tostring(diff_length)))

			if diff_length < 0.001 then
				printc(255, 0, 0, 255, "[MULTIPOINT] Target too close to viewpos, diff_length: " .. tostring(diff_length))
				return false
			end

			local direction_to_target = SafeNormalize(diff_vector)

			-- Debug: show the normalized direction and its length
			printc(255, 255, 0, 255,
				string.format("[MULTIPOINT] direction_to_target: %s, length: %s", tostring(direction_to_target),
					tostring(direction_to_target and direction_to_target:Length() or 'nil')))

			-- Safety check: ensure direction is valid
			if not direction_to_target then
				printc(255, 0, 0, 255, "[MULTIPOINT] Failed to calculate direction to target - vector may be zero length")
				return false
			end

			-- Apply weapon offset in the direction to target
			local weapon_offset = self.weapon_info.vecOffset
			if not weapon_offset then
				weapon_offset = Vector3(23.5, -8, -3)
			end
			local shoot_offset_pos = viewpos +
				self.math_utils.RotateOffsetAlongDirection(weapon_offset, direction_to_target)

			-- Trace from offset position to target
			local line_trace = engine.TraceLine(shoot_offset_pos, target_pos, MASK_SHOT_HULL, shouldHit)

			-- Debug trace results
			if line_trace then
				printc(255, 255, 0, 255, string.format("[MULTIPOINT] Trace fraction: %s", tostring(line_trace.fraction)))
				if line_trace.fraction < 1 then
					printc(255, 0, 0, 255,
						string.format("[MULTIPOINT] Trace hit entity: %s",
							tostring(line_trace.entity and line_trace.entity:GetIndex() or 'nil')))
				end
			else
				printc(255, 0, 0, 255, "[MULTIPOINT] Trace returned nil!")
			end

			return line_trace and line_trace.fraction >= 1
		else
			-- For projectiles with volume, calculate proper ballistic arc to get aim direction
			local projectile_speed = self.weapon_info:GetVelocity(0):Length()
			local gravity = self.weapon_info:GetGravity(0) * 800
			local ballistic_dir = self.math_utils.SolveBallisticArc(self.vecShootPos, target_pos, projectile_speed,
				gravity)
			if not ballistic_dir then
				return false -- No ballistic solution exists
			end

			-- Now simulate the projectile from shoot position using the ballistic direction as initial velocity
			local distance = (target_pos - self.vecShootPos):Length()
			local step_size = 50 -- Check every 50 units
			local max_steps = math.ceil(distance / step_size)

			for i = 1, max_steps do
				local check_distance = i * step_size
				if check_distance > distance then
					break
				end

				-- Calculate projectile position using ballistic trajectory simulation
				local time = check_distance / projectile_speed

				-- Simulate projectile motion: position = start + velocity*t + 0.5*gravity*t^2
				local initial_velocity = ballistic_dir * projectile_speed
				local projectile_pos = self.vecShootPos + (initial_velocity * time)

				-- Apply gravity to the trajectory (projectile falls as it travels)
				if gravity > 0 then
					projectile_pos.z = projectile_pos.z - (0.5 * gravity * time * time)
				end

				-- Check if projectile can reach this position
				local hull_trace = engine.TraceHull(self.vecShootPos, projectile_pos, vecMins, vecMaxs, MASK_SHOT_HULL,
					shouldHit)
				if not hull_trace or hull_trace.fraction < 1 then
					return false
				end
			end

			return true
		end
	end

	local head_pos = self.ent_utils.GetBones and self.ent_utils.GetBones(self.pTarget)[1] or nil
	local center_pos = self.vecPredictedPos + Vector3(0, 0, target_height / 2)
	local feet_pos = self.vecPredictedPos

	local fallback_points = {
		-- Bottom corners (feet/ground level, prioritized if feet are enabled)
		{ pos = Vector3(-target_width / 2, -target_depth / 2, mins.z - origin.z), name = "bottom_corner_1" },
		{ pos = Vector3(target_width / 2, -target_depth / 2, mins.z - origin.z),  name = "bottom_corner_2" },
		{ pos = Vector3(-target_width / 2, target_depth / 2, mins.z - origin.z),  name = "bottom_corner_3" },
		{ pos = Vector3(target_width / 2, target_depth / 2, mins.z - origin.z),   name = "bottom_corner_4" },

		-- Mid-height corners (body level)
		{ pos = Vector3(-target_width / 2, -target_depth / 2, target_height / 2), name = "mid_corner_1" },
		{ pos = Vector3(target_width / 2, -target_depth / 2, target_height / 2),  name = "mid_corner_2" },
		{ pos = Vector3(-target_width / 2, target_depth / 2, target_height / 2),  name = "mid_corner_3" },
		{ pos = Vector3(target_width / 2, target_depth / 2, target_height / 2),   name = "mid_corner_4" },

		-- Mid-points on edges (body level)
		{ pos = Vector3(0, -target_depth / 2, target_height / 2),                 name = "mid_front" },
		{ pos = Vector3(0, target_depth / 2, target_height / 2),                  name = "mid_back" },
		{ pos = Vector3(-target_width / 2, 0, target_height / 2),                 name = "mid_left" },
		{ pos = Vector3(target_width / 2, 0, target_height / 2),                  name = "mid_right" },

		-- Bottom mid-points (legs level)
		{ pos = Vector3(0, -target_depth / 2, mins.z - origin.z),                 name = "bottom_front" },
		{ pos = Vector3(0, target_depth / 2, mins.z - origin.z),                  name = "bottom_back" },
		{ pos = Vector3(-target_width / 2, 0, mins.z - origin.z),                 name = "bottom_left" },
		{ pos = Vector3(target_width / 2, 0, mins.z - origin.z),                  name = "bottom_right" },

		-- Top corners (head level)
		{ pos = Vector3(-target_width / 2, -target_depth / 2, target_height),     name = "top_corner_1" },
		{ pos = Vector3(target_width / 2, -target_depth / 2, target_height),      name = "top_corner_2" },
		{ pos = Vector3(-target_width / 2, target_depth / 2, target_height),      name = "top_corner_3" },
		{ pos = Vector3(target_width / 2, target_depth / 2, target_height),       name = "top_corner_4" },

		-- Top mid-points (head level)
		{ pos = Vector3(0, -target_depth / 2, target_height),                     name = "top_front" },
		{ pos = Vector3(0, target_depth / 2, target_height),                      name = "top_back" },
		{ pos = Vector3(-target_width / 2, 0, target_height),                     name = "top_left" },
		{ pos = Vector3(target_width / 2, 0, target_height),                      name = "top_right" },
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

	-- Debug: show that we're trying fallback points
	printc(255, 255, 0, 255, "[MULTIPOINT] Trying fallback points for projectile")

	for _, point in ipairs(fallback_points) do
		local test_pos = self.vecPredictedPos + point.pos
		printc(255, 255, 0, 255,
			string.format("[MULTIPOINT] Testing point %s at position: %s", point.name, tostring(test_pos)))

		if canShootToPoint(test_pos) then
			printc(0, 255, 0, 255, string.format("[MULTIPOINT] Selected fallback %s (projectile)", point.name))
			return test_pos
		else
			printc(255, 0, 0, 255, string.format("[MULTIPOINT] Fallback %s failed", point.name))
		end
	end

	printc(255, 0, 0, 255, "[MULTIPOINT] No valid multipoint found!")

	-- Fallback: return center position if all else fails
	printc(255, 255, 0, 255, "[MULTIPOINT] Using fallback center position")
	return center_pos
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
