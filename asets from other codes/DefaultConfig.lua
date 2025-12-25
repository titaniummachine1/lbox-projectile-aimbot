local Default_Config = {
	currentTab = "Main",

	Main = {
		Fetch_Database = true,
		AutoPriority = true, -- Auto set priority 10 on detected cheaters
		AutoFetch = true, -- Automatically fetch database on startup
		LastFetchTimestamp = 0,
		partyCallaut = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
	},

	Advanced = {
		Evicence_Tolerance = 100, -- Evidence score threshold to mark as cheater
		LogLevel = { false, true, false, false }, -- [Debug, Info, Warning, Error] (default: Info)
		debug = false, -- Debug mode (removes self from database, enables verbose logging)
		-- Detection toggles (only for implemented detections)
		Choke = true, -- Fake Lag detection
		Warp = true, -- Warp/DT detection
		Bhop = true, -- Bunny hop detection
		DuckSpeed = true, -- Duck speed detection
		AntyAim = true, -- Anti-aim detection
		SilentAimbot = true, -- Silent aimbot (extrapolation) detection
	},
}

return Default_Config
