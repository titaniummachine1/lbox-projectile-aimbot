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
		ActivationMode = 1, -- 0=Always, 1=On Hold, 2=Toggle
		OnAttack = true, -- Activate when cmd has attack input (combines with mode)
		AimFOV = 15,
		AimMethod = "silent +", -- "silent +", "silent", "normal"
		AimMode = 0, -- 0=Legit, 1=Blatant
		DrawOnly = false, -- Visualize targeting without shooting
		MaxDistance = 3000,
		MaxSimTime = 1.5,
		MinConfidence = 40,
		AimSentry = true,
		AimOtherBuildings = false,
		TrackedTargets = 2, -- how many enemies to keep movement history for
		PreferFeet = true, -- prioritize shooting ~5 units above ground to launch enemies
		AutoFlipViewmodels = true,
	},

	-- Visual settings
	Visuals = {
		Enabled = true,
		FadeOutDuration = 1.0,
		ShowConfidence = true,
		ShowProfiler = false, -- Performance profiler overlay
		DrawPlayerPath = true,
		DrawProjectilePath = true,
		DrawBoundingBox = true,
		DrawMultipointTarget = true,
		ShowMultipointDebug = false,
		MultipointDebugDuration = 1.0,
		DrawQuads = false,
		SelfPrediction = false,

		-- Path style options (dropdown index -2 = style: 3=Pavement, 4=ArrowPath, 5=Arrows, 6=L Line, 7=Dashed, 8=Line)
		PathStyles = { "Pavement", "ArrowPath", "Arrows", "L Line", "Dashed", "Line" },
		PlayerPathStyle = 3, -- Pavement (with -2 offset)
		ProjectilePathStyle = 8, -- Line (with -2 offset)

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
			SelfPrediction = { 255, 100, 255, 255 },
		},

		-- Line/element thickness
		Thickness = {
			PlayerPath = 5,
			ProjectilePath = 2,
			BoundingBox = 1.5,
			MultipointTarget = 4.0,
			SelfPrediction = 3,
		},
	},
}

return DefaultConfig
