-- Imports
local G = require("globals")
local DefaultConfig = require("default_config")

-- Module declaration
local Config = {}

-- Local constants / utilities -----
local luaFullPath = GetScriptName()
local luaFileName = luaFullPath:match("([^/\\]+)%.lua$"):gsub("%.lua$", "")
local folderName = string.format([[Lua %s]], luaFileName)

-- Config Path Helper -----
local function getConfigPath()
	local _, fullPath = filesystem.CreateDirectory(folderName)
	local sep = package.config:sub(1, 1)
	return fullPath .. sep .. "config.cfg"
end

-- Serialize a Lua table -----
local function serializeTable(tbl, level)
	level = level or 0
	local indent = string.rep("    ", level)
	local out = indent .. "{\n"
	
	for k, v in pairs(tbl) do
		local keyRepr = (type(k) == "string") and string.format('["%s"]', k) or string.format("[%s]", k)
		out = out .. indent .. "    " .. keyRepr .. " = "
		
		if type(v) == "table" then
			out = out .. serializeTable(v, level + 1) .. ",\n"
		elseif type(v) == "string" then
			out = out .. string.format('"%s",\n', v)
		else
			out = out .. tostring(v) .. ",\n"
		end
	end
	
	out = out .. indent .. "}"
	return out
end

-- Deep copy table -----
local function deepCopy(orig)
	if type(orig) ~= "table" then
		return orig
	end
	
	local copy = {}
	for k, v in pairs(orig) do
		copy[k] = deepCopy(v)
	end
	
	return copy
end

-- Recursive key presence check -----
local function keysMatch(template, loaded)
	for k, v in pairs(template) do
		if loaded[k] == nil then
			return false
		end
		
		if type(v) == "table" and type(loaded[k]) == "table" then
			if not keysMatch(v, loaded[k]) then
				return false
			end
		end
	end
	
	return true
end

-- Ensure all menu settings have defaults -----
local function safeInitMenu()
	if not G.Menu then
		G.Menu = deepCopy(DefaultConfig)
		return
	end

	local function ensureField(parent, key, default)
		if parent[key] == nil then
			parent[key] = deepCopy(default)
		elseif type(default) == "table" and type(parent[key]) == "table" then
			for k, v in pairs(default) do
				ensureField(parent[key], k, v)
			end
		end
	end

	for key, value in pairs(DefaultConfig) do
		ensureField(G.Menu, key, value)
	end
end

-- Public API ----
function Config.saveCFG(cfgTable)
	cfgTable = cfgTable or G.Menu or DefaultConfig
	local path = getConfigPath()

	local file = io.open(path, "w")
	if not file then
		printc(255, 0, 0, 255, "[Config] Failed to write: " .. path)
		return false
	end

	file:write(serializeTable(cfgTable))
	file:close()
	printc(100, 183, 0, 255, "[Config] Saved: " .. path)
	return true
end

function Config.loadCFG()
	local path = getConfigPath()
	local file = io.open(path, "r")

	if not file then
		printc(255, 200, 100, 255, "[Config] No config found, creating default...")
		G.Menu = deepCopy(DefaultConfig)
		Config.saveCFG(G.Menu)
		safeInitMenu()
		return G.Menu
	end

	local content = file:read("*a")
	file:close()

	local chunk, err = load("return " .. content)
	if not chunk then
		printc(255, 100, 100, 255, "[Config] Compile error, regenerating: " .. tostring(err))
		G.Menu = deepCopy(DefaultConfig)
		Config.saveCFG(G.Menu)
		safeInitMenu()
		return G.Menu
	end

	local ok, cfg = pcall(chunk)

	-- Validate: Must be table, keys must match, SHIFT bypass for reset
	local shiftHeld = input.IsButtonDown(KEY_LSHIFT)
	if not ok or type(cfg) ~= "table" or not keysMatch(DefaultConfig, cfg) or shiftHeld then
		if shiftHeld then
			printc(255, 200, 100, 255, "[Config] SHIFT held – regenerating config...")
		else
			printc(255, 100, 100, 255, "[Config] Invalid or outdated config – regenerating...")
		end
		G.Menu = deepCopy(DefaultConfig)
		Config.saveCFG(G.Menu)
		safeInitMenu()
		return G.Menu
	end

	printc(0, 255, 140, 255, "[Config] Loaded: " .. path)
	G.Menu = cfg
	safeInitMenu()
	return G.Menu
end

function Config.getFilePath()
	return getConfigPath()
end

-- Self-init (optional) ---
local function configAutoSaveOnUnload()
	print("[Config] Unloading script, saving configuration...")

	if not G or not G.Menu then
		print("[Config] Warning: G.Menu is nil, cannot save config")
		return
	end

	local success, result = pcall(function()
		local path = getConfigPath()
		local file = io.open(path, "w")
		if file then
			file:write(serializeTable(G.Menu))
			file:close()
			print("[Config] Config saved successfully to: " .. path)
			return true
		else
			print("[Config] ERROR: Cannot open file for writing: " .. tostring(path))
			return false
		end
	end)

	if not success then
		print("[Config] ERROR during save: " .. tostring(result))
	end
end

-- Callbacks -----
callbacks.Register("Unload", "ConfigAutoSaveOnUnload", configAutoSaveOnUnload)

-- Auto-load config on require
Config.loadCFG()

return Config

