local State = {}

State.camera = {
	pathPercent = 0.5,
	smoothedAngles = EulerAngles(0, 0, 0),
	smoothedPos = Vector3(0, 0, 0),
	isDragging = false,
	dragOffsetX = 0,
	dragOffsetY = 0,
	materialsReady = false,
	texture = nil,
	material = nil,
	storedPositions = {},
	storedVelocities = {},
	lastView = nil,
	active = false,
	lastKeyState = false,
	storedImpactPos = nil,
	storedImpactPlane = nil,
	storedFlagOffset = Vector3(0, 0, 0),
}

State.trajectory = {
	positions = {},
	velocities = {},
	impactPos = nil,
	impactPlane = nil,
	flagOffset = Vector3(0, 0, 0),
	isValid = false,
}

State.bombard = {
	active = false,
	lockedYaw = 0,
	lockedDistance = 500,
	lockedOrigin = nil,
	targetZHeight = 0,
	lastValidZHeight = 0,
	highGroundHeld = false,
	chargeLevel = 0.5,
	useStoredCharge = false,
	calculatedPitch = nil,
	originPoint = nil,
	targetPoint = nil,
}

State.input = {
	lastActivateState = false,
	lastHighGroundState = false,
}

State.physicsEnv = nil

return State
