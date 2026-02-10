local Config = require("config")
local State = require("state")
local Entity = require("entity")
local Bombard = require("bombard")
local Simulation = require("simulation")
local Visuals = require("visuals")
local Camera = require("camera")
local Menu = require("menu")
local PhysicsEnvModule = require("physics_env")
local PhantomTrajectory = require("phantom_trajectory")

local lastErrorTime = 0
local lastErrorMsg = ""
local lastWasFiring = false
local lastFireTime = 0

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
	local isFiring = (cmd.buttons & Config.IN_ATTACK) ~= 0

	Bombard.handleInput(cmd)
	Bombard.execute(cmd)

	if Camera.isActive() then
		Camera.handleInput()
		Camera.updateSmoothing()
	end

	Bombard.handleChargeRelease(cmd)

	-- Run simulation after all bombard logic including charge release
	Simulation.run(cmd)

	-- Check for fire button release (when projectile actually fires)
	if Entity.isProjectileWeapon() and State.trajectory and State.trajectory.isValid then
		if lastWasFiring and not isFiring then
			local currentTime = globals.RealTime()
			-- Add cooldown to prevent spam (0.1 seconds)
			if currentTime - lastFireTime > 0.1 then
				-- We just released the fire button - projectile fired
				print("[Main] Fire detected! lastWasFiring:", lastWasFiring, "isFiring:", isFiring)
				PhantomTrajectory.onProjectileFired(State.trajectory, globals.RealTime())
				lastFireTime = currentTime
			end
		end
	end

	-- Update phantom trajectory (remove points based on elapsed time)
	PhantomTrajectory.update()

	-- Store current fire state for next frame
	lastWasFiring = isFiring
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

	if not Entity.isProjectileWeapon() then
		return
	end

	-- Draw main trajectory if enabled
	if Config.visual.line.enabled then
		Visuals.drawTrajectory()
	end

	-- Draw phantom trajectory independently (if enabled)
	PhantomTrajectory.draw()

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
