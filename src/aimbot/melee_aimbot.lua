local G = require("globals")
local utils = {
	math = require("utils.math"),
	weapon = require("utils.weapon_utils"),
}

local MeleeAimbot = {}

-- Constants for trickstab
local TF2 = {
	BACKSTAB_RANGE = 66,
	MELEE_HIT_RANGE = 225,
	BACKSTAB_ANGLE = 90,
	SPY = 8,
}

local function NormalizeYaw(yaw)
	yaw = yaw % 360
	if yaw > 180 then
		yaw = yaw - 360
	elseif yaw < -180 then
		yaw = yaw + 360
	end
	return yaw
end

---Walk in a world direction by calculating what yaw makes input go there
local function WalkTo(cmd, worldDir)
	local targetYaw = math.deg(math.atan(worldDir.y, worldDir.x))
	local viewAngles = engine.GetViewAngles()

	-- Method: Keep player input, rotate view to compensate
	-- This is what the user's reference script did with 'Angle Snap'
	local inputForward = cmd:GetForwardMove()
	local inputSide = cmd:GetSideMove()

	local inputAngle = 0
	if math.abs(inputForward) > 0.1 or math.abs(inputSide) > 0.1 then
		inputAngle = math.deg(math.atan(-inputSide, inputForward))
	end

	local desiredViewYaw = NormalizeYaw(targetYaw - inputAngle)
	engine.SetViewAngles(EulerAngles(viewAngles.x, desiredViewYaw, 0))
end

function MeleeAimbot.Run(cmd, plocal, weapon)
	local isSpy = plocal:GetPropInt("m_iClass") == TF2.SPY
	local cfg = G.Menu.Aimbot

	-- Potential target selection for melee
	local target = MeleeAimbot.GetBestTarget(plocal)
	if not target then
		return false
	end

	if isSpy and cfg.AutoTrickstab then
		return MeleeAimbot.HandleTrickstab(cmd, plocal, weapon, target)
	else
		return MeleeAimbot.HandleRegularMelee(cmd, plocal, weapon, target)
	end
end

function MeleeAimbot.GetBestTarget(plocal)
	local localPos = plocal:GetAbsOrigin()
	local enemyTeam = plocal:GetTeamNumber() == 2 and 3 or 2
	local bestTarget = nil
	local bestDist = math.huge

	for _, entity in pairs(entities.FindByClass("CTFPlayer")) do
		if entity:IsAlive() and not entity:IsDormant() and entity:GetTeamNumber() == enemyTeam then
			local dist = (entity:GetAbsOrigin() - localPos):Length()
			if dist < TF2.MELEE_HIT_RANGE and dist < bestDist then
				bestDist = dist
				bestTarget = entity
			end
		end
	end

	return bestTarget
end

function MeleeAimbot.HandleTrickstab(cmd, plocal, weapon, target)
	-- Simplified trickstab logic based on the user's reference
	local targetPos = target:GetAbsOrigin()
	local localPos = plocal:GetAbsOrigin()

	-- Check if we are behind the target
	local targetViewAngles = target:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	if not targetViewAngles then
		return false
	end

	local targetForward = EulerAngles(targetViewAngles.x, targetViewAngles.y, targetViewAngles.z):Forward()
	local toLocal = (localPos - targetPos):Normalized()

	-- Dot product check for backstab angle
	local dot = targetForward:Dot(toLocal)
	local isBehind = dot < -0.5 -- Roughly within 120 degrees of the back

	local dist = (targetPos - localPos):Length()

	if isBehind and dist <= TF2.BACKSTAB_RANGE then
		-- We are in range and behind! Trigger attack
		cmd:SetButtons(cmd:GetButtons() | 1) -- IN_ATTACK
		return true
	elseif G.Menu.Aimbot.AutoWalk then
		-- Move towards the target's back
		local backPos = targetPos - targetForward * 40
		local moveDir = (backPos - localPos):Normalized()
		WalkTo(cmd, moveDir)
		return true
	end

	return false
end

function MeleeAimbot.HandleRegularMelee(cmd, plocal, weapon, target)
	-- Basic melee aimbot: look at target and attack when in range
	local localPos = plocal:GetAbsOrigin()
	local targetPos = target:GetAbsOrigin() + Vector3(0, 0, 45) -- Aim at chest

	local angle = (targetPos - (localPos + plocal:GetPropVector("localdata", "m_vecViewOffset[0]"))):Angles()

	-- Silent aim or regular aim?
	engine.SetViewAngles(angle)

	local dist = (target:GetAbsOrigin() - localPos):Length()
	if dist <= 80 then -- Standard melee range
		cmd:SetButtons(cmd:GetButtons() | 1) -- IN_ATTACK
	end

	return true
end

return MeleeAimbot
