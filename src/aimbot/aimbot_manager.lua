local G = require("globals")
local GetProjectileInfo = require("projectile_info")

local ProjectileAimbot = require("aimbot.projectile_aimbot")
local MeleeAimbot = require("aimbot.melee_aimbot")
-- local HitscanAimbot = require("aimbot.hitscan_aimbot") -- Disabled for now

local AimbotManager = {}

function AimbotManager.Run(cmd, plocal, weapon)
	local info = GetProjectileInfo(weapon:GetPropInt("m_iItemDefinitionIndex"))

	if info then
		-- We have projectile info, use projectile aimbot
		return ProjectileAimbot.Run(cmd, plocal, weapon, info)
	end

	-- If no projectile info, check weapon type
	local weaponID = weapon:GetPropInt("m_iItemDefinitionIndex")
	-- In TF2, weapons are generally hitscan or melee if not projectiles.
	-- We can use GetWeaponID or classes to distinguish.

	-- Check if it's a melee weapon
	-- Quick check: TF2 melee weapons usually have short range.
	-- Alternatively, check weapon class or slot.
	local slot = weapon:GetSlot()
	if slot == 2 then -- Slot 2 is usually melee in TF2
		return MeleeAimbot.Run(cmd, plocal, weapon)
	end

	-- If hitscan (slot 0 or 1 usually, and no projectile info)
	-- Disabled for now as per user request
	-- return HitscanAimbot.Run(cmd, plocal, weapon)

	return false
end

return AimbotManager
