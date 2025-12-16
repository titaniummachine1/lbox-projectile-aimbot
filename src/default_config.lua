-- Default configuration for Projectile Aimbot
local DefaultConfig = {
	-- UI State
	UI = {
		SelectedTab = 1, -- Current tab index
	},

	-- Aimbot settings
	Aimbot = {
		Enabled = true,
		AimKey = 0, -- KEY_NONE
		ActivationMode = 0, -- 0=Always, 1=On Hold, 2=Toggle
		OnAttack = false, -- Activate when cmd has attack input (combines with mode)
		AimFOV = 15,
		AimMethod = "silent +", -- "silent +", "silent", "normal"
		MaxDistance = 3000,
		MaxSimTime = 3.0,
		MinAccuracy = 2,
		MaxAccuracy = 12,
		MinConfidence = 40,
		AimSentry = true,
		AimOtherBuildings = false,
		TrackedTargets = 4, -- how many enemies to keep movement history for
		PreferFeet = true, -- prioritize shooting ~5 units above ground to launch enemies
		AutoFlipViewmodels = false,
	},

	-- Visual settings
	Visuals = {
		Enabled = true,
		ShowConfidence = true,
		ShowProfiler = false, -- Performance profiler overlay
		DrawPlayerPath = true,
		DrawProjectilePath = true,
		DrawBoundingBox = true,
		DrawMultipointTarget = true,
		MultipointDebugDuration = 1.0,
		DrawQuads = false,

		-- Colors (HSV hue 0-360, or 360+ for white)
		Colors = {
			PlayerPath = 180, -- Cyan
			ProjectilePath = 60, -- Yellow
			BoundingBox = 120, -- Green
			MultipointTarget = 0, -- Red
			Quads = 240, -- Blue
		},

		ColorsRGBA = {
			PlayerPath = { 0, 255, 255, 255 },
			ProjectilePath = { 255, 255, 0, 255 },
			BoundingBox = { 0, 255, 0, 255 },
			MultipointTarget = { 255, 0, 0, 255 },
			Quads = { 0, 0, 255, 25 },
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
