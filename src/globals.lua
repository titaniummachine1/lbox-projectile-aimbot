-- Imports
local DefaultConfig = require("default_config")

-- Module declaration
local G = {}

-- Shared state (imported by: main, menu, config)
G.Menu = nil -- Populated by config.lua on load
G.Config = {} -- Runtime config cache

return G

