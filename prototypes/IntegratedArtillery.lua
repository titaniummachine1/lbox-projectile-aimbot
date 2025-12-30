-- Add src to package path
local scriptPath = debug.getinfo(1, "S").source:sub(2)
local scriptDir = scriptPath:match("(.*[/\\])")
if scriptDir then
	package.path = package.path .. ";" .. scriptDir .. "../src/?.lua"
	package.path = package.path .. ";" .. scriptDir .. "../src/?/init.lua"
end

local Physics = require("physics.projectile_simulation")
local Visuals = require("visuals.trajectory_drawer")
local ProjectileInfo = require("projectile_info")

local LOG = function(sMsg)
	print(string.format("[ln: %d, cl: %0.3f] %s", debug.getinfo(2, "l").currentline, os.clock(), sMsg))
end

LOG("Script load started!")

local config = {
	polygon = {
		enabled = true,
		r = 255,
		g = 200,
		b = 155,
		a = 50,
		size = 10,
		segments = 20,
	},

	line = {
		enabled = true,
		r = 255,
		g = 255,
		b = 255,
		a = 255,
		thickness = 2,
	},

	flags = {
		enabled = true,
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
		enabled = false,
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
		prefer_showing_spells = false,
		show_other_key = -1,
		is_toggle = false,
	},

	measure_segment_size = 2.5,
	ignore_thickness = true,
}

-- Validate thickness config
if
	(
		(not config.line.enabled or config.line.thickness <= 1)
		and (not config.flags.enabled or config.flags.thickness <= 1)
		and (not config.outline.line_and_flags or config.outline.thickness <= 1)
	) or config.ignore_thickness
then
	config.ignore_thickness = true
else
	if config.line.thickness <= 0 then
		config.line.enabled = false
	end
	if config.flags.thickness <= 0 then
		config.flags.enabled = false
	end
	if config.outline.thickness <= 0 then
		config.outline.line_and_flags = false
	end
end

-- Globals
local g_flTraceInterval = math.max(0.5, math.min(8, config.measure_segment_size)) / 66
local g_fFlagInterval = g_flTraceInterval * 1320
local g_vEndOrigin = Vector3(0, 0, 0)
local g_bSpellPreferState = config.spells.prefer_showing_spells
local g_iLastPollTick = 0
local g_ProjectileCamera = nil

local PROJECTILE_TYPE_BASIC = 0
local PROJECTILE_TYPE_PSEUDO = 1
local PROJECTILE_TYPE_SIMUL = 2

local function VEC_ROT(a, b)
	return (b:Forward() * a.x) + (b:Right() * a.y) + (b:Up() * a.z)
end

local function UpdateSpellPreference()
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

callbacks.Register("Draw", function()
	UpdateSpellPreference()

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	local pLocalPlayer = entities.GetLocalPlayer()
	if not pLocalPlayer or pLocalPlayer:InCond(7) or not pLocalPlayer:IsAlive() then
		return
	end

	local pLocalWeapon = pLocalPlayer:GetPropEntity("m_hActiveWeapon")
	if not pLocalWeapon then
		return
	end

	local stProjectileInfo = ProjectileInfo.GetProjectileInformation(pLocalWeapon:GetPropInt("m_iItemDefinitionIndex"))
	local stSpellInfo = ProjectileInfo.GetSpellInformation(pLocalPlayer)
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
	local vecViewAngles = engine.GetViewAngles() + stInfo:GetAngleOffset(flChargeBeginTime)
	local vecSource =
		stInfo:GetFirePosition(pLocalPlayer, vecLocalView, vecViewAngles, pLocalWeapon:IsViewModelFlipped())
	if not vecSource then
		return
	end

	if stInfo.m_iAlignDistance > 0 then
		local vecGoalPoint = vecLocalView + (vecViewAngles:Forward() * stInfo.m_iAlignDistance)
		local res = engine.TraceLine(vecLocalView, vecGoalPoint, 100679691)
		vecViewAngles = (((res.fraction <= 0.1) and vecGoalPoint or res.endpos) - vecSource):Angles()
	end

	vecSource = vecSource + stInfo.m_vecAbsoluteOffset

	-- Prepare config for visualizer
	config.flagOffset = vecViewAngles:Right() * -config.flags.size

	local resultTrace, points
	if stInfo.m_iType == PROJECTILE_TYPE_BASIC then
		resultTrace, points = Physics.DoBasicProjectileTrace(
			vecSource,
			vecViewAngles:Forward(),
			stInfo.m_vecMins,
			stInfo.m_vecMaxs,
			g_flTraceInterval,
			g_fFlagInterval
		)
	elseif stInfo.m_iType == PROJECTILE_TYPE_PSEUDO then
		resultTrace, points = Physics.DoPseudoProjectileTrace(
			vecSource,
			VEC_ROT(stInfo:GetVelocity(flChargeBeginTime), vecViewAngles),
			stInfo:GetGravity(flChargeBeginTime),
			stInfo.m_flDrag,
			stInfo.m_vecMins,
			stInfo.m_vecMaxs,
			g_flTraceInterval
		)
	elseif stInfo.m_iType == PROJECTILE_TYPE_SIMUL then
		local pObject = Physics.GetPhysicsObject(stInfo.m_sModelName)
		pObject:SetPosition(vecSource, vecViewAngles, true)
		pObject:SetVelocity(
			VEC_ROT(stInfo:GetVelocity(flChargeBeginTime), vecViewAngles),
			stInfo:GetAngularVelocity(flChargeBeginTime)
		)

		resultTrace, points =
			Physics.DoSimulProjectileTrace(pObject, stInfo.m_vecMins, stInfo.m_vecMaxs, g_flTraceInterval)
	else
		LOG(string.format('Unknown projectile type "%s"!', stInfo.m_iType))
		return
	end

	-- Prepend source to points (visuals start from source)
	-- DoBasic/Pseudo/Simul might not include source as first point (Basic loops from 1).
	-- But TrajectoryLine in snippet did: TrajectoryLine:Insert(vecSource) called BEFORE loop.
	table.insert(points, 1, vecSource)

	if #points == 0 then
		return
	end

	if resultTrace then
		Visuals.DrawImpactPolygon(resultTrace.plane, resultTrace.endpos, config)
		g_vEndOrigin = resultTrace.endpos
	end

	if #points == 1 then
		-- Only start point?
		if config.camera.enabled and g_ProjectileCamera then
			Visuals.DrawCameraWindow(g_ProjectileCamera)
		end
		return
	end

	Visuals.DrawProjectileLine(points, config)

	if config.camera.enabled then
		if not g_ProjectileCamera then
			g_ProjectileCamera = Visuals.CreateProjectileCamera(config)
		end
		Visuals.DrawCameraWindow(g_ProjectileCamera)
	end
end)

if config.camera.enabled then
	callbacks.Register("PostRenderView", function(view)
		if not config.camera.enabled then
			return
		end
		if not g_ProjectileCamera then
			return
		end -- wait for Draw to init

		local CustomCtx = client.GetPlayerView()
		local source = config.camera.source
		local distance, angle = source.distance, source.angle

		CustomCtx.fov = source.fov

		local stDTrace = engine.TraceLine(
			g_vEndOrigin,
			g_vEndOrigin - (Vector3(angle, CustomCtx.angles.y, CustomCtx.angles.z):Forward() * distance),
			100679683,
			function()
				return false
			end
		)
		local stUTrace = engine.TraceLine(
			g_vEndOrigin,
			g_vEndOrigin - (Vector3(-angle, CustomCtx.angles.y, CustomCtx.angles.z):Forward() * distance),
			100679683,
			function()
				return false
			end
		)

		if stDTrace.fraction >= stUTrace.fraction - 0.1 then
			CustomCtx.angles = EulerAngles(angle, CustomCtx.angles.y, CustomCtx.angles.z)
			CustomCtx.origin = stDTrace.endpos
		else
			CustomCtx.angles = EulerAngles(-angle, CustomCtx.angles.y, CustomCtx.angles.z)
			CustomCtx.origin = stUTrace.endpos
		end

		-- Update buffer
		render.Push3DView(CustomCtx, 0x37, g_ProjectileCamera.Texture)
		render.ViewDrawScene(true, true, CustomCtx)
		render.PopView()
	end)
end

callbacks.Register("Unload", function()
	Physics.GetPhysicsObject:Shutdown()
	-- Visuals.Cleanup() -- if implemented
end)

LOG("Script fully loaded!")
