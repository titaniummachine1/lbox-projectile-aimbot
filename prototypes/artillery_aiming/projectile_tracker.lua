-- Bootstrap
local Manager = require("projectile/manager")

local ProjectileTracker = {}

function ProjectileTracker.Startup()
	if Manager then
		Manager.Startup()
	end
end

function ProjectileTracker.Shutdown()
	if Manager then
		Manager.Shutdown()
	end
end

-- Main.lua Interface
function ProjectileTracker.update()
	if Manager then
		Manager.Update()
	end
end

function ProjectileTracker.draw()
	if Manager then
		Manager.Draw()
	end
end

return ProjectileTracker
