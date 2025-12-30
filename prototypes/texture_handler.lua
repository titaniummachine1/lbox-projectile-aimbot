-------------------------------
-- OPTIMIZED TEXTURE HANDLER FOR TF2/LMAOBOX
-- Based on https://github.com/titaniummachine1/lua-image-embeding
-------------------------------

local function createTextureFromBase64(base64Data)
	assert(base64Data, "createTextureFromBase64: base64Data missing")

	-- Optimized Base64 decoder with lookup table (from repository)
	local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local b64_lookup = {}
	for i = 1, #b64_chars do
		b64_lookup[b64_chars:sub(i, i)] = i - 1
	end

	local function base64_decode(data)
		-- Remove whitespace and padding
		data = data:gsub("%s+", ""):gsub("=+$", "")

		local decoded = {}
		local padding = (4 - (#data % 4)) % 4

		-- Process 4 characters at a time
		for i = 1, #data, 4 do
			local chunk = data:sub(i, i + 3)
			local n = 0

			-- Convert 4 base64 chars to 24-bit number
			for j = 1, #chunk do
				local char = chunk:sub(j, j)
				local val = b64_lookup[char]
				if val then
					n = n * 64 + val
				end
			end

			-- Extract 3 bytes from 24-bit number (Lua 5.1 compatible)
			if #chunk >= 2 then
				decoded[#decoded + 1] = string.char(math.floor(n / 65536) % 256)
			end
			if #chunk >= 3 then
				decoded[#decoded + 1] = string.char(math.floor(n / 256) % 256)
			end
			if #chunk >= 4 then
				decoded[#decoded + 1] = string.char(n % 256)
			end
		end

		return table.concat(decoded)
	end

	-- Decode base64 to raw bytes
	local rawData = base64_decode(base64Data)
	assert(rawData and #rawData >= 8, "createTextureFromBase64: invalid base64 data")

	-- Extract dimensions from first 8 bytes (big-endian uint32s)
	local width = (rawData:byte(1) * 16777216) + (rawData:byte(2) * 65536) + (rawData:byte(3) * 256) + rawData:byte(4)
	local height = (rawData:byte(5) * 16777216) + (rawData:byte(6) * 65536) + (rawData:byte(7) * 256) + rawData:byte(8)

	assert(width > 0 and height > 0, "createTextureFromBase64: invalid dimensions")

	-- Extract RGBA pixel data (skip 8-byte header)
	local rgbaData = rawData:sub(9)

	-- Validate data length
	local expectedLength = width * height * 4
	assert(
		#rgbaData == expectedLength,
		string.format("createTextureFromBase64: expected %d bytes, got %d", expectedLength, #rgbaData)
	)

	-- Create texture using TF2/Lmaobox API
	local texture = draw.CreateTextureRGBA(rgbaData, width, height)
	assert(texture, "createTextureFromBase64: failed to create texture")

	return texture, width, height
end

local function drawTexture(texture, x, y, width, height, r, g, b, a)
	assert(texture, "drawTexture: texture missing")
	assert(width > 0 and height > 0, "drawTexture: invalid dimensions")

	-- Set color (default white)
	draw.Color(r or 255, g or 255, b or 255, a or 255)

	-- Draw textured rectangle
	draw.TexturedRect(texture, x, y, x + width, y + height)
end

-- Example usage with embedded texture data
local function exampleUsage()
	-- Base64-encoded RGBA image data (replace with your actual image)
	local base64Image = [[
		-- Paste your Base64 string here from the Python script
	]]

	-- Create texture once
	local texture, texWidth, texHeight = createTextureFromBase64(base64Image)

	-- Draw function
	local function drawEmbeddedTexture()
		local x, y = 100, 100 -- Position
		drawTexture(texture, x, y, texWidth, texHeight)
	end

	-- Register for drawing
	callbacks.Register("Draw", "RenderEmbeddedTexture", drawEmbeddedTexture)
end

-- Export functions
return {
	createTextureFromBase64 = createTextureFromBase64,
	drawTexture = drawTexture,
	exampleUsage = exampleUsage,
}
