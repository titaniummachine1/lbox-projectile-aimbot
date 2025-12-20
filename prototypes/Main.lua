-- Main entry for SplashbotPROOF prototype with profiling

local TickProfiler = require("tick_profiler")

-- Enable profiler
TickProfiler.SetEnabled(true)

-- Load the splash bot proof of concept
require("SplashbotPROOF")

print("SplashbotPROOF loaded with profiler enabled")
print("Press INSERT to toggle profiler on/off")

-- Toggle profiler with INSERT key
local function OnDraw()
	if input.IsButtonPressed(KEY_INSERT) then
		local enabled = TickProfiler.IsEnabled()
		TickProfiler.SetEnabled(not enabled)
		print("Profiler", not enabled and "ENABLED" or "DISABLED")
	end
end

callbacks.Register("Draw", "PROFILER_TOGGLE", OnDraw)
