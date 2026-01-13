-- Imports

-- Module declaration
local TickProfiler = {}

-- Local constants / utilities -----
local sections = {}
local stacks = {}
local acc = {}
local display = {}
local enabled = false
local lastSnapshot = 0

local SNAPSHOT_INTERVAL = 10
local SMOOTHING_FACTOR = 0.1
local SORT_DELAY = 33
local lastSortTime = 0
local lastMemCheck = collectgarbage("count") * 1024
local totalAllocatedLastSecond = 0
local allocRate = 0
local lastAllocReset = 0

local font = draw.CreateFont("Tahoma", 12, 600, FONTFLAG_OUTLINE)
local fontSmall = draw.CreateFont("Tahoma", 11, 400, FONTFLAG_OUTLINE)
local overlayPadding = 12

local COLORS = {
	GREY = { 150, 150, 150, 255 },
	WHITE = { 255, 255, 255, 255 },
	YELLOW = { 255, 200, 50, 255 },
	RED = { 255, 50, 50, 255 },
	GREEN = { 100, 255, 100, 255 },
}

-- Private helpers -----
local function lerpColor(t, c1, c2)
	return {
		math.floor(c1[1] + (c2[1] - c1[1]) * t),
		math.floor(c1[2] + (c2[2] - c1[2]) * t),
		math.floor(c1[3] + (c2[3] - c1[3]) * t),
		255,
	}
end

local function getColorForValue(val, t1, t2, t3)
	if val <= t1 then
		local t = val / t1
		return lerpColor(t, COLORS.GREY, COLORS.WHITE)
	elseif val <= t2 then
		local t = (val - t1) / (t2 - t1)
		return lerpColor(t, COLORS.WHITE, COLORS.YELLOW)
	else
		local t = math.min(1, (val - t2) / (t3 - t2))
		return lerpColor(t, COLORS.YELLOW, COLORS.RED)
	end
end

local function now()
	return os.clock()
end

local function reset()
	sections = {}
	stacks = {}
	acc = {}
	display = {}
end

local function formatTime(microseconds)
	if microseconds >= 1000 then
		return string.format("%6.2f ms", microseconds / 1000)
	else
		return string.format("%6.0f µs", microseconds)
	end
end

local function formatMemory(bytes)
	local sign = bytes < 0 and "-" or " "
	local absBytes = math.abs(bytes)

	if absBytes >= 1024 * 1024 then
		return string.format("%s%5.2f MB", sign, absBytes / (1024 * 1024))
	elseif absBytes >= 1024 then
		return string.format("%s%5.2f KB", sign, absBytes / 1024)
	else
		return string.format("%s%5.0f B ", sign, absBytes)
	end
end

local function buildEntries()
	local currentTick = globals.TickCount()

	if currentTick - lastSnapshot >= SNAPSHOT_INTERVAL then
		lastSnapshot = currentTick

		for name, data in pairs(acc) do
			local avg = data.samples > 0 and (data.total / data.samples) or 0
			local memAvg = data.samples > 0 and (data.memTotal / data.samples) or 0

			data.dispAvg = data.dispAvg + (avg - data.dispAvg) * SMOOTHING_FACTOR
			data.dispPeak = data.dispPeak + (data.peak - data.dispPeak) * SMOOTHING_FACTOR
			data.dispMemAvg = data.dispMemAvg + (memAvg - data.dispMemAvg) * SMOOTHING_FACTOR
			data.dispMemPeak = data.dispMemPeak + (data.memPeak - data.dispMemPeak) * SMOOTHING_FACTOR

			data.total = 0
			data.samples = 0
			data.peak = 0
			data.memTotal = 0
			data.memPeak = 0
		end
	end

	if currentTick - lastSortTime >= SORT_DELAY then
		lastSortTime = currentTick
		display = {}

		for name, data in pairs(acc) do
			display[#display + 1] = {
				name = name,
				timeAvg = data.dispAvg * 1000000,
				timePeak = data.dispPeak * 1000000,
				memAvg = data.dispMemAvg,
				memPeak = data.dispMemPeak,
			}
		end

		table.sort(display, function(a, b)
			if math.abs(a.timeAvg - b.timeAvg) > 10 then
				return a.timeAvg > b.timeAvg
			end
			return a.memAvg > b.memAvg
		end)
	end

	-- Update Global Allocation Rate
	local currentMem = collectgarbage("count") * 1024
	if currentMem > lastMemCheck then
		totalAllocatedLastSecond = totalAllocatedLastSecond + (currentMem - lastMemCheck)
	end
	lastMemCheck = currentMem

	local nowTime = now()
	if nowTime - lastAllocReset >= 1.0 then
		allocRate = totalAllocatedLastSecond
		totalAllocatedLastSecond = 0
		lastAllocReset = nowTime
	end

	return display
end

local function drawOverlay()
	if not enabled then
		return
	end
	if engine.IsGameUIVisible() or engine.Con_IsVisible() then
		return
	end

	local entries = buildEntries()
	if #entries == 0 then
		return
	end

	draw.SetFont(font)
	local screenW, screenH = draw.GetScreenSize()
	local x = overlayPadding
	local lineHeight = 14

	local headerHeight = lineHeight + 4
	local statsHeight = lineHeight + 4
	local entriesHeight = #entries * lineHeight
	local totalHeight = entriesHeight + headerHeight + statsHeight + overlayPadding

	local y = screenH - overlayPadding
	local minY = overlayPadding + totalHeight

	if minY > screenH then
		y = totalHeight
	end

	local totalMeasuredMem = 0
	for _, entry in ipairs(entries) do
		totalMeasuredMem = totalMeasuredMem + entry.memAvg
	end

	for i = #entries, 1, -1 do
		local entry = entries[i]

		local timeColor = getColorForValue(entry.timeAvg, 50, 500, 2000)
		local memColor = entry.memAvg < 0 and COLORS.GREEN or getColorForValue(entry.memAvg, 100, 1024, 10240)

		local tAvgStr = formatTime(entry.timeAvg)
		local tPeakStr = formatTime(entry.timePeak)
		local mAvgStr = formatMemory(entry.memAvg)
		local mPeakStr = formatMemory(entry.memPeak)

		local curX = x

		draw.Color(timeColor[1], timeColor[2], timeColor[3], 255)
		draw.Text(curX, y, tAvgStr)
		curX = curX + 70

		draw.Color(150, 150, 150, 255)
		draw.Text(curX, y, tPeakStr)
		curX = curX + 70

		draw.Color(100, 100, 100, 255)
		draw.Text(curX, y, "|")
		curX = curX + 15

		draw.Color(memColor[1], memColor[2], memColor[3], 255)
		draw.Text(curX, y, mAvgStr)
		curX = curX + 70

		draw.Color(150, 150, 150, 255)
		draw.Text(curX, y, mPeakStr)
		curX = curX + 70

		draw.Color(100, 100, 100, 255)
		draw.Text(curX, y, "|")
		curX = curX + 15

		draw.Color(255, 255, 255, 255)
		draw.Text(curX, y, entry.name)

		y = y - lineHeight
	end

	y = y - lineHeight - 4
	draw.SetFont(fontSmall)
	draw.Color(200, 200, 200, 255)

	local curX = x
	draw.Text(curX, y, "Time Avg")
	curX = curX + 70
	draw.Text(curX, y, "Time Peak")
	curX = curX + 85
	draw.Text(curX, y, "Mem Avg")
	curX = curX + 70
	draw.Text(curX, y, "Mem Peak")
	curX = curX + 85
	draw.Text(curX, y, "Section Name")

	y = y - lineHeight - 4
	local memUsed = collectgarbage("count") * 1024
	local memStr = string.format(
		"Lua Total: %s | Measured: %s | Rate: %s/s",
		formatMemory(memUsed),
		formatMemory(totalMeasuredMem),
		formatMemory(allocRate)
	)
	draw.Color(255, 200, 100, 255)
	draw.Text(x, y, memStr)
end

-- Public API ----
function TickProfiler.SetEnabled(state)
	local shouldEnable = state == true
	if shouldEnable == enabled then
		return
	end

	enabled = shouldEnable

	if not enabled then
		reset()
	end
end

function TickProfiler.IsEnabled()
	return enabled
end

function TickProfiler.BeginSection(name)
	if not enabled then
		return
	end

	local stack = stacks[name]
	if not stack then
		stack = {}
		stacks[name] = stack
	end

	local startTime = now()
	local startMem = collectgarbage("count") * 1024
	stack[#stack + 1] = { time = startTime, mem = startMem }
end

function TickProfiler.EndSection(name)
	if not enabled then
		return
	end

	local stack = stacks[name]
	if not stack or #stack == 0 then
		return
	end

	local startData = stack[#stack]
	stack[#stack] = nil

	local elapsed = now() - startData.time
	if elapsed < 0 then
		elapsed = 0
	end

	local endMem = collectgarbage("count") * 1024
	local memDelta = endMem - startData.mem

	local section = acc[name]
	if not section then
		section = {
			total = 0,
			samples = 0,
			peak = 0,
			memTotal = 0,
			memPeak = 0,
			dispAvg = 0,
			dispPeak = 0,
			dispMemAvg = 0,
			dispMemPeak = 0,
		}
		acc[name] = section
	end

	section.total = section.total + elapsed
	section.samples = section.samples + 1
	if elapsed > section.peak then
		section.peak = elapsed
	end

	section.memTotal = section.memTotal + memDelta
	if memDelta > section.memPeak then
		section.memPeak = memDelta
	end
end

function TickProfiler.Measure(name, fn, ...)
	if not enabled then
		return fn(...)
	end
	if type(fn) ~= "function" then
		return
	end

	TickProfiler.BeginSection(name)
	local results = { pcall(fn, ...) }
	TickProfiler.EndSection(name)

	if not results[1] then
		error(results[2])
	end

	return table.unpack(results, 2)
end

function TickProfiler.Reset()
	reset()
end

function TickProfiler.GetSections()
	return acc
end

-- Callbacks -----
callbacks.Unregister("Draw", "PROJ_AIMBOT_PROFILER_DRAW")
callbacks.Register("Draw", "PROJ_AIMBOT_PROFILER_DRAW", drawOverlay)

return TickProfiler
