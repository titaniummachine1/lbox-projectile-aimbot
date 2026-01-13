-- TickProfiler - Rolling 132-sample performance profiler
local TickProfiler = {}

-- Constants -----
local RING_SIZE = 132 -- Rolling window size (2 seconds at 66 tick)
local SORT_DELAY = 20 -- Re-sort display every N ticks
local COLORS = {
	GREY = { 150, 150, 150, 255 },
	WHITE = { 255, 255, 255, 255 },
	YELLOW = { 255, 200, 50, 255 },
	RED = { 255, 50, 50, 255 },
	GREEN = { 100, 255, 100, 255 },
}

-- State -----
local sections = {} -- { name = { timeRing={}, memRing={}, ringIdx=1, count=0 } }
local stacks = {}
local display = {}
local enabled = false
local lastSortTick = 0
local lastMemCheck = collectgarbage("count") * 1024
local allocRingBuffer = {}
local allocRingIdx = 1

-- Fonts
local font = draw.CreateFont("Tahoma", 12, 600, FONTFLAG_OUTLINE)
local fontSmall = draw.CreateFont("Tahoma", 11, 400, FONTFLAG_OUTLINE)

-- Helpers -----

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

local function getTimeColor(us)
	if us < 50 then
		return COLORS.GREY
	end
	if us < 500 then
		return COLORS.WHITE
	end
	if us < 2000 then
		return COLORS.YELLOW
	end
	return COLORS.RED
end

local function getMemColor(bytes)
	if bytes < 0 then
		return COLORS.GREEN
	end
	if bytes < 1024 then
		return COLORS.GREY
	end
	if bytes < 10240 then
		return COLORS.YELLOW
	end
	return COLORS.RED
end

local function calcRingStats(ring, count)
	if count == 0 then
		return 0, 0
	end
	local sum, peak = 0, 0
	local n = math.min(count, RING_SIZE)
	for i = 1, n do
		local v = ring[i] or 0
		sum = sum + v
		if v > peak then
			peak = v
		end
	end
	return sum / n, peak
end

local function rebuildDisplay()
	display = {}
	for name, sec in pairs(sections) do
		local tAvg, tPeak = calcRingStats(sec.timeRing, sec.count)
		local mAvg, mPeak = calcRingStats(sec.memRing, sec.count)
		table.insert(display, {
			name = name,
			tAvg = tAvg * 1000000, -- Convert to microseconds
			tPeak = tPeak * 1000000,
			mAvg = mAvg,
			mPeak = mPeak,
		})
	end
	table.sort(display, function(a, b)
		return a.tAvg > b.tAvg
	end)
end

local function drawOverlay()
	if not enabled or engine.IsGameUIVisible() then
		return
	end

	local currentTick = globals.TickCount()
	if currentTick - lastSortTick >= SORT_DELAY then
		lastSortTick = currentTick
		rebuildDisplay()
	end

	if #display == 0 then
		return
	end

	draw.SetFont(font)
	local _, screenH = draw.GetScreenSize()
	local x, y = 12, screenH - 12
	local lineHeight = 14
	local totalMeasuredMem = 0

	for i = #display, 1, -1 do
		local e = display[i]
		totalMeasuredMem = totalMeasuredMem + e.mAvg
		local tColor = getTimeColor(e.tAvg)
		local mColor = getMemColor(e.mAvg)

		draw.Color(table.unpack(tColor))
		draw.Text(x, y, formatTime(e.tAvg))
		draw.Color(table.unpack(COLORS.GREY))
		draw.Text(x + 70, y, formatTime(e.tPeak))
		draw.Color(100, 100, 100, 255)
		draw.Text(x + 140, y, "|")
		draw.Color(table.unpack(mColor))
		draw.Text(x + 155, y, formatMemory(e.mAvg))
		draw.Color(table.unpack(COLORS.GREY))
		draw.Text(x + 225, y, formatMemory(e.mPeak))
		draw.Color(100, 100, 100, 255)
		draw.Text(x + 295, y, "|")
		draw.Color(table.unpack(COLORS.WHITE))
		draw.Text(x + 310, y, e.name)
		y = y - lineHeight
	end

	-- Header
	y = y - 4
	draw.SetFont(fontSmall)
	draw.Color(table.unpack(COLORS.GREY))
	draw.Text(x, y, "Time Avg")
	draw.Text(x + 70, y, "Time Peak")
	draw.Text(x + 155, y, "Mem Avg")
	draw.Text(x + 225, y, "Mem Peak")
	draw.Text(x + 310, y, "Section Name")

	-- Footer
	y = y - 18
	local memUsed = collectgarbage("count") * 1024
	local allocAvg, _ = calcRingStats(allocRingBuffer, RING_SIZE)
	local ratePerSec = allocAvg * 66 -- Approximate rate
	local memStr = string.format(
		"Lua Total: %s | Measured: %s | Rate: %s/s",
		formatMemory(memUsed),
		formatMemory(totalMeasuredMem),
		formatMemory(ratePerSec)
	)
	draw.Color(table.unpack(COLORS.YELLOW))
	draw.Text(x, y, memStr)
end

-- Public API -----

function TickProfiler.SetEnabled(state)
	enabled = state == true
	if not enabled then
		sections, stacks, display = {}, {}, {}
		for i = 1, RING_SIZE do
			allocRingBuffer[i] = 0
		end
	end
end

function TickProfiler.BeginSection(name)
	if not enabled then
		return
	end
	local s = stacks[name] or {}
	stacks[name] = s
	table.insert(s, { t = os.clock(), m = collectgarbage("count") * 1024 })
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
	local elapsed = os.clock() - start.t
	local memDelta = (collectgarbage("count") * 1024) - start.m

	local sec = sections[name]
	if not sec then
		sec = { timeRing = {}, memRing = {}, ringIdx = 1, count = 0 }
		for i = 1, RING_SIZE do
			sec.timeRing[i], sec.memRing[i] = 0, 0
		end
		sections[name] = sec
	end

	sec.timeRing[sec.ringIdx] = elapsed
	sec.memRing[sec.ringIdx] = memDelta
	sec.ringIdx = (sec.ringIdx % RING_SIZE) + 1
	sec.count = math.min(sec.count + 1, RING_SIZE)

	-- Track global allocation
	local currentMem = collectgarbage("count") * 1024
	local allocDelta = currentMem > lastMemCheck and (currentMem - lastMemCheck) or 0
	allocRingBuffer[allocRingIdx] = allocDelta
	allocRingIdx = (allocRingIdx % RING_SIZE) + 1
	lastMemCheck = currentMem
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
local function onUnload()
	callbacks.Unregister("Draw", "PROJ_AIMBOT_PROFILER_DRAW")
	package.loaded["tick_profiler"] = nil
end

callbacks.Unregister("Draw", "PROJ_AIMBOT_PROFILER_DRAW")
callbacks.Register("Draw", "PROJ_AIMBOT_PROFILER_DRAW", drawOverlay)
callbacks.Register("Unload", onUnload)

return TickProfiler
