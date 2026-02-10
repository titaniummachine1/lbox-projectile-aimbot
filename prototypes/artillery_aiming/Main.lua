local Config = require("config")
local State = require("state")
local Entity = require("entity")
local Bombard = require("bombard")
local Simulation = require("simulation")
local Visuals = require("visuals")
local Camera = require("camera")
local Menu = require("menu")
local PhysicsEnvModule = require("physics_env")
local ProjectileTracker = require("projectile_tracker")

local lastErrorTime = 0
local lastErrorMsg = ""

local function reportError(source, err)
	local now = os.clock()
	local msg = tostring(err)
	if msg ~= lastErrorMsg or (now - lastErrorTime) > 1 then
		print("[ArtilleryAiming] ERROR in " .. source .. ": " .. msg)
		lastErrorMsg = msg
		lastErrorTime = now
	end
end

local function onCreateMoveInner(cmd)
	Bombard.handleInput(cmd)
	Bombard.execute(cmd)

	if Camera.isActive() then
		Camera.handleInput()
		Camera.updateSmoothing()
	end

	Bombard.handleChargeRelease(cmd)

	ProjectileTracker.update()
end

local function onCreateMove(cmd)
	local ok, err = pcall(onCreateMoveInner, cmd)
	if not ok then
		reportError("CreateMove", err)
	end
end

local function onDrawInner()
	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	-- Run simulation per frame (matches legacy draw-based behavior)
	Simulation.run(nil)

	-- Draw main trajectory if enabled and holding projectile weapon
	if Config.visual.line.enabled and Entity.isProjectileWeapon() then
		Visuals.drawTrajectory()
	end

	ProjectileTracker.draw()

	if Camera.isActive() then
		Camera.drawTexture()
		Camera.drawCameraTrajectory()
		Camera.drawWindow()
		Visuals.drawAimGuide()
	end

	Menu.draw()
end

local function onDraw()
	local ok, err = pcall(onDrawInner)
	if not ok then
		reportError("Draw", err)
	end
end

local function onPostRenderView(view)
	local ok, err = pcall(Camera.onPostRenderView, view)
	if not ok then
		reportError("PostRenderView", err)
	end
end

local function onUnload()
	PhysicsEnvModule.destroy()
	Visuals.deleteTexture()
	Camera.cleanup()
end

callbacks.Unregister("CreateMove", "ArtilleryLogic")
callbacks.Register("CreateMove", "ArtilleryLogic", onCreateMove)

callbacks.Unregister("Draw", "ArtilleryDraw")
callbacks.Register("Draw", "ArtilleryDraw", onDraw)

callbacks.Unregister("PostRenderView", "ProjCamStoreView")
callbacks.Register("PostRenderView", "ProjCamStoreView", onPostRenderView)

callbacks.Unregister("Unload", "ArtilleryUnload")
callbacks.Register("Unload", "ArtilleryUnload", onUnload)

print("[ArtilleryAiming] Loaded successfully")
