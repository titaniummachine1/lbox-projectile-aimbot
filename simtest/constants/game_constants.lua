-- Module declaration
local GameConstants = {}

-- Engine & System Constants -----
GameConstants.TICK_INTERVAL = globals.TickInterval()
GameConstants.SV_GRAVITY = 800
GameConstants.SV_MAXVELOCITY = 3500
GameConstants.SV_STOPSPEED = 100
GameConstants.SV_FRICTION = 4
GameConstants.SV_ACCELERATE = 10
GameConstants.SV_AIRACCELERATE = 10

-- Math Constants -----
GameConstants.RAD2DEG = 180 / math.pi
GameConstants.DEG2RAD = math.pi / 180

-- Physics Defaults -----
GameConstants.DEFAULT_STEP_SIZE = 18
GameConstants.DEFAULT_MAX_CLIP_PLANES = 5
GameConstants.DIST_EPSILON = 0.03125
GameConstants.GROUND_CHECK_OFFSET = 2.0
GameConstants.NON_JUMP_VELOCITY = 140.0
GameConstants.STILL_SPEED_THRESHOLD = 50.0

-- Game Masks and Flags -----
GameConstants.MASK_PLAYERSOLID = MASK_PLAYERSOLID
GameConstants.MASK_SHOT_HULL = MASK_SHOT_HULL
GameConstants.MASK_SHOT = MASK_SHOT
GameConstants.MASK_VISIBLE = MASK_VISIBLE
GameConstants.MASK_SOLID = 33570827
GameConstants.MASK_WATER = 0x4018 -- CONTENTS_WATER | CONTENTS_SLIME

GameConstants.FL_ONGROUND = 1 << 0
GameConstants.FL_DUCKING = 1 << 1

-- TF2 Specific Enums -----
GameConstants.TF_Class = {
	Scout = 1,
	Sniper = 2,
	Soldier = 3,
	Demoman = 4,
	Medic = 5,
	Heavy = 6,
	Pyro = 7,
	Spy = 8,
	Engineer = 9,
}

GameConstants.TF_Cond = {
	Cloaked = 16,
	Charging = 17,
	BlastJumping = 81,
	ParachuteDeployed = 108,
	HalloweenKart = 114,
	HalloweenKartDash = 115,
}

GameConstants.RuneTypes = {
	RUNE_NONE = -1,
	RUNE_STRENGTH = 0,
	RUNE_HASTE = 1,
	RUNE_REGEN = 2,
	RUNE_RESIST = 3,
	RUNE_VAMPIRE = 4,
	RUNE_REFLECT = 5,
	RUNE_PRECISION = 6,
	RUNE_AGILITY = 7,
	RUNE_KNOCKOUT = 8,
	RUNE_KING = 9,
	RUNE_PLAGUE = 10,
	RUNE_SUPERNOVA = 11,
}

-- Water levels
GameConstants.WaterLevel = {
	NotInWater = 0,
	Feet = 1,
	Waist = 2,
	Eyes = 3,
}

-- Input Buttons
GameConstants.Buttons = {
	ATTACK = 1,
	ATTACK2 = 2048,
	DUCK = 2,
	JUMP = 4,
}

return GameConstants
