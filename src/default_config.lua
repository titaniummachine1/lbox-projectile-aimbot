-- Default configuration for Projectile Aimbot
local DefaultConfig = {
	-- Aimbot settings
	Aimbot = {
		Enabled = true,
		AimKey = 0, -- KEY_NONE
		AimFOV = 15,
		AimMethod = "silent +", -- "silent +", "silent", "normal"
		MaxDistance = 3000,
		MinAccuracy = 2,
		MaxAccuracy = 12,
		MinConfidence = 40,
		AimSentry = true,
		AimOtherBuildings = false,
	},

	-- Visual settings
	Visuals = {
		Enabled = true,
		ShowConfidence = true,
		DrawPlayerPath = true,
		DrawProjectilePath = true,
		DrawBoundingBox = true,
		DrawMultipointTarget = true,
		DrawQuads = false,

		-- Colors (HSV hue 0-360, or 360+ for white)
		Colors = {
			PlayerPath = 180, -- Cyan
			ProjectilePath = 60, -- Yellow
			BoundingBox = 120, -- Green
			MultipointTarget = 0, -- Red
			Quads = 240, -- Blue
		},

		-- Line/element thickness
		Thickness = {
			PlayerPath = 1.5,
			ProjectilePath = 1.5,
			BoundingBox = 1.5,
			MultipointTarget = 4.0,
		},
	},
}

return DefaultConfig
