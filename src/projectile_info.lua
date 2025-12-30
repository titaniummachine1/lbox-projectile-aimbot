local function CLAMP(a, b, c)
	return (a < b) and b or (a > c) and c or a
end
local TRACE_HULL = engine.TraceHull
local MASK_SHOT_HULL = 100679691 -- MASK_SOLID_BRUSHONLY
local FL_DUCKING = 2

local function VEC_ROT(a, b)
	return (b:Forward() * a.x) + (b:Right() * a.y) + (b:Up() * a.z)
end

local PROJECTILE_TYPE_BASIC = 0
local PROJECTILE_TYPE_PSEUDO = 1
local PROJECTILE_TYPE_SIMUL = 2

local aItemDefinitions = {}
local function AppendItemDefinitions(iType, ...)
	for _, i in pairs({ ... }) do
		aItemDefinitions[i] = iType
	end
end

local aSpellDefinitions = {}
local function AppendSpellDefinitions(iType, ...)
	for _, i in pairs({ ... }) do
		aSpellDefinitions[i] = iType
	end
end

local function DefineProjectileDefinition(tbl)
	return {
		m_iType = PROJECTILE_TYPE_BASIC,
		m_vecOffset = tbl.vecOffset or Vector3(0, 0, 0),
		m_vecAbsoluteOffset = tbl.vecAbsoluteOffset or Vector3(0, 0, 0),
		m_vecAngleOffset = tbl.vecAngleOffset or Vector3(0, 0, 0),
		m_vecVelocity = tbl.vecVelocity or Vector3(0, 0, 0),
		m_vecAngularVelocity = tbl.vecAngularVelocity or Vector3(0, 0, 0),
		m_vecMins = tbl.vecMins or (not tbl.vecMaxs) and Vector3(0, 0, 0) or -tbl.vecMaxs,
		m_vecMaxs = tbl.vecMaxs or (not tbl.vecMins) and Vector3(0, 0, 0) or -tbl.vecMins,
		m_flGravity = tbl.flGravity or 0.001,
		m_flDrag = tbl.flDrag or 0,
		m_iAlignDistance = tbl.iAlignDistance or 0,
		m_sModelName = tbl.sModelName or "",

		GetOffset = not tbl.GetOffset
				and function(self, bDucking, bIsFlipped)
					return bIsFlipped and Vector3(self.m_vecOffset.x, -self.m_vecOffset.y, self.m_vecOffset.z)
						or self.m_vecOffset
				end
			or tbl.GetOffset, -- self, bDucking, bIsFlipped

		GetFirePosition = tbl.GetFirePosition or function(self, pLocalPlayer, vecLocalView, vecViewAngles, bIsFlipped)
			local resultTrace = TRACE_HULL(
				vecLocalView,
				vecLocalView
					+ VEC_ROT(
						self:GetOffset((pLocalPlayer:GetPropInt("m_fFlags") & FL_DUCKING) ~= 0, bIsFlipped),
						vecViewAngles
					),
				-Vector3(8, 8, 8),
				Vector3(8, 8, 8),
				MASK_SHOT_HULL
			)

			return (not resultTrace.startsolid) and resultTrace.endpos or nil
		end,

		GetVelocity = (not tbl.GetVelocity) and function(self, ...)
			return self.m_vecVelocity
		end or tbl.GetVelocity, -- self, flChargeBeginTime

		GetAngularVelocity = (not tbl.GetAngularVelocity) and function(self, ...)
			return self.m_vecAngularVelocity
		end or tbl.GetAngularVelocity, -- self, flChargeBeginTime

		GetGravity = (not tbl.GetGravity) and function(self, ...)
			return self.m_flGravity
		end or tbl.GetGravity, -- self, flChargeBeginTime
	}
end

local function DefineBasicProjectileDefinition(tbl)
	local stReturned = DefineProjectileDefinition(tbl)
	stReturned.m_iType = PROJECTILE_TYPE_BASIC

	return stReturned
end

local function DefinePseudoProjectileDefinition(tbl)
	local stReturned = DefineProjectileDefinition(tbl)
	stReturned.m_iType = PROJECTILE_TYPE_PSEUDO

	return stReturned
end

local function DefineSimulProjectileDefinition(tbl)
	local stReturned = DefineProjectileDefinition(tbl)
	stReturned.m_iType = PROJECTILE_TYPE_SIMUL

	return stReturned
end

local function DefineDerivedProjectileDefinition(def, tbl)
	local stReturned = {}
	for k, v in pairs(def) do
		stReturned[k] = v
	end
	for k, v in pairs(tbl) do
		stReturned[((type(v) ~= "function") and "m_" or "") .. k] = v
	end

	if not tbl.GetOffset and tbl.vecOffset then
		stReturned.GetOffset = function(self, bDucking, bIsFlipped)
			return bIsFlipped and Vector3(self.m_vecOffset.x, -self.m_vecOffset.y, self.m_vecOffset.z)
				or self.m_vecOffset
		end
	end

	if not tbl.GetVelocity and tbl.vecVelocity then
		stReturned.GetVelocity = function(self, ...)
			return self.m_vecVelocity
		end
	end

	if not tbl.GetAngularVelocity and tbl.vecAngularVelocity then
		stReturned.GetAngularVelocity = function(self, ...)
			return self.m_vecAngularVelocity
		end
	end

	if not tbl.GetGravity and tbl.flGravity then
		stReturned.GetGravity = function(self, ...)
			return self.m_flGravity
		end
	end

	return stReturned
end

local aProjectileInfo = {}
local aSpellInfo = {}

AppendItemDefinitions(
	1,
	18, -- Rocket Launcher tf_weapon_rocketlauncher
	205, -- Rocket Launcher (Renamed/Strange) 	tf_weapon_rocketlauncher
	228, -- The Black Box 	tf_weapon_rocketlauncher
	237, -- Rocket Jumper 	tf_weapon_rocketlauncher
	658, -- Festive Rocket Launcher
	730, -- The Beggar's Bazooka
	800, -- Silver Botkiller Rocket Launcher Mk.I
	809, -- Gold Botkiller Rocket Launcher Mk.I
	889, -- Rust Botkiller Rocket Launcher Mk.I
	898, -- Blood Botkiller Rocket Launcher Mk.I
	907, -- Carbonado Botkiller Rocket Launcher Mk.I
	916, -- Diamond Botkiller Rocket Launcher Mk.I
	965, -- Silver Botkiller Rocket Launcher Mk.II
	974, -- Gold Botkiller Rocket Launcher Mk.II
	1085, -- Festive Black Box
	1104, -- The Air Strike
	15006, -- Woodland Warrior
	15014, -- Sand Cannon
	15028, -- American Pastoral
	15043, -- Smalltown Bringdown
	15052, -- Shell Shocker
	15057, -- Aqua Marine
	15081, -- Autumn
	15104, -- Blue Mew
	15105, -- Brain Candy
	15129, -- Coffin Nail
	15130, -- High Roller's
	15150 -- Warhawk
)
aProjectileInfo[1] = DefineBasicProjectileDefinition({
	vecVelocity = Vector3(1100, 0, 0),
	vecMaxs = Vector3(0, 0, 0),
	iAlignDistance = 2000,

	GetOffset = function(self, bDucking, bIsFlipped)
		return Vector3(23.5, 12 * (bIsFlipped and -1 or 1), bDucking and 8 or -3)
	end,
})

AppendItemDefinitions(
	2,
	127 -- The Direct Hit
)
aProjectileInfo[2] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
	vecVelocity = Vector3(2000, 0, 0),
})

AppendItemDefinitions(
	3,
	414 -- The Liberty Launcher
)
aProjectileInfo[3] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
	vecVelocity = Vector3(1550, 0, 0),
})

AppendItemDefinitions(
	4,
	513 -- The Original
)
aProjectileInfo[4] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
	GetOffset = function(self, bDucking)
		return Vector3(23.5, 0, bDucking and 8 or -3)
	end,
})

-- https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/shared/tf/tf_weapon_dragons_fury.cpp
AppendItemDefinitions(
	5,
	1178 -- Dragon's Fury
)
aProjectileInfo[5] = DefineBasicProjectileDefinition({
	vecVelocity = Vector3(600, 0, 0),
	vecMaxs = Vector3(1, 1, 1),

	GetOffset = function(self, bDucking, bIsFlipped)
		return Vector3(3, 7, -9)
	end,
})

AppendItemDefinitions(
	6,
	442 -- The Righteous Bison
)
aProjectileInfo[6] = DefineBasicProjectileDefinition({
	vecVelocity = Vector3(1200, 0, 0),
	vecMaxs = Vector3(1, 1, 1),
	iAlignDistance = 2000,

	GetOffset = function(self, bDucking, bIsFlipped)
		return Vector3(23.5, -8 * (bIsFlipped and -1 or 1), bDucking and 8 or -3)
	end,
})

AppendItemDefinitions(
	7,
	20, -- Stickybomb Launcher
	207, -- Stickybomb Launcher (Renamed/Strange)
	661, -- Festive Stickybomb Launcher
	797, -- Silver Botkiller Stickybomb Launcher Mk.I
	806, -- Gold Botkiller Stickybomb Launcher Mk.I
	886, -- Rust Botkiller Stickybomb Launcher Mk.I
	895, -- Blood Botkiller Stickybomb Launcher Mk.I
	904, -- Carbonado Botkiller Stickybomb Launcher Mk.I
	913, -- Diamond Botkiller Stickybomb Launcher Mk.I
	962, -- Silver Botkiller Stickybomb Launcher Mk.II
	971, -- Gold Botkiller Stickybomb Launcher Mk.II
	15009, -- Sudden Flurry
	15012, -- Carpet Bomber
	15024, -- Blasted Bombardier
	15038, -- Rooftop Wrangler
	15045, -- Liquid Asset
	15048, -- Pink Elephant
	15082, -- Autumn
	15083, -- Pumpkin Patch
	15084, -- Macabre Web
	15113, -- Sweet Dreams
	15137, -- Coffin Nail
	15138, -- Dressed to Kill
	15155 -- Blitzkrieg
)
aProjectileInfo[7] = DefineSimulProjectileDefinition({
	vecOffset = Vector3(16, 8, -6),
	vecAngularVelocity = Vector3(600, 0, 0),
	vecMaxs = Vector3(2, 2, 2),
	sModelName = "models/weapons/w_models/w_stickybomb.mdl",

	GetVelocity = function(self, flChargeBeginTime)
		return Vector3(900 + CLAMP(flChargeBeginTime / 4, 0, 1) * 1500, 0, 200)
	end,
})

AppendItemDefinitions(
	8,
	1150 -- The Quickiebomb Launcher
)
aProjectileInfo[8] = DefineDerivedProjectileDefinition(aProjectileInfo[7], {
	sModelName = "models/workshop/weapons/c_models/c_kingmaker_sticky/w_kingmaker_stickybomb.mdl",

	GetVelocity = function(self, flChargeBeginTime)
		return Vector3(900 + CLAMP(flChargeBeginTime / 1.2, 0, 1) * 1500, 0, 200)
	end,
})

AppendItemDefinitions(
	9,
	130, -- The Scottish Resistance
	265 -- Sticky Jumper
)
aProjectileInfo[9] = DefineDerivedProjectileDefinition(aProjectileInfo[7], {
	sModelName = "models/weapons/w_models/w_stickybomb_d.mdl",
})

AppendItemDefinitions(
	10,
	19, -- Grenade Launcher
	206, -- Grenade Launcher (Renamed/Strange)
	1007, -- Festive Grenade Launcher
	1151, -- The Iron Bomber
	15077, -- Autumn
	15079, -- Macabre Web
	15091, -- Rainbow
	15092, -- Sweet Dreams
	15116, -- Coffin Nail
	15117, -- Top Shelf
	15142, -- Warhawk
	15158 -- Butcher Bird
)
aProjectileInfo[10] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(16, 8, -6),
	vecVelocity = Vector3(1200, 0, 200),
	vecMaxs = Vector3(2, 2, 2),
	flGravity = 1,
	flDrag = 0.45,
})

AppendItemDefinitions(
	11,
	308 -- The Loch-n-Load
)
aProjectileInfo[11] = DefineDerivedProjectileDefinition(aProjectileInfo[10], {
	vecVelocity = Vector3(1500, 0, 200),
	flDrag = 0.225,
})

AppendItemDefinitions(
	12,
	996 -- The Loose Cannon
)
aProjectileInfo[12] = DefineDerivedProjectileDefinition(aProjectileInfo[10], {
	vecVelocity = Vector3(1440, 0, 200),
	flGravity = 1.4,
	flDrag = 0.5,
})

AppendItemDefinitions(
	13,
	56, -- The Huntsman
	1005, -- Festive Huntsman
	1092 --The Fortified Compound
)
aProjectileInfo[13] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(23.5, -8, -3),
	vecMaxs = Vector3(0, 0, 0),
	iAlignDistance = 2000,

	GetVelocity = function(self, flChargeBeginTime)
		return Vector3(1800 + CLAMP(flChargeBeginTime, 0, 1) * 800, 0, 0)
	end,

	GetGravity = function(self, flChargeBeginTime)
		return 0.5 - CLAMP(flChargeBeginTime, 0, 1) * 0.4
	end,
})

AppendItemDefinitions(
	14,
	39, -- The Flare Gun
	595, -- The Manmelter
	740, -- The Scorch Shot
	1081 -- Festive Flare Gun
)
aProjectileInfo[14] = DefinePseudoProjectileDefinition({
	vecVelocity = Vector3(2000, 0, 0),
	vecMaxs = Vector3(0, 0, 0),
	flGravity = 0.3,
	iAlignDistance = 2000,

	GetOffset = function(self, bDucking, bIsFlipped)
		return Vector3(23.5, 12 * (bIsFlipped and -1 or 1), bDucking and 8 or -3)
	end,
})

AppendItemDefinitions(
	15,
	305, -- Crusader's Crossbow
	1079 -- Festive Crusader's Crossbow
)
aProjectileInfo[15] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(23.5, -8, -3),
	vecVelocity = Vector3(2400, 0, 0),
	vecMaxs = Vector3(3, 3, 3),
	flGravity = 0.2,
	iAlignDistance = 2000,
})

AppendItemDefinitions(
	16,
	997 -- The Rescue Ranger
)
aProjectileInfo[16] = DefineDerivedProjectileDefinition(aProjectileInfo[15], {
	vecMaxs = Vector3(1, 1, 1),
})

AppendItemDefinitions(
	17,
	17, -- Syringe Gun
	36, -- The Blutsauger
	204, -- Syringe Gun (Renamed/Strange)
	412 -- The Overdose
)
aProjectileInfo[17] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(16, 6, -8),
	vecVelocity = Vector3(1000, 0, 0),
	vecMaxs = Vector3(1, 1, 1),
	flGravity = 0.3,
})

AppendItemDefinitions(
	18,
	58, -- Jarate
	222, -- Mad Milk
	1083, -- Festive Jarate
	1105, -- The Self-Aware Beauty Mark
	1121 -- Mutated Milk
)
aProjectileInfo[18] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(16, 8, -6),
	vecVelocity = Vector3(1000, 0, 200),
	vecMaxs = Vector3(8, 8, 8),
	flGravity = 1.125,
})

AppendItemDefinitions(
	19,
	812, -- The Flying Guillotine
	833 -- The Flying Guillotine (Genuine)
)
aProjectileInfo[19] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(23.5, 8, -3),
	vecVelocity = Vector3(3000, 0, 300),
	vecMaxs = Vector3(2, 2, 2),
	flGravity = 2.25,
	flDrag = 1.3,
})

AppendItemDefinitions(
	20,
	44 -- The Sandman
)
aProjectileInfo[20] = DefineSimulProjectileDefinition({
	vecVelocity = Vector3(2985.1118164063, 0, 298.51116943359),
	vecAngularVelocity = Vector3(0, 50, 0),
	vecMaxs = Vector3(4.25, 4.25, 4.25),
	sModelName = "models/weapons/w_models/w_baseball.mdl",

	GetFirePosition = function(self, pLocalPlayer, vecLocalView, vecViewAngles, bIsFlipped)
		--https://github.com/ValveSoftware/source-sdk-2013/blob/0565403b153dfcde602f6f58d8f4d13483696a13/src/game/shared/tf/tf_weapon_bat.cpp#L232
		return pLocalPlayer:GetAbsOrigin()
			+ ((Vector3(0, 0, 50) + (vecViewAngles:Forward() * 32)) * pLocalPlayer:GetPropFloat("m_flModelScale"))
	end,
})

AppendItemDefinitions(
	21,
	648 -- The Wrap Assassin
)
aProjectileInfo[21] = DefineDerivedProjectileDefinition(aProjectileInfo[20], {
	vecMins = Vector3(-2.990180015564, -2.5989532470703, -2.483987569809),
	vecMaxs = Vector3(2.6593606472015, 2.5989530086517, 2.4839873313904),
	sModelName = "models/weapons/c_models/c_xms_festive_ornament.mdl",
})

AppendItemDefinitions(
	22,
	441 -- The Cow Mangler 5000
)
aProjectileInfo[22] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
	GetOffset = function(self, bDucking, bIsFlipped)
		return Vector3(23.5, 8 * (bIsFlipped and 1 or -1), bDucking and 8 or -3)
	end,
})

--https://github.com/ValveSoftware/source-sdk-2013/blob/0565403b153dfcde602f6f58d8f4d13483696a13/src/game/shared/tf/tf_weapon_raygun.cpp#L249
AppendItemDefinitions(
	23,
	588 -- The Pomson 6000
)
aProjectileInfo[23] = DefineDerivedProjectileDefinition(aProjectileInfo[6], {
	vecAbsoluteOffset = Vector3(0, 0, -13),
})

AppendItemDefinitions(
	24,
	1180 -- Gas Passer
)
aProjectileInfo[24] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(16, 8, -6),
	vecVelocity = Vector3(2000, 0, 200),
	vecMaxs = Vector3(8, 8, 8),
	flGravity = 1,
	flDrag = 1.32,
})

AppendItemDefinitions(
	25,
	528 -- The Short Circuit
)
aProjectileInfo[25] = DefineBasicProjectileDefinition({
	vecOffset = Vector3(40, 15, -10),
	vecVelocity = Vector3(700, 0, 0),
	vecMaxs = Vector3(1, 1, 1),
})

AppendItemDefinitions(
	26,
	42, -- Sandvich
	159, -- The Dalokohs Bar
	311, -- The Buffalo Steak Sandvich
	433, -- Fishcake
	863, -- Robo-Sandvich
	1002, -- Festive Sandvich
	1190 -- Second Banana
)
aProjectileInfo[26] = DefinePseudoProjectileDefinition({
	vecOffset = Vector3(0, 0, -8),
	vecAngleOffset = Vector3(-10, 0, 0),
	vecVelocity = Vector3(500, 0, 0),
	vecMaxs = Vector3(17, 17, 10),
	flGravity = 1.02,
})

AppendSpellDefinitions(
	1,
	9 -- TF_Spell_Meteor
)
aSpellInfo[1] = DefinePseudoProjectileDefinition({
	vecVelocity = Vector3(1000, 0, 200),
	vecMaxs = Vector3(0, 0, 0),
	flGravity = 1.025,
	flDrag = 0.15,

	GetOffset = function(self, bDucking, bIsFlipped)
		return Vector3(3, 7, -9)
	end,
})

AppendSpellDefinitions(
	2,
	1, -- TF_Spell_Bats
	6 -- TF_Spell_Teleport
)
aSpellInfo[2] = DefineDerivedProjectileDefinition(aSpellInfo[1], {
	vecMins = Vector3(-0.019999999552965, -0.019999999552965, -0.019999999552965),
	vecMaxs = Vector3(0.019999999552965, 0.019999999552965, 0.019999999552965),
})

AppendSpellDefinitions(
	3,
	3 -- TF_Spell_MIRV
)
aSpellInfo[3] = DefineDerivedProjectileDefinition(aSpellInfo[1], {
	vecMaxs = Vector3(1.5, 1.5, 1.5),
	flDrag = 0.525,
})

AppendSpellDefinitions(
	4,
	10 -- TF_Spell_SpawnBoss
)
aSpellInfo[4] = DefineDerivedProjectileDefinition(aSpellInfo[1], {
	vecMaxs = Vector3(3.0, 3.0, 3.0),
	flDrag = 0.35,
})

AppendSpellDefinitions(
	5,
	11 -- TF_Spell_SkeletonHorde
)
aSpellInfo[5] = DefineDerivedProjectileDefinition(aSpellInfo[4], {
	vecMaxs = Vector3(2.0, 2.0, 2.0),
})

AppendSpellDefinitions(
	6,
	0 -- TF_Spell_Fireball
)
aSpellInfo[6] = DefineDerivedProjectileDefinition(aSpellInfo[1], {
	iType = PROJECTILE_TYPE_BASIC,
	vecVelocity = Vector3(1200, 0, 0),
})

AppendSpellDefinitions(
	7,
	7 -- TF_Spell_LightningBall
)
aSpellInfo[7] = DefineDerivedProjectileDefinition(aSpellInfo[6], {
	vecVelocity = Vector3(480, 0, 0),
})

AppendSpellDefinitions(
	8,
	12 -- TF_Spell_Fireball
)
aSpellInfo[8] = DefineDerivedProjectileDefinition(aSpellInfo[6], {
	vecVelocity = Vector3(1500, 0, 0),
})

local function GetProjectileInformation(i)
	return aProjectileInfo[aItemDefinitions[i or 0]]
end

local function GetSpellInformation(pLocalPlayer)
	if not pLocalPlayer then
		return
	end

	local pSpellBook = pLocalPlayer:GetEntityForLoadoutSlot(9) -- LOADOUT_POSITION_ACTION
	if not pSpellBook or pSpellBook:GetWeaponID() ~= 97 then -- TF_WEAPON_SPELLBOOK
		return
	end

	local i = pSpellBook:GetPropInt("m_iSelectedSpellIndex")
	local iOverride = client.GetConVar("tf_test_spellindex")
	if iOverride > -1 then
		i = iOverride
	elseif pSpellBook:GetPropInt("m_iSpellCharges") <= 0 or i == -2 then -- SPELL_UNKNOWN
		return
	end

	return aSpellInfo[aSpellDefinitions[i or 0]]
end

return setmetatable({
	GetProjectileInformation = GetProjectileInformation,
	GetSpellInformation = GetSpellInformation,
}, {
	__call = function(self, i)
		return GetProjectileInformation(i)
	end,
})
