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
	["CTFProjectile_Cleaver"] = "tf_weapon_cleaver"
}

function Manager.getFallbackData(ent)
	local className = ent:GetClass()
	local weaponId = CLASS_TO_WEAPON[className]
	
	if weaponId and WEAPON_FALLBACKS[weaponId] then
		return WEAPON_FALLBACKS[weaponId]
	end
	
	-- Try to get weapon info from the entity if possible
	local owner = ent:GetOwner()
	if owner and owner:IsValid() then
		local weapon = owner:GetPropEntity("m_hActiveWeapon")
		if weapon and weapon:IsValid() then
			local weaponClass = weapon:GetClass()
			if WEAPON_FALLBACKS[weaponClass] then
				return WEAPON_FALLBACKS[weaponClass]
			end
		end
	end
	
	-- Default fallback for unknown projectiles
	return {
		blastRadius = 146, -- Standard TF2 explosion radius
		speed = 1100, -- Standard projectile speed
		gravity = 0.5,
		upwardVel = 0
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
		"CTFProjectile_JarGas",
		"CTFPumpkinBomb",
		"CTFProjectile_EnergyBall",
		"CTFProjectile_Cleaver"
	}

	for _, className in ipairs(classes) do
		local ents = entities.FindByClass(className)
		for _, ent in pairs(ents) do
			if ent:IsValid() and not ent:IsDormant() then
				local idx = ent:GetIndex()
				local proj = tracked[idx]

				if not proj then
					-- Initialize new projectile tracking with fallback data
					local fallbackData = Manager.getFallbackData(ent)
					proj = {
						entity = ent,
						lastPos = ent:GetAbsOrigin(),
						lastVel = ent:EstimateAbsVelocity(),
						radius = fallbackData.blastRadius,
						color = Config.visual.polygon.live_color or { 255, 255, 255, 255 },
						filter = Kalman.VectorKalman.new(3, 0.001, Vector3(0, 0, 0)),
						pointCount = 0,
						fallbackData = fallbackData,
					}
					tracked[idx] = proj
				end

				proj.seenThisFrame = true
				proj.origin = ent:GetAbsOrigin()

				-- Prediction
				local path, count, impactPos, impactPlane = Simulation.predict(ent, 150)
				proj.predictedPath = path
				proj.impactPos = impactPos
				proj.impactPlane = impactPlane
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
		Visuals.drawTrackerTrajectory(proj)
	end
end

return Manager
