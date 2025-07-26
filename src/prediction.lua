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
	local projectile_speed = self.weapon_info:GetVelocity(0):Length()

	if self.pWeapon:GetWeaponID() == E_WeaponBaseID.TF_WEAPON_COMPOUND_BOW then
		-- check if bow is currently being charged
		local charge_begin_time = self.pWeapon:GetChargeBeginTime()
		projectile_speed = self.weapon_info:GetVelocity(charge_begin_time or 0):Length()

		-- if charge_begin_time is 0, the bow isn't charging
		if charge_begin_time > 0 then
			charge_time = globals.CurTime() - charge_begin_time
			-- clamp charge time between 0 and 1 second (full charge)
			charge_time = math.max(0, math.min(charge_time, 1.0))

			-- apply charge multiplier to projectile speed
			local charge_multiplier = 1.0 + (charge_time * 0.44) -- 44% speed increase at full charge
			projectile_speed = projectile_speed * charge_multiplier
		else
			-- bow is not charging, use minimum speed
			charge_time = 0.0
		end
	elseif self.pWeapon:GetWeaponID() == E_WeaponBaseID.TF_WEAPON_PIPEBOMBLAUNCHER then
		local charge_begin_time = self.pWeapon:GetChargeBeginTime()
		projectile_speed = self.weapon_info:GetVelocity(charge_begin_time or 0):Length()

		if charge_begin_time > 0 then
			charge_time = globals.CurTime() - charge_begin_time
			if charge_time > 4.0 then
				charge_time = 0.0
			end
		end
	end

	return charge_time, projectile_speed
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

	local charge_time, projectile_speed = self:GetChargeTimeAndSpeed()
	local gravity = self.weapon_info:GetGravity(charge_time) * 800 --- example: 200

	local detonate_time = self.pWeapon:GetWeaponID() == E_WeaponBaseID.TF_WEAPON_PIPEBOMBLAUNCHER and 0.7 or 0
	local travel_time_est = (vecTargetOrigin - self.vecShootPos):Length() / projectile_speed
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

	if self.settings.multipointing then
		local bSplashWeapon = IsSplashDamageWeapon(self.pWeapon)
		local viewPos = self.pLocal:GetAbsOrigin() + self.pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")

		multipoint:Set(
			self.pLocal,
			self.pWeapon,
			self.pTarget,
			self.bIsHuntsman,
			self.bAimAtTeamMates,
			viewPos, -- Use view position, not calculated shoot position
			predicted_target_pos,
			self.weapon_info,
			self.math_utils,
			self.settings.max_distance,
			bSplashWeapon,
			self.ent_utils,
			self.settings
		)

		---@diagnostic disable-next-line: cast-local-type
		predicted_target_pos = multipoint:GetBestHitPoint()

		if not predicted_target_pos then
			return nil
		end
	end

	local aim_dir = self.math_utils.NormalizeVector(predicted_target_pos - self.vecShootPos)
	if not aim_dir then
		return nil
	end

	if gravity > 0 then
		-- Get velocity components from weapon info
		local velocity_vector = self.weapon_info:GetVelocity(charge_time)
		local forward_speed = velocity_vector.x
		local upward_speed = velocity_vector.z or 0

		-- Use the new ballistic calculation that properly handles upward velocity
		local ballistic_dir = self.math_utils.SolveBallisticArcWithUpwardVelocity(
			self.vecShootPos,
			predicted_target_pos,
			forward_speed,
			upward_speed,
			gravity
		)

		if ballistic_dir then
			aim_dir = ballistic_dir
		else
			-- Fallback to old method if new calculation fails
			ballistic_dir = self.math_utils.SolveBallisticArc(self.vecShootPos, predicted_target_pos, projectile_speed,
				gravity)
			if ballistic_dir then
				aim_dir = ballistic_dir
			end
		end
	end

	return {
		vecPos = predicted_target_pos,
		nTime = total_time,
		nChargeTime = charge_time,
		vecAimDir = aim_dir,
		vecPlayerPath = player_positions,
	}
end

return pred
