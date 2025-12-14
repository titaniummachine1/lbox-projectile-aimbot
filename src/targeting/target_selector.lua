-- Module: target_selector
-- Selects the top N enemy targets based on FOV then distance.

local TargetSelector = {}

---Score targets by FOV first, then distance.
---@param localPlayer Entity
---@param maxTargets integer
---@param maxDistance number
---@return Entity[]
function TargetSelector.selectTop(localPlayer, maxTargets, maxDistance)
	if not localPlayer or not localPlayer:IsAlive() then
		return {}
	end

	maxTargets = math.max(1, maxTargets or 4)
	maxDistance = maxDistance or 3000

	local lpPos = localPlayer:GetAbsOrigin()
	local viewAngles = engine.GetViewAngles()
	local enemies = {}

	for _, ent in pairs(entities.FindByClass("CTFPlayer")) do
		if
			ent
			and ent:IsAlive()
			and not ent:IsDormant()
			and ent:GetTeamNumber() ~= localPlayer:GetTeamNumber()
			and not ent:InCond(E_TFCOND.TFCond_Cloaked)
		then
			local pos = ent:GetAbsOrigin()
			if pos then
				local dist = (lpPos - pos):Length()
				if dist <= maxDistance then
					local angTo = (pos - lpPos):Angles()
					local fov = math.abs(((angTo.y - viewAngles.y + 180) % 360) - 180)
					enemies[#enemies + 1] = { ent = ent, fov = fov, dist = dist }
				end
			end
		end
	end

	table.sort(enemies, function(a, b)
		if a.fov == b.fov then
			return a.dist < b.dist
		end
		return a.fov < b.fov
	end)

	local out = {}
	for i = 1, math.min(maxTargets, #enemies) do
		out[#out + 1] = enemies[i].ent
	end

	return out
end

return TargetSelector
