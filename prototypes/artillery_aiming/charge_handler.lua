local ChargeHandler = {}

local Config = require("config")
local State = require("state")
local Entity = require("entity")
local AimCalculator = require("aim_calculator")

local warnedSpeedFallback = {}
local warnedGravityFallback = {}

function ChargeHandler.handleInput(cmd)
	if not Config.bombard.enabled then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return
	end

	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon or not pWeapon:IsValid() then
		return
	end

	local ctx = Entity.getWeaponContext(pLocal, pWeapon)
	if not ctx then
		return
	end

	local st = State.bombard

	-- Handle activation key
	if input.IsButtonPressed(Config.keybinds.activate) then
		if not st.isLocked then
			TargetFinder.lockCurrentAim()
		end
	end

	-- Handle high ground key
	local highGroundDown = input.IsButtonPressed(Config.keybinds.high_ground)
	if highGroundDown and not st.highGroundHeld then
		-- Toggle high ground mode or increase Z height
		if st.targetZHeight then
			st.targetZHeight = st.targetZHeight + 50
		end
	end
	st.highGroundHeld = highGroundDown
end

function ChargeHandler.execute(cmd)
	if not State.camera.active then
		return
	end

	local st = State.bombard
	if not st.isLocked or not st.targetPoint then
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() or not pLocal:IsAlive() then
		return
	end

	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon or not pWeapon:IsValid() then
		return
	end

	local ctx = Entity.getWeaponContext(pLocal, pWeapon)
	if not ctx then
		return
	end

	-- Calculate aiming
	local pitch, charge, error = AimCalculator.calculateAiming(ctx, st.targetPoint)
	if not pitch then
		return
	end

	-- Apply aim angles
	local aimAngles = EulerAngles(pitch, 0, 0)
	cmd:SetViewAngles(aimAngles)

	-- Handle charge weapons
	if ctx.hasCharge then
		if charge >= 0 and charge <= 1 then
			cmd:SetButtons(cmd:GetButtons() | IN_ATTACK)
			st.useStoredCharge = true
			st.storedCharge = charge
		end
	else
		-- Fixed speed weapons - just fire
		cmd:SetButtons(cmd:GetButtons() | IN_ATTACK)
	end
end

function ChargeHandler.handleChargeRelease(cmd)
	if not State.bombard.useStoredCharge then
		return
	end

	local st = State.bombard
	if not st.storedCharge then
		return
	end

	-- Release fire button when charge is reached
	if input.IsButtonPressed(1) then -- IN_ATTACK
		cmd:SetButtons(cmd:GetButtons() & ~IN_ATTACK)
		st.useStoredCharge = false
		st.storedCharge = nil
	end
end

return ChargeHandler
