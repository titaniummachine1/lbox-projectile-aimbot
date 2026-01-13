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
local sections = {} -- { name = { timeRing={}, memRing={}, ringIdx=1, count=0, lastUpdate=0 } }
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
	local currentTick = globals.TickCount()
	display = {}

	for name, sec in pairs(sections) do
		-- auto-hide if not updated for RING_SIZE ticks
		if currentTick - sec.lastUpdate < RING_SIZE then
			local tAvg, tPeak = calcRingStats(sec.timeRing, sec.count)
			local mAvg, mPeak = calcRingStats(sec.memRing, sec.count)

			tAvg = tAvg * 1000000 -- to microseconds
			tPeak = tPeak * 1000000

			local isHighTime = tAvg > 1
			-- Smart score:
			-- For High-Time: Time takes precedence, but significant memory outweighs it.
			-- Scaling: 1 KB allocation = 10 us "cost" weight.
			local score = isHighTime and (tAvg + (mAvg / 1024) * 10) or mAvg

			table.insert(display, {
				name = name,
				tAvg = tAvg,
				tPeak = tPeak,
				mAvg = mAvg,
				mPeak = mPeak,
				score = score,
				isHighTime = isHighTime,
			})
		end
	end

	table.sort(display, function(a, b)
		-- Group High-Time above Low-Time
		if a.isHighTime ~= b.isHighTime then
			return a.isHighTime
		end
		-- Within group, sort by calculated score
		return a.score > b.score
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

	-- Layout Config
	local x, yIdx = 16, 16 -- Starting top-left
	local colWidths = { 70, 70, 15, 75, 75, 15, 300 }
	local rowHeight = 18
	local padding = 6

	-- Calculate total dimensions
	local totalHeight = (#display + 3) * rowHeight + (padding * 2)
	local totalWidth = 0
	for _, w in ipairs(colWidths) do
		totalWidth = totalWidth + w
	end

	-- Draw Main Background (Glass-like)
	draw.Color(20, 20, 20, 200) -- Dark translucency
	draw.FilledRect(x, yIdx, x + totalWidth + padding * 2, yIdx + totalHeight)
	draw.Color(60, 60, 60, 255) -- Border
	draw.OutlinedRect(x, yIdx, x + totalWidth + padding * 2, yIdx + totalHeight)

	local curX, curY = x + padding, yIdx + padding

	-- 1. Reserve Space for Global Header (Drawn at end)
	curY = curY + rowHeight

	-- 2. Draw Table Header
	draw.Color(40, 40, 40, 255)
	draw.FilledRect(x + 2, curY - 2, x + totalWidth + (padding * 2) - 2, curY + rowHeight - 4)

	draw.SetFont(fontSmall)
	draw.Color(200, 200, 200, 255)
	local hX = curX
	draw.Text(hX, curY, "Avg Time")
	hX = hX + colWidths[1]
	draw.Text(hX, curY, "Peak Time")
	hX = hX + colWidths[2] + colWidths[3]
	draw.Text(hX, curY, "Avg Mem")
	hX = hX + colWidths[4]
	draw.Text(hX, curY, "Peak Mem")
	hX = hX + colWidths[5] + colWidths[6]
	draw.Text(hX, curY, "Section Name")

	curY = curY + rowHeight

	-- 3. Draw Entries
	draw.SetFont(font)
	local totalMeasuredMem = 0
	for i, e in ipairs(display) do
		totalMeasuredMem = totalMeasuredMem + e.mAvg

		-- Row Highlight
		if i % 2 == 0 then
			draw.Color(35, 35, 35, 150)
			draw.FilledRect(x + 2, curY - 2, x + totalWidth + (padding * 2) - 2, curY + rowHeight - 2)
		end

		local tColor = getTimeColor(e.tAvg)
		local mColor = getMemColor(e.mAvg)

		local eX = curX
		-- Time
		draw.Color(table.unpack(tColor))
		draw.Text(eX, curY, formatTime(e.tAvg))
		eX = eX + colWidths[1]
		draw.Color(160, 160, 160, 255)
		draw.Text(eX, curY, formatTime(e.tPeak))

		eX = eX + colWidths[2]
		draw.Color(80, 80, 80, 255)
		draw.Text(eX, curY, "|")

		-- Mem
		eX = eX + colWidths[3]
		draw.Color(table.unpack(mColor))
		draw.Text(eX, curY, formatMemory(e.mAvg))
		eX = eX + colWidths[4]
		draw.Color(160, 160, 160, 255)
		draw.Text(eX, curY, formatMemory(e.mPeak))

		eX = eX + colWidths[5]
		draw.Color(80, 80, 80, 255)
		draw.Text(eX, curY, "|")

		-- Name
		eX = eX + colWidths[6]
		draw.Color(255, 255, 255, 255)
		draw.Text(eX, curY, e.name)

		curY = curY + rowHeight
	end

	-- 4. Draw Global Stats (Now that we have totalMeasuredMem)
	draw.SetFont(fontSmall)
	local memUsed = collectgarbage("count") * 1024
	local allocAvg, _ = calcRingStats(allocRingBuffer, RING_SIZE)
	local ratePerSec = allocAvg * 66

	draw.Color(255, 200, 50, 255)
	local globalStr = string.format(
		"LUA: %s | MEASURED: %s | RATE: %s/s",
		formatMemory(memUsed),
		formatMemory(totalMeasuredMem),
		formatMemory(ratePerSec)
	)
	draw.Text(curX, yIdx + padding, globalStr)
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
		sec = { timeRing = {}, memRing = {}, ringIdx = 1, count = 0, lastUpdate = 0 }
		for i = 1, RING_SIZE do
			sec.timeRing[i], sec.memRing[i] = 0, 0
		end
		sections[name] = sec
	end

	sec.timeRing[sec.ringIdx] = elapsed
	sec.memRing[sec.ringIdx] = memDelta
	sec.ringIdx = (sec.ringIdx % RING_SIZE) + 1
	sec.count = math.min(sec.count + 1, RING_SIZE)
	sec.lastUpdate = globals.TickCount()

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
