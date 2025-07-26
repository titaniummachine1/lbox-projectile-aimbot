---@meta

---@class MathLib
local Math = {}

---@param source Vector3
---@param dest Vector3
---@return EulerAngles
function Math.PositionAngles(source, dest) end

---@param vFrom EulerAngles
---@param vTo EulerAngles
---@return number
function Math.AngleFov(vFrom, vTo) end

---@param vec Vector3
---@return Vector3
function Math.NormalizeVector(vec) end

---@param p0 Vector3
---@param p1 Vector3
---@param speed number
---@param gravity number
---@return Vector3|nil
function Math.SolveBallisticArc(p0, p1, speed, gravity) end

---@param shootPos Vector3
---@param targetPos Vector3
---@param speed number
---@return number
function Math.EstimateTravelTime(shootPos, targetPos, speed) end

---@param val number
---@param min number
---@param max number
---@return number
function Math.clamp(val, min, max) end

---@param p0 Vector3
---@param p1 Vector3
---@param speed number
---@param gravity number
---@return number|nil
function Math.GetBallisticFlightTime(p0, p1, speed, gravity) end

---@param direction Vector3
---@return Vector3
function Math.DirectionToAngles(direction) end

---@param offset Vector3
---@param direction Vector3
function Math.RotateOffsetAlongDirection(offset, direction) end

---@param p0 Vector3 Starting position
---@param p1 Vector3 Target position
---@param forward_speed number Forward velocity component
---@param upward_speed number Upward velocity component
---@param gravity number Gravity value
---@return Vector3|nil Aim direction
function Math.SolveBallisticArcWithUpwardVelocity(p0, p1, forward_speed, upward_speed, gravity) end

---@param p0 Vector3 Starting position
---@param p1 Vector3 Target position
---@param forward_speed number Forward velocity component
---@param upward_speed number Upward velocity component
---@param gravity number Gravity value
---@return number|nil Flight time
function Math.GetBallisticFlightTimeWithUpwardVelocity(p0, p1, forward_speed, upward_speed, gravity) end

return Math
