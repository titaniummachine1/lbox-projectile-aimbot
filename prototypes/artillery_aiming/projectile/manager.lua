local Manager = {}

local Config = require("config")
local Simulation = require("projectile/simulation")
local Kalman = require("kalman")
local Visuals = require("visuals")

-- Comprehensive fallback data for TF2 projectile properties
-- Used when Entity.GetProjectileInformation() fails or returns incomplete data
local WEAPON_FALLBACKS = {
	-- Soldier Weapons
	["tf_weapon_rocketlauncher"] = {
		blastRadius = 146,
		speed = 1100,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tf_weapon_rocketlauncher_directhit"] = {
		blastRadius = 44,
		speed = 1980,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tf_weapon_rocketlauncher_airstrike"] = {
		blastRadius = 131.4, -- 105.1 when airborne
		speed = 1100,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tf_weapon_particle_cannon"] = { -- Cow Mangler
		blastRadius = 146,
		speed = 1100,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tf_weapon_rocketlauncher_blackbox"] = {
		blastRadius = 146,
		speed = 1100,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tf_weapon_rocketlauncher_liberty"] = {
		blastRadius = 146,
		speed = 1540,
		gravity = 0.5,
		upwardVel = 0,
	},

	-- Demoman Weapons
	["tf_weapon_grenadelauncher"] = {
		blastRadius = 146,
		speed = 1216.6,
		gravity = 1.0,
		upwardVel = 0,
	},
	["tf_weapon_pipebomblauncher"] = {
		blastRadius = 146,
		speed = 898.9,
		gravity = 1.0,
		upwardVel = 0,
	},
	["tf_weapon_cannon"] = { -- Loose Cannon
		blastRadius = 146,
		speed = 1453.3,
		gravity = 1.0,
		upwardVel = 0,
	},
	["tf_weapon_grenadelauncher_iron"] = { -- Iron Bomber
		blastRadius = 124.1,
		speed = 1216.6,
		gravity = 1.0,
		upwardVel = 0,
	},
	["tf_weapon_grenadelauncher_lochnload"] = { -- Loch-n-Load
		blastRadius = 109.5,
		speed = 1513.3,
		gravity = 1.0,
		upwardVel = 0,
	},
	["tf_weapon_stickylauncher"] = {
		blastRadius = 146,
		speed = 898.9,
		gravity = 1.0,
		upwardVel = 0,
	},

	-- Pyro Weapons
	["tf_weapon_flaregun"] = { -- Detonator/Scorch Shot
		blastRadius = 110,
		speed = 3000,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tf_weapon_jar_gas"] = { -- Gas Passer
		blastRadius = 134.5,
		speed = 1000,
		gravity = 0.5,
		upwardVel = 0,
	},

	-- Scout Weapons
	["tf_weapon_jar"] = { -- Jarate
		blastRadius = 200,
		speed = 1000,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tf_weapon_jar_milk"] = { -- Mad Milk
		blastRadius = 200,
		speed = 1000,
		gravity = 0.5,
		upwardVel = 0,
	},

	-- Engineer Weapons
	["obj_sentrygun"] = { -- Sentry Rockets
		blastRadius = 146,
		speed = 1100,
		gravity = 0.5,
		upwardVel = 0,
	},

	-- Melee Weapons with Explosions
	["tf_weapon_stickbomb"] = { -- Ullapool Caber
		blastRadius = 102,
		speed = 0, -- melee, no projectile
		gravity = 0,
		upwardVel = 0,
	},

	-- Environmental/Events
	["tf_pumpkin_bomb"] = { -- Pumpkin Bombs
		blastRadius = 300,
		speed = 0,
		gravity = 0,
		upwardVel = 0,
	},
	["eyeball_boss"] = { -- MONOCULUS projectiles
		blastRadius = 146,
		speed = 1100,
		gravity = 0.5,
		upwardVel = 0,
	},
	["tank_boss"] = { -- Sentry Buster explosion
		blastRadius = 285,
		speed = 0,
		gravity = 0,
		upwardVel = 0,
	},
}

-- Class name to weapon ID mappings for better fallback lookup
local CLASS_TO_WEAPON = {
	["CTFProjectile_Rocket"] = "tf_weapon_rocketlauncher",
	["tf_projectile_rocket"] = "tf_weapon_rocketlauncher",
	["CTFGrenadePipebombProjectile"] = "tf_weapon_grenadelauncher",
	["CTFProjectile_Jar"] = "tf_weapon_jar",
	["CTFProjectile_Flare"] = "tf_weapon_flaregun",
	["CTFProjectile_JarGas"] = "tf_weapon_jar_gas",
	["CTFPumpkinBomb"] = "tf_pumpkin_bomb",
	["CTFProjectile_EnergyBall"] = "tf_weapon_particle_cannon",
	["CTFProjectile_Cleaver"] = "tf_weapon_cleaver",
}

function Manager.getProjectileInfo(ent)
	local className = ent:GetClass()
	local weaponId = CLASS_TO_WEAPON[className]

	-- Try to get weapon info from projectile owner first
	local owner = ent:GetOwner()
	if owner and owner:IsValid() then
		local weapon = owner:GetPropEntity("m_hActiveWeapon")
		if weapon and weapon:IsValid() then
			-- Use dynamic projectile info fetching like the TF2 aimbot code
			local projInfo = weapon:GetProjectileInfo()
			if projInfo then
				local speed = projInfo[1] or 1100
				local gravityFactor = projInfo[2] or 0.5
				local sv_gravity = client.GetConVar("sv_gravity") or 800
				local effectiveGravity = sv_gravity * gravityFactor

				return {
					blastRadius = WEAPON_FALLBACKS[weapon:GetClass()]
							and WEAPON_FALLBACKS[weapon:GetClass()].blastRadius
						or 146,
					speed = speed,
					gravity = effectiveGravity,
					upwardVel = 0,
				}
			end
		end
	end

	-- Fallback to static data if dynamic fetching fails
	if weaponId and WEAPON_FALLBACKS[weaponId] then
		return WEAPON_FALLBACKS[weaponId]
	end

	-- Default fallback for unknown projectiles
	return {
		blastRadius = 146, -- Standard TF2 explosion radius
		speed = 1100, -- Standard projectile speed
		gravity = 400, -- Standard gravity
		upwardVel = 0,
	}
end

local tracked = {}

function Manager.Startup()
	tracked = {}
end

function Manager.Shutdown()
	tracked = {}
end

function Manager.Update()
	if not Config.visual.live_projectiles.enabled then
		return
	end

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then
		return
	end

	-- Mark all as not seen
	for _, proj in pairs(tracked) do
		proj.seenThisFrame = false
	end

	-- Iterate standard projectile classes
	local classes = {
		"CTFProjectile_Rocket",
		"tf_projectile_rocket",
		"CTFGrenadePipebombProjectile",
		"CTFProjectile_Jar",
		"CTFProjectile_Flare",
	}

	for _, className in ipairs(classes) do
		local ents = entities.FindByClass(className)
		for _, ent in pairs(ents) do
			if ent:IsValid() and not ent:IsDormant() then
				local idx = ent:GetIndex()
				local proj = tracked[idx]

				if not proj then
					-- Initialize new projectile tracking with enhanced data
					local fallbackData = Manager.getProjectileInfo(ent)
					local currentPos = ent:GetAbsOrigin()
					local currentVel = ent:EstimateAbsVelocity()

					proj = {
						entity = ent,
						lastPos = currentPos,
						lastVel = currentVel,
						radius = fallbackData.blastRadius,
						color = Config.visual.polygon.live_color or { 255, 255, 255, 255 },
						filter = Kalman.VectorKalman.new(3, 0.001, Vector3(currentVel.x, currentVel.y, currentVel.z)),
						pointCount = 0,
						fallbackData = fallbackData,
						-- Enhanced tracking data
						positionHistory = {}, -- Store last 10 positions
						velocityHistory = {}, -- Store calculated velocities
						spawnTime = globals.CurTime(),
						lifespan = 10, -- Default 10 seconds, will be updated from weapon data
						lastUpdateTime = globals.CurTime(),
						lastSurfaceNormal = Vector3(0, 0, 1), -- Default to up, will be updated from simulation
					}

					-- Initialize position history with current position
					for i = 1, 10 do
						proj.positionHistory[i] = currentPos
					end

					-- Try to get weapon data for lifespan
					local owner = ent:GetOwner()
					if owner and owner:IsValid() then
						local weapon = owner:GetPropEntity("m_hActiveWeapon")
						if weapon and weapon:IsValid() then
							local weaponData = weapon:GetWeaponData()
							if weaponData and weaponData.projectileSpeed and weaponData.projectileSpeed > 0 then
								-- Estimate lifespan based on projectile speed and typical max range
								local maxRange = 4000 -- Typical TF2 projectile max range
								proj.lifespan = maxRange / weaponData.projectileSpeed
								-- Clamp to reasonable bounds
								proj.lifespan = math.max(2, math.min(30, proj.lifespan))
							end
						end
					end

					tracked[idx] = proj
				end

				proj.seenThisFrame = true
				local currentTime = globals.CurTime()
				local deltaTime = currentTime - proj.lastUpdateTime
				proj.lastUpdateTime = currentTime

				local currentPos = ent:GetAbsOrigin()
				local currentVel = ent:EstimateAbsVelocity()

				-- Update position history (shift array)
				for i = 10, 2, -1 do
					proj.positionHistory[i] = proj.positionHistory[i - 1]
				end
				proj.positionHistory[1] = currentPos

				-- Calculate velocity from position history (10 ticks ago vs current)
				local historicalPos = proj.positionHistory[10] or proj.positionHistory[1]
				local positionDelta = currentPos - historicalPos
				local timeDelta = deltaTime * 10 -- Approximate time over 10 ticks

				local calculatedVel = Vector3(0, 0, 0)
				if timeDelta > 0 then
					calculatedVel = positionDelta / timeDelta
				end

				-- Combine velocity sources: current EstimateAbsVelocity, historical calculation, and Kalman filtered
				local combinedVel = (currentVel + calculatedVel) * 0.5

				-- Apply Kalman filtering for smooth velocity
				proj.filter:predict(combinedVel)
				local filteredVel = proj.filter:update(combinedVel)

				-- Store velocity history
				table.insert(proj.velocityHistory, 1, filteredVel)
				if #proj.velocityHistory > 10 then
					table.remove(proj.velocityHistory)
				end

				-- Update projectile data
				proj.lastPos = currentPos
				proj.lastVel = filteredVel
				proj.origin = currentPos

				-- Check if projectile has exceeded its lifespan
				local age = currentTime - proj.spawnTime
				if age > proj.lifespan then
					tracked[idx] = nil
					goto continue
				end

				-- Prediction with improved velocity data
				local path, count, impactPos, impactPlane = Simulation.predict(ent, 150)
				proj.predictedPath = path
				proj.impactPos = impactPos
				proj.impactPlane = impactPlane

				-- Store the last surface normal from simulation for low velocity situations
				if impactPlane then
					proj.lastSurfaceNormal = impactPlane
				end

				::continue::
			end
		end
	end

	-- Cleanup
	local toRemove = {}
	for idx, proj in pairs(tracked) do
		if not proj.seenThisFrame then
			table.insert(toRemove, idx)
		end
	end
	for _, idx in ipairs(toRemove) do
		tracked[idx] = nil
	end
end

function Manager.Draw()
	if not Config.visual.live_projectiles.enabled then
		return
	end

	for _, proj in pairs(tracked) do
		if proj.predictedPath then
			-- Call our new visual hook
			if Visuals.drawTrackerTrajectory then
				Visuals.drawTrackerTrajectory(proj)
			end
		end
	end
end

return Manager
