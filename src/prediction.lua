local multipoint = require("src.multipoint")

---@class Prediction
---@field pLocal Entity
---@field pWeapon Entity
---@field pTarget Entity
---@field weapon_info WeaponInfo
---@field proj_sim ProjectileSimulation
---@field player_sim table
---@field vecShootPos Vector3
---@field math_utils MathLib
---@field nLatency number
---@field settings table
---@field private __index table
---@field ent_utils table
local pred = {}
pred.__index = pred

function pred:Set(
	pLocal,
	pWeapon,
	pTarget,
	weapon_info,
	proj_sim,
	player_sim,
	math_utils,
	vecShootPos,
	nLatency,
	settings,
	bIsHuntsman,
	bAimAtTeamMates,
	ent_utils
)
	self.pLocal = pLocal
	self.pWeapon = pWeapon
	self.weapon_info = weapon_info
	self.proj_sim = proj_sim
	self.player_sim = player_sim
	self.vecShootPos = vecShootPos
	self.pTarget = pTarget
	self.nLatency = nLatency
	self.math_utils = math_utils
	self.settings = settings
	self.bIsHuntsman = bIsHuntsman
	self.bAimAtTeamMates = bAimAtTeamMates
	self.ent_utils = ent_utils
end

function pred:GetChargeTimeAndSpeed()
	local charge_time = 0.0
	local velocity_vector = self.weapon_info:GetVelocity(0)

	-- Get charge time for weapons that support it
	local charge_begin_time = self.pWeapon:GetChargeBeginTime()
	if charge_begin_time and charge_begin_time > 0 then
		charge_time = globals.CurTime() - charge_begin_time

		-- Weapon-specific charge time limits
		if self.pWeapon:GetWeaponID() == E_WeaponBaseID.TF_WEAPON_COMPOUND_BOW then
			-- clamp charge time between 0 and 1 second (full charge)
			charge_time = math.max(0, math.min(charge_time, 1.0))
		elseif self.pWeapon:GetWeaponID() == E_WeaponBaseID.TF_WEAPON_PIPEBOMBLAUNCHER then
			if charge_time > 4.0 then
				charge_time = 0.0
			end
		end

		-- Get velocity with charge time
		velocity_vector = self.weapon_info:GetVelocity(charge_time)
	end

	return charge_time, velocity_vector
end

---@param pWeapon Entity
local function IsSplashDamageWeapon(pWeapon)
	local projtype = pWeapon:GetWeaponProjectileType()
	local result = projtype == E_ProjectileType.TF_PROJECTILE_ROCKET
		or projtype == E_ProjectileType.TF_PROJECTILE_PIPEBOMB_REMOTE
		or projtype == E_ProjectileType.TF_PROJECTILE_PIPEBOMB_PRACTICE
		or projtype == E_ProjectileType.TF_PROJECTILE_CANNONBALL
	return result
end

---@return PredictionResult?
function pred:Run()
	if not self.pLocal or not self.pWeapon or not self.pTarget then
		return nil
	end

	local vecTargetOrigin = self.pTarget:GetAbsOrigin()
	local dist = (self.vecShootPos - vecTargetOrigin):Length()
	if dist > self.settings.max_distance then
		return nil
	end

	local charge_time, velocity_vector = self:GetChargeTimeAndSpeed()
	local gravity = self.weapon_info:GetGravity(charge_time) * 800 --- example: 200

	-- Extract velocity components for calculations
	local forward_speed = math.sqrt(velocity_vector.x ^ 2 + velocity_vector.y ^ 2)
	local upward_speed = velocity_vector.z or 0
	local total_speed = velocity_vector:Length()

	local detonate_time = self.pWeapon:GetWeaponID() == E_WeaponBaseID.TF_WEAPON_PIPEBOMBLAUNCHER and 0.7 or 0

	local travel_time_est
	if gravity > 0 then
		-- For ballistic weapons, calculate travel time based on ballistic trajectory
		local ballistic_dir = self.math_utils.GetProjectileAimDirection(
			self.vecShootPos,
			vecTargetOrigin,
			forward_speed,
			upward_speed,
			gravity
		)

		if ballistic_dir then
			travel_time_est = self.math_utils.GetFlightTimeAlongDir(
				self.vecShootPos,
				vecTargetOrigin,
				total_speed,
				gravity,
				ballistic_dir
			)
		else
			-- Fallback to old ballistic calculation
			ballistic_dir = self.math_utils.SolveBallisticArc(self.vecShootPos, vecTargetOrigin, total_speed, gravity)
			if ballistic_dir then
				travel_time_est = self.math_utils.GetFlightTimeAlongDir(
					self.vecShootPos,
					vecTargetOrigin,
					total_speed,
					gravity,
					ballistic_dir
				)
			end
		end
	end

	-- If no ballistic solution or no gravity, use linear calculation
	if not travel_time_est then
		travel_time_est = (vecTargetOrigin - self.vecShootPos):Length() / total_speed
	end

	if not travel_time_est then return nil end -- no solution found

	local total_time = travel_time_est + self.nLatency + detonate_time
	if total_time > self.settings.max_sim_time or total_time > self.weapon_info.m_flLifetime then
		return nil
	end

	local flstepSize = self.pLocal:GetPropFloat("localdata", "m_flStepSize") or 18
	local player_positions = self.player_sim.Run(flstepSize, self.pTarget, total_time)
	if not player_positions then
		return nil
	end

	local predicted_target_pos = player_positions[#player_positions] or self.pTarget:GetAbsOrigin()

	-- Use multipoint to determine the default aim point
	local default_aim_pos = predicted_target_pos
	if self.settings.multipointing then
		local bSplashWeapon = IsSplashDamageWeapon(self.pWeapon)
		local viewPos = self.pLocal:GetAbsOrigin() + self.pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")

		multipoint:Set(
			self.pLocal,
			self.pWeapon,
			self.pTarget,
			self.bIsHuntsman,
			self.bAimAtTeamMates,
			viewPos,
			predicted_target_pos,
			self.weapon_info,
			self.math_utils,
			self.settings.max_distance,
			bSplashWeapon,
			self.ent_utils,
			self.settings
		)

		local multipoint_pos = multipoint:GetBestHitPoint()
		if multipoint_pos then
			default_aim_pos = multipoint_pos
		end
	end

	-- Calculate ballistic aim direction for the default aim point
	local aim_dir = self.math_utils.NormalizeVector(default_aim_pos - self.vecShootPos)
	if not aim_dir then
		return nil
	end

	-- For ballistic weapons, calculate aim direction first
	if gravity > 0 then
		-- Use the improved ballistic calculation with total speed
		local velocity_vector = self.weapon_info:GetVelocity(0)
		local total_speed = velocity_vector:Length()

		local ballistic_dir = self.math_utils.GetProjectileAimDirection(
			self.vecShootPos,
			default_aim_pos,
			total_speed,
			gravity
		)

		if ballistic_dir then
			aim_dir = ballistic_dir
			printc(150, 255, 150, 255,
				string.format("[PROJ AIMBOT] Ballistic calculation succeeded - gravity: %.2f, total_speed: %.1f",
					gravity / 800, total_speed))
		else
			-- Fallback to old method if new calculation fails
			ballistic_dir = self.math_utils.SolveBallisticArc(self.vecShootPos, default_aim_pos, total_speed,
				gravity)
			if ballistic_dir then
				aim_dir = ballistic_dir
				printc(150, 255, 150, 255,
					string.format(
					"[PROJ AIMBOT] Fallback ballistic calculation succeeded - gravity: %.2f, total_speed: %.1f",
						gravity / 800, total_speed))
			else
				printc(255, 100, 100, 255,
					string.format("[PROJ AIMBOT] Ballistic calculation failed - gravity: %.2f, total_speed: %.1f",
						gravity / 800, total_speed))
			end
		end
	end

	return {
		vecPos = predicted_target_pos,
		nTime = total_time,
		nChargeTime = charge_time,
		vecAimDir = aim_dir,
		vecPlayerPath = player_positions,
		defaultAimPos = default_aim_pos, -- Store the default aim position for fallback
	}
end

return pred
