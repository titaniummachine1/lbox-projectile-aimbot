local TargetFinder = {}

local Config = require("config")
local State = require("state")
local Utils = require("utils")

function TargetFinder.findTarget()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return nil
	end

	local eyePos = pLocal:GetEyePos()
	local viewAngles = pLocal:GetEyeAngles()
	local forward = viewAngles:Forward()

	-- Find the point we're aiming at
	local maxDist = 5000
	local tr = engine.TraceLine(eyePos, eyePos + forward * maxDist, Config.TRACE_MASK)
	
	if not tr or tr.fraction >= 1 then
		return nil
	end

	return tr.endpos, tr.plane
end

function TargetFinder.lockCurrentAim()
	if not input.IsButtonPressed(Config.keybinds.activate) then
		return
	end

	local targetPos, plane = TargetFinder.findTarget()
	if not targetPos then
		return
	end

	local st = State.bombard
	st.originPoint = targetPos
	st.targetPoint = targetPos
	st.targetPlane = plane
	st.targetZHeight = targetPos.z
	st.lastValidZHeight = targetPos.z
	st.useStoredCharge = false
	st.isLocked = true
end

function TargetFinder.updateZHeight()
	local traj = State.trajectory
	local st = State.bombard

	if not traj.isValid or #traj.positions < 2 then
		return
	end

	-- Use impact Z from simulation if available
	if traj.impactPos then
		st.targetZHeight = traj.impactPos.z
		return
	end

	-- Fallback: use last trajectory point
	local lastPos = traj.positions[#traj.positions]
	if lastPos then
		st.targetZHeight = lastPos.z
		st.lastValidZHeight = lastPos.z
	end
end

return TargetFinder
