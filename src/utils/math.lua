-- Backward-compatible wrapper for new organized math utils
-- Imports
local Angles = require("utils.math.angles")
local Ballistics = require("utils.math.ballistics")
local VectorMath = require("utils.math.vector")

-- Module declaration
local Math = {}

-- Expose new organized functions with old names for compatibility
Math.PositionAngles = Angles.positionAngles
Math.AngleFov = Angles.angleFov
Math.DirectionToAngles = Angles.directionToAngles
Math.RotateOffsetAlongDirection = Angles.rotateOffsetAlongDirection

Math.SolveBallisticArc = Ballistics.solveBallisticArc
Math.SolveBallisticArcBoth = Ballistics.solveBallisticArcBoth
Math.EstimateTravelTime = Ballistics.estimateTravelTime
Math.GetBallisticFlightTime = Ballistics.getBallisticFlightTime

Math.NormalizeVector = VectorMath.normalize

---@param val number
---@param min number
---@param max number
function Math.clamp(val, min, max)
	return math.max(min, math.min(val, max))
end

return Math
