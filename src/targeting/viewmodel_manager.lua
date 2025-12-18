-- Module: viewmodel_manager
-- Handles automatic viewmodel flipping for optimal projectile aiming

local ViewmodelManager = {}

-- Imports
local G = require("globals")
local WeaponOffsets = require("constants.weapon_offsets")
local utils = {}
utils.math = require("utils.math")

---Count how many corners can be shot from a given fire position
---@param firePos Vector3
---@param corners Vector3[]
---@param targetIndex integer
---@param speed number
---@param gravity number
---@param hullMins Vector3
---@param hullMaxs Vector3
---@param traceMask number
---@param localIndex integer
---@return integer
local function countShootableCorners(firePos, corners, targetIndex, speed, gravity, hullMins, hullMaxs, traceMask, localIndex)
	if not firePos then
		return 0
	end

	local function shouldHitEntity(ent, contentsMask)
		if not ent then
			return false
		end
		local idx = ent.GetIndex and ent:GetIndex() or nil
		if idx == localIndex then
			return false
		end
		if idx == targetIndex then
			return true
		end
		return false
	end

	local count = 0
	for i = 1, 8 do
		local corner = corners[i]
		-- Solve ballistics from fire position to corner
		local aimAngle = utils.math.SolveBallisticArc(firePos, corner, speed, gravity)
		if aimAngle then
			local trace
			if hullMins:Length() > 0.01 or hullMaxs:Length() > 0.01 then
				trace = engine.TraceHull(firePos, corner, hullMins, hullMaxs, traceMask, shouldHitEntity)
			else
				trace = engine.TraceLine(firePos, corner, traceMask, shouldHitEntity)
			end

			if trace and not trace.startsolid and not trace.allsolid then
				if trace.fraction > 0.99 then
					count = count + 1
				elseif trace.entity and trace.entity.GetIndex and trace.entity:GetIndex() == targetIndex then
					count = count + 1
				end
			end
		end
	end
	return count
end

---Get 8 corners of player AABB in world space
---@param targetPos Vector3
---@param mins Vector3
---@param maxs Vector3
---@return Vector3[]
local function getAABBCorners(targetPos, mins, maxs)
	local worldMins = targetPos + mins
	local worldMaxs = targetPos + maxs
	return {
		Vector3(worldMins.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMins.z),
		Vector3(worldMaxs.x, worldMins.y, worldMins.z),
		Vector3(worldMins.x, worldMins.y, worldMaxs.z),
		Vector3(worldMins.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMaxs.y, worldMaxs.z),
		Vector3(worldMaxs.x, worldMins.y, worldMaxs.z),
	}
end

---Compute fire position for given viewmodel flip state
---@param weaponDefIndex integer
---@param isDucking boolean
---@param isFlipped boolean
---@param aimEyePos Vector3
---@param dirToTarget Vector3
---@return Vector3?
function ViewmodelManager.computeFirePos(weaponDefIndex, isDucking, isFlipped, aimEyePos, dirToTarget)
	-- Always get non-flipped offset first, then apply flip manually
	local offset = WeaponOffsets.getOffset(weaponDefIndex, isDucking, false)
	if not offset then
		-- Fallback offset for weapons not in the table
		offset = Vector3(23.5, 12, -3) -- Rocket launcher style
	end

	-- Apply viewmodel flip by negating Y coordinate
	if isFlipped then
		offset = Vector3(offset.x, -offset.y, offset.z)
	end

	local rotatedOffset = utils.math.RotateOffsetAlongDirection(offset, dirToTarget)
	local offsetPos = aimEyePos + rotatedOffset
	local trace = engine.TraceHull(aimEyePos, offsetPos, -Vector3(8, 8, 8), Vector3(8, 8, 8), MASK_SHOT_HULL)
	if not trace or trace.startsolid then
		return nil -- can't reach this offset, invalid
	end
	return trace.endpos
end

---Auto flip viewmodels based on multipoint corner visibility
---@param targetEntity Entity
---@param predictedPos Vector3
---@param aimEyePos Vector3
---@param weapon Weapon
---@param speed number
---@param gravity number
---@param hullMins Vector3
---@param hullMaxs Vector3
---@param traceMask number
---@param localIndex integer
function ViewmodelManager.autoFlipIfNeeded(targetEntity, predictedPos, aimEyePos, weapon, speed, gravity, hullMins, hullMaxs, traceMask, localIndex)
	if not G.Menu or not G.Menu.Aimbot or not G.Menu.Aimbot.AutoFlipViewmodels then
		return
	end

	local weaponDefIndex = weapon:GetPropInt("m_iItemDefinitionIndex")
	if not weaponDefIndex then
		return
	end

	local targetMins = targetEntity:GetMins()
	local targetMaxs = targetEntity:GetMaxs()
	if not (targetMins and targetMaxs) then
		return
	end

	local targetIndex = targetEntity:GetIndex()
	if not targetIndex then
		return
	end

	local isDucking = false
	do
		local okFlags, flags = pcall(function()
			return entities.GetLocalPlayer():GetPropInt("m_fFlags")
		end)
		if okFlags and type(flags) == "number" and type(FL_DUCKING) == "number" then
			isDucking = (flags & FL_DUCKING) ~= 0
		end
	end

	local dirToTarget = predictedPos - aimEyePos
	local corners = getAABBCorners(predictedPos, targetMins, targetMaxs)

	-- Check default (non-flipped) viewmodel first
	local currentFlipped = weapon:IsViewModelFlipped()

	local defaultFirePos = ViewmodelManager.computeFirePos(weaponDefIndex, isDucking, false, aimEyePos, dirToTarget)
	local defaultScore = defaultFirePos and countShootableCorners(defaultFirePos, corners, targetIndex, speed, gravity, hullMins, hullMaxs, traceMask, localIndex) or 0

	-- If default has 6+ corners, use it and don't check flipped
	if defaultScore >= 6 then
		if currentFlipped ~= false then
			client.RemoveConVarProtection("cl_flipviewmodels")
			client.SetConVar("cl_flipviewmodels", 0)
			client.Command("cl_flipviewmodels 0", true)
		end
		autoFlipDecided = true
		return
	end

	-- If default has <6 corners, check flipped and choose the better one
	local flippedFirePos = ViewmodelManager.computeFirePos(weaponDefIndex, isDucking, true, aimEyePos, dirToTarget)
	local flippedScore = flippedFirePos and countShootableCorners(flippedFirePos, corners, targetIndex, speed, gravity, hullMins, hullMaxs, traceMask, localIndex) or 0

	-- Prefer default when scores are equal, only flip if flipped is strictly better
	local shouldFlip = flippedScore > defaultScore
	local desired = shouldFlip and 1 or 0

	-- Only change if different from current state
	if shouldFlip ~= currentFlipped then
		client.RemoveConVarProtection("cl_flipviewmodels")
		client.SetConVar("cl_flipviewmodels", desired)
		client.Command("cl_flipviewmodels " .. tostring(desired), true)
	end
end

return ViewmodelManager
