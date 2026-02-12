-- Simple 1D Kalman Filter
local KalmanFilter = {}
KalmanFilter.__index = KalmanFilter

function KalmanFilter:new(q, r, initialVal, initialP)
	return setmetatable({
		Q = q or 1, -- Process noise covariance
		R = r or 10, -- Measurement noise covariance
		x = initialVal or 0, -- Value (state)
		P = initialP or 1000, -- Estimation error covariance
	}, KalmanFilter)
end

function KalmanFilter:predict(u, Q)
	-- Prediction update: x = x + u, P = P + Q
	self.x = self.x + (u or 0)
	self.P = self.P + (Q or self.Q)
end

function KalmanFilter:update(z, R)
	-- Measurement update
	-- K = P / (P + R)
	local K = self.P / (self.P + (R or self.R))

	-- x = x + K * (z - x)
	self.x = self.x + K * (z - self.x)

	-- P = (1 - K) * P
	self.P = (1 - K) * self.P

	return self.x
end

-- 3D Vector Kalman Filter (wraps 3 independent 1D filters)
local VectorKalman = {}
VectorKalman.__index = VectorKalman

function VectorKalman:new(q, r, initialVec)
	local v = initialVec or Vector3(0, 0, 0)
	return setmetatable({
		kx = KalmanFilter:new(q, r, v.x),
		ky = KalmanFilter:new(q, r, v.y),
		kz = KalmanFilter:new(q, r, v.z),
	}, VectorKalman)
end

function VectorKalman:predict(vec)
	self.kx:predict(vec and vec.x)
	self.ky:predict(vec and vec.y)
	self.kz:predict(vec and vec.z)
end

function VectorKalman:update(vec)
	local x = self.kx:update(vec.x)
	local y = self.ky:update(vec.y)
	local z = self.kz:update(vec.z)
	return Vector3(x, y, z)
end

local Kalman = {
	KalmanFilter = KalmanFilter,
	VectorKalman = VectorKalman,
}

return Kalman
