local AimCalculator = {}

local Config = require("config")
local Utils = require("utils")

local clamp = Utils.clamp
local DEFAULT_GRAVITY = Config.physics.default_gravity
local DEFAULT_BASE_SPEED = Config.physics.sticky_base_speed
local DEFAULT_MAX_SPEED = Config.physics.sticky_max_speed
local DEFAULT_UPWARD_VEL = Config.physics.sticky_upward_vel

local MAX_ACCEPTABLE_ERROR = 100

-- Calculate maximum ballistic range for projectile
-- Uses basic physics: d_max = v^2 / g at optimal 45° angle
local function calculateMaxRange(forwardSpeed, upwardVel, gravity)
	-- Total velocity magnitude at max charge
	local totalSpeed = math.sqrt(forwardSpeed * forwardSpeed + upwardVel * upwardVel)

	-- Maximum range at 45°: d_max = v^2 / g
	local maxRange = (totalSpeed * totalSpeed) / gravity

	return maxRange
end

local function predictImpactZ(speed, pitchDeg, upwardVel, gravity, horizontalDist)
	local ang = EulerAngles(pitchDeg, 0, 0)
	local forward = ang:Forward()
	local up = ang:Up()

	local vx = speed * math.sqrt(forward.x * forward.x + forward.y * forward.y)
	local vz = speed * forward.z + upwardVel * up.z

	if vx < 1 then
		return nil
	end
	local t = horizontalDist / vx
	return (vz * t) - (0.5 * gravity * t * t), t
end

local function findPitchInRange(speed, upwardVel, gravity, horizontalDist, targetDz, minPitch, maxPitch)
	local lowP = minPitch
	local highP = maxPitch
	local bestPitch = nil
	local bestError = math.huge

	for _ = 1, 20 do
		local mid = (lowP + highP) * 0.5
		local hitZ = predictImpactZ(speed, mid, upwardVel, gravity, horizontalDist)
		if not hitZ then
			lowP = mid
		else
			local err = hitZ - targetDz
			if math.abs(err) < bestError then
				bestError = math.abs(err)
				bestPitch = mid
			end
			if err > 0 then
				lowP = mid
			else
				highP = mid
			end
		end
	end

	return bestPitch, bestError
end

local function findLowArcPitch(speed, upwardVel, gravity, dx, dz)
	return findPitchInRange(speed, upwardVel, gravity, dx, dz, -89, 89)
end

local function findHighArcPitch(speed, upwardVel, gravity, dx, dz)
	return findPitchInRange(speed, upwardVel, gravity, dx, dz, -89, -45)
end

local function solveChargeWeapon(baseSpeed, maxSpeed, upwardVel, gravity, dx, dz)
	local bestPitch = nil
	local bestCharge = nil
	local bestError = math.huge

	local minChargePitch = nil
	local minChargeVal = nil
	local minChargeErr = math.huge
	do
		local lo, hi = 0.0, 1.0
		for _ = 1, 15 do
			local mid = (lo + hi) * 0.5
			local speed = baseSpeed + mid * (maxSpeed - baseSpeed)
			local pitch, err = findLowArcPitch(speed, upwardVel, gravity, dx, dz)
			if pitch and err < MAX_ACCEPTABLE_ERROR then
				minChargePitch = pitch
				minChargeVal = mid
				minChargeErr = err
				hi = mid
			else
				lo = mid
			end
		end
	end

	local lo, hi = 0.0, 1.0
	for _ = 1, 15 do
		local mid = (lo + hi) * 0.5
		local speed = baseSpeed + mid * (maxSpeed - baseSpeed)
		local pitch, err = findHighArcPitch(speed, upwardVel, gravity, dx, dz)
		if pitch and err < MAX_ACCEPTABLE_ERROR then
			if err < bestError then
				bestError = err
				bestPitch = pitch
				bestCharge = mid
			end
			hi = mid
		else
			lo = mid
		end
	end

	if bestPitch and bestError < MAX_ACCEPTABLE_ERROR then
		return bestPitch, bestCharge, bestError
	end

	return minChargePitch, minChargeVal or 1.0, minChargeErr
end

local function solveFixedSpeedWeapon(speed, upwardVel, gravity, dx, dz)
	local bestPitch = nil
	local bestError = math.huge

	-- Try low arc
	local lowPitch, lowErr = findLowArcPitch(speed, upwardVel, gravity, dx, dz)
	if lowPitch and lowErr < MAX_ACCEPTABLE_ERROR then
		bestPitch = lowPitch
		bestError = lowErr
	end

	-- Try high arc
	local highPitch, highErr = findHighArcPitch(speed, upwardVel, gravity, dx, dz)
	if highPitch and highErr < MAX_ACCEPTABLE_ERROR and highErr < bestError then
		bestPitch = highPitch
		bestError = highErr
	end

	return bestPitch, bestError
end

function AimCalculator.calculateAiming(ctx, targetPos)
	local dx = Utils.distance2D(ctx.eyePos, targetPos)
	local dz = targetPos.z - ctx.eyePos.z

	if ctx.hasCharge then
		return solveChargeWeapon(ctx.baseSpeed, ctx.maxSpeed, ctx.upwardVel, ctx.gravityScale, dx, dz)
	else
		return solveFixedSpeedWeapon(ctx.speed, ctx.upwardVel, ctx.gravityScale, dx, dz)
	end
end

function AimCalculator.getMaxRange(ctx)
	local forwardSpeed = ctx.hasCharge and ctx.maxSpeed or ctx.speed
	return calculateMaxRange(forwardSpeed, ctx.upwardVel, ctx.gravityScale)
end

return AimCalculator
