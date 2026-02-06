local Config = require("config")
local Utils = require("utils")

local Entity = {}

Entity.ItemDefinitions = {
	[222] = 11,
	[812] = 12,
	[833] = 12,
	[1121] = 11,
	[18] = -1,
	[205] = -1,
	[127] = -1,
	[228] = -1,
	[237] = -1,
	[414] = -1,
	[441] = -1,
	[513] = -1,
	[658] = -1,
	[730] = -1,
	[800] = -1,
	[809] = -1,
	[889] = -1,
	[898] = -1,
	[907] = -1,
	[916] = -1,
	[965] = -1,
	[974] = -1,
	[1085] = -1,
	[1104] = -1,
	[15006] = -1,
	[15014] = -1,
	[15028] = -1,
	[15043] = -1,
	[15052] = -1,
	[15057] = -1,
	[15081] = -1,
	[15104] = -1,
	[15105] = -1,
	[15129] = -1,
	[15130] = -1,
	[15150] = -1,
	[442] = -1,
	[1178] = -1,
	[588] = -1,
	[39] = 8,
	[351] = 8,
	[595] = 8,
	[740] = 8,
	[1180] = 0,
	[19] = 5,
	[206] = 5,
	[308] = 5,
	[996] = 6,
	[1007] = 5,
	[1151] = 4,
	[15077] = 5,
	[15079] = 5,
	[15091] = 5,
	[15092] = 5,
	[15116] = 5,
	[15117] = 5,
	[15142] = 5,
	[15158] = 5,
	[20] = 1,
	[207] = 1,
	[130] = 3,
	[265] = 3,
	[661] = 1,
	[797] = 1,
	[806] = 1,
	[886] = 1,
	[895] = 1,
	[904] = 1,
	[913] = 1,
	[962] = 1,
	[971] = 1,
	[1150] = 2,
	[15009] = 1,
	[15012] = 1,
	[15024] = 1,
	[15038] = 1,
	[15045] = 1,
	[15048] = 1,
	[15082] = 1,
	[15083] = 1,
	[15084] = 1,
	[15113] = 1,
	[15137] = 1,
	[15138] = 1,
	[15155] = 1,
	[997] = 9,
	[17] = 10,
	[204] = 10,
	[36] = 10,
	[305] = 9,
	[412] = 10,
	[1079] = 9,
	[56] = 7,
	[1005] = 7,
	[1092] = 7,
	[58] = 11,
	[1083] = 11,
	[1105] = 11,
}

local clamp = Utils.clamp

function Entity.GetProjectileInformation(pWeapon, bDucking, iCase, iDefIndex, iWepID, pLocal, chargeOverride)
	local chargeTime = chargeOverride or pWeapon:GetPropFloat("m_flChargeBeginTime") or 0

	if not chargeOverride then
		if chargeTime ~= 0 then
			chargeTime = globals.CurTime() - chargeTime
		end
	end

	local offsets = {
		Vector3(16, 8, -6),
		Vector3(23.5, -8, -3),
		Vector3(23.5, 12, -3),
		Vector3(16, 6, -8),
	}
	local collisionMaxs = {
		Vector3(0, 0, 0),
		Vector3(1, 1, 1),
		Vector3(2, 2, 2),
		Vector3(3, 3, 3),
	}

	if iCase == -1 then
		local vOffset = Vector3(23.5, -8, bDucking and 8 or -3)
		local vCollisionMax = collisionMaxs[1]
		local fForwardVelocity = 1200
		if iWepID == 22 or iWepID == 65 then
			vOffset.y = (iDefIndex == 513) and 0 or 12
			fForwardVelocity = (iWepID == 65) and 2000 or ((iDefIndex == 414) and 1550 or 1100)
		elseif iWepID == 109 then
			vOffset.y, vOffset.z = 6, -3
		else
			fForwardVelocity = 1200
		end
		return vOffset, fForwardVelocity, 0, vCollisionMax, 0, nil
	elseif iCase == 1 then
		return offsets[1], 900 + clamp(chargeTime / 4, 0, 1) * 1500, 200, collisionMaxs[3], 0, nil
	elseif iCase == 2 then
		return offsets[1], 900 + clamp(chargeTime / 1.2, 0, 1) * 1500, 200, collisionMaxs[3], 0, nil
	elseif iCase == 3 then
		return offsets[1], 900 + clamp(chargeTime / 4, 0, 1) * 1500, 200, collisionMaxs[3], 0, nil
	elseif iCase == 4 then
		return offsets[1], 1200, 200, collisionMaxs[4], 400, 0.45
	elseif iCase == 5 then
		local vel = (iDefIndex == 308) and 1500 or 1200
		local drag = (iDefIndex == 308) and 0.225 or 0.45
		return offsets[1], vel, 200, collisionMaxs[4], 400, drag
	elseif iCase == 6 then
		return offsets[1], 1440, 200, collisionMaxs[3], 560, 0.5
	elseif iCase == 7 then
		return offsets[2],
			1800 + clamp(chargeTime, 0, 1) * 800,
			0,
			collisionMaxs[2],
			200 - clamp(chargeTime, 0, 1) * 160,
			nil
	elseif iCase == 8 then
		return Vector3(23.5, 12, bDucking and 8 or -3), 2000, 0, Vector3(0.1, 0.1, 0.1), 120, 0.5
	elseif iCase == 9 then
		local idx = (iDefIndex == 997) and 2 or 4
		return offsets[2], 2400, 0, collisionMaxs[idx], 80, nil
	elseif iCase == 10 then
		return offsets[4], 1000, 0, collisionMaxs[2], 120, nil
	elseif iCase == 11 then
		return Vector3(23.5, 8, -3), 1000, 200, collisionMaxs[4], 450, nil
	elseif iCase == 12 then
		return Vector3(23.5, 8, -3), 3000, 300, collisionMaxs[3], 900, 1.3
	end
end

function Entity.isProjectileWeapon()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return false
	end
	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon or not pWeapon:IsValid() then
		return false
	end
	local projectileType = pWeapon:GetWeaponProjectileType()
	return projectileType and projectileType >= 2
end

function Entity.getWeaponContext(pLocal, pWeapon)
	assert(pLocal and pWeapon, "getWeaponContext: missing pLocal or pWeapon")

	local iItemDefIndex = pWeapon:GetPropInt("m_iItemDefinitionIndex")
	if not iItemDefIndex then
		return nil
	end

	local iCase = Entity.ItemDefinitions[iItemDefIndex] or 0
	if iCase == 0 then
		return nil
	end

	local weaponID = pWeapon:GetWeaponID()
	if not weaponID then
		return nil
	end

	local isDucking = (pLocal:GetPropInt("m_fFlags") & FL_DUCKING) == 2

	local canCharge = pWeapon.CanCharge and pWeapon:CanCharge() or false
	local chargeMaxTime = 0
	if canCharge then
		chargeMaxTime = pWeapon:GetChargeMaxTime() or 4.0
	end

	return {
		itemDefIndex = iItemDefIndex,
		itemCase = iCase,
		weaponID = weaponID,
		isDucking = isDucking,
		hasCharge = canCharge,
		chargeMaxTime = chargeMaxTime,
		usesPhysics = (iCase >= 1 and iCase <= 3),
	}
end

return Entity
