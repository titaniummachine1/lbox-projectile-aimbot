-- Imports

-- Module declaration
local GameConstants = {}

-- Game masks and flags -----
GameConstants.MASK_PLAYERSOLID = MASK_PLAYERSOLID
GameConstants.MASK_SHOT_HULL = MASK_SHOT_HULL
GameConstants.MASK_VISIBLE = MASK_VISIBLE
GameConstants.MASK_SOLID = 33570827
GameConstants.MASK_WATER = 0x4018 -- CONTENTS_WATER | CONTENTS_SLIME

GameConstants.FL_ONGROUND = FL_ONGROUND
GameConstants.FL_DUCKING = FL_DUCKING

-- Rune types -----
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

-- Collision types -----
GameConstants.CollisionType = {
	NORMAL = 0,
	HEAL_TEAMMATES = 1,
	HEAL_BUILDINGS = 2,
	HEAL_HURT = 3,
	NONE = 4,
}

-- Projectile types -----
GameConstants.ProjectileType = {
	BASIC = 0,
	PSEUDO = 1,
	SIMUL = 2,
}

-- Math constants -----
GameConstants.RAD2DEG = 180 / math.pi
GameConstants.DEG2RAD = math.pi / 180

-- Physics constants -----
GameConstants.DEFAULT_GRAVITY = 800
GameConstants.DEFAULT_STEP_SIZE = 18
GameConstants.DEFAULT_MAX_CLIP_PLANES = 5

return GameConstants
