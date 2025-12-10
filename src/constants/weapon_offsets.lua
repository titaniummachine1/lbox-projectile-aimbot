-- Imports

-- Module declaration
local WeaponOffsets = {}

---Weapon-specific projectile spawn offsets
---Based on Fedoraware/TF2 source code
---Format: { normal = Vector3, ducking = Vector3 }
WeaponOffsets.OFFSETS = {
	-- Rocket Launchers
	[18] = { normal = Vector3(23.5, 12, -3), ducking = Vector3(23.5, 12, 8) }, -- Rocket Launcher
	[205] = { normal = Vector3(23.5, 12, -3), ducking = Vector3(23.5, 12, 8) }, -- RL (Renamed)
	[228] = { normal = Vector3(23.5, 12, -3), ducking = Vector3(23.5, 12, 8) }, -- Black Box
	[513] = { normal = Vector3(23.5, 0, -3), ducking = Vector3(23.5, 0, 8) }, -- The Original (centered)
	[730] = { normal = Vector3(23.5, 12, -3), ducking = Vector3(23.5, 12, 8) }, -- Beggar's Bazooka

	-- Grenade/Sticky Launchers
	[19] = { normal = Vector3(16, 8, -6) }, -- Grenade Launcher
	[206] = { normal = Vector3(16, 8, -6) }, -- GL (Renamed)
	[20] = { normal = Vector3(16, 8, -6) }, -- Stickybomb Launcher
	[207] = { normal = Vector3(16, 8, -6) }, -- SL (Renamed)

	-- Flare Guns
	[39] = { normal = Vector3(23.5, 12, -3), ducking = Vector3(23.5, 12, 8) }, -- Flare Gun
	[351] = { normal = Vector3(23.5, 12, -3), ducking = Vector3(23.5, 12, 8) }, -- Detonator
	[740] = { normal = Vector3(23.5, 12, -3), ducking = Vector3(23.5, 12, 8) }, -- Scorch Shot

	-- Crossbow
	[305] = { normal = Vector3(23.5, -8, -3) }, -- Crusader's Crossbow
	[1079] = { normal = Vector3(23.5, -8, -3) }, -- Festive Crossbow

	-- Huntsman
	[56] = { normal = Vector3(23.5, -8, -3) }, -- Huntsman
	[1005] = { normal = Vector3(23.5, -8, -3) }, -- Festive Huntsman

	-- Syringe Gun
	[17] = { normal = Vector3(16, 6, -8) }, -- Syringe Gun
	[36] = { normal = Vector3(16, 6, -8) }, -- Blutsauger
	[412] = { normal = Vector3(16, 6, -8) }, -- Overdose

	-- Rescue Ranger / Pomson
	[997] = { normal = Vector3(23.5, -8, -3), ducking = Vector3(23.5, -8, 8) }, -- Rescue Ranger
	[588] = { normal = Vector3(23.5, -8, -3), ducking = Vector3(23.5, -8, 8) }, -- Pomson 6000

	-- Dragon's Fury
	[1178] = { normal = Vector3(3, 7, -9) }, -- Dragon's Fury
}

---Gets projectile spawn offset for weapon
---@param weaponDefIndex integer Item definition index
---@param isDucking boolean Is player ducking
---@param isFlipped boolean Is viewmodel flipped
---@return Vector3? offset Spawn offset (nil if no specific offset)
function WeaponOffsets.getOffset(weaponDefIndex, isDucking, isFlipped)
	local offsetData = WeaponOffsets.OFFSETS[weaponDefIndex]
	if not offsetData then
		return nil
	end

	-- Use ducking offset if available and player is ducking
	local offset = (isDucking and offsetData.ducking) or offsetData.normal
	if not offset then
		offset = offsetData.normal
	end

	-- Flip Y offset if viewmodel is flipped
	if isFlipped and offset then
		return Vector3(offset.x, -offset.y, offset.z)
	end

	return offset
end

---Calculates final projectile fire position
---@param player Entity Local player
---@param eyePos Vector3 Eye position
---@param angles EulerAngles View angles
---@param weaponDefIndex integer Weapon definition index
---@return Vector3 firePos Final fire position
function WeaponOffsets.getFirePosition(player, eyePos, angles, weaponDefIndex)
	assert(player, "WeaponOffsets: player is nil")
	assert(eyePos, "WeaponOffsets: eyePos is nil")
	assert(angles, "WeaponOffsets: angles is nil")

	local isDucking = (player:GetPropInt("m_fFlags") & FL_DUCKING) ~= 0
	local _, cl_flipviewmodels = client.GetConVar("cl_flipviewmodels")
	local isFlipped = cl_flipviewmodels == 1

	local offset = WeaponOffsets.getOffset(weaponDefIndex, isDucking, isFlipped)
	if not offset then
		return eyePos -- No offset, use eye position
	end

	-- Convert offset to world space
	local forward = angles:Forward()
	local right = angles:Right()
	local up = angles:Up()

	local firePos = eyePos + (forward * offset.x) + (right * offset.y) + (up * offset.z)

	return firePos
end

return WeaponOffsets
