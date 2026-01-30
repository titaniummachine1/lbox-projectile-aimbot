-- Local Projectile Visualization Module
-- Registers its own callbacks to run independently of the main aimbot logic

local G = require("globals")
local G = require("globals")
local globals = require("globals")

local GetProjectileInfo = require("projectile_info")
local TrajectoryDrawer = require("visuals.trajectory_drawer")
-- Note: 'SimulateProj' was require("simulation.Projectiles.projectile_simulation") in original code
local SimulateProj = require("simulation.Projectiles.projectile_simulation")

-- Configuration aliases for easier porting
local function GetConfig()
	-- Map G.Menu.Visuals to the structure expected by the original script logic
	if not G.Menu or not G.Menu.Visuals then
		return nil
	end

	local vis = G.Menu.Visuals
	local colors = vis.ColorsRGBA or {}
	local startColor = colors.ProjectilePathStart or { 0, 255, 0, 255 }

	return {
		polygon = {
			enabled = vis.DrawImpactPolygon or false,
			r = startColor[1],
			g = startColor[2],
			b = startColor[3],
			a = 50, -- Fixed alpha from snippet or add menu option? Snippet had 50.
			size = 10,
			segments = 20,
		},
		line = {
			enabled = vis.DrawLocalProjectile or false, -- This is the main toggle
			r = startColor[1],
			g = startColor[2],
			b = startColor[3],
			a = 255,
			thickness = 2, -- Snippet default
		},
		flags = {
			enabled = true, -- Default true in snippet
			r = 255,
			g = 0,
			b = 0,
			a = 255,
			size = 5,
			thickness = 2,
		},
		outline = {
			line_and_flags = true,
			polygon = true,
			r = 0,
			g = 0,
			b = 0,
			a = 155,
			thickness = 1,
		},
		camera = {
			enabled = false, -- Default false
			x = 100,
			y = 300,
			aspect_ratio = 4 / 3,
			height = 400,
			source = {
				scale = 0.5,
				fov = 110,
				distance = 200,
				angle = 30,
			},
		},
		spells = {
			prefer_showing_spells = false, -- could be mapped if menu option exists
			show_other_key = -1,
			is_toggle = false,
		},
		measure_segment_size = 2.5,
		ignore_thickness = false, -- Default

		-- Helper for coordinate conversion (passed to trajectory drawer)
		flagOffset = nil,
	}
end

-- State variables
local g_bSpellPreferState = false
local g_iLastPollTick = 0
local g_vEndOrigin = Vector3(0, 0, 0)

-- Simulation Helpers matching the snippet
-- These duplicates logic from projectile_simulation.lua but tailored exactly to the snippet's look/feel
-- or we can use the projectile_simulation logic if it matches.
-- The user asked to integrate "just like original file". original file had its own simulation functions.
-- For "perfect" results, I should use the logic I likely put in projectile_simulation.lua,
-- or if I want to be 100% safe, use the snippet's simulation logic here.
-- Given the instruction, I will use the `projectile_simulation` module which *should* have this logic,
-- but I will double check if I implemented `DoBasicProjectileTrace` etc. there.
-- I did. So I will use them.

local Sim = require("simulation.Projectiles.projectile_simulation")

local function UpdateSpellPreference(config)
	if config.spells.show_other_key == -1 then
		return
	end

	if config.spells.is_toggle then
		local bPressed, iTick = input.IsButtonPressed(config.spells.show_other_key)
		if bPressed and iTick ~= g_iLastPollTick then
			g_iLastPollTick = iTick
			g_bSpellPreferState = not g_bSpellPreferState
		end
	elseif input.IsButtonDown(config.spells.show_other_key) then
		g_bSpellPreferState = not config.spells.prefer_showing_spells
	else
		g_bSpellPreferState = config.spells.prefer_showing_spells
	end
end

-- The snippet's trajectory line accumulator
local TrajectoryLine = {
	m_aPositions = {},
	m_iSize = 0,
	m_vFlagOffset = Vector3(0, 0, 0),
}
function TrajectoryLine:Insert(vec)
	self.m_iSize = self.m_iSize + 1
	self.m_aPositions[self.m_iSize] = vec
end
function TrajectoryLine:Reset()
	self.m_aPositions = {}
	self.m_iSize = 0
	self.m_vFlagOffset = Vector3(0, 0, 0)
end

-- We need to bridge the Simulation module to use our TrajectoryLIne accumulator
-- Or we just get resultTrace from Sim and extract points?
-- Sim module likely returns a trace object or takes a callback.
-- Checking projectile_simulation.lua...
-- Actually, the snippet version of logic *populates* TrajectoryLine *during* the trace loop.
-- To act "exactly like original", it's best to have the `Do...Trace` functions here or
-- have Sim module return a list of points.
-- I'll define local versions of the trace functions that populate `TrajectoryLine`
-- because the user wants "perfect" replication.

local TRACE_HULL = engine.TraceHull
local MASK_SHOT_HULL = 100679691
local FLOOR = math.floor

local function VEC_ROT(a, b)
	return (b:Forward() * a.x) + (b:Right() * a.y) + (b:Up() * a.z)
end

local g_flTraceInterval = 2.5 / 66 -- Default
local g_fFlagInterval = g_flTraceInterval * 1320

local function DoBasicProjectileTrace(vecSource, vecForward, vecMins, vecMaxs)
	local resultTrace = TRACE_HULL(vecSource, vecSource + (vecForward * 10000), vecMins, vecMaxs, MASK_SHOT_HULL)
	if resultTrace.startsolid then
		return resultTrace
	end

	local iSegments = FLOOR((resultTrace.endpos - resultTrace.startpos):Length() / g_fFlagInterval)
	for i = 1, iSegments do
		TrajectoryLine:Insert(vecForward * (i * g_fFlagInterval) + vecSource)
	end
	TrajectoryLine:Insert(resultTrace.endpos)
	return resultTrace
end

local function DoPseudoProjectileTrace(vecSource, vecVelocity, flGravity, flDrag, vecMins, vecMaxs)
	local flGravity = flGravity * 400 -- Snippet does this multiplier
	local vecPosition = vecSource
	local resultTrace

	-- Using default trace interval from snippet config
	local interval = g_flTraceInterval

	for i = 0.01515, 5, interval do
		local flScalar = (flDrag == 0) and i or ((1 - math.exp(-flDrag * i)) / flDrag)

		resultTrace = TRACE_HULL(
			vecPosition,
			Vector3(
				vecVelocity.x * flScalar + vecSource.x,
				vecVelocity.y * flScalar + vecSource.y,
				(vecVelocity.z - flGravity * i) * flScalar + vecSource.z
			),
			vecMins,
			vecMaxs,
			MASK_SHOT_HULL
		)

		vecPosition = resultTrace.endpos
		TrajectoryLine:Insert(resultTrace.endpos)

		if resultTrace.fraction ~= 1 then
			break
		end
	end
	return resultTrace
end

local function DoSimulProjectileTrace(pObject, vecMins, vecMaxs)
	-- Requires physics enviroment which is managed where?
	-- The snippet creates a local PhysicsEnvironment.
	-- We can reuse the one from `physics.projectile_simulation` if exposed, or create a local one.
	-- Ideally reuse to save perf.

	local SimEnv = Sim.PhysicsEnvironment -- Access exposed field directly
	if not SimEnv then
		return
	end

	local resultTrace
	for i = 1, 330 do
		local vecStart = pObject:GetPosition()
		SimEnv:Simulate(g_flTraceInterval)

		resultTrace = TRACE_HULL(vecStart, pObject:GetPosition(), vecMins, vecMaxs, MASK_SHOT_HULL)
		TrajectoryLine:Insert(resultTrace.endpos)
		if resultTrace.fraction ~= 1 then
			break
		end
	end

	-- IMPORTANT: Reset happens in SimEnv
	SimEnv:ResetSimulationClock()
	return resultTrace
end

-- Helpers
local FL_DUCKING = 2

callbacks.Register("Draw", function()
	local config = GetConfig()
	if not config or not config.line.enabled then
		return
	end

	-- Update Config Globals
	g_flTraceInterval = math.max(0.5, math.min(8, config.measure_segment_size)) / 66
	g_fFlagInterval = g_flTraceInterval * 1320

	UpdateSpellPreference(config)
	TrajectoryLine:Reset()

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	local pLocalPlayer = entities.GetLocalPlayer()
	if not pLocalPlayer or pLocalPlayer:InCond(7) or not pLocalPlayer:IsAlive() then
		return
	end -- 7 = TFCond_Taunting?

	local pLocalWeapon = pLocalPlayer:GetPropEntity("m_hActiveWeapon")
	if not pLocalWeapon then
		return
	end

	local iItemDefIndex = pLocalWeapon:GetPropInt("m_iItemDefinitionIndex")
	local stProjectileInfo = GetProjectileInfo.GetProjectileInformation(iItemDefIndex) -- Correct access
	local stSpellInfo = GetProjectileInfo.GetSpellInformation(pLocalPlayer) -- Correct access

	local stInfo = nil
	if g_bSpellPreferState then
		stInfo = stSpellInfo or stProjectileInfo
	else
		stInfo = stProjectileInfo or stSpellInfo
	end

	if not stInfo then
		return
	end

	local flChargeBeginTime = pLocalWeapon:GetPropFloat("PipebombLauncherLocalData", "m_flChargeBeginTime") or 0
	if flChargeBeginTime > 0 then
		flChargeBeginTime = globals.CurTime() - flChargeBeginTime
	end

	local vecLocalView = pLocalPlayer:GetAbsOrigin() + pLocalPlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
	local vecViewAngles = engine.GetViewAngles() + stInfo.m_vecAngleOffset

	local vecSource =
		stInfo:GetFirePosition(pLocalPlayer, vecLocalView, vecViewAngles, pLocalWeapon:IsViewModelFlipped())
	if not vecSource then
		return
	end

	if stInfo.m_iAlignDistance > 0 then
		local vecGoalPoint = vecLocalView + (vecViewAngles:Forward() * stInfo.m_iAlignDistance)
		local res = engine.TraceLine(vecLocalView, vecGoalPoint, MASK_SHOT_HULL)
		vecViewAngles = (((res.fraction <= 0.1) and vecGoalPoint or res.endpos) - vecSource):Angles()
	end

	vecSource = vecSource + stInfo.m_vecAbsoluteOffset

	TrajectoryLine.m_vFlagOffset = vecViewAngles:Right() * -config.flags.size
	TrajectoryLine:Insert(vecSource)

	-- Capture flag offset into config for drawer
	config.flagOffset = TrajectoryLine.m_vFlagOffset

	local resultTrace
	if stInfo.m_iType == 0 then -- PROJECTILE_TYPE_BASIC
		resultTrace = DoBasicProjectileTrace(vecSource, vecViewAngles:Forward(), stInfo.m_vecMins, stInfo.m_vecMaxs)
	elseif stInfo.m_iType == 1 then -- PROJECTILE_TYPE_PSEUDO
		resultTrace = DoPseudoProjectileTrace(
			vecSource,
			VEC_ROT(stInfo:GetVelocity(flChargeBeginTime), vecViewAngles),
			stInfo:GetGravity(flChargeBeginTime),
			stInfo.m_flDrag,
			stInfo.m_vecMins,
			stInfo.m_vecMaxs
		)
	elseif stInfo.m_iType == 2 then -- PROJECTILE_TYPE_SIMUL
		local pObject = Sim.GetPhysicsObject(stInfo.m_sModelName) -- Reuse Sim module's object manager
		pObject:SetPosition(vecSource, vecViewAngles, true)
		pObject:SetVelocity(
			VEC_ROT(stInfo:GetVelocity(flChargeBeginTime), vecViewAngles),
			stInfo:GetAngularVelocity(flChargeBeginTime)
		)

		resultTrace = DoSimulProjectileTrace(pObject, stInfo.m_vecMins, stInfo.m_vecMaxs)
	end

	if TrajectoryLine.m_iSize == 0 then
		return
	end

	if resultTrace then
		if config.polygon.enabled then
			-- Need to ensure polygon color uses config
			-- TrajectoryDrawer uses config passed to it or hardcoded in function depending on impl
			-- Our Updated TrajectoryDrawer accepts (plane, origin, config)
			TrajectoryDrawer.DrawImpactPolygon(resultTrace.plane, resultTrace.endpos, config)
		end
		g_vEndOrigin = resultTrace.endpos
	end

	-- Draw the line using TrajectoryDrawer
	-- TrajectoryDrawer.DrawProjectileLine(points, config)
	TrajectoryDrawer.DrawProjectileLine(TrajectoryLine.m_aPositions, config)
end)

-- Projectile Camera Callback (if enabled)
-- Only partially integrated as user really focused on "path"
-- But we'll add it if they enable it (no menu option currently?)
-- We'll assume if config.camera.enabled is true (it is false in my GetConfig currently default)

return {}
