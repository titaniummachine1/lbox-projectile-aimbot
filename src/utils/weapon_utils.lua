local wep_utils = {}

local old_weapon, lastFire, nextAttack

local function GetLastFireTime(weapon)
	return weapon:GetPropFloat("LocalActiveTFWeaponData", "m_flLastFireTime")
end

local function GetNextPrimaryAttack(weapon)
	return weapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")
end

--- https://www.unknowncheats.me/forum/team-fortress-2-a/273821-canshoot-function.html
function wep_utils.CanShoot()
	local player = entities:GetLocalPlayer()
	if not player then
		return false
	end

	local weapon = player:GetPropEntity("m_hActiveWeapon")
	if not weapon or not weapon:IsValid() then
		return false
	end
	if weapon:GetPropInt("LocalWeaponData", "m_iClip1") == 0 then
		return false
	end

	local lastfiretime = GetLastFireTime(weapon)
	if lastFire ~= lastfiretime or weapon ~= old_weapon then
		lastFire = lastfiretime
		nextAttack = GetNextPrimaryAttack(weapon)
	end
	old_weapon = weapon
	return nextAttack <= globals.CurTime()
end

---@param val number
---@param min number
---@param max number
local function clamp(val, min, max)
	return math.max(min, math.min(val, max))
end

-- Dynamic projectile information using projectile_info.lua
local GetProjectileInformation = require("src.projectile_info")

---@param pWeapon Entity
---@return WeaponInfo|nil
function wep_utils.GetWeaponInfo(pWeapon)
	local definition_index = pWeapon:GetPropInt("m_iItemDefinitionIndex")
	local weaponInfo = GetProjectileInformation(definition_index)

	if not weaponInfo then
		return nil
	end

	return weaponInfo
end

---@param pWeapon Entity
---@return Vector3, number, number, Vector3, number, number|nil
function wep_utils.GetProjectileInformation(pWeapon, bDucking)
	local weaponInfo = wep_utils.GetWeaponInfo(pWeapon)
	if not weaponInfo then
		return Vector3(0, 0, 0), 0, 0, Vector3(0, 0, 0), 0, nil
	end

	-- Get charge time for weapons that support it
	local chargeTime = pWeapon:GetPropFloat("m_flChargeBeginTime") or 0
	if chargeTime ~= 0 then
		chargeTime = globals.CurTime() - chargeTime
	end

	-- Get offset
	local offset = weaponInfo:GetOffset(bDucking, pWeapon:IsViewModelFlipped())

	-- Get velocity dynamically
	local velocity
	if weaponInfo.GetVelocity then
		velocity = weaponInfo:GetVelocity(chargeTime)
	else
		velocity = weaponInfo.m_vecVelocity or Vector3(0, 0, 0)
	end

	-- Extract velocity components
	local forward_speed = math.sqrt(velocity.x ^ 2 + velocity.y ^ 2)
	local upward_speed = velocity.z or 0

	-- Get collision hull
	local collision_hull = weaponInfo.m_vecMaxs or Vector3(0, 0, 0)

	-- Get gravity dynamically
	local gravity
	if weaponInfo.GetGravity then
		gravity = weaponInfo:GetGravity(chargeTime) * 800 -- Convert to HU/s²
	else
		gravity = (weaponInfo.m_flGravity or 0) * 800
	end

	-- Get drag
	local drag = weaponInfo.m_flDrag

	return offset, forward_speed, upward_speed, collision_hull, gravity, drag
end

---@param pLocal Entity
---@param weapon_info WeaponInfo
---@param eAngle EulerAngles
---@return Vector3
function wep_utils.GetShootPos(pLocal, weapon_info, eAngle)
	local vStartPosition = pLocal:GetAbsOrigin() + pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	return weapon_info:GetFirePosition(pLocal, vStartPosition, eAngle, client.GetConVar("cl_flipviewmodels") == 1)
end

return wep_utils
