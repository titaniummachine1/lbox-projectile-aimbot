-- Module declaration
local TickProfiler = {}

-- Constants / Config -----
local SNAPSHOT_INTERVAL = 10
local SMOOTHING_FACTOR = 0.2
local SORT_DELAY = 10
local COLORS = {
	GREY = { 150, 150, 150, 255 },
	WHITE = { 255, 255, 255, 255 },
	YELLOW = { 255, 200, 50, 255 },
	RED = { 255, 50, 50, 255 },
	GREEN = { 100, 255, 100, 255 },
	DARK_GREY = { 100, 100, 100, 255 },
	BLUE = { 100, 200, 255, 255 },
}

-- State -----
local acc = {}
local stacks = {} -- Map of section names to timing stacks
local activeStack = {} -- Current call hierarchy [name1, name2, ...]
local watches = {} -- Custom watch metrics { name = value }
local display = {}
local enabled = false
local lastSnapshot, lastSortTime, lastAllocReset = 0, 0, 0
local lastMemCheck = collectgarbage("count") * 1024
local totalAllocatedSec, allocRate = 0, 0

-- Fonts
local font = draw.CreateFont("Tahoma", 12, 600, FONTFLAG_OUTLINE)
local fontSmall = draw.CreateFont("Tahoma", 11, 400, FONTFLAG_OUTLINE)

-- Private Helpers -----

local function formatTime(us)
	if us >= 1000 then
		return string.format("%6.2f ms", us / 1000)
	end
	return string.format("%6.0f µs", us)
end

local function formatMemory(bytes)
	local absB = math.abs(bytes)
	local sign = bytes < 0 and "-" or " "
	if absB >= 1048576 then
		return string.format("%s%5.2f MB", sign, absB / 1048576)
	end
	if absB >= 1024 then
		return string.format("%s%5.2f KB", sign, absB / 1024)
	end
	return string.format("%s%5.0f B ", sign, absB)
end

local function getColorForValue(val, t1, t2, t3)
	local function lerp(t, c1, c2)
		return {
			math.floor(c1[1] + (c2[1] - c1[1]) * t),
			math.floor(c1[2] + (c2[2] - c1[2]) * t),
			math.floor(c1[3] + (c2[3] - c1[3]) * t),
			255,
		}
	end
	if val <= t1 then
		return lerp(val / t1, COLORS.GREY, COLORS.WHITE)
	end
	if val <= t2 then
		return lerp((val - t1) / (t2 - t1), COLORS.WHITE, COLORS.YELLOW)
	end
	return lerp(math.min(1, (val - t2) / (t3 - t2)), COLORS.YELLOW, COLORS.RED)
end

local function updateStats()
	local currentTick = globals.TickCount()
	if currentTick - lastSnapshot >= SNAPSHOT_INTERVAL then
		lastSnapshot = currentTick
		for _, data in pairs(acc) do
			local avg = data.samples > 0 and (data.total / data.samples) or 0
			local mAvg = data.samples > 0 and (data.memTotal / data.samples) or 0
			data.dispAvg = data.dispAvg + (avg - data.dispAvg) * SMOOTHING_FACTOR
			data.dispPeak = data.dispPeak + (data.peak - data.dispPeak) * SMOOTHING_FACTOR
			data.dispMemAvg = data.dispMemAvg + (mAvg - data.dispMemAvg) * SMOOTHING_FACTOR
			data.dispMemPeak = data.dispMemPeak + (data.memPeak - data.dispMemPeak) * SMOOTHING_FACTOR
			data.total, data.samples, data.peak, data.memTotal, data.memPeak = 0, 0, 0, 0, 0
		end
	end

	if currentTick - lastSortTime >= SORT_DELAY then
		lastSortTime, display = currentTick, {}
		-- 1. Add Watches (at the top)
		local watchSortedKeys = {}
		for k in pairs(watches) do
			table.insert(watchSortedKeys, k)
		end
		table.sort(watchSortedKeys)
		for _, k in ipairs(watchSortedKeys) do
			table.insert(display, { name = k, value = watches[k], isWatch = true })
		end
		-- 2. Add Sections (hierarchical sort)
		local sectionsList = {}
		for name, data in pairs(acc) do
			table.insert(sectionsList, {
				name = name,
				tAvg = data.dispAvg * 1000000,
				tPeak = data.dispPeak * 1000000,
				mAvg = data.dispMemAvg,
				mPeak = data.dispMemPeak,
				depth = data.depth or 0,
			})
		end
		-- Sort by depth, then by time
		table.sort(sectionsList, function(a, b)
			if a.depth ~= b.depth then
				return a.depth < b.depth
			end
			return a.tAvg > b.tAvg
		end)
		for _, s in ipairs(sectionsList) do
			table.insert(display, s)
		end
	end

	local currentMem = collectgarbage("count") * 1024
	if currentMem > lastMemCheck then
		totalAllocatedSec = totalAllocatedSec + (currentMem - lastMemCheck)
	end
	lastMemCheck = currentMem

	local nowClock = os.clock()
	if nowClock - lastAllocReset >= 1.0 then
		allocRate, totalAllocatedSec, lastAllocReset = totalAllocatedSec, 0, nowClock
	end
end

local function drawEntries(x, y)
	local lineHeight = 14
	local totalMeasured = 0
	for i = #display, 1, -1 do
		local e = display[i]
		if e.isWatch then
			draw.Color(table.unpack(COLORS.BLUE))
			draw.Text(x, y, string.format("WATCH: %s = %s", e.name, tostring(e.value)))
			y = y - lineHeight
		else
			totalMeasured = totalMeasured + e.mAvg
			local tColor = getColorForValue(e.tAvg, 20, 200, 1000)
			local mColor = e.mAvg < 0 and COLORS.GREEN or getColorForValue(e.mAvg, 100, 1024, 10240)

			draw.Color(table.unpack(tColor))
			draw.Text(x, y, formatTime(e.tAvg))
			draw.Color(table.unpack(COLORS.GREY))
			draw.Text(x + 70, y, formatTime(e.tPeak))
			draw.Color(table.unpack(COLORS.DARK_GREY))
			draw.Text(x + 140, y, "|")
			draw.Color(table.unpack(mColor))
			draw.Text(x + 155, y, formatMemory(e.mAvg))
			draw.Color(table.unpack(COLORS.GREY))
			draw.Text(x + 225, y, formatMemory(e.mPeak))
			draw.Color(table.unpack(COLORS.DARK_GREY))
			draw.Text(x + 295, y, "|")
			draw.Color(table.unpack(COLORS.WHITE))

			local prefix = e.depth > 0 and (string.rep("  ", e.depth) .. "└ ") or ""
			draw.Text(x + 310, y, prefix .. e.name)
			y = y - lineHeight
		end
	end
	return y, totalMeasured
end

local function drawOverlay()
	if not enabled or engine.IsGameUIVisible() then
		return
	end
	updateStats()
	if #display == 0 then
		return
	end

	draw.SetFont(font)
	local _, screenH = draw.GetScreenSize()
	local x, y = 12, screenH - 12
	local nextY, totalMeasured = drawEntries(x, y)

	y = nextY - 4
	draw.SetFont(fontSmall)
	draw.Color(table.unpack(COLORS.GREY))
	draw.Text(x, y, "Time Avg")
	draw.Text(x + 70, y, "Time Peak")
	draw.Text(x + 155, y, "Mem Avg")
	draw.Text(x + 225, y, "Mem Peak")
	draw.Text(x + 310, y, "Section Name")

	y = y - 18
	local memUsed = collectgarbage("count") * 1024
	local memStr = string.format(
		"Lua Total: %s | Measured: %s | Rate: %s/s",
		formatMemory(memUsed),
		formatMemory(totalMeasured),
		formatMemory(allocRate)
	)
	draw.Color(table.unpack(COLORS.YELLOW))
	draw.Text(x, y, memStr)
end

-- Public API -----

function TickProfiler.SetEnabled(state)
	enabled = state == true
	if not enabled then
		acc, stacks, watches, activeStack, display = {}, {}, {}, {}, {}
	end
end

function TickProfiler.Watch(name, value)
	if not enabled then
		return
	end
	watches[name] = value
end

function TickProfiler.BeginSection(name)
	if not enabled then
		return
	end
	local s = stacks[name] or {}
	stacks[name] = s

	local depth = #activeStack
	table.insert(activeStack, name)

	table.insert(s, {
		t = os.clock(),
		m = collectgarbage("count") * 1024,
		depth = depth,
	})
end

function TickProfiler.EndSection(name)
	if not enabled then
		return
	end
	local s = stacks[name]
	if not s or #s == 0 then
		return
	end

	local start = table.remove(s)
	if activeStack[#activeStack] == name then
		table.remove(activeStack)
	end

	local elapsed = os.clock() - start.t
	local memDelta = (collectgarbage("count") * 1024) - start.m

	local sec = acc[name]
	if not sec then
		sec = {
			total = 0,
			samples = 0,
			peak = 0,
			memTotal = 0,
			memPeak = 0,
			dispAvg = 0,
			dispPeak = 0,
			dispMemAvg = 0,
			dispMemPeak = 0,
			depth = start.depth,
		}
		acc[name] = sec
	end

	sec.depth = start.depth -- Sync depth
	sec.total = sec.total + elapsed
	sec.samples = sec.samples + 1
	if elapsed > sec.peak then
		sec.peak = elapsed
	end
	sec.memTotal = sec.memTotal + memDelta
	if memDelta > sec.memPeak then
		sec.memPeak = memDelta
	end
end

function TickProfiler.Measure(name, fn, ...)
	if not enabled then
		return fn(...)
	end
	TickProfiler.BeginSection(name)
	local res = { pcall(fn, ...) }
	TickProfiler.EndSection(name)
	if not res[1] then
		error(res[2])
	end
	return table.unpack(res, 2)
end

-- Callbacks -----
callbacks.Unregister("Draw", "PROJ_AIMBOT_PROFILER_DRAW")
callbacks.Register("Draw", "PROJ_AIMBOT_PROFILER_DRAW", drawOverlay)

return TickProfiler
