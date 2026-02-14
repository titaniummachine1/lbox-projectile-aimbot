--[[ Swing prediction for  Lmaobox  ]] --
--[[          --Authors--           ]] --
--[[           Terminator           ]] --
--[[  (github.com/titaniummachine1  ]] --


-- Unload the module if it's already loaded
if package.loaded["ImMenu"] then
    package.loaded["ImMenu"] = nil
end

-- Initialize libraries
local lnxLib = require("lnxlib")
local ImMenu = require("immenu")

local DEBUG_PROFILER = false

local function NoOpProfilerCall()
end

local Profiler
if DEBUG_PROFILER then
    Profiler = require("Profiler")
    Profiler.SetVisible(true)
else
    Profiler = {
        BeginSystem = NoOpProfilerCall,
        EndSystem = NoOpProfilerCall,
        Begin = NoOpProfilerCall,
        End = NoOpProfilerCall,
        Draw = NoOpProfilerCall,
        SetVisible = NoOpProfilerCall,
    }
end

local Math, Conversion = lnxLib.Utils.Math, lnxLib.Utils.Conversion
local WPlayer, WWeapon = lnxLib.TF2.WPlayer, lnxLib.TF2.WWeapon
local Helpers = lnxLib.TF2.Helpers
--local Prediction = lnxLib.TF2.Prediction
--local Fonts = lnxLib.UI.Fonts
local Input = lnxLib.Utils.Input
local Notify = lnxLib.UI.Notify

-- Player list fetched fresh each tick via entities.FindByClass("CTFPlayer")

-- ============================================================================
-- VECTOR HELPERS (defined first for use throughout)
-- ============================================================================
local vectorDivide = vector.Divide
local vectorLength = vector.Length
local vectorDistance = vector.Distance

--- Normalize vector (fastest method)
local function Normalize(vec)
    return vectorDivide(vec, vectorLength(vec))
end

--- Distance 2D using vector Length2D
local function Distance2D(a, b)
    return (a - b):Length2D()
end

--- Distance 3D (fastest possible in Lua)
local function Distance3D(a, b)
    return vectorDistance(a, b)
end

--- Cross product of two vectors
local function Cross(a, b)
    return a:Cross(b)
end

--- Dot product of two vectors
local function Dot(a, b)
    return a:Dot(b)
end

--- 2D vector length (horizontal only)
local function Length2D(vec)
    return vec:Length2D()
end

-- ============================================================================
-- ADVANCED SIMULATION SYSTEM INTEGRATION
-- ============================================================================
-- Strafe prediction system for perfect wishdir resolution
local StrafePredictor = {}
StrafePredictor.velocityHistory = {}

function StrafePredictor.recordVelocity(entityIndex, velocity, maxSamples)
    assert(entityIndex, "StrafePredictor: entityIndex is nil")
    assert(velocity, "StrafePredictor: velocity is nil")

    if not StrafePredictor.velocityHistory[entityIndex] then
        StrafePredictor.velocityHistory[entityIndex] = {}
    end

    local history = StrafePredictor.velocityHistory[entityIndex]
    table.insert(history, 1, Vector3(velocity:Unpack()))

    maxSamples = maxSamples or 10
    while #history > maxSamples do
        table.remove(history)
    end
end

function StrafePredictor.calculateAverageYawChange(entityIndex, minSamples)
    local history = StrafePredictor.velocityHistory[entityIndex]
    if not history or #history < (minSamples or 3) then
        return nil
    end

    local maxDeltaPerTickRad = math.rad(45)
    local minSpeedForSample = 25

    local deltas = {}
    local deltaCount = 0

    for i = 1, #history - 1 do
        local vel1 = history[i]
        local vel2 = history[i + 1]

        if vel1:Length2D() >= minSpeedForSample and vel2:Length2D() >= minSpeedForSample then
            local yaw1 = math.atan(vel1.y, vel1.x)
            local yaw2 = math.atan(vel2.y, vel2.x)

            local diff = yaw1 - yaw2
            while diff > math.pi do
                diff = diff - 2 * math.pi
            end
            while diff < -math.pi do
                diff = diff + 2 * math.pi
            end

            if math.abs(diff) <= maxDeltaPerTickRad then
                deltaCount = deltaCount + 1
                deltas[deltaCount] = diff
            end
        end
    end

    if deltaCount < (minSamples or 3) then
        return nil
    end

    -- Reject if deltas flip sign (left/right dodging, not consistent strafing)
    local posCount = 0
    local negCount = 0
    local totalYawChange = 0
    for i = 1, deltaCount do
        local d = deltas[i]
        totalYawChange = totalYawChange + d
        if d > 0.01 then
            posCount = posCount + 1
        elseif d < -0.01 then
            negCount = negCount + 1
        end
    end

    -- If both positive and negative deltas exist, direction is inconsistent
    local signedSamples = posCount + negCount
    if signedSamples > 0 then
        local dominantRatio = math.max(posCount, negCount) / signedSamples
        if dominantRatio < 0.6 then
            return nil
        end
    end

    return totalYawChange / deltaCount
end

function StrafePredictor.getYawDeltaPerTickDegrees(entityIndex, minSamples)
    local avgYawChangeRad = StrafePredictor.calculateAverageYawChange(entityIndex, minSamples or 3)
    if not avgYawChangeRad then
        return 0
    end
    return avgYawChangeRad * (180 / math.pi)
end

function StrafePredictor.updateAll(entities, maxSamples)
    for _, entity in pairs(entities) do
        if entity:IsAlive() and not entity:IsDormant() then
            local velocity = entity:EstimateAbsVelocity()
            if velocity and velocity:Length2D() > 1 then
                StrafePredictor.recordVelocity(entity:GetIndex(), velocity, maxSamples)
            end
        else
            StrafePredictor.velocityHistory[entity:GetIndex()] = nil
        end
    end
end

function StrafePredictor.clearHistory(entityIndex)
    StrafePredictor.velocityHistory[entityIndex] = nil
end

-- Enhanced wishdir tracker for 9-direction prediction
local WishdirTracker = {}
WishdirTracker.state = {}
WishdirTracker.MAX_TRACKED = 4
WishdirTracker.EXPIRY_TICKS = 66
WishdirTracker.STILL_SPEED_THRESHOLD = 50

WishdirTracker.DIRECTIONS = {
    { name = "forward",      x = 450,  y = 0 },
    { name = "forwardright", x = 450,  y = -450 },
    { name = "right",        x = 0,    y = -450 },
    { name = "backright",    x = -450, y = -1 },
    { name = "back",         x = -450, y = 0 },
    { name = "backleft",     x = -450, y = 450 },
    { name = "left",         x = 0,    y = 450 },
    { name = "forwardleft",  x = 450,  y = 450 },
    { name = "coast",        x = 0,    y = 0 },
}

function WishdirTracker.normalizeDirection(x, y)
    local len = math.sqrt(x * x + y * y)
    if len < 0.0001 then
        return Vector3(0, 0, 0)
    end
    return Vector3(x / len, y / len, 0)
end

function WishdirTracker.getEntityYaw(entity)
    if not entity then
        return nil
    end
    local yaw = entity:GetPropFloat("m_angEyeAngles[1]")
    if yaw then
        return yaw
    end
    if entity.GetPropVector and type(entity.GetPropVector) == "function" then
        local eyeVec = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles")
        if eyeVec and eyeVec.y then
            return eyeVec.y
        end
    end
    return nil
end

function WishdirTracker.clampVelocityTo8Directions(velocity, yaw)
    local horizLen = Length2D(velocity)
    if horizLen < WishdirTracker.STILL_SPEED_THRESHOLD then
        return Vector3(0, 0, 0)
    end

    local yawRad = yaw * (math.pi / 180)
    local cosYaw = math.cos(yawRad)
    local sinYaw = math.sin(yawRad)

    local forward = Vector3(cosYaw, sinYaw, 0)
    local right = Vector3(sinYaw, -cosYaw, 0)

    local velNormX = velocity.x / horizLen
    local velNormY = velocity.y / horizLen
    local velNorm = Vector3(velNormX, velNormY, 0)
    local relForward = Dot(forward, velNorm)
    local relRight = Dot(right, velNorm)

    local snapX = 0
    local snapY = 0
    if relForward > 0.3 then
        snapX = 1
    elseif relForward < -0.3 then
        snapX = -1
    end
    if relRight > 0.3 then
        snapY = -1
    elseif relRight < -0.3 then
        snapY = 1
    end

    return WishdirTracker.normalizeDirection(snapX, snapY)
end

function WishdirTracker.update(entity)
    if not entity or not entity:IsAlive() or entity:IsDormant() then
        return
    end

    local idx = entity:GetIndex()
    if not WishdirTracker.state[idx] then
        WishdirTracker.state[idx] = {}
    end
    local s = WishdirTracker.state[idx]

    local currentPos = entity:GetAbsOrigin()
    local currentVel = entity:EstimateAbsVelocity()
    local currentYaw = WishdirTracker.getEntityYaw(entity)
    local currentTick = globals.TickCount()

    if not (currentPos and currentVel and currentYaw) then
        return
    end

    local function getHorizontalError(a, b)
        local dx = a.x - b.x
        local dy = a.y - b.y
        return dx * dx + dy * dy
    end

    local detectedWishdir = nil
    local cachedPredictions = s.predictions
    if cachedPredictions and cachedPredictions.targetTick == currentTick then
        local bestScore = math.huge
        local bestVelDot = -2
        local entries = cachedPredictions.entries
        if entries then
            -- Precompute velocity direction for tiebreaker
            local velDirX, velDirY = 0, 0
            local horizLen = Length2D(currentVel)
            if horizLen > 1 then
                velDirX = currentVel.x / horizLen
                velDirY = currentVel.y / horizLen
            end

            for i = 1, #entries do
                local candidate = entries[i]
                local posError = getHorizontalError(candidate.pos, currentPos)
                local velError = getHorizontalError(candidate.vel, currentVel)
                local score = posError + velError

                -- Velocity-direction tiebreaker: dot product of candidate dir with velocity
                local dirDot = candidate.dir.x * velDirX + candidate.dir.y * velDirY

                local dominated = score < bestScore * 0.99
                local tied = (not dominated) and score < bestScore * 1.01
                if dominated or (tied and dirDot > bestVelDot) then
                    bestScore = score
                    bestVelDot = dirDot
                    detectedWishdir = candidate.dir
                end
            end
        end
    end

    local horizLen = Length2D(currentVel)
    if not detectedWishdir then
        detectedWishdir = Vector3(0, 0, 0)
        if horizLen >= WishdirTracker.STILL_SPEED_THRESHOLD then
            detectedWishdir = WishdirTracker.clampVelocityTo8Directions(currentVel, currentYaw)
        elseif s.lastPos then
            local movementDelta = currentPos - s.lastPos
            local movementHorizLen = Length2D(movementDelta)
            if movementHorizLen > 1.0 then
                detectedWishdir = WishdirTracker.clampVelocityTo8Directions(movementDelta, currentYaw)
            end
        end
    elseif horizLen < WishdirTracker.STILL_SPEED_THRESHOLD then
        detectedWishdir = Vector3(0, 0, 0)
    end

    s.detectedWishdir = detectedWishdir
    s.lastPos = currentPos
    s.lastVel = currentVel
    s.lastYaw = currentYaw
    s.lastTick = currentTick

    local okCtx, playerCtx = pcall(createPlayerContext, entity, detectedWishdir)
    if not okCtx or not playerCtx then
        s.predictions = nil
        return
    end

    local simCtx = createSimulationContext()
    s.predictions = {
        targetTick = currentTick + 1,
        entries = simulateWishdirCandidates(playerCtx, simCtx),
    }
end

function WishdirTracker.updateLight(entity)
    if not entity or not entity:IsAlive() or entity:IsDormant() then
        return
    end

    local idx = entity:GetIndex()
    if not WishdirTracker.state[idx] then
        WishdirTracker.state[idx] = {}
    end
    local s = WishdirTracker.state[idx]

    local currentPos = entity:GetAbsOrigin()
    local currentVel = entity:EstimateAbsVelocity()
    local currentYaw = WishdirTracker.getEntityYaw(entity) or 0
    local currentTick = globals.TickCount()
    if not (currentPos and currentVel) then
        return
    end

    local detectedWishdir = Vector3(0, 0, 0)
    local horizLen = Length2D(currentVel)
    if horizLen >= WishdirTracker.STILL_SPEED_THRESHOLD then
        detectedWishdir = WishdirTracker.clampVelocityTo8Directions(currentVel, currentYaw)
    elseif s.lastPos then
        local movementDelta = currentPos - s.lastPos
        if Length2D(movementDelta) > 1.0 then
            detectedWishdir = WishdirTracker.clampVelocityTo8Directions(movementDelta, currentYaw)
        end
    end

    s.detectedWishdir = detectedWishdir
    s.lastPos = currentPos
    s.lastVel = currentVel
    s.lastYaw = currentYaw
    s.lastTick = currentTick
    s.predictions = nil
end

function WishdirTracker.getRelativeWishdir(entity)
    if not entity then
        return nil
    end

    local idx = entity:GetIndex()
    local s = WishdirTracker.state[idx]

    if s and s.detectedWishdir and s.lastTick == globals.TickCount() then
        return s.detectedWishdir
    end

    return nil
end

function WishdirTracker.clearAllHistory()
    WishdirTracker.state = {}
end

-- Module-level trace filter to avoid closure allocations
local currentTraceIndex = 0
local currentTraceTeam = -1
local function TraceFilterOtherPlayers(ent)
    if not ent or not ent:IsValid() then
        return false
    end

    if ent:GetIndex() == currentTraceIndex then
        return false
    end

    if ent:IsPlayer() and currentTraceTeam ~= -1 and ent:GetTeamNumber() == currentTraceTeam then
        return false
    end

    return true
end

-- Enhanced PlayerTick simulation system
local PlayerTick = {}
PlayerTick.DEG2RAD = math.pi / 180
PlayerTick.RAD2DEG = 180 / math.pi
PlayerTick.NON_JUMP_VELOCITY = 180.0
PlayerTick.GROUND_CHECK_OFFSET = 66.0
PlayerTick.DIST_EPSILON = 0.03125
PlayerTick.SV_MAXVELOCITY = 3500
PlayerTick.MAX_CLIP_PLANES = 5
PlayerTick.IMPACT_NORMAL_FLOOR = 0.7

local RuneTypes_t = {
    RUNE_NONE = -1,
    RUNE_STRENGTH = 0,
    RUNE_HASTE = 1,
    RUNE_REGEN = 2,
    RUNE_RESIST = 3,
    RUNE_VAMPIRE = 4,
    RUNE_REFLECT = 5,
    RUNE_PRECISION = 6,
    RUNE_AGILITY = 7,
    RUNE_KNOCKOUT = 8,
    RUNE_KING = 9,
    RUNE_PLAGUE = 10,
    RUNE_SUPERNOVA = 11,
    RUNE_TYPES_MAX = 12,
}

local moveTemp1 = Vector3()
local moveTemp2 = Vector3()
local moveClipPlanes = {}
for i = 1, PlayerTick.MAX_CLIP_PLANES do
    moveClipPlanes[i] = Vector3()
end

-- Note: Length2D is defined in global helpers section

function PlayerTick.rotateDirByAngle(dir, angleDeg)
    local currentAngle = math.atan(dir.y, dir.x) * PlayerTick.RAD2DEG
    local newAngle = (currentAngle + angleDeg) * PlayerTick.DEG2RAD
    dir.x = math.cos(newAngle)
    dir.y = math.sin(newAngle)
    dir.z = 0
end

function PlayerTick.normalizeAngleDeg(angle)
    return ((angle + 180) % 360) - 180
end

function PlayerTick.checkVelocity(velocity, maxvelocity)
    maxvelocity = maxvelocity or PlayerTick.SV_MAXVELOCITY

    if velocity.x > maxvelocity then
        velocity.x = maxvelocity
    end
    if velocity.x < -maxvelocity then
        velocity.x = -maxvelocity
    end
    if velocity.y > maxvelocity then
        velocity.y = maxvelocity
    end
    if velocity.y < -maxvelocity then
        velocity.y = -maxvelocity
    end
    if velocity.z > maxvelocity then
        velocity.z = maxvelocity
    end
    if velocity.z < -maxvelocity then
        velocity.z = -maxvelocity
    end
end

function PlayerTick.checkIsOnGround(origin, velocity, mins, maxs, index)
    if velocity and velocity.z > PlayerTick.NON_JUMP_VELOCITY then
        return false
    end

    moveTemp1.x = origin.x
    moveTemp1.y = origin.y
    moveTemp1.z = origin.z
    moveTemp2.x = origin.x
    moveTemp2.y = origin.y
    moveTemp2.z = origin.z - PlayerTick.GROUND_CHECK_OFFSET

    currentTraceIndex = index
    local trace = engine.TraceHull(moveTemp1, moveTemp2, mins, maxs, MASK_PLAYERSOLID, TraceFilterOtherPlayers)

    if trace and trace.fraction < 0.06 and not trace.startsolid and trace.plane and trace.plane.z >= PlayerTick.IMPACT_NORMAL_FLOOR then
        return true
    end

    return false
end

function PlayerTick.friction(velocity, is_on_ground, frametime, sv_friction, sv_stopspeed, surface_friction)
    surface_friction = surface_friction or 1.0

    local speed = velocity:Length()

    if speed < 0.1 then
        return
    end

    local drop = 0

    if is_on_ground then
        local control = (speed < sv_stopspeed) and sv_stopspeed or speed
        drop = control * sv_friction * surface_friction * frametime
    end

    local newspeed = speed - drop
    if newspeed < 0 then
        newspeed = 0
    end

    if newspeed ~= speed then
        newspeed = newspeed / speed
        velocity.x = velocity.x * newspeed
        velocity.y = velocity.y * newspeed
        velocity.z = velocity.z * newspeed
    end
end

function PlayerTick.accelerate(velocity, wishdir, wishspeed, accel, frametime, surface_friction)
    surface_friction = surface_friction or 1.0

    local currentspeed = velocity:Length()
    local addspeed = wishspeed - currentspeed

    if addspeed <= 0 then
        return
    end

    local accelspeed = math.min(accel * frametime * wishspeed * surface_friction, addspeed)

    velocity.x = velocity.x + wishdir.x * accelspeed
    velocity.y = velocity.y + wishdir.y * accelspeed
    velocity.z = velocity.z + wishdir.z * accelspeed
end

function PlayerTick.getAirSpeedCap(target, suppressCharge)
    if not target then
        return 30.0
    end

    local hookTarget = target:GetPropEntity("m_hGrapplingHookTarget")
    if hookTarget then
        if target.GetCarryingRuneType and target:GetCarryingRuneType() == RuneTypes_t.RUNE_AGILITY then
            local classIndex = target:GetPropInt("m_iClass")
            if classIndex == E_Character.TF2_Soldier or classIndex == E_Character.TF2_Heavy then
                return 850
            end
            return 950
        end
        local _, grappleMoveSpeed = client.GetConVar("tf_grapplinghook_move_speed")
        return grappleMoveSpeed or 30.0
    end

    if not suppressCharge and target:InCond(E_TFCOND.TFCond_Charging) then
        local _, tf_max_charge_speed = client.GetConVar("tf_max_charge_speed")
        return tf_max_charge_speed or 750
    end

    local flCap = 30.0
    if target:InCond(E_TFCOND.TFCond_ParachuteDeployed) then
        local _, parachuteAirControl = client.GetConVar("tf_parachute_aircontrol")
        flCap = flCap * (parachuteAirControl or 1.0)
    end

    if target:InCond(E_TFCOND.TFCond_HalloweenKart) then
        if target:InCond(E_TFCOND.TFCond_HalloweenKartDash) then
            local _, kartDashSpeed = client.GetConVar("tf_halloween_kart_dash_speed")
            return kartDashSpeed or flCap
        end
        local _, kartAirControl = client.GetConVar("tf_hallowen_kart_aircontrol")
        flCap = flCap * (kartAirControl or 1.0)
    end

    local airControlScale = target:AttributeHookFloat("mod_air_control")
    if not airControlScale then
        return flCap
    end
    return flCap * airControlScale
end

function PlayerTick.airAccelerate(v, wishdir, wishspeed, accel, dt, surf, target, suppressCharge)
    wishspeed = math.min(wishspeed, PlayerTick.getAirSpeedCap(target, suppressCharge))

    local currentspeed = v:Length()
    local addspeed = wishspeed - currentspeed
    if addspeed <= 0 then
        return
    end

    local accelspeed = math.min(accel * wishspeed * dt * surf, addspeed)
    v.x = v.x + accelspeed * wishdir.x
    v.y = v.y + accelspeed * wishdir.y
    v.z = v.z + accelspeed * wishdir.z
end

function PlayerTick.clipVelocity(velocity, normal, overbounce)
    local backoff = velocity:Dot(normal)
    if backoff < 0 then
        backoff = backoff * overbounce
    else
        backoff = backoff / overbounce
    end

    velocity.x = velocity.x - normal.x * backoff
    velocity.y = velocity.y - normal.y * backoff
    velocity.z = velocity.z - normal.z * backoff
end

function PlayerTick.tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval, surface_friction)
    local time_left = tickinterval
    local numplanes = 0

    for bumpcount = 0, 3 do
        if velocity:LengthSqr() < 0.0001 then
            break
        end

        moveTemp1.x = origin.x + velocity.x * time_left
        moveTemp1.y = origin.y + velocity.y * time_left
        moveTemp1.z = origin.z + velocity.z * time_left

        currentTraceIndex = index
        local trace = engine.TraceHull(
            origin,
            moveTemp1,
            mins,
            maxs,
            MASK_PLAYERSOLID,
            TraceFilterOtherPlayers
        )

        if trace.allsolid then
            velocity.x = 0
            velocity.y = 0
            velocity.z = 0
            break
        end

        if trace.fraction > 0 then
            origin.x = trace.endpos.x
            origin.y = trace.endpos.y
            origin.z = trace.endpos.z
        end

        if trace.fraction >= 0.99 then
            break
        end

        time_left = time_left * (1 - trace.fraction)

        if numplanes >= PlayerTick.MAX_CLIP_PLANES then
            velocity.x = 0
            velocity.y = 0
            velocity.z = 0
            break
        end

        local plane = moveClipPlanes[numplanes + 1]
        plane.x = trace.plane.x
        plane.y = trace.plane.y
        plane.z = trace.plane.z
        numplanes = numplanes + 1

        local overbounce = (trace.plane.z > 0.7) and 1.0 or (1.0 + (1.0 - (surface_friction or 1.0)) * 0.5)
        PlayerTick.clipVelocity(velocity, plane, overbounce)

        local validVelocity = true
        for i = 1, numplanes do
            local normal = moveClipPlanes[i]
            local planeDot = velocity.x * normal.x + velocity.y * normal.y + velocity.z * normal.z
            if planeDot < 0 then
                validVelocity = false
                break
            end
        end

        if not validVelocity and numplanes >= 2 then
            local plane1 = moveClipPlanes[1]
            local plane2 = moveClipPlanes[2]

            moveTemp2.x = plane1.y * plane2.z - plane1.z * plane2.y
            moveTemp2.y = plane1.z * plane2.x - plane1.x * plane2.z
            moveTemp2.z = plane1.x * plane2.y - plane1.y * plane2.x

            local len = moveTemp2:LengthSqr()
            if len > 0.001 then
                moveTemp2.x = moveTemp2.x / len
                moveTemp2.y = moveTemp2.y / len
                moveTemp2.z = moveTemp2.z / len

                local scalar = velocity.x * moveTemp2.x + velocity.y * moveTemp2.y + velocity.z * moveTemp2.z
                velocity.x = moveTemp2.x * scalar
                velocity.y = moveTemp2.y * scalar
                velocity.z = moveTemp2.z * scalar
            else
                velocity.x = 0
                velocity.y = 0
                velocity.z = 0
            end
        end
    end

    return origin
end

function PlayerTick.stepMove(origin, velocity, mins, maxs, index, tickinterval, stepheight)
    local originalX, originalY, originalZ = origin.x, origin.y, origin.z
    local originalVx, originalVy, originalVz = velocity.x, velocity.y, velocity.z

    PlayerTick.tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval, 1.0)

    local downDistance = (origin.x - originalX) + (origin.y - originalY)

    if downDistance > 5.0 or (originalVx * originalVx + originalVy * originalVy) < 1.0 then
        return origin
    end

    origin.x = originalX
    origin.y = originalY
    origin.z = originalZ
    velocity.x = originalVx
    velocity.y = originalVy
    velocity.z = originalVz

    moveTemp1.x = origin.x
    moveTemp1.y = origin.y
    moveTemp1.z = origin.z + stepheight + PlayerTick.DIST_EPSILON

    currentTraceIndex = index
    local upTrace = engine.TraceHull(origin, moveTemp1, mins, maxs, MASK_PLAYERSOLID, TraceFilterOtherPlayers)

    if not upTrace.startsolid and not upTrace.allsolid then
        origin.x = upTrace.endpos.x
        origin.y = upTrace.endpos.y
        origin.z = upTrace.endpos.z
    end

    local upOriginalX, upOriginalY, upOriginalZ = origin.x, origin.y, origin.z
    PlayerTick.tryPlayerMove(origin, velocity, mins, maxs, index, tickinterval, 1.0)

    local upDistance = (origin.x - upOriginalX) + (origin.y - upOriginalY)
    if upDistance <= downDistance then
        origin.x = originalX + (origin.x - originalX)
        origin.y = originalY + (origin.y - originalY)
        origin.z = originalZ
        velocity.x = originalVx
        velocity.y = originalVy
        velocity.z = originalVz
        return origin
    end

    moveTemp1.x = origin.x
    moveTemp1.y = origin.y
    moveTemp1.z = origin.z - stepheight - PlayerTick.DIST_EPSILON
    currentTraceIndex = index
    local downTrace = engine.TraceHull(origin, moveTemp1, mins, maxs, MASK_PLAYERSOLID, TraceFilterOtherPlayers)

    if downTrace.plane and downTrace.plane.z >= PlayerTick.IMPACT_NORMAL_FLOOR and not downTrace.startsolid and not downTrace.allsolid then
        origin.x = downTrace.endpos.x
        origin.y = downTrace.endpos.y
        origin.z = downTrace.endpos.z
    end

    return origin
end

function PlayerTick.categorizePosition(origin, velocity, mins, maxs, index)
    moveTemp1.x = origin.x
    moveTemp1.y = origin.y
    moveTemp1.z = origin.z
    moveTemp2.x = origin.x
    moveTemp2.y = origin.y
    moveTemp2.z = origin.z - PlayerTick.GROUND_CHECK_OFFSET

    if velocity.z > PlayerTick.NON_JUMP_VELOCITY then
        return false, nil, 1.0
    end

    currentTraceIndex = index
    local trace = engine.TraceHull(moveTemp1, moveTemp2, mins, maxs, MASK_PLAYERSOLID, TraceFilterOtherPlayers)
    if trace.plane and trace.fraction < 0.06 and trace.plane.z >= PlayerTick.IMPACT_NORMAL_FLOOR then
        if not trace.startsolid and not trace.allsolid then
            origin.x = moveTemp1.x + trace.fraction * (moveTemp2.x - moveTemp1.x)
            origin.y = moveTemp1.y + trace.fraction * (moveTemp2.y - moveTemp1.y)
            origin.z = moveTemp1.z + trace.fraction * (moveTemp2.z - moveTemp1.z)
        end
        return true, trace.plane, 1.0
    end

    return false, nil, 1.0
end

function PlayerTick.simulateTick(playerCtx, simCtx)
    assert(playerCtx, "PlayerTick: playerCtx is nil")
    assert(simCtx, "PlayerTick: simCtx is nil")
    assert(
        playerCtx.velocity and playerCtx.origin and playerCtx.mins and playerCtx.maxs,
        "PlayerTick: invalid playerCtx"
    )
    assert(playerCtx.entity and playerCtx.index and playerCtx.maxspeed, "PlayerTick: invalid playerCtx")
    assert(simCtx.tickinterval and simCtx.sv_gravity, "PlayerTick: invalid simCtx")
    assert(
        simCtx.sv_friction and simCtx.sv_stopspeed and simCtx.sv_accelerate and simCtx.sv_airaccelerate,
        "PlayerTick: invalid simCtx"
    )

    local tickinterval = simCtx.tickinterval
    currentTraceTeam = playerCtx.team or -1

    playerCtx.viewYaw = playerCtx.viewYaw or playerCtx.yaw or 0

    local yawDelta = playerCtx.yawDeltaPerTick or 0
    if math.abs(yawDelta) > 0.0001 then
        playerCtx.viewYaw = playerCtx.viewYaw + yawDelta
    end

    local is_on_ground, _, surface_friction = PlayerTick.categorizePosition(
        playerCtx.origin,
        playerCtx.velocity,
        playerCtx.mins,
        playerCtx.maxs,
        playerCtx.index
    )

    if is_on_ground and playerCtx.velocity.z < 0 then
        playerCtx.velocity.z = 0
    end

    local baseWish = playerCtx.relativeWishDir or Vector3(0, 0, 0)
    local wishLen = Length2D(baseWish)
    local wishdir

    local effectiveMaxspeed = playerCtx.maxspeed
    if playerCtx.isDucked and is_on_ground then
        effectiveMaxspeed = effectiveMaxspeed / 3
    end
    local wishspeed = effectiveMaxspeed

    if wishLen > 0.0001 then
        local yawRad = playerCtx.viewYaw * PlayerTick.DEG2RAD
        local cosYaw = math.cos(yawRad)
        local sinYaw = math.sin(yawRad)
        local worldX = cosYaw * baseWish.x - sinYaw * baseWish.y
        local worldY = sinYaw * baseWish.x + cosYaw * baseWish.y
        local worldLen = math.sqrt(worldX * worldX + worldY * worldY)
        if worldLen > 0.0001 then
            wishdir = Vector3(worldX / worldLen, worldY / worldLen, 0)
        else
            wishdir = Vector3(0, 0, 0)
            wishspeed = 0
        end
    else
        wishdir = Vector3(0, 0, 0)
        wishspeed = 0
    end

    PlayerTick.friction(
        playerCtx.velocity,
        is_on_ground,
        tickinterval,
        simCtx.sv_friction,
        simCtx.sv_stopspeed,
        surface_friction
    )

    if wishspeed > 0 then
        if is_on_ground then
            PlayerTick.accelerate(
                playerCtx.velocity,
                wishdir,
                wishspeed,
                simCtx.sv_accelerate,
                tickinterval,
                surface_friction
            )
        elseif playerCtx.velocity.z < 0 then
            PlayerTick.airAccelerate(
                playerCtx.velocity,
                wishdir,
                wishspeed,
                simCtx.sv_airaccelerate,
                tickinterval,
                surface_friction,
                playerCtx.entity,
                playerCtx.suppressCharge
            )
        end
    end

    if is_on_ground then
        local velLength = playerCtx.velocity:Length()
        if velLength > effectiveMaxspeed and effectiveMaxspeed > 0 then
            local scale = effectiveMaxspeed / velLength
            playerCtx.velocity.x = playerCtx.velocity.x * scale
            playerCtx.velocity.y = playerCtx.velocity.y * scale
            playerCtx.velocity.z = playerCtx.velocity.z * scale
        end
    end

    if is_on_ground then
        playerCtx.origin = PlayerTick.stepMove(
            playerCtx.origin,
            playerCtx.velocity,
            playerCtx.mins,
            playerCtx.maxs,
            playerCtx.index,
            tickinterval,
            playerCtx.stepheight or 18
        )
    else
        playerCtx.origin = PlayerTick.tryPlayerMove(
            playerCtx.origin,
            playerCtx.velocity,
            playerCtx.mins,
            playerCtx.maxs,
            playerCtx.index,
            tickinterval,
            surface_friction
        )
    end

    PlayerTick.checkVelocity(playerCtx.velocity)

    if not is_on_ground then
        playerCtx.velocity.z = playerCtx.velocity.z - (simCtx.sv_gravity * tickinterval)
    elseif playerCtx.velocity.z < 0 then
        playerCtx.velocity.z = 0
    end

    local new_ground_state = PlayerTick.checkIsOnGround(
        playerCtx.origin,
        playerCtx.velocity,
        playerCtx.mins,
        playerCtx.maxs,
        playerCtx.index
    )
    playerCtx.wasOnGround = new_ground_state

    return Vector3(playerCtx.origin:Unpack())
end

function PlayerTick.simulateTickLight(playerCtx, simCtx)
    return PlayerTick.simulateTick(playerCtx, simCtx)
end

-- Simulation context creator
local cachedSimulationContextTick = -1
local cachedSimulationContext = nil

local function createSimulationContext()
    local currentTick = globals.TickCount()
    assert(currentTick, "createContext: globals.TickCount() returned nil")

    if cachedSimulationContext and cachedSimulationContextTick == currentTick then
        return cachedSimulationContext
    end

    local _, sv_gravity = client.GetConVar("sv_gravity")
    assert(sv_gravity, "createContext: client.GetConVar('sv_gravity') returned nil")

    local _, sv_friction = client.GetConVar("sv_friction")
    assert(sv_friction, "createContext: client.GetConVar('sv_friction') returned nil")

    local _, sv_stopspeed = client.GetConVar("sv_stopspeed")
    assert(sv_stopspeed, "createContext: client.GetConVar('sv_stopspeed') returned nil")

    local _, sv_accelerate = client.GetConVar("sv_accelerate")
    assert(sv_accelerate, "createContext: client.GetConVar('sv_accelerate') returned nil")

    local _, sv_airaccelerate = client.GetConVar("sv_airaccelerate")
    assert(sv_airaccelerate, "createContext: client.GetConVar('sv_airaccelerate') returned nil")

    local tickinterval = globals.TickInterval()
    assert(tickinterval, "createContext: globals.TickInterval() returned nil")
    assert(tickinterval > 0, "createContext: tickinterval must be positive")

    cachedSimulationContext = {
        sv_gravity = sv_gravity,
        sv_friction = sv_friction,
        sv_stopspeed = sv_stopspeed,
        sv_accelerate = sv_accelerate,
        sv_airaccelerate = sv_airaccelerate,
        tickinterval = tickinterval,
    }

    cachedSimulationContextTick = currentTick
    return cachedSimulationContext
end

local function clonePlayerContext(src)
    assert(src, "clonePlayerContext: source context missing")
    local clone = {
        entity = src.entity,
        mins = src.mins,
        maxs = src.maxs,
        maxspeed = src.maxspeed,
        index = src.index,
        team = src.team,
        stepheight = src.stepheight,
        yaw = src.yaw,
        yawDeltaPerTick = src.yawDeltaPerTick,
        viewYaw = src.viewYaw,
        wasOnGround = src.wasOnGround,
        isDucked = src.isDucked,
    }

    assert(src.origin, "clonePlayerContext: origin missing")
    clone.origin = src.origin -- No clone needed, gets replaced in simulation

    assert(src.velocity, "clonePlayerContext: velocity missing")
    clone.velocity = Vector3(src.velocity:Unpack()) -- Must clone, gets mutated

    -- Assigned, not mutated, no cloning needed
    clone.relativeWishDir = src.relativeWishDir

    return clone
end

local function simulateWishdirCandidates(baseCtx, simCtx)
    assert(baseCtx, "simulateWishdirCandidates: baseCtx missing")
    assert(simCtx, "simulateWishdirCandidates: simCtx missing")

    local results = {}
    local baseOrigin = baseCtx.origin
    local baseVelocity = baseCtx.velocity
    local baseWasOnGround = baseCtx.wasOnGround
    local baseYaw = baseCtx.yaw
    local baseViewYaw = baseCtx.viewYaw
    local workCtx = clonePlayerContext(baseCtx)

    assert(baseOrigin, "simulateWishdirCandidates: base origin missing")
    assert(baseVelocity, "simulateWishdirCandidates: base velocity missing")

    for i = 1, #WishdirTracker.DIRECTIONS do
        local dirSpec = WishdirTracker.DIRECTIONS[i]
        local dirVec = WishdirTracker.normalizeDirection(dirSpec.x, dirSpec.y)
        workCtx.origin = baseOrigin
        workCtx.velocity.x = baseVelocity.x
        workCtx.velocity.y = baseVelocity.y
        workCtx.velocity.z = baseVelocity.z
        workCtx.wasOnGround = baseWasOnGround
        workCtx.yaw = baseYaw
        workCtx.viewYaw = baseViewYaw
        workCtx.relativeWishDir = dirVec

        local predictedPos = PlayerTick.simulateTickLight(workCtx, simCtx)

        results[#results + 1] = {
            name = dirSpec.name,
            dir = dirVec,
            pos = predictedPos, -- simulateTick already returns Vector3, no need to clone
            vel = Vector3(workCtx.velocity:Unpack()),
        }
    end

    return results
end

-- Player context creator
local function createPlayerContext(entity, relativeWishDir)
    assert(entity, "createPlayerContext: entity is nil")

    local velocity = entity:EstimateAbsVelocity()
    assert(velocity, "createPlayerContext: entity:EstimateAbsVelocity() returned nil")

    local origin = entity:GetAbsOrigin()
    assert(origin, "createPlayerContext: entity:GetAbsOrigin() returned nil")

    local maxspeed = entity:GetPropFloat("m_flMaxspeed")
    assert(maxspeed, "createPlayerContext: entity:GetPropFloat('m_flMaxspeed') returned nil")
    assert(maxspeed > 0, "createPlayerContext: maxspeed must be positive")

    local mins, maxs = entity:GetMins(), entity:GetMaxs()
    assert(mins, "createPlayerContext: entity:GetMins() returned nil")
    assert(maxs, "createPlayerContext: entity:GetMaxs() returned nil")

    local index = entity:GetIndex()
    assert(index, "createPlayerContext: entity:GetIndex() returned nil")

    local team = entity:GetTeamNumber()
    assert(team, "createPlayerContext: entity:GetTeamNumber() returned nil")

    -- Shrink hull by 0.125 for non-local players (origin compression fix from Source engine)
    local localPlayer = entities.GetLocalPlayer()
    local isLocalEntity = localPlayer and (index == localPlayer:GetIndex())
    if not isLocalEntity then
        mins = Vector3(mins.x + 0.125, mins.y + 0.125, mins.z)
        maxs = Vector3(maxs.x - 0.125, maxs.y - 0.125, maxs.z - 0.125)
    end

    local originWithOffset = origin + Vector3(0, 0, 1)

    local yaw = entity:GetPropFloat("m_angEyeAngles[1]") or 0
    local yawDeltaPerTick = StrafePredictor.getYawDeltaPerTickDegrees(index, 3)

    if not relativeWishDir then
        relativeWishDir = WishdirTracker.getRelativeWishdir(entity)
        if not relativeWishDir then
            -- Fallback: clamp current velocity to 8 directions
            local horizLen = Length2D(velocity)
            if horizLen < 50 then
                relativeWishDir = Vector3(0, 0, 0)
            else
                local yawRad = yaw * (math.pi / 180)
                local cosYaw = math.cos(yawRad)
                local sinYaw = math.sin(yawRad)

                local forward = Vector3(cosYaw, sinYaw, 0)
                local right = Vector3(sinYaw, -cosYaw, 0)

                local velNormX = velocity.x / horizLen
                local velNormY = velocity.y / horizLen
                local velNorm = Vector3(velNormX, velNormY, 0)

                local relX = Dot(forward, velNorm)
                local relY = Dot(right, velNorm)

                local relLen = math.sqrt(relX * relX + relY * relY)
                if relLen > 0.001 then
                    relativeWishDir = Vector3(relX / relLen, relY / relLen, 0)
                else
                    relativeWishDir = Vector3(0, 0, 0)
                end
            end
        end
    end

    -- Ducking state via netvar
    local isDucked = entity:GetPropBool("m_bDucked") or false

    return {
        entity = entity,
        velocity = Vector3(velocity:Unpack()), -- Clone once for mutation safety
        origin = originWithOffset,             -- Already a Vector3 from line 937, no need to clone
        mins = mins,
        maxs = maxs,
        maxspeed = maxspeed,
        index = index,
        team = team,
        stepheight = 18,
        yaw = yaw,
        yawDeltaPerTick = yawDeltaPerTick,
        relativeWishDir = relativeWishDir, -- Already a Vector3, no need to clone
        isDucked = isDucked,
    }
end

local function GetPressedkey()
    local pressedKey = Input.GetPressedKey()
    if not pressedKey then
        -- Check for standard mouse buttons
        if input.IsButtonDown(MOUSE_LEFT) then return MOUSE_LEFT end
        if input.IsButtonDown(MOUSE_RIGHT) then return MOUSE_RIGHT end
        if input.IsButtonDown(MOUSE_MIDDLE) then return MOUSE_MIDDLE end

        -- Check for additional mouse buttons
        for i = 1, 10 do
            if input.IsButtonDown(MOUSE_FIRST + i - 1) then return MOUSE_FIRST + i - 1 end
        end
    end
    return pressedKey
end

--[[menu:AddComponent(MenuLib.Button("Debug", function() -- Disable Weapon Sway (Executes commands)
    client.SetConVar("cl_vWeapon_sway_interp",              0)             -- Set cl_vWeapon_sway_interp to 0
    client.SetConVar("cl_jiggle_bone_framerate_cutoff", 0)             -- Set cl_jiggle_bone_framerate_cutoff to 0
    client.SetConVar("cl_bobcycle",                     10000)         -- Set cl_bobcycle to 10000
    client.SetConVar("sv_cheats", 1)                                    -- debug fast setup
    client.SetConVar("mp_disable_respawn_times", 1)
    client.SetConVar("mp_respawnwavetime", -1)
    client.SetConVar("mp_teams_unbalance_limit", 1000)
end, ItemFlags.FullWidth))]]

local Menu = {
    -- Tab management - Start with Aimbot tab open by default
    currentTab = 1, -- 1 = Aimbot, 2 = Charge, 3 = Visuals, 4 = Misc
    tabs = { "Aimbot", "Demoknight", "Visuals", "Misc" },

    -- Aimbot settings
    Aimbot = {
        Aimbot = true,
        Silent = true,
        AimbotFOV = 360,
        SwingTime = 13,
        AlwaysUseMaxSwingTime = false, -- Default to always use max for best experience
        MaxSwingTime = 11,             -- Starting value, will be updated based on weapon
        ChargeBot = true,              -- Moved to Charge tab in UI but kept here for backward compatibility
    },

    -- Charge settings (moved from mixed locations to a dedicated section)
    Charge = {
        ChargeBot = false,
        ChargeBotFOV = 360,
        ChargeBotActivationMode = 1,
        ChargeBotActivationModes = { "Always On", "On Key", "On Release" },
        ChargeBotKeybind = KEY_NONE,
        ChargeBotKeybindName = "Always On",
        ChargeControl = false,
        ChargeSensitivity = 1.0,
        ChargeReach = true,
        ChargeJump = true,
        LateCharge = true,
    },

    -- Visuals settings
    Visuals = {
        EnableVisuals = true,
        Sphere = false,
        Section = 1,
        Sections = { "Local", "Target", "Experimental" },
        Local = {
            RangeCircle = true,
            path = {
                enable = true,
                Color = { 255, 255, 255, 255 },
                Styles = { "Pavement", "ArrowPath", "Arrows", "L Line", "dashed", "line" },
                Style = 1,
                width = 5,
            },
        },
        Target = {
            path = {
                enable = true,
                Color = { 255, 255, 255, 255 },
                Styles = { "Pavement", "ArrowPath", "Arrows", "L Line", "dashed", "line" },
                Style = 1,
                width = 5,
            },
        },
    },

    -- Misc settings
    Misc = {
        strafePred = true,
        CritRefill = { Active = true, NumCrits = 1 },
        CritMode = 1,
        CritModes = { "Rage", "On Button" },
        InstantAttack = false,
        WarpOnAttack = true, -- New option to control warp during instant attack
        TroldierAssist = false,
        advancedHitreg = true,
    },

    -- Global settings
    Keybind = KEY_NONE,
    KeybindName = "Always On",
}

local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("\\([^\\]-)$"):gsub("%.lua$", "")

-- Config helpers rewrite -----------------------------------------------------------------
-- Build full path once from script name or supplied folder
local function GetConfigPath(folder_name)
    folder_name = folder_name or string.format([[Lua %s]], Lua__fileName)
    local _, fullPath = filesystem.CreateDirectory(folder_name) -- succeeds even if already exists
    local sep = package.config:sub(1, 1)
    return fullPath .. sep .. "config.cfg"
end

-- Serialize a Lua table (simple, ordered by iteration) ------------------------------------
local function serializeTable(tbl, level)
    level = level or 0
    local indent = string.rep("    ", level)
    local out = indent .. "{\n"
    for k, v in pairs(tbl) do
        local keyRepr = (type(k) == "string") and string.format("[\"%s\"]", k) or string.format("[%s]", k)
        out = out .. indent .. "    " .. keyRepr .. " = "
        if type(v) == "table" then
            out = out .. serializeTable(v, level + 1) .. ",\n"
        elseif type(v) == "string" then
            out = out .. string.format("\"%s\",\n", v)
        else
            out = out .. tostring(v) .. ",\n"
        end
    end
    out = out .. indent .. "}"
    return out
end

-- Shallow-key presence check (recurses into subtables) ------------------------------------
local function keysMatch(template, loaded)
    for k, v in pairs(template) do
        if loaded[k] == nil then return false end
        if type(v) == "table" and type(loaded[k]) == "table" then
            if not keysMatch(v, loaded[k]) then return false end
        end
    end
    return true
end

-- Save current (or supplied) menu ---------------------------------------------------------
local function CreateCFG(folder_name, cfg)
    cfg = cfg or Menu
    local path = GetConfigPath(folder_name)
    local f = io.open(path, "w")
    if not f then
        printc(255, 0, 0, 255, "[Config] Failed to write: " .. path)
        return
    end
    f:write(serializeTable(cfg))
    f:close()
    printc(100, 183, 0, 255, "[Config] Saved: " .. path)
end

-- Load config; regenerate if invalid/outdated/SHIFT bypass ---------------------------------
local function LoadCFG(folder_name)
    local path = GetConfigPath(folder_name)
    local f = io.open(path, "r")
    if not f then
        -- First run – make directory & default cfg
        CreateCFG(folder_name, Menu)
        return Menu
    end
    local content = f:read("*a")
    f:close()

    local chunk, err = load("return " .. content)
    if not chunk then
        print("[Config] Compile error, regenerating: " .. tostring(err))
        CreateCFG(folder_name, Menu)
        return Menu
    end

    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= "table" or not keysMatch(Menu, cfg) or input.IsButtonDown(KEY_LSHIFT) then
        print("[Config] Invalid or outdated cfg – regenerating …")
        CreateCFG(folder_name, Menu)
        return Menu
    end

    printc(0, 255, 140, 255, "[Config] Loaded: " .. path)
    return cfg
end
-- End of config helpers rewrite -----------------------------------------------------------

local status, loadedMenu = pcall(function()
    return assert(LoadCFG(string.format([[Lua %s]], Lua__fileName)))
end) -- Auto-load config

if status and loadedMenu then
    Menu = loadedMenu
end

-- Ensure all the Menu settings are initialized
local function SafeInitMenu()
    -- Initialize Aimbot settings
    Menu.Aimbot = Menu.Aimbot or {}
    Menu.Aimbot.Aimbot = Menu.Aimbot.Aimbot ~= nil and Menu.Aimbot.Aimbot or true
    Menu.Aimbot.Silent = Menu.Aimbot.Silent ~= nil and Menu.Aimbot.Silent or true
    Menu.Aimbot.AimbotFOV = Menu.Aimbot.AimbotFOV or 360
    Menu.Aimbot.SwingTime = Menu.Aimbot.SwingTime or 13
    Menu.Aimbot.AlwaysUseMaxSwingTime = Menu.Aimbot.AlwaysUseMaxSwingTime ~= nil and Menu.Aimbot.AlwaysUseMaxSwingTime or
        true
    Menu.Aimbot.MaxSwingTime = Menu.Aimbot.MaxSwingTime or 13
    Menu.Aimbot.ChargeBot = Menu.Aimbot.ChargeBot ~= nil and Menu.Aimbot.ChargeBot or true

    -- Initialize Misc settings
    Menu.Misc = Menu.Misc or {}
    Menu.Misc.InstantAttack = Menu.Misc.InstantAttack ~= nil and Menu.Misc.InstantAttack or false
    Menu.Misc.WarpOnAttack = Menu.Misc.WarpOnAttack ~= nil and Menu.Misc.WarpOnAttack or true

    -- Initialize other sections if needed
    Menu.Charge = Menu.Charge or {}
    Menu.Charge.ChargeBot = Menu.Charge.ChargeBot ~= nil and Menu.Charge.ChargeBot or false
    Menu.Charge.ChargeBotFOV = Menu.Charge.ChargeBotFOV or 360
    Menu.Charge.ChargeBotActivationMode = Menu.Charge.ChargeBotActivationMode or 1
    Menu.Charge.ChargeBotActivationModes = Menu.Charge.ChargeBotActivationModes or
        { "Always On", "On Key", "On Release" }
    Menu.Charge.ChargeBotKeybind = Menu.Charge.ChargeBotKeybind or KEY_NONE
    Menu.Charge.ChargeBotKeybindName = Menu.Charge.ChargeBotKeybindName or "Always On"
    Menu.Visuals = Menu.Visuals or {}
    Menu.Charge.LateCharge = Menu.Charge.LateCharge ~= nil and Menu.Charge.LateCharge or true
end

-- Call the initialization function to ensure no nil values
SafeInitMenu()

-- Entity-independent constants
local swingrange = 48
local TotalSwingRange = 48
local SwingHullSize = 38
local SwingHalfhullSize = SwingHullSize / 2
local Charge_Range = 128
local normalWeaponRange = 48
local normalTotalSwingRange = 48
local vHitbox = { Vector3(-24, -24, 0), Vector3(24, 24, 82) }
local gravity = client.GetConVar("sv_gravity") or 800
local stepSize = 18

-- TF2 class walking speeds indexed by m_iClass
local TF2_CLASS_SPEED = {
    [1] = 400, -- Scout
    [2] = 240, -- Sniper
    [3] = 300, -- Soldier
    [4] = 280, -- Demoman
    [5] = 320, -- Medic
    [6] = 230, -- Heavy
    [7] = 300, -- Pyro
    [8] = 320, -- Spy
    [9] = 300, -- Engineer
}

-- TF2 Physics Constants (from Auto Trickstab for enhanced prediction)
local TF2 = {
    -- Movement & physics
    MAX_SPEED = 320,       -- Base movement speed
    ACCELERATION = 10,     -- Ground acceleration
    GROUND_FRICTION = 4.0, -- Friction coefficient
    STOP_SPEED = 100,      -- Speed at which friction stops

    -- Collision angles
    FORWARD_COLLISION_ANGLE = 55, -- Wall collision angle
    GROUND_ANGLE_LOW = 45,        -- Ground collision low angle
    GROUND_ANGLE_HIGH = 55,       -- Ground collision high angle

    -- Player dimensions
    HITBOX_RADIUS = 24, -- Player collision radius
    HITBOX_HEIGHT = 82, -- Player height
    VIEW_OFFSET_Z = 75, -- Eye level from ground
}

-- Hull dimensions (precomputed)
local HULL = {
    MIN = Vector3(-23.99, -23.99, 0),
    MAX = Vector3(23.99, 23.99, 82),
    SWING_MIN = Vector3(-19, -19, -19), -- Half of 38
    SWING_MAX = Vector3(19, 19, 19),
}

-- Math constants (precomputed)
local MATH = {
    TWO_PI = 2 * math.pi,
    DEG_TO_RAD = math.pi / 180,
    RAD_TO_DEG = 180 / math.pi,
    HALF_PI = math.pi / 2,
    HALF_CIRCLE = 180,
    FULL_CIRCLE = 360,
}

-- Function to update server cvars only on events
local function UpdateServerCvars()
    gravity = client.GetConVar("sv_gravity") or 800
end

UpdateServerCvars() -- Initialize on script load

-- Per-tick variables (reset each tick)
local isMelee = false
local pLocal = nil
local players = nil
local tick_count = 0
local can_attack = false
local can_charge = false
local pLocalPath = {}
local vPlayerPath = {}
local drawVhitbox = {}

-- Track swing ticks after +attack is sent
local swingTickCounter = 0

-- Helpers for charge-bot yaw clamping
local function Clamp(val, min, max)
    if val < min then
        return min
    elseif val > max then
        return max
    end
    return val
end
local MAX_CHARGE_BOT_TURN = 17

-- Jitter tracker: rolling window of latency samples for standard deviation
local JITTER_WINDOW_SIZE = 66
local jitterSamples = {}
local jitterWriteIndex = 0
local jitterSampleCount = 0
local cachedJitterTicks = 1
local lastJitterUpdateTick = -1

local function UpdateJitterTracker()
    local currentTick = globals.TickCount()
    if currentTick == lastJitterUpdateTick then return end
    lastJitterUpdateTick = currentTick

    local nc = clientstate.GetNetChannel()
    if not nc then return end

    local currentLatency = nc:GetLatency(0)
    assert(type(currentLatency) == "number", "UpdateJitterTracker: GetLatency returned non-number")

    jitterWriteIndex = (jitterWriteIndex % JITTER_WINDOW_SIZE) + 1
    jitterSamples[jitterWriteIndex] = currentLatency
    if jitterSampleCount < JITTER_WINDOW_SIZE then
        jitterSampleCount = jitterSampleCount + 1
    end

    if jitterSampleCount < 2 then
        cachedJitterTicks = 1
        return
    end

    local sum = 0
    for i = 1, jitterSampleCount do
        sum = sum + jitterSamples[i]
    end
    local mean = sum / jitterSampleCount

    local varianceSum = 0
    for i = 1, jitterSampleCount do
        local diff = jitterSamples[i] - mean
        varianceSum = varianceSum + diff * diff
    end
    local stdDev = math.sqrt(varianceSum / (jitterSampleCount - 1))

    local tickInterval = globals.TickInterval()
    assert(tickInterval > 0, "UpdateJitterTracker: invalid TickInterval")

    local jitterTicks = math.ceil(stdDev / tickInterval)
    if jitterTicks < 1 then jitterTicks = 1 end
    cachedJitterTicks = jitterTicks
end

local function GetJitterOffsetTicks()
    return cachedJitterTicks
end

-- Variables to track attack and charge state
local attackStarted = false
local attackTickCount = 0
local lastChargeTime = 0
local chargeAimAngles = nil
local chargeState = "idle"
local chargeJumpPendingTick = nil

-- Track the tick index of the last +attack press (user or script)
local lastAttackTick = -1000 -- initialize far in the past

-- Add this function to reset the attack tracking when needed
local function resetAttackTracking()
    attackStarted = false
    attackTickCount = 0
end




-- Per-tick entity variables (will be reset each tick)
local pLocalClass = nil
local pLocalFuture = nil
local pLocalOrigin = nil
local pWeapon = nil
local Latency = nil
local viewheight = nil
local Vheight = nil
local vPlayerFuture = nil
local vPlayer = nil
local vPlayerOrigin = nil
local chargeLeft = nil
local onGround = nil
local CurrentTarget = nil
local aimposVis = nil
local tickCounterrecharge = 0

local settings = {
    MinDistance = 0,
    MaxDistance = 770,
    MinFOV = 0,
    MaxFOV = Menu.Aimbot.AimbotFOV,
}

local lastAngles = {} ---@type table<number, Vector3>
local lastDeltas = {} ---@type table<number, number>
local avgDeltas = {} ---@type table<number, number>
local strafeAngles = {} ---@type table<number, number>
local inaccuracy = {} ---@type table<number, number>
local pastPositions = {} -- Stores past positions of the local player
local maxPositions = 4   -- Number of past positions to consider

local function CalcStrafe()
    local autostrafe = gui.GetValue("Auto Strafe")
    local flags = entities.GetLocalPlayer():GetPropInt("m_fFlags")
    local OnGround = (flags & FL_ONGROUND) ~= 0

    for idx, entity in pairs(players) do
        if not entity or not entity:IsValid() then
            goto continue
        end

        local entityIndex = entity:GetIndex()
        if not entityIndex then
            goto continue
        end

        if entity:IsDormant() or not entity:IsAlive() then
            lastAngles[entityIndex] = nil
            lastDeltas[entityIndex] = nil
            avgDeltas[entityIndex] = nil
            strafeAngles[entityIndex] = nil
            inaccuracy[entityIndex] = nil
            goto continue
        end

        local v = entity:EstimateAbsVelocity()
        if entity == pLocal then
            table.insert(pastPositions, 1, entity:GetAbsOrigin())
            if #pastPositions > maxPositions then
                table.remove(pastPositions)
            end

            if not OnGround and autostrafe == 2 and #pastPositions >= maxPositions then
                v = Vector3(0, 0, 0)
                for i = 1, #pastPositions - 1 do
                    v = v + (pastPositions[i] - pastPositions[i + 1])
                end
                v = v / (maxPositions - 1)
            else
                v = entity:EstimateAbsVelocity()
            end
        end

        local angle = v:Angles()

        if lastAngles[entityIndex] == nil then
            lastAngles[entityIndex] = angle
            goto continue
        end

        local delta = angle.y - lastAngles[entityIndex].y

        -- Calculate the average delta using exponential smoothing
        local smoothingFactor = 0.2
        local avgDelta = (lastDeltas[entityIndex] or delta) * (1 - smoothingFactor) + delta * smoothingFactor

        -- Save the average delta
        avgDeltas[entityIndex] = avgDelta

        local vector1 = Vector3(1, 0, 0)
        local vector2 = Vector3(1, 0, 0)

        -- Apply deviation
        local ang1 = vector1:Angles()
        ang1.y = ang1.y + (lastDeltas[entityIndex] or delta)
        vector1 = ang1:Forward() * vector1:Length()

        local ang2 = vector2:Angles()
        ang2.y = ang2.y + avgDelta
        vector2 = ang2:Forward() * vector2:Length()

        -- Calculate the distance between the two vectors
        local distance = (vector1 - vector2):Length()

        -- Save the strafe angle
        strafeAngles[entityIndex] = avgDelta

        -- Calculate the inaccuracy as the distance between the two vectors
        inaccuracy[entityIndex] = distance

        -- Save the last delta
        lastDeltas[entityIndex] = delta

        lastAngles[entityIndex] = angle

        ::continue::
    end
end

-- Normalize angle to [-180, 180] range (from Auto Trickstab)
local function NormalizeYaw(yaw)
    yaw = yaw % MATH.FULL_CIRCLE
    if yaw > MATH.HALF_CIRCLE then
        yaw = yaw - MATH.FULL_CIRCLE
    elseif yaw < -MATH.HALF_CIRCLE then
        yaw = yaw + MATH.FULL_CIRCLE
    end
    return yaw
end

-- Apply ground friction to velocity (from Auto Trickstab)
local function ApplyFriction(velocity, onGround)
    if not velocity or not onGround then
        return velocity or Vector3(0, 0, 0)
    end

    local speed = velocity:Length()
    if speed < TF2.STOP_SPEED then
        return Vector3(0, 0, 0)
    end

    local friction = TF2.GROUND_FRICTION * globals.TickInterval()
    local control = (speed < TF2.STOP_SPEED) and TF2.STOP_SPEED or speed
    local drop = control * friction

    local newspeed = speed - drop
    if newspeed < 0 then
        newspeed = 0
    end

    if newspeed < speed then
        local scale = newspeed / speed
        return velocity * scale
    end

    return velocity
end

-- Handle forward collision with walls (from Auto Trickstab)
local function HandleForwardCollision(vel, wallTrace)
    local normal = wallTrace.plane
    local angle = math.deg(math.acos(normal:Dot(Vector3(0, 0, 1))))

    -- Steep wall: reflect velocity
    if angle > TF2.FORWARD_COLLISION_ANGLE then
        local dot = vel:Dot(normal)
        vel = vel - normal * dot
    end

    return wallTrace.endpos.x, wallTrace.endpos.y
end

-- Handle ground collision (from Auto Trickstab)
local function HandleGroundCollision(vel, groundTrace, vUp)
    local normal = groundTrace.plane
    local angle = math.deg(math.acos(normal:Dot(vUp)))
    local onGround = false

    if angle < TF2.GROUND_ANGLE_LOW then
        onGround = true
    elseif angle < TF2.GROUND_ANGLE_HIGH then
        vel.x, vel.y, vel.z = 0, 0, 0
    else
        local dot = vel:Dot(normal)
        vel = vel - normal * dot
        onGround = true
    end

    if onGround then
        vel.z = 0
    end
    return groundTrace.endpos, onGround
end

-- Position history for lag compensation (1 second = 66 ticks at 66 tick server)
local POSITION_HISTORY_SIZE = 66
local positionHistory = {} -- Queue: index 1 = newest, index 66 = oldest

-- Cleanup stale entries from unbounded caches
local function cleanupStaleCacheEntries()
    -- Clean up WishdirTracker.state for invalid entities
    for idx, _ in pairs(WishdirTracker.state) do
        local ent = entities.GetByIndex(idx)
        if not ent or not ent:IsValid() or not ent:IsAlive() then
            WishdirTracker.state[idx] = nil
        end
    end

    -- Clean up positionHistory for invalid entities
    for idx, _ in pairs(positionHistory) do
        local ent = entities.GetByIndex(idx)
        if not ent or not ent:IsValid() or not ent:IsAlive() then
            positionHistory[idx] = nil
        end
    end

    -- Clean up StrafePredictor.velocityHistory for invalid entities
    for idx, _ in pairs(StrafePredictor.velocityHistory) do
        local ent = entities.GetByIndex(idx)
        if not ent or not ent:IsValid() or not ent:IsAlive() then
            StrafePredictor.velocityHistory[idx] = nil
        end
    end
end

-- Lag compensation function from Auto Trickstab
-- Predicts enemy position ahead by half our ping to account for network latency
local function ApplyLagCompensation(enemyPos, enemyEntity)
    if not enemyEntity then
        return enemyPos
    end

    local netChan = clientstate.GetNetChannel()
    if not netChan then
        return enemyPos
    end

    local latOut = netChan:GetLatency(0) -- FLOW_OUTGOING
    local latIn = netChan:GetLatency(1)  -- FLOW_INCOMING
    local totalLatency = latOut + latIn
    local halfPing = totalLatency / 2    -- Time for server to receive our position

    -- Convert to ticks for simulation consistency
    local tick_interval = globals.TickInterval()
    local predictionTicks = math.floor(halfPing / tick_interval)
    local predictionTime = predictionTicks * tick_interval

    -- Predict where enemy will be when server processes our attack
    local enemyVelocity = enemyEntity:EstimateAbsVelocity()
    if enemyVelocity then
        return enemyPos + enemyVelocity * predictionTime
    end

    return enemyPos
end

-- Update position history for tracking
local function UpdatePositionHistory(entity)
    if not entity or not entity:IsValid() then
        return
    end

    local entityIndex = entity:GetIndex()
    local currentPos = entity:GetAbsOrigin()

    if not positionHistory[entityIndex] then
        positionHistory[entityIndex] = {}
    end

    -- Add new position to the front of the queue
    table.insert(positionHistory[entityIndex], 1, {
        pos = currentPos,
        tick = globals.TickCount()
    })

    -- Remove old positions beyond history size
    while #positionHistory[entityIndex] > POSITION_HISTORY_SIZE do
        table.remove(positionHistory[entityIndex])
    end
end

-- Get predicted position based on velocity and history
local function GetPredictedPosition(entity, ticksAhead)
    if not entity or not entity:IsValid() then
        return nil
    end

    local currentPos = entity:GetAbsOrigin()
    local velocity = entity:EstimateAbsVelocity()

    if not velocity then
        return currentPos
    end

    local tickInterval = globals.TickInterval()
    local predictionTime = ticksAhead * tickInterval

    return currentPos + velocity * predictionTime
end
---@param player WPlayer
---@param t      integer       -- number of ticks to simulate
---@param d      number?       -- strafe deviation angle per tick (degrees, optional)
---@param simulateCharge boolean? -- simulate shield charge starting now
---@param fixedAngles EulerAngles? -- view-angle override for charge direction
---@param pCmd UserCmd?
---@param suppressChargeInSim boolean? -- suppress charge speed/air cap in simulation (local player charging but not exploiting)
---@return { pos : Vector3[], vel: Vector3[] }?
local function PredictPlayer(player, t, d, simulateCharge, fixedAngles, pCmd, suppressChargeInSim)
    assert(player, "PredictPlayer: player is nil")
    assert(t and t > 0, "PredictPlayer: invalid tick count")

    local localPlayer = entities.GetLocalPlayer()
    assert(localPlayer, "PredictPlayer: no local player")

    local isLocal = (player == localPlayer)

    -- Update tracking systems for enemies
    if not isLocal then
        StrafePredictor.updateAll({ player })
        WishdirTracker.update(player)
    end

    -- Build simulation and player contexts
    local simCtx = createSimulationContext()
    local playerCtx = createPlayerContext(player)

    -- Resolve wishdir
    if isLocal and pCmd then
        -- Local player: use actual cmd input (exact, no guessing)
        local forwardMove = pCmd:GetForwardMove()
        local sideMove = pCmd:GetSideMove()

        if math.abs(forwardMove) > 0.1 or math.abs(sideMove) > 0.1 then
            local inputLen = math.sqrt(forwardMove * forwardMove + sideMove * sideMove)
            local normFwd = forwardMove / inputLen
            local normSide = sideMove / inputLen
            -- x = forward, positive y = left (matches DIRECTIONS table convention)
            playerCtx.relativeWishDir = Vector3(normFwd, -normSide, 0)
        else
            playerCtx.relativeWishDir = Vector3(0, 0, 0)
        end
    elseif not isLocal then
        -- Enemy: prefer WishdirTracker (9-candidate sim), fall back to velocity snap
        local trackedWishdir = WishdirTracker.getRelativeWishdir(player)
        if trackedWishdir then
            playerCtx.relativeWishDir = trackedWishdir
        else
            local vel = playerCtx.velocity
            local horizSpeed = Length2D(vel)
            if horizSpeed > 50 then
                playerCtx.relativeWishDir = WishdirTracker.clampVelocityTo8Directions(vel, playerCtx.yaw or 0)
            else
                playerCtx.relativeWishDir = Vector3(0, 0, 0)
            end
        end
    else
        -- Local player without cmd: fall back to velocity direction
        local vel = playerCtx.velocity
        local horizSpeed = Length2D(vel)
        if horizSpeed > 50 then
            playerCtx.relativeWishDir = WishdirTracker.clampVelocityTo8Directions(vel, playerCtx.yaw or 0)
        else
            playerCtx.relativeWishDir = Vector3(0, 0, 0)
        end
    end

    -- Local player charge simulation override:
    -- When charging but NOT doing exploit, simulate as walking speed with forward-only wishdir.
    -- This prevents the sim from using charge speed (750) which would over-predict movement.
    if isLocal and suppressChargeInSim then
        local classIndex = player:GetPropInt("m_iClass") or 4
        local walkSpeed = TF2_CLASS_SPEED[classIndex] or 280
        playerCtx.maxspeed = walkSpeed
        playerCtx.suppressCharge = true
        playerCtx.relativeWishDir = Vector3(1, 0, 0)
        playerCtx.yawDeltaPerTick = 0
    end

    -- Local player: clamp horizontal speed to maxspeed.
    -- Swing cancels charge instantly, so prediction must assume walking speed.
    if isLocal then
        local v = playerCtx.velocity
        local hSpeed = Length2D(v)
        local maxspd = playerCtx.maxspeed
        if hSpeed > maxspd and maxspd > 0 then
            local scale = maxspd / hSpeed
            v.x = v.x * scale
            v.y = v.y * scale
        end
    end

    -- Feed strafe deviation as yaw delta per tick so simulateTick rotates wishdir each tick
    if d and math.abs(d) > 0.01 then
        playerCtx.yawDeltaPerTick = d
    end

    -- Lag compensation for enemies
    if not isLocal then
        playerCtx.origin = ApplyLagCompensation(playerCtx.origin, player)
    end

    -- Charge direction (computed once, reused each tick)
    local chargeForward
    if simulateCharge then
        local useAngles = fixedAngles or engine.GetViewAngles()
        local fwd = useAngles:Forward()
        fwd.z = 0
        chargeForward = Normalize(fwd)
    end

    local _out = {
        pos = { [0] = Vector3(playerCtx.origin:Unpack()) },
        vel = { [0] = Vector3(playerCtx.velocity:Unpack()) },
    }

    local simulateOneTick = isLocal and PlayerTick.simulateTick or PlayerTick.simulateTickLight

    -- Simulate t ticks
    for i = 1, t do
        local newPos = simulateOneTick(playerCtx, simCtx)

        -- Charge acceleration applied AFTER movement (matches engine order)
        if chargeForward then
            local v = playerCtx.velocity
            local accel = 750 * simCtx.tickinterval
            v.x = v.x + chargeForward.x * accel
            v.y = v.y + chargeForward.y * accel
        end

        _out.pos[i] = Vector3(newPos:Unpack())
        _out.vel[i] = Vector3(playerCtx.velocity:Unpack())
    end

    return _out
end

local function PredictPlayerSimpleLinear(player, t, d)
    assert(player, "PredictPlayerSimpleLinear: player is nil")
    assert(t and t > 0, "PredictPlayerSimpleLinear: invalid tick count")

    local origin = player:GetAbsOrigin()
    local velocity = player:EstimateAbsVelocity()
    assert(origin, "PredictPlayerSimpleLinear: origin is nil")
    assert(velocity, "PredictPlayerSimpleLinear: velocity is nil")

    local tickinterval = globals.TickInterval()
    local pos = Vector3(origin:Unpack())
    local vel = Vector3(velocity:Unpack())
    local yawDeltaDeg = d or 0

    local out = {
        pos = { [0] = Vector3(pos:Unpack()) },
        vel = { [0] = Vector3(vel:Unpack()) },
    }

    for i = 1, t do
        if math.abs(yawDeltaDeg) > 0.01 then
            local yawRad = yawDeltaDeg * PlayerTick.DEG2RAD
            local cosYaw = math.cos(yawRad)
            local sinYaw = math.sin(yawRad)
            local vx = vel.x
            local vy = vel.y
            vel.x = cosYaw * vx - sinYaw * vy
            vel.y = sinYaw * vx + cosYaw * vy
        end

        pos.x = pos.x + vel.x * tickinterval
        pos.y = pos.y + vel.y * tickinterval
        pos.z = pos.z + vel.z * tickinterval

        out.pos[i] = Vector3(pos:Unpack())
        out.vel[i] = Vector3(vel:Unpack())
    end

    return out
end

-- Constants for minimum and maximum speed
local MIN_SPEED = 10             -- Minimum speed to avoid jittery movements
local MAX_SPEED = 650            -- Maximum speed the player can move

local MoveDir = Vector3(0, 0, 0) -- Variable to store the movement direction
-- Using tick-scoped pLocal defined in OnCreateMove; avoid shadowing here

-- Function to compute the move direction
local function ComputeMove(pCmd, a, b)
    local diff = (b - a)
    if diff:Length() == 0 then return Vector3(0, 0, 0) end

    local x = diff.x
    local y = diff.y
    local vSilent = Vector3(x, y, 0)

    local ang = vSilent:Angles()
    local cPitch, cYaw, cRoll = pCmd:GetViewAngles()
    local yaw = math.rad(ang.y - cYaw)
    local pitch = math.rad(ang.x - cPitch)
    local move = Vector3(math.cos(yaw) * MAX_SPEED, -math.sin(yaw) * MAX_SPEED, 0)

    return move
end

-- Function to make the player walk to a destination smoothly
local function WalkTo(pCmd, pLocal, pDestination)
    -- Safety check - if destination is invalid, don't attempt to move
    if not pDestination or not pLocal then
        return
    end

    local localPos = pLocal:GetAbsOrigin()
    local distVector = pDestination - localPos

    -- Safety check - make sure the distance vector is valid
    if not distVector or distVector:Length() > 1000 then
        return
    end

    local dist = distVector:Length()

    -- Determine the speed based on the distance
    local speed = math.max(MIN_SPEED, math.min(MAX_SPEED, dist))

    -- If distance is greater than 1, proceed with walking
    if dist > 1 then
        local result = ComputeMove(pCmd, localPos, pDestination)

        -- Safety check - make sure result is valid
        if not result then return end

        -- Scale down the movements based on the calculated speed
        local scaleFactor = speed / MAX_SPEED
        pCmd:SetForwardMove(result.x * scaleFactor)
        pCmd:SetSideMove(result.y * scaleFactor)
    else
        pCmd:SetForwardMove(0)
        pCmd:SetSideMove(0)
    end
end

local playerTicks = {}
-- Removed: maxTick calculation no longer needed with NetChannel API
local maxTick = 0

-- Returns if the player is visible
---@param target Entity
---@param from Vector3
---@param to Vector3
---@return boolean
local function VisPos(target, from, to)
    local trace = engine.TraceLine(from, to, MASK_SHOT | CONTENTS_GRATE)
    return (trace.entity == target) or (trace.fraction > 0.99)
end

-- Returns whether the entity can be seen from the given entity
---@param fromEntity Entity
local function IsVisible(player, fromEntity)
    local from = fromEntity:GetAbsOrigin() + Vheight
    local to = player:GetAbsOrigin() + Vheight
    if from and to then
        return VisPos(player, from, to)
    else
        return false
    end
end

-- Function to get the best target
local function GetBestTarget(me, maxFov)
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then return end

    -- Collect candidates
    local normalCandidates = {} -- { {player=Entity, factor=number} }

    local meleeCandidates = {}

    -- Range threshold - use TotalSwingRange plus a buffer of 50 units
    local meleeRangeThreshold = TotalSwingRange + 50
    local foundTargetInMeleeRange = false

    local localPlayerViewAngles = engine.GetViewAngles()
    local localPlayerOrigin = localPlayer:GetAbsOrigin()
    local localPlayerEyePos = localPlayerOrigin + Vector3(0, 0, 75)

    -- Use configured FOV without restrictions
    local effectiveFOV = maxFov or Menu.Aimbot.AimbotFOV

    for _, player in pairs(players) do
        if player == nil
            or not player:IsValid()
            or not player:IsAlive()
            or player:IsDormant()
            or player == me or player:GetTeamNumber() == me:GetTeamNumber()
            or (gui.GetValue("ignore cloaked") == 1 and player:InCond(4))
            or (me:InCond(17) and (player:GetAbsOrigin().z - me:GetAbsOrigin().z) > 17)
            or not IsVisible(player, me) then
            goto continue
        end

        local playerOrigin = player:GetAbsOrigin()
        local distance = (playerOrigin - localPlayerOrigin):Length()
        local Pviewoffset = player:GetPropVector("localdata", "m_vecViewOffset[0]")
        local Pviewpos = playerOrigin + Pviewoffset

        -- Check if player is in FOV
        local angles = Math.PositionAngles(localPlayerOrigin, Pviewpos)
        local fov = Math.AngleFov(localPlayerViewAngles, angles)
        if fov > effectiveFOV then
            goto continue
        end

        -- Check if target is visible
        local isVisible = Helpers.VisPos(player, localPlayerEyePos, playerOrigin + Vector3(0, 0, 75))
        local visibilityFactor = isVisible and 1 or 0.1

        -- First priority: targets within melee range
        if distance <= meleeRangeThreshold then
            foundTargetInMeleeRange = true
            -- Base factor for melee targets
            local meleeFovFactor = Math.RemapValClamped(fov, 0, effectiveFOV, 1, 0.7)
            local factor = meleeFovFactor * visibilityFactor
            table.insert(meleeCandidates, { player = player, factor = factor })
        elseif distance <= 770 then
            -- Standard targets
            local distanceFactor = Math.RemapValClamped(distance, settings.MinDistance, settings.MaxDistance, 1, 0.9)
            local fovFactor = Math.RemapValClamped(fov, 0, effectiveFOV, 1, 0.1)
            local factor = distanceFactor * fovFactor * visibilityFactor
            table.insert(normalCandidates, { player = player, factor = factor })
        end
        ::continue::
    end

    -- Helper: choose best from candidates, applying health weighting if multiple
    local function chooseBest(cands)
        if #cands == 0 then return nil end
        -- If more than one, apply health weight
        if #cands > 1 then
            for _, c in pairs(cands) do
                local p = c.player
                local hp = p:GetHealth() or 0
                local maxhp = p:GetPropInt("m_iMaxHealth") or hp
                local missing = (maxhp > 0) and ((maxhp - hp) / maxhp) or 0
                c.factor = c.factor * (1 + missing)
            end
        end
        -- Pick max
        local best = cands[1]
        for i = 2, #cands do
            if cands[i].factor > best.factor then best = cands[i] end
        end
        return best.player
    end

    if foundTargetInMeleeRange then
        return chooseBest(meleeCandidates)
    else
        return chooseBest(normalCandidates)
    end
end

-- Function to check if target is in range
local function checkInRange(targetPos, spherePos, sphereRadius)
    local hitbox_min_trigger = targetPos + vHitbox[1]
    local hitbox_max_trigger = targetPos + vHitbox[2]

    -- Calculate the closest point on the hitbox to the sphere
    local closestPoint = Vector3(
        math.max(hitbox_min_trigger.x, math.min(spherePos.x, hitbox_max_trigger.x)),
        math.max(hitbox_min_trigger.y, math.min(spherePos.y, hitbox_max_trigger.y)),
        math.max(hitbox_min_trigger.z, math.min(spherePos.z, hitbox_max_trigger.z))
    )

    -- Calculate the distance from the closest point to the sphere center
    local distanceAlongVector = (spherePos - closestPoint):Length()

    -- Check if the target is within the sphere radius
    if sphereRadius > distanceAlongVector then
        -- Calculate the direction from spherePos to closestPoint
        local direction = Normalize(closestPoint - spherePos)
        local SwingtraceEnd = spherePos + direction * sphereRadius

        if Menu.Misc.advancedHitreg == true then
            local trace = engine.TraceLine(spherePos, SwingtraceEnd, MASK_SHOT_HULL)
            if trace.fraction < 1 and trace.entity == CurrentTarget then
                return true, closestPoint
            else
                local SwingHull = {
                    Min = Vector3(-SwingHalfhullSize, -SwingHalfhullSize, -SwingHalfhullSize),
                    Max =
                        Vector3(SwingHalfhullSize, SwingHalfhullSize, SwingHalfhullSize)
                }
                trace = engine.TraceHull(spherePos, SwingtraceEnd, SwingHull.Min, SwingHull.Max, MASK_SHOT_HULL)
                if trace.fraction < 1 and trace.entity == CurrentTarget then
                    return true, closestPoint
                else
                    return false, nil
                end
            end
        end

        return true, closestPoint
    else
        -- Target is not in range
        return false, nil
    end
end

local Hitbox = {
    Head = 1,
    Neck = 2,
    Pelvis = 4,
    Body = 5,
    Chest = 7
}

local function calculateMaxAngleChange(currentVelocity, minVelocity, maxTurnRate)
    -- Assuming a linear relationship between turn rate and velocity drop
    -- More complex relationships will require a more sophisticated model

    -- If current velocity is already below the threshold, no turning is allowed
    if currentVelocity < minVelocity then
        return 0
    end

    -- Calculate the proportion of velocity we can afford to lose
    local velocityBuffer = currentVelocity - minVelocity

    -- Assuming maxTurnRate is the turn rate at which the velocity would drop to zero
    -- Calculate the maximum turn rate that would reduce the velocity to the threshold
    local maxSafeTurnRate = (velocityBuffer / currentVelocity) * maxTurnRate

    return maxSafeTurnRate
end

-- At the top of the file, after the initial libraries and imports

-- Constants for charge control
local CHARGE_CONSTANTS = {
    TURN_MULTIPLIER = 1.0,
    MAX_ROTATION_PER_FRAME = 73.04,
    SIDE_MOVE_VALUE = 450
}

-- State tracking variables
local prevCharging = false

-- Condition IDs
local CONDITIONS = {
    CHARGING = 17
}

local function playerHasChargeShield(player)
    assert(player, "playerHasChargeShield: player missing")
    local shields = entities.FindByClass("CTFWearableDemoShield")
    if not shields then
        return false, nil
    end
    for _, shield in pairs(shields) do
        if shield and shield:IsValid() then
            local owner = shield:GetPropEntity("m_hOwnerEntity")
            if owner == player then
                local defIndex = shield:GetPropInt("m_iItemDefinitionIndex") or 0
                return true, defIndex
            end
        end
    end
    return false, nil
end

-- Improved ChargeControl function that incorporates logic from Charge_controll.lua
local function ChargeControl(pCmd)
    -- Check if charge control is enabled in the menu
    if Menu.Charge.ChargeControl ~= true then
        return
    end

    -- Skip if not charging
    if not pLocal:InCond(17) then
        return
    end

    -- Find all demo shields by class name
    local shields = entities.FindByClass("CTFWearableDemoShield")

    -- Check if any shield belongs to player and is Tide Turner
    for i, shield in pairs(shields) do
        if shield and shield:IsValid() then
            local owner = shield:GetPropEntity("m_hOwnerEntity")

            if owner == pLocal then
                local defIndex = shield:GetPropInt("m_iItemDefinitionIndex")

                -- Check if it's Tide Turner (ID 1099)
                if defIndex == 1099 then
                    -- Skip charge control for Tide Turner
                    return
                end
            end
        end
    end

    -- Get mouse X movement (negative = left, positive = right)
    local mouseDeltaX = -pCmd.mousedx

    -- Skip processing if no horizontal mouse movement
    if mouseDeltaX == 0 then
        return
    end

    -- Get current view angles and game settings
    local currentAngles = engine.GetViewAngles()
    local m_yaw = select(2, client.GetConVar("m_yaw")) -- Get m_yaw from game settings

    -- Calculate turn amount using standard Source engine formula
    local turnAmount = mouseDeltaX * m_yaw * CHARGE_CONSTANTS.TURN_MULTIPLIER

    -- Apply side movement based on turning direction (simulate A/D keys)
    if turnAmount > 0 then
        -- Turning left, simulate pressing D (right strafe)
        pCmd.sidemove = CHARGE_CONSTANTS.SIDE_MOVE_VALUE
    else
        -- Turning right, simulate pressing A (left strafe)
        pCmd.sidemove = -CHARGE_CONSTANTS.SIDE_MOVE_VALUE
    end

    -- CRITICAL: Limit maximum turn per frame to 73.04 degrees
    turnAmount = Clamp(turnAmount, -MAX_CHARGE_BOT_TURN, MAX_CHARGE_BOT_TURN)

    -- Calculate new yaw angle
    local newYaw = currentAngles.yaw + turnAmount

    -- Handle -180/180 degree boundary crossing
    newYaw = newYaw % 360
    if newYaw > 180 then
        newYaw = newYaw - 360
    elseif newYaw < -180 then
        newYaw = newYaw + 360
    end

    -- Set the new view angles
    engine.SetViewAngles(EulerAngles(currentAngles.pitch, newYaw, currentAngles.roll))
end

local acceleration = 750

local function UpdateHomingMissile()
    local pLocalPos = pLocal:GetAbsOrigin()
    local vPlayerPos = vPlayerOrigin
    local pLocalVel = pLocal:EstimateAbsVelocity()
    local vPlayerVel = vPlayer:EstimateAbsVelocity()

    local timeStep = globals.TickInterval() -- Time step for simulation
    local interceptPoint = nil
    local interceptTime = 0

    while interceptTime <= 3 do
        -- Simulate the target's next position
        vPlayerPos = vPlayerPos + (vPlayerVel * timeStep)

        -- Calculate the distance to the target's new position
        local distanceToTarget = (vPlayerPos - pLocalPos):Length()

        -- Calculate the time it would take for Demoman to reach this distance
        -- with the given acceleration (using the formula: d = 0.5 * a * t^2)
        local timeToReach = math.sqrt(2 * distanceToTarget / acceleration)

        if timeToReach <= interceptTime then
            interceptPoint = vPlayerPos
            break
        end

        interceptTime = interceptTime + timeStep
    end

    if interceptPoint then
        return interceptPoint
    end
end

local hasNotified = false
local function checkInRangeSimple(playerIndex, swingRange, pWeapon, cmd)
    local inRange = false
    local point = nil

    -- If instant attack (warp) is ready, use current positions only (time is frozen).
    local instantAttackReady = Menu.Misc.InstantAttack and warp.CanWarp() and
        warp.GetChargedTicks() >= Menu.Aimbot.SwingTime
    if instantAttackReady then
        inRange, point = checkInRange(vPlayerOrigin, pLocalOrigin, swingRange)
        if inRange then
            return inRange, point, false
        end
        return false, nil, false
    end

    -- Prefer predicted positions: swing lands after SwingTime ticks,
    -- so predicted range is what matters to avoid premature swings.
    inRange, point = checkInRange(vPlayerFuture, pLocalFuture, swingRange)
    if inRange then
        return inRange, point, false, true
    end

    -- Fallback: current positions (stationary targets, edge cases)
    inRange, point = checkInRange(vPlayerOrigin, pLocalOrigin, swingRange)
    if inRange then
        return inRange, point, false, false
    end

    return false, nil, false, false
end

-- Store the original Crit Hack Key value outside the main loop or function
local originalCritHackKey = 0
local originalMeleeCritHack = 0
local menuWasOpen = false
local critRefillActive = false
local lastCritBucketValue = -1
local critBucketStallCount = 0
local CRIT_REFILL_PROXIMITY_MULTIPLIER = 4
local CRIT_BUCKET_MAX_STALL_TICKS = 132
local dashKeyNotBoundNotified = true

local function AnyEnemyWithinRange(localPlayer, range)
    assert(localPlayer, "AnyEnemyWithinRange: localPlayer missing")
    local localOrigin = localPlayer:GetAbsOrigin()
    local localTeam = localPlayer:GetTeamNumber()
    local allPlayers = entities.FindByClass("CTFPlayer")
    for _, ent in pairs(allPlayers) do
        if ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant()
            and ent ~= localPlayer and ent:GetTeamNumber() ~= localTeam then
            local dist = (ent:GetAbsOrigin() - localOrigin):Length()
            if dist <= range then
                return true
            end
        end
    end
    return false
end

local function IsChargeBotActiveByMode()
    local chargeActivationMode = Menu.Charge.ChargeBotActivationMode or 1
    if chargeActivationMode == 1 then
        return true
    end

    local chargeKeybind = Menu.Charge.ChargeBotKeybind or KEY_NONE
    if chargeKeybind == KEY_NONE then
        return chargeActivationMode == 3
    end

    local keyHeld = input.IsButtonDown(chargeKeybind)
    if chargeActivationMode == 2 then
        return keyHeld
    end
    return not keyHeld
end

--[[ Code needed to run 66 times a second ]] --
-- Predicts player position after set amount of ticks
---@param strafeAngle number
local function OnCreateMove(pCmd)
    Profiler.BeginSystem("SwingPred_Tick")

    -- Clear ALL entity variables at start of every tick to prevent stale references
    pLocal = nil
    pWeapon = nil
    players = nil
    CurrentTarget = nil
    vPlayer = nil
    pLocalClass = nil
    pLocalFuture = nil
    pLocalOrigin = nil
    vPlayerFuture = nil
    vPlayerOrigin = nil
    chargeLeft = nil
    onGround = nil
    aimposVis = nil
    Latency = nil
    viewheight = nil
    Vheight = nil

    -- Clear visual data
    pLocalPath = {}
    vPlayerPath = {}
    drawVhitbox = {}

    Profiler.Begin("Setup")
    -- Periodic cleanup of stale cache entries (once every 5 seconds)
    local currentTime = globals.RealTime()
    if currentTime - (lastCacheCleanup or 0) > 5 then
        lastCacheCleanup = currentTime
        cleanupStaleCacheEntries()
    end

    -- Update jitter tracker each tick
    UpdateJitterTracker()

    -- Reset state flags
    isMelee = false
    can_attack = false
    can_charge = false

    -- Get the local player entity
    pLocal = entities.GetLocalPlayer()
    Profiler.End("Setup")
    if not pLocal or not pLocal:IsAlive() then
        Profiler.EndSystem("SwingPred_Tick")
        goto continue -- Return if the local player entity doesn't exist or is dead
    end

    local hasChargeShield, shieldDefIndex = playerHasChargeShield(pLocal)

    -- Update stepSize per-tick based on current player
    stepSize = pLocal:GetPropFloat("localdata", "m_flStepSize") or 18

    -- Track latest +attack input (from user or script) for charge-reach logic
    if (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
        lastAttackTick = globals.TickCount()
    end

    -- Quick reference values used multiple times
    pLocalClass              = pLocal:GetPropInt("m_iClass")
    chargeLeft               = pLocal:GetPropFloat("m_flChargeMeter")
    local chargeReachEnabled = Menu.Charge and Menu.Charge.ChargeReach == true

    if not chargeReachEnabled then
        resetAttackTracking()
        chargeState = "idle"
        chargeAimAngles = nil
    end

    -- ===== Charge Reach State Machine (Demoman only) =====
    Profiler.Begin("ChargeStateMachine")
    local chargeBotActiveNow = Menu.Charge.ChargeBot == true and IsChargeBotActiveByMode()
    if chargeReachEnabled and pLocalClass == 4 and hasChargeShield then
        if chargeState == "aim" then
            if chargeAimAngles then
                if chargeBotActiveNow then
                    engine.SetViewAngles(EulerAngles(chargeAimAngles.pitch, chargeAimAngles.yaw, 0))
                else
                    pCmd:SetViewAngles(chargeAimAngles.pitch, chargeAimAngles.yaw, 0)
                end
            end
            chargeState = "charge" -- next tick will trigger charge
        elseif chargeState == "charge" then
            pCmd:SetButtons(pCmd:GetButtons() | IN_ATTACK2)
            chargeState = "idle"
            chargeAimAngles = nil
        end
    else
        -- Not Demoman: never drive charge reach state machine
        chargeState = "idle"
        chargeAimAngles = nil
    end
    -- =====================================
    Profiler.End("ChargeStateMachine")

    -- Show notification if instant attack is enabled but dash key is not bound
    if Menu.Misc.InstantAttack == true and gui.GetValue("dash move key") == 0 and not dashKeyNotBoundNotified then
        Notify.Simple("Instant Attack Warning", "Dash key is not bound. Instant Attack will not work properly.", 4)
        dashKeyNotBoundNotified = true
    elseif (Menu.Misc.InstantAttack ~= true or gui.GetValue("dash move key") ~= 0) and dashKeyNotBoundNotified then
        dashKeyNotBoundNotified = false
    end

    local fChargeBeginTime = (pLocal:GetPropFloat("PipebombLauncherLocalData", "m_flChargeBeginTime") or 0);

    -- Check if the local player is a spy
    pLocalClass = pLocal:GetPropInt("m_iClass")
    if pLocalClass == nil or pLocalClass == 8 then
        Profiler.EndSystem("SwingPred_Tick")
        goto continue -- Skip the rest of the code if the local player is a spy or hasn't chosen a class
    end

    -- Get the local player's active weapon
    pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
    if not pWeapon then
        Profiler.EndSystem("SwingPred_Tick")
        goto continue -- Return if the local player doesn't have an active weapon
    end
    local nextPrimaryAttack = pWeapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")
    --print(Conversion.Time_to_Ticks(nextPrimaryAttack) .. "LastShoot", globals.TickCount())

    -- Latency compensation removed - TF2 handles this automatically

    -- Get the local player's flags and charge meter
    local flags = pLocal:GetPropInt("m_fFlags")
    local airbone = pLocal:InCond(81)
    chargeLeft = pLocal:GetPropFloat("m_flChargeMeter")
    chargeLeft = math.floor(chargeLeft)

    -- Get the local player's active weapon data and definition
    local pWeaponData = pWeapon:GetWeaponData()
    local pWeaponID = pWeapon:GetWeaponID()
    local pWeaponDefIndex = pWeapon:GetPropInt("m_iItemDefinitionIndex")
    local pWeaponDef = itemschema.GetItemDefinitionByID(pWeaponDefIndex)
    local pWeaponName = pWeaponDef:GetName()
    local pUsingMargetGarden = false

    if pWeaponDefIndex == 416 then
        pUsingMargetGarden = true
    end

    --[--Troldier assist--]
    if Menu.Misc.TroldierAssist == true then
        local state = ""
        if airbone then
            pCmd:SetButtons(pCmd.buttons | IN_DUCK)
            state = "slot3"
        else
            state = "slot1"
        end

        client.Command(state, true)
    end

    --[-Don`t run script below when not usign melee--]

    isMelee = pWeapon:IsMeleeWeapon() -- check if using melee weapon
    if not isMelee then
        Profiler.EndSystem("SwingPred_Tick")
        goto continue
    end -- if not melee then skip code

    --[-------Get pLocalOrigin--------]

    -- Get pLocal eye level and set vector at our eye level to ensure we check distance from eyes
    local viewOffset = pLocal:GetPropVector("localdata", "m_vecViewOffset[0]") -- Vector3(0, 0, 70)
    local adjustedHeight = pLocal:GetAbsOrigin() + viewOffset
    viewheight = (adjustedHeight - pLocal:GetAbsOrigin()):Length()

    -- Eye level
    Vheight = Vector3(0, 0, viewheight)
    pLocalOrigin = (pLocal:GetAbsOrigin() + Vheight)

    --[-------- Get SwingRange --------]
    swingrange = pWeapon:GetSwingRange()

    SwingHullSize = 35.6
    SwingHalfhullSize = SwingHullSize / 2

    if pWeaponDef:GetName() == "The Disciplinary Action" then
        SwingHullSize = 55.8
        swingrange = 81.6
    end

    -- Store normal weapon range when NOT charging (this is the true weapon range)
    local isCurrentlyCharging = pLocal:InCond(17)
    if not isCurrentlyCharging then
        normalWeaponRange = swingrange
        normalTotalSwingRange = swingrange + (SwingHullSize / 2)
    end

    -- Simple charge reach logic
    local hasFullCharge = chargeLeft == 100
    local isDemoman = pLocalClass == 4
    local isExploitReady = Menu.Charge.ChargeReach == true and hasFullCharge and isDemoman and hasChargeShield
    local withinAttackWindow = (globals.TickCount() - lastAttackTick) <= 13

    if isCurrentlyCharging then
        -- When charging: check if we swung within last 13 ticks
        local isDoingExploit = Menu.Charge.ChargeReach == true and withinAttackWindow and hasChargeShield

        if isDoingExploit then
            -- Use charge reach range (128) + hull size for total range
            TotalSwingRange = Charge_Range + (SwingHullSize / 2)
            --client.ChatPrintf("[Debug] Charge reach exploit active! TotalSwingRange = " .. TotalSwingRange)
        else
            -- Force back to normal weapon range
            swingrange = normalWeaponRange
            TotalSwingRange = normalTotalSwingRange
            --client.ChatPrintf("[Debug] Charging without exploit, TotalSwingRange = " .. TotalSwingRange)
        end
    else
        -- Not charging: check if ready for exploit
        if isExploitReady then
            -- Use charge reach range (128) + hull size when ready
            TotalSwingRange = Charge_Range + (SwingHullSize / 2)
        else
            -- Normal weapon range
            TotalSwingRange = swingrange + (SwingHullSize / 2)
        end
    end
    --[--Manual charge control--]

    if Menu.Charge.ChargeControl == true and pLocal:InCond(17) and hasChargeShield then
        ChargeControl(pCmd)
    end

    --[-----Get best target------------------]
    local keybind = Menu.Keybind
    local chargeBotModeActive = IsChargeBotActiveByMode()
    local chargeBotTargetingActive = Menu.Charge.ChargeBot == true and chargeBotModeActive
    local isChargeBotLockContext = chargeBotTargetingActive and pLocalClass == 4 and hasChargeShield
        and (pLocal:InCond(17) or (chargeLeft == 100 and input.IsButtonDown(MOUSE_RIGHT)))
    local selectedTargetFOV = Menu.Aimbot.AimbotFOV
    if isChargeBotLockContext then
        selectedTargetFOV = Menu.Charge.ChargeBotFOV
    end

    -- Get fresh player list each tick
    players = entities.FindByClass("CTFPlayer")

    if keybind == 0 then
        -- Check if player has no key bound
        CurrentTarget = GetBestTarget(pLocal, selectedTargetFOV)
        vPlayer = CurrentTarget
    elseif input.IsButtonDown(keybind) then
        -- If player has bound key for aimbot, only work when it's on
        CurrentTarget = GetBestTarget(pLocal, selectedTargetFOV)
        vPlayer = CurrentTarget
    elseif chargeBotTargetingActive then
        CurrentTarget = GetBestTarget(pLocal, Menu.Charge.ChargeBotFOV)
        vPlayer = CurrentTarget
    else
        CurrentTarget = nil
        vPlayer = nil
    end

    ---------------critHack------------------
    -- Main logic

    -- Check if menu is open to capture user settings
    local menuIsOpen = gui.IsMenuOpen()

    -- If menu just opened, update our stored values
    if menuIsOpen and not menuWasOpen then
        originalCritHackKey = gui.GetValue("Crit Hack Key")
        originalMeleeCritHack = gui.GetValue("Melee Crit Hack")
    end

    -- Update menu state for next frame
    menuWasOpen = menuIsOpen

    -- Only proceed with crit refill logic when menu is closed
    local serverAllowsCrits = (client.GetConVar("tf_weapon_criticals") or 0) ~= 0
        and (client.GetConVar("tf_weapon_criticals_melee") or 0) ~= 0
    if not menuIsOpen and pWeapon and serverAllowsCrits then
        local CritValue = 39
        local CritBucket = pWeapon:GetCritTokenBucket()
        local NumCrits = CritValue * Menu.Misc.CritRefill.NumCrits
        NumCrits = math.clamp(NumCrits, 27, 1000)

        local proximityRange = TotalSwingRange * CRIT_REFILL_PROXIMITY_MULTIPLIER
        local enemyNearby = AnyEnemyWithinRange(pLocal, proximityRange)
        local safeToRefill = not enemyNearby and CurrentTarget == nil

        if safeToRefill and Menu.Misc.CritRefill.Active and CritBucket < NumCrits then
            if not critRefillActive then
                gui.SetValue("Crit Hack Key", 0)
                gui.SetValue("Melee Crit Hack", 2)
                critRefillActive = true
                lastCritBucketValue = CritBucket
                critBucketStallCount = 0
            end

            if CritBucket > lastCritBucketValue then
                lastCritBucketValue = CritBucket
                critBucketStallCount = 0
            else
                critBucketStallCount = critBucketStallCount + 1
            end

            if critBucketStallCount >= CRIT_BUCKET_MAX_STALL_TICKS then
                gui.SetValue("Crit Hack Key", originalCritHackKey)
                gui.SetValue("Melee Crit Hack", Menu.Misc.CritMode)
                critRefillActive = false
                lastCritBucketValue = -1
                critBucketStallCount = 0
            else
                pCmd:SetButtons(pCmd:GetButtons() | IN_ATTACK)
            end
        else
            if critRefillActive then
                gui.SetValue("Crit Hack Key", originalCritHackKey)
                gui.SetValue("Melee Crit Hack", Menu.Misc.CritMode)
                critRefillActive = false
                lastCritBucketValue = -1
                critBucketStallCount = 0
            end
        end
    else
        if critRefillActive then
            gui.SetValue("Crit Hack Key", originalCritHackKey)
            gui.SetValue("Melee Crit Hack", Menu.Misc.CritMode)
            critRefillActive = false
            lastCritBucketValue = -1
            critBucketStallCount = 0
        end
    end

    local Target_ONGround
    local strafeAngle = 0
    can_attack = false
    local stop = false
    local OnGround = (flags & FL_ONGROUND) ~= 0

    --[[--------------Modular Charge-Jump (manual) -------------------]]
    if Menu.Charge.ChargeJump == true and pLocalClass == 4 and hasChargeShield then
        if (pCmd:GetButtons() & IN_ATTACK2) ~= 0 and chargeLeft == 100 and OnGround then
            local jumpJitterDelay = GetJitterOffsetTicks()
            pCmd:SetButtons(pCmd:GetButtons() & ~IN_ATTACK2)
            pCmd:SetButtons(pCmd:GetButtons() | IN_JUMP)
            chargeJumpPendingTick = globals.TickCount() + jumpJitterDelay
        end
        if chargeJumpPendingTick and globals.TickCount() >= chargeJumpPendingTick then
            pCmd:SetButtons(pCmd:GetButtons() | IN_ATTACK2)
            chargeJumpPendingTick = nil
        end
    end

    --[--------------Prediction-------------------]
    -- Predict both players' positions after swing
    gravity = client.GetConVar("sv_gravity")
    stepSize = pLocal:GetPropFloat("localdata", "m_flStepSize") or stepSize

    Profiler.Begin("CalcStrafe")
    -- Ensure players list is populated before using in CalcStrafe
    if not players then
        players = entities.FindByClass("CTFPlayer")
    end
    CalcStrafe()
    Profiler.End("CalcStrafe")

    Profiler.Begin("LocalPrediction")
    -- Local player prediction
    if pLocal:EstimateAbsVelocity():Length() < 10 then
        -- If the local player is not accelerating, set the predicted position to the current position
        pLocalFuture = pLocalOrigin
    else
        -- Always predict local player movement regardless of instant attack state
        local player = WPlayer.FromEntity(pLocal)

        -- Check if we're doing instant attack with warp
        local instantAttackReady = Menu.Misc.InstantAttack == true and warp.CanWarp() and
            warp.GetChargedTicks() >= Menu.Aimbot.SwingTime

        -- Don't use strafe prediction when warping (time is frozen for us too)
        local useStrafePred = Menu.Misc.strafePred == true and
            not (instantAttackReady and Menu.Misc.WarpOnAttack == true)
        strafeAngle = useStrafePred and strafeAngles[pLocal:GetIndex()] or 0

        -- Always use weapon-specific ticks for simulation with instant attack
        local simTicks = Menu.Aimbot.SwingTime
        if not instantAttackReady then
            simTicks = Menu.Aimbot.SwingTime
        end

        -- When charging but NOT doing exploit: suppress charge speed in sim.
        -- Swing cancels charge instantly, so predict at walking speed.
        -- During exploit execution (swinging during charge): allow full charge speed.
        local localCharging = pLocal:InCond(17)
        local localExploitActive = localCharging and Menu.Charge.ChargeReach == true
            and (globals.TickCount() - lastAttackTick) <= 13 and hasChargeShield
        local suppressCharge = localCharging and not localExploitActive
        local predData = PredictPlayer(player, simTicks, strafeAngle, false, nil, pCmd, suppressCharge)
        if not predData then
            Profiler.End("LocalPrediction")
            Profiler.EndSystem("SwingPred_Tick")
            return
        end

        pLocalPath = predData.pos
        pLocalFuture = predData.pos[simTicks] + viewOffset
    end
    Profiler.End("LocalPrediction")

    -- stop if no target
    if CurrentTarget == nil then
        Profiler.EndSystem("SwingPred_Tick")
        return
    end

    -- Validate target is still valid (alive, not dormant, etc.)
    if not CurrentTarget:IsValid() or not CurrentTarget:IsAlive() or CurrentTarget:IsDormant() then
        Profiler.EndSystem("SwingPred_Tick")
        return
    end

    vPlayerOrigin = CurrentTarget:GetAbsOrigin() -- Get closest player origin

    local VpFlags = CurrentTarget:GetPropInt("m_fFlags")
    local DUCKING = (VpFlags & FL_DUCKING) ~= 0
    if DUCKING then
        vHitbox[2].z = 62
    else
        vHitbox[2].z = 82
    end

    -- Check if instant attack is ready (no dash-key dependency)
    local instantAttackReady = Menu.Misc.InstantAttack == true and warp.CanWarp() and
        warp.GetChargedTicks() >= Menu.Aimbot.SwingTime
    local canInstantAttack = instantAttackReady

    -- Debug output for instant attack status (only when instant attack is enabled)
    if Menu.Misc.InstantAttack == true and can_attack then
        local chargedTicks = warp.GetChargedTicks() or 0
        local canWarp = warp.CanWarp()
        local swingTime = Menu.Aimbot.SwingTime
        client.ChatPrintf(string.format(
            "[Debug] InstantAttack Check: CanWarp=%s, ChargedTicks=%d, SwingTime=%d, Ready=%s",
            tostring(canWarp), chargedTicks, swingTime, tostring(instantAttackReady)))
    end

    Profiler.Begin("EnemyPrediction")
    if not instantAttackReady then
        -- Only predict enemy movement when NOT using instant attack
        local player = WPlayer.FromEntity(CurrentTarget)
        strafeAngle = strafeAngles[CurrentTarget:GetIndex()] or 0

        -- Default to Menu.Aimbot.SwingTime since we're not using instant attack
        local simTicks = Menu.Aimbot.SwingTime

        local targetDistance = (CurrentTarget:GetAbsOrigin() - pLocalOrigin):Length()
        local complexSimDistance = TotalSwingRange * 2

        local predData
        if targetDistance <= complexSimDistance then
            predData = PredictPlayer(player, simTicks, strafeAngle, false, nil)
        else
            -- Far target: keep history updated, but skip expensive collision simulation.
            StrafePredictor.updateAll({ CurrentTarget })
            WishdirTracker.updateLight(CurrentTarget)
            predData = PredictPlayerSimpleLinear(CurrentTarget, simTicks, strafeAngle)
        end

        if not predData then
            Profiler.End("EnemyPrediction")
            Profiler.EndSystem("SwingPred_Tick")
            return
        end

        vPlayerPath = predData.pos
        vPlayerFuture = predData.pos[simTicks]

        drawVhitbox[1] = vPlayerFuture + vHitbox[1]
        drawVhitbox[2] = vPlayerFuture + vHitbox[2]
    else
        -- When using instant attack, enemy doesn't move (time is frozen for them)
        vPlayerFuture = CurrentTarget:GetAbsOrigin()
        drawVhitbox[1] = vPlayerFuture + vHitbox[1]
        drawVhitbox[2] = vPlayerFuture + vHitbox[2]
    end
    Profiler.End("EnemyPrediction")

    --[--------------Distance check using TotalSwingRange-------------------]
    -- Get current distance between local player and closest player
    local vdistance = (vPlayerOrigin - pLocalOrigin):Length()

    -- Get distance between local player and closest player after swing
    local fDistance = (vPlayerFuture - pLocalFuture):Length()
    local inRange = false
    local inRangePoint = Vector3(0, 0, 0)

    Profiler.Begin("RangeCheck")
    -- Use TotalSwingRange for range checking (already calculated with charge reach logic)
    local hitFromPredicted
    inRange, inRangePoint, can_charge, hitFromPredicted = checkInRangeSimple(CurrentTarget:GetIndex(), TotalSwingRange,
        pWeapon, pCmd)
    -- Use inRange to decide if can attack
    can_attack = inRange

    -- Always aim at current position, even when range check used predicted positions.
    -- Recompute aim point from current positions so we aim where the target IS now.
    local currentAimPoint = inRangePoint
    if inRange and hitFromPredicted then
        local _, curPoint = checkInRange(vPlayerOrigin, pLocalOrigin, TotalSwingRange)
        if curPoint then
            currentAimPoint = curPoint
        end
    end

    Profiler.End("RangeCheck")

    --[--------------AimBot-------------------]
    Profiler.Begin("Aimbot")
    local aimpos = CurrentTarget:GetAbsOrigin() + Vheight

    if Menu.Aimbot.Aimbot == true then
        local aim_angles
        if currentAimPoint then
            aimpos = currentAimPoint
            aimposVis = aimpos
            aim_angles = Math.PositionAngles(pLocalOrigin, aimpos)
        end

        local chargeBotEnabled = Menu.Charge.ChargeBot == true and chargeBotModeActive
        local isDemoknight = pLocalClass == 4 and hasChargeShield

        -- Charge-bot steering while actively charging (only when ChargeBot enabled)
        if chargeBotEnabled and isDemoknight and pLocal:InCond(17) and not can_attack then
            local aimPosTarget = inRangePoint or vPlayerFuture
            if aimPosTarget then
                local traceTarget = engine.TraceHull(pLocalOrigin, aimPosTarget, vHitbox[1], vHitbox[2],
                    MASK_PLAYERSOLID_BRUSHONLY)
                if traceTarget.fraction == 1 or traceTarget.entity == CurrentTarget then
                    aim_angles = Math.PositionAngles(pLocalOrigin, aimPosTarget)
                    local currentAng = engine.GetViewAngles()
                    local yawDiff = NormalizeYaw(aim_angles.yaw - currentAng.yaw)
                    local limitedYaw = NormalizeYaw(currentAng.yaw +
                        Clamp(yawDiff, -MAX_CHARGE_BOT_TURN, MAX_CHARGE_BOT_TURN))
                    engine.SetViewAngles(EulerAngles(aim_angles.pitch, limitedYaw, 0))
                end
            end

            -- Pre-charge aim: look at target BEFORE initiating charge (only when ChargeBot enabled)
        elseif chargeBotEnabled and isDemoknight and chargeLeft == 100
            and input.IsButtonDown(MOUSE_RIGHT) and not can_attack and fDistance < 750 then
            local aimPosTarget = inRangePoint or vPlayerFuture
            if aimPosTarget then
                local traceTarget = engine.TraceHull(pLocalFuture, aimPosTarget, vHitbox[1], vHitbox[2],
                    MASK_PLAYERSOLID_BRUSHONLY)
                if traceTarget.fraction == 1 or traceTarget.entity == CurrentTarget then
                    aim_angles = Math.PositionAngles(pLocalOrigin, aimPosTarget)
                    local currentAng = engine.GetViewAngles()
                    local yawDiff = NormalizeYaw(aim_angles.yaw - currentAng.yaw)
                    local limitedYaw = NormalizeYaw(currentAng.yaw +
                        Clamp(yawDiff, -MAX_CHARGE_BOT_TURN, MAX_CHARGE_BOT_TURN))
                    engine.SetViewAngles(EulerAngles(aim_angles.pitch, limitedYaw, 0))
                end
            end

            -- Normal aimbot: snap to target when in range
        elseif can_attack and aim_angles and aim_angles.pitch and aim_angles.yaw then
            if Menu.Aimbot.Silent == true then
                pCmd:SetViewAngles(aim_angles.pitch, aim_angles.yaw, 0)
            else
                engine.SetViewAngles(EulerAngles(aim_angles.pitch, aim_angles.yaw, 0))
            end
        end
    end
    Profiler.End("Aimbot")



    Profiler.Begin("AttackLogic")
    -- Only try instant attack when it's possible
    if can_attack then
        -- Get the actual weapon smack delay if available
        local weaponSmackDelay = 13 -- Default fallback value
        if pWeapon and pWeapon:GetWeaponData() then
            local weaponData = pWeapon:GetWeaponData()
            if weaponData and weaponData.smackDelay then
                -- Convert smackDelay time to ticks (rounded up to ensure we have enough time)
                weaponSmackDelay = math.floor(weaponData.smackDelay / globals.TickInterval())
                -- Ensure a minimum viable value
                weaponSmackDelay = math.max(weaponSmackDelay, 5)

                -- Update the menu's SwingTime setting to match the current weapon's properties
                -- Only update if it's different to avoid constant updates
                if Menu.Aimbot.SwingTime ~= weaponSmackDelay then
                    local oldValue = Menu.Aimbot.SwingTime or 13 -- Add default value if nil

                    -- If user has enabled "Always Use Max", or set the value to the current max,
                    -- update the swing time to the new maximum
                    if Menu.Aimbot.AlwaysUseMaxSwingTime == true or oldValue >= (Menu.Aimbot.MaxSwingTime or 13) then
                        Menu.Aimbot.SwingTime = weaponSmackDelay
                    end

                    -- Update the maximum swing time value for the slider
                    Menu.Aimbot.MaxSwingTime = weaponSmackDelay

                    -- Display notification about the change with weapon name
                    pWeaponName = "Unknown"
                    pcall(function()
                        pWeaponDefIndex = pWeapon:GetPropInt("m_iItemDefinitionIndex")
                        pWeaponDef = itemschema.GetItemDefinitionByID(pWeaponDefIndex)
                        pWeaponName = pWeaponDef and pWeaponDef:GetName() or "Unknown"
                    end)

                    -- Display formatted notification with more details
                    Notify.Simple(string.format(
                        "Updated SwingTime for %s:\n - Old value: %d ticks\n - New value: %d ticks\n - Actual delay: %.2f seconds",
                        pWeaponName,
                        oldValue,
                        Menu.Aimbot.SwingTime or weaponSmackDelay,
                        weaponData.smackDelay
                    ))
                end
            end
        end

        if Menu.Misc.InstantAttack == true and canInstantAttack and Menu.Misc.WarpOnAttack == true then
            -- Instant attack with warp is enabled and ready
            local velocity = pLocal:EstimateAbsVelocity()
            local oppositePoint

            -- Calculate opposite point for movement
            if velocity:Length() > 10 then
                oppositePoint = pLocal:GetAbsOrigin() - velocity
            else
                local angles = engine.GetViewAngles()
                local forward = angles:Forward()
                oppositePoint = pLocal:GetAbsOrigin() + forward * 20
            end

            -- Move to opposite point for better warp positioning
            if oppositePoint and (oppositePoint - pLocal:GetAbsOrigin()):Length() < 300 then
                WalkTo(pCmd, pLocal, oppositePoint)
            end

            -- Set up the attack and warp
            pCmd:SetButtons(pCmd:GetButtons() | IN_ATTACK) -- Initiate attack

            client.RemoveConVarProtection("sv_maxusrcmdprocessticks")
            local safeTickValue = math.min(weaponSmackDelay, 20)
            client.SetConVar("sv_maxusrcmdprocessticks", safeTickValue)

            -- Trigger the warp
            local chargedTicks = warp.GetChargedTicks() or 0
            if chargedTicks >= safeTickValue then
                warp.TriggerWarp(safeTickValue)
                -- Debug output
                client.ChatPrintf("[Debug] Instant Attack: Warping with " .. chargedTicks .. " ticks")
            else
                -- Not enough ticks for warp, but still do instant attack without warp
                client.ChatPrintf("[Debug] Instant Attack: Not enough ticks (" ..
                    chargedTicks .. "/" .. safeTickValue .. "), normal attack")
            end

            can_attack = false
        elseif Menu.Misc.InstantAttack == true and canInstantAttack and Menu.Misc.WarpOnAttack ~= true then
            -- Instant attack enabled but warp disabled - just do normal attack
            client.ChatPrintf("[Debug] Instant Attack: Warp disabled, using normal attack")
            local normalAttackTicks = math.min(math.floor(weaponSmackDelay), 24)
            client.RemoveConVarProtection("sv_maxusrcmdprocessticks")
            client.SetConVar("sv_maxusrcmdprocessticks", normalAttackTicks)
            pCmd:SetButtons(pCmd:GetButtons() | IN_ATTACK)
            can_attack = false
        else
            -- Normal attack (instant attack disabled or not ready)
            local normalAttackTicks = math.min(math.floor(weaponSmackDelay), 24)
            client.RemoveConVarProtection("sv_maxusrcmdprocessticks")
            client.SetConVar("sv_maxusrcmdprocessticks", normalAttackTicks)
            pCmd:SetButtons(pCmd:GetButtons() | IN_ATTACK)

            -- Start tracking attack ticks for charge reach exploit
            if pLocalClass == 4 and Menu.Charge.ChargeReach == true and chargeLeft == 100 and hasChargeShield and not attackStarted then
                attackStarted = true
                attackTickCount = 0
                -- Store aim direction to target future position so charge travels correctly
                if inRangePoint then
                    chargeAimAngles = Math.PositionAngles(pLocalOrigin, inRangePoint)
                else
                    chargeAimAngles = Math.PositionAngles(pLocalOrigin, vPlayerFuture)
                end
            end

            can_attack = false
        end

        -- Track attack ticks and execute charge at right moment
        if attackStarted then
            if not (chargeReachEnabled and pLocalClass == 4 and hasChargeShield and chargeLeft == 100) then
                resetAttackTracking()
                chargeState = "idle"
                chargeAimAngles = nil
            else
                attackTickCount = attackTickCount + 1

                -- Get weapon smack delay (when the weapon will hit)
                local weaponSmackDelay = Menu.Aimbot.MaxSwingTime
                if pWeapon and pWeapon:GetWeaponData() and pWeapon:GetWeaponData().smackDelay then
                    weaponSmackDelay = math.floor(pWeapon:GetWeaponData().smackDelay / globals.TickInterval())
                end

                -- If charge-jump enabled issue jump with jitter delay before charge
                if Menu.Charge.ChargeJump == true and OnGround then
                    pCmd:SetButtons(pCmd:GetButtons() | IN_JUMP)
                end

                -- Determine when to trigger charge based on LateCharge + jitter
                local jitterOffset = GetJitterOffsetTicks()
                local chargeTriggerTick
                if Menu.Charge.LateCharge == true then
                    -- Late charge: as late as possible (near the hit), offset by jitter from end
                    chargeTriggerTick = weaponSmackDelay - jitterOffset
                else
                    -- Early charge: as soon as possible, jitter floor from start
                    chargeTriggerTick = jitterOffset
                end
                if chargeTriggerTick < 1 then
                    chargeTriggerTick = 1
                end

                if attackTickCount >= chargeTriggerTick then
                    -- Schedule aim then charge via state machine
                    chargeState = "aim" -- on this tick we aim; next tick we charge
                    -- Reset attack tracking
                    attackStarted = false
                    attackTickCount = 0
                end
            end
        end

        -- No need to track exploit flag anymore; logic is purely timing-based
    end

    Profiler.End("AttackLogic")
    -- Update last variables
    vHitbox[2].z = 82
    Profiler.EndSystem("SwingPred_Tick")
    ::continue::
end

-- Sphere cache and drawn edges cache
local sphere_cache = { vertices = {}, radius = 90, center = Vector3(0, 0, 0) }
local drawnEdges = {}

local function setup_sphere(center, radius, segments)
    sphere_cache.center = center
    sphere_cache.radius = radius
    sphere_cache.segments = segments
    sphere_cache.vertices = {} -- Clear the old vertices

    local thetaStep = math.pi / segments
    local phiStep = 2 * math.pi / segments

    for i = 0, segments - 1 do
        local theta1 = thetaStep * i
        local theta2 = thetaStep * (i + 1)

        for j = 0, segments - 1 do
            local phi1 = phiStep * j
            local phi2 = phiStep * (j + 1)

            -- Generate a square for each segment
            table.insert(sphere_cache.vertices, {
                Vector3(math.sin(theta1) * math.cos(phi1), math.sin(theta1) * math.sin(phi1), math.cos(theta1)),
                Vector3(math.sin(theta1) * math.cos(phi2), math.sin(theta1) * math.sin(phi2), math.cos(theta1)),
                Vector3(math.sin(theta2) * math.cos(phi2), math.sin(theta2) * math.sin(phi2), math.cos(theta2)),
                Vector3(math.sin(theta2) * math.cos(phi1), math.sin(theta2) * math.sin(phi1), math.cos(theta2))
            })
        end
    end
end

local function arrowPathArrow2(startPos, endPos, width)
    if not (startPos and endPos) then return nil, nil end

    local direction = endPos - startPos
    local length = direction:Length()
    if length == 0 then return nil, nil end
    direction = Normalize(direction)

    local perpDir = Vector3(-direction.y, direction.x, 0)
    local leftBase = startPos + perpDir * width
    local rightBase = startPos - perpDir * width

    local screenStartPos = client.WorldToScreen(startPos)
    local screenEndPos = client.WorldToScreen(endPos)
    local screenLeftBase = client.WorldToScreen(leftBase)
    local screenRightBase = client.WorldToScreen(rightBase)

    if screenStartPos and screenEndPos and screenLeftBase and screenRightBase then
        draw.Line(screenStartPos[1], screenStartPos[2], screenEndPos[1], screenEndPos[2])
        draw.Line(screenLeftBase[1], screenLeftBase[2], screenEndPos[1], screenEndPos[2])
        draw.Line(screenRightBase[1], screenRightBase[2], screenEndPos[1], screenEndPos[2])
    end

    return leftBase, rightBase
end




local function arrowPathArrow(startPos, endPos, arrowWidth)
    if not startPos or not endPos then return end

    local direction = endPos - startPos
    if direction:Length() == 0 then return end

    -- Normalize the direction vector and calculate perpendicular direction
    direction = Normalize(direction)
    local perpendicular = Vector3(-direction.y, direction.x, 0) * arrowWidth

    -- Calculate points for arrow fins
    local finPoint1 = startPos + perpendicular
    local finPoint2 = startPos - perpendicular

    -- Convert world positions to screen positions
    local screenStartPos = client.WorldToScreen(startPos)
    local screenEndPos = client.WorldToScreen(endPos)
    local screenFinPoint1 = client.WorldToScreen(finPoint1)
    local screenFinPoint2 = client.WorldToScreen(finPoint2)

    -- Draw the arrow
    if screenStartPos and screenEndPos then
        draw.Line(screenEndPos[1], screenEndPos[2], screenFinPoint1[1], screenFinPoint1[2])
        draw.Line(screenEndPos[1], screenEndPos[2], screenFinPoint2[1], screenFinPoint2[2])
        draw.Line(screenFinPoint1[1], screenFinPoint1[2], screenFinPoint2[1], screenFinPoint2[2])
    end
end

local function drawPavement(startPos, endPos, width)
    if not (startPos and endPos) then return nil end

    local direction = endPos - startPos
    local length = direction:Length()
    if length == 0 then return nil end
    direction = Normalize(direction)

    -- Calculate perpendicular direction for the width
    local perpDir = Vector3(-direction.y, direction.x, 0)

    -- Calculate left and right base points of the pavement
    local leftBase = startPos + perpDir * width
    local rightBase = startPos - perpDir * width

    -- Convert positions to screen coordinates
    local screenStartPos = client.WorldToScreen(startPos)
    local screenEndPos = client.WorldToScreen(endPos)
    local screenLeftBase = client.WorldToScreen(leftBase)
    local screenRightBase = client.WorldToScreen(rightBase)

    -- Draw the pavement
    if screenStartPos and screenEndPos and screenLeftBase and screenRightBase then
        draw.Line(screenStartPos[1], screenStartPos[2], screenEndPos[1], screenEndPos[2])
        draw.Line(screenStartPos[1], screenStartPos[2], screenLeftBase[1], screenLeftBase[2])
        draw.Line(screenStartPos[1], screenStartPos[2], screenRightBase[1], screenRightBase[2])
    end

    return leftBase, rightBase
end


-- Call setup_sphere once at the start of your program
setup_sphere(Vector3(0, 0, 0), 90, 7)

local white_texture = draw.CreateTextureRGBA(string.char(
    0xff, 0xff, 0xff, 25,
    0xff, 0xff, 0xff, 25,
    0xff, 0xff, 0xff, 25,
    0xff, 0xff, 0xff, 25
), 2, 2);

local drawPolygon = (function()
    local v1x, v1y = 0, 0;
    local function cross(a, b)
        return (b[1] - a[1]) * (v1y - a[2]) - (b[2] - a[2]) * (v1x - a[1])
    end

    local TexturedPolygon = draw.TexturedPolygon;

    return function(vertices)
        local cords, reverse_cords = {}, {};
        local sizeof = #vertices;
        local sum = 0;

        v1x, v1y = vertices[1][1], vertices[1][2];
        for i, pos in ipairs(vertices) do
            local convertedTbl = { pos[1], pos[2], 0, 0 };

            cords[i], reverse_cords[sizeof - i + 1] = convertedTbl, convertedTbl;

            sum = sum + cross(pos, vertices[(i % sizeof) + 1]);
        end


        TexturedPolygon(white_texture, (sum < 0) and reverse_cords or cords, true)
    end
end)();

local bindTimer = 0
local bindDelay = 0.25 -- Delay of 0.25 seconds

local function handleKeybind(noKeyText, keybind, keybindName)
    if keybindName ~= "Press The Key" and ImMenu.Button(keybindName or noKeyText) then
        bindTimer = os.clock() + bindDelay
        keybindName = "Press The Key"
    elseif keybindName == "Press The Key" then
        ImMenu.Text("Press the key")
    end

    if keybindName == "Press The Key" then
        if os.clock() >= bindTimer then
            local pressedKey = GetPressedkey()
            if pressedKey then
                if pressedKey == KEY_ESCAPE then
                    -- Reset keybind if the Escape key is pressed
                    keybind = 0
                    keybindName = noKeyText
                    Notify.Simple("Keybind Success", "Bound Key: " .. keybindName, 2)
                else
                    -- Update keybind with the pressed key
                    keybind = pressedKey
                    keybindName = Input.GetKeyName(pressedKey)
                    Notify.Simple("Keybind Success", "Bound Key: " .. keybindName, 2)
                end
            end
        end
    end
    return keybind, keybindName
end



local function L_line(start_pos, end_pos, secondary_line_size)
    if not (start_pos and end_pos) then
        return
    end
    local direction = end_pos - start_pos
    local direction_length = direction:Length()
    if direction_length == 0 then
        return
    end
    local normalized_direction = Normalize(direction)
    local perpendicular = Vector3(normalized_direction.y, -normalized_direction.x, 0) * secondary_line_size
    local w2s_start_pos = client.WorldToScreen(start_pos)
    local w2s_end_pos = client.WorldToScreen(end_pos)
    if not (w2s_start_pos and w2s_end_pos) then
        return
    end
    local secondary_line_end_pos = start_pos + perpendicular
    local w2s_secondary_line_end_pos = client.WorldToScreen(secondary_line_end_pos)
    if w2s_secondary_line_end_pos then
        draw.Line(w2s_start_pos[1], w2s_start_pos[2], w2s_end_pos[1], w2s_end_pos[2])
        draw.Line(w2s_start_pos[1], w2s_start_pos[2], w2s_secondary_line_end_pos[1], w2s_secondary_line_end_pos[2])
    end
end

-- Function to update the tabs
local function updateTabs(selectedTab)
    for tabName, _ in pairs(Menu.tabs) do
        Menu.tabs[tabName] = (tabName == selectedTab)
    end
end

-- debug command: ent_fire !picker Addoutput "health 99999" --superbot
local Verdana = draw.CreateFont("Verdana", 16, 800) -- Create a font for doDraw
draw.SetFont(Verdana)
--[[ Code called every frame ]]                     --
local function doDraw()
    Profiler.Draw()
    -- Render menu UI even when dead or visuals disabled
    if gui.IsMenuOpen() and ImMenu and ImMenu.Begin("Swing Prediction") then
        ImMenu.BeginFrame(1) -- tabs
        Menu.currentTab = ImMenu.TabControl(Menu.tabs, Menu.currentTab)
        ImMenu.EndFrame()

        if Menu.currentTab == 1 then -- Aimbot tab
            ImMenu.BeginFrame(1)
            Menu.Aimbot.Aimbot = ImMenu.Checkbox("Enable", Menu.Aimbot.Aimbot)
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            Menu.Aimbot.Silent = ImMenu.Checkbox("Silent Aim", Menu.Aimbot.Silent)
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            Menu.Aimbot.AimbotFOV = ImMenu.Slider("Fov", Menu.Aimbot.AimbotFOV, 1, 360)
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            -- Use dynamic maximum value from the current weapon's smack delay
            local swingTimeMaxDisplay = Menu.Aimbot.MaxSwingTime or 13 -- Add default value if nil
            local swingTimeLabel = string.format("Swing Time (max: %d)", swingTimeMaxDisplay)
            Menu.Aimbot.SwingTime = ImMenu.Slider(swingTimeLabel, Menu.Aimbot.SwingTime, 1, swingTimeMaxDisplay)
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            Menu.Aimbot.AlwaysUseMaxSwingTime = ImMenu.Checkbox("Always Use Max Swing Time",
                Menu.Aimbot.AlwaysUseMaxSwingTime)
            -- If the user enables "Always Use Max", automatically set the value to max
            if Menu.Aimbot.AlwaysUseMaxSwingTime == true then
                Menu.Aimbot.SwingTime = Menu.Aimbot.MaxSwingTime or 13 -- Add default value if nil
            end
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            ImMenu.Text("Keybind: ")
            Menu.Keybind, Menu.KeybindName = handleKeybind("Always On", Menu.Keybind, Menu.KeybindName)
            ImMenu.EndFrame()
        end

        if Menu.currentTab == 2 then -- Demoknight tab
            ImMenu.BeginFrame(1)
            Menu.Charge.ChargeBot = ImMenu.Checkbox("Charge Bot", Menu.Charge.ChargeBot)
            ImMenu.EndFrame()

            if Menu.Charge.ChargeBot == true then
                ImMenu.BeginFrame(1)
                Menu.Charge.ChargeBotFOV = ImMenu.Slider("Charge Bot Fov", Menu.Charge.ChargeBotFOV, 1, 360)
                ImMenu.EndFrame()

                ImMenu.BeginFrame(1)
                Menu.Charge.ChargeBotActivationMode = ImMenu.Option(Menu.Charge.ChargeBotActivationMode,
                    Menu.Charge.ChargeBotActivationModes)
                ImMenu.EndFrame()

                if Menu.Charge.ChargeBotActivationMode >= 2 then
                    ImMenu.BeginFrame(1)
                    ImMenu.Text("Charge Bot Keybind: ")
                    Menu.Charge.ChargeBotKeybind, Menu.Charge.ChargeBotKeybindName = handleKeybind("No Key",
                        Menu.Charge.ChargeBotKeybind, Menu.Charge.ChargeBotKeybindName)
                    ImMenu.EndFrame()
                end
            end

            ImMenu.BeginFrame(1)
            Menu.Charge.ChargeControl = ImMenu.Checkbox("Charge Control", Menu.Charge.ChargeControl)
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            Menu.Charge.ChargeReach = ImMenu.Checkbox("Charge Reach", Menu.Charge.ChargeReach)
            if Menu.Charge.ChargeReach == true then
                Menu.Charge.LateCharge = ImMenu.Checkbox("Late Charge", Menu.Charge.LateCharge)
                local jitterDisplay = string.format("Jitter Offset: %d tick(s)", GetJitterOffsetTicks())
                ImMenu.Text(jitterDisplay)
            end
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            Menu.Charge.ChargeJump = ImMenu.Checkbox("Charge Jump", Menu.Charge.ChargeJump)
            ImMenu.EndFrame()
        end

        if Menu.currentTab == 4 then -- Misc tab
            ImMenu.BeginFrame()
            Menu.Misc.InstantAttack = ImMenu.Checkbox("Instant Attack", Menu.Misc.InstantAttack)
            -- Add warp on attack button when instant attack is enabled
            if Menu.Misc.InstantAttack == true then
                Menu.Misc.WarpOnAttack = ImMenu.Checkbox("Warp On Attack", Menu.Misc.WarpOnAttack)
            end
            Menu.Misc.advancedHitreg = ImMenu.Checkbox("Advanced Hitreg", Menu.Misc.advancedHitreg)
            Menu.Misc.TroldierAssist = ImMenu.Checkbox("Troldier Assist", Menu.Misc.TroldierAssist)
            ImMenu.EndFrame()

            ImMenu.BeginFrame()
            Menu.Misc.CritRefill.Active = ImMenu.Checkbox("Auto Crit refill", Menu.Misc.CritRefill.Active)
            if Menu.Misc.CritRefill.Active == true then
                Menu.Misc.CritRefill.NumCrits = ImMenu.Slider("Crit Number", Menu.Misc.CritRefill.NumCrits, 1, 25)
            end
            ImMenu.EndFrame()
            ImMenu.BeginFrame()
            if Menu.Misc.CritRefill.Active == true then
                Menu.Misc.CritMode = ImMenu.Option(Menu.Misc.CritMode, Menu.Misc.CritModes)
            end
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            Menu.Misc.strafePred = ImMenu.Checkbox("Local Strafe Pred", Menu.Misc.strafePred)
            ImMenu.EndFrame()
        end

        if Menu.currentTab == 3 then -- Visuals tab
            ImMenu.BeginFrame(1)
            Menu.Visuals.EnableVisuals = ImMenu.Checkbox("Enable", Menu.Visuals.EnableVisuals)
            ImMenu.EndFrame()

            ImMenu.BeginFrame(1)
            Menu.Visuals.Section = ImMenu.Option(Menu.Visuals.Section, Menu.Visuals.Sections)
            ImMenu.EndFrame()

            if Menu.Visuals.Section == 1 then
                Menu.Visuals.Local.RangeCircle = ImMenu.Checkbox("Range Circle", Menu.Visuals.Local.RangeCircle)
                Menu.Visuals.Local.path.enable = ImMenu.Checkbox("Local Path", Menu.Visuals.Local.path.enable)
                Menu.Visuals.Local.path.Style = ImMenu.Option(Menu.Visuals.Local.path.Style,
                    Menu.Visuals.Local.path.Styles)
                Menu.Visuals.Local.path.width = ImMenu.Slider("Width", Menu.Visuals.Local.path.width, 1, 20, 0.1)
            end

            if Menu.Visuals.Section == 2 then
                Menu.Visuals.Target.path.enable = ImMenu.Checkbox("Target Path", Menu.Visuals.Target.path.enable)
                Menu.Visuals.Target.path.Style = ImMenu.Option(Menu.Visuals.Target.path.Style,
                    Menu.Visuals.Target.path.Styles)
                Menu.Visuals.Target.path.width = ImMenu.Slider("Width", Menu.Visuals.Target.path.width, 1, 20, 0.1)
            end

            if Menu.Visuals.Section == 3 then
                ImMenu.BeginFrame(1)
                ImMenu.Text("Experimental")
                Menu.Visuals.Sphere = ImMenu.Checkbox("Range Shield", Menu.Visuals.Sphere)
                ImMenu.EndFrame()
            end
        end

        ImMenu.End()
    end

    -- Render visuals only when alive and visuals enabled
    if not (engine.Con_IsVisible() or engine.IsGameUIVisible()) and Menu.Visuals.EnableVisuals == true then
        local drawPLocal = entities.GetLocalPlayer()
        if drawPLocal and drawPLocal:IsAlive() then
            local drawPWeapon = drawPLocal:GetPropEntity("m_hActiveWeapon")
            if drawPWeapon and drawPWeapon:IsMeleeWeapon() then
                draw.Color(255, 255, 255, 255)
                local w, h = draw.GetScreenSize()

                -- Display warp status when instant attack is enabled
                if Menu.Misc.InstantAttack == true then
                    -- Simple fallback approach using basic functions
                    local charged = warp and warp.GetChargedTicks() or 0
                    local maxTicks = 24 -- Default max
                    local isWarping = warp and warp.IsWarping() or false
                    local canWarp = warp and warp.CanWarp() or false

                    local warpText = string.format("Warp: %d/%d", charged, maxTicks)
                    local statusText = string.format("CanWarp: %s | Warping: %s", tostring(canWarp), tostring(isWarping))
                    local warpOnAttackText = string.format("WarpOnAttack: %s", tostring(Menu.Misc.WarpOnAttack))

                    -- Set color based on status
                    if isWarping then
                        draw.Color(255, 100, 100, 255) -- Red when warping
                    elseif canWarp and charged >= 13 then
                        draw.Color(100, 255, 100, 255) -- Green when ready
                    elseif canWarp then
                        draw.Color(255, 255, 100, 255) -- Yellow when can warp but not enough ticks
                    else
                        draw.Color(255, 255, 255, 255) -- White when not ready
                    end

                    draw.SetFont(Verdana)
                    local textW, textH = draw.GetTextSize(warpText)
                    draw.Text(w - textW - 10, 100, warpText)

                    -- Additional status info
                    draw.Color(255, 255, 255, 255)
                    local statusW, statusH = draw.GetTextSize(statusText)
                    draw.Text(w - statusW - 10, 120, statusText)

                    local warpOnAttackW, warpOnAttackH = draw.GetTextSize(warpOnAttackText)
                    draw.Text(w - warpOnAttackW - 10, 140, warpOnAttackText)
                end

                draw.Color(255, 255, 255, 255) -- Reset color for other visuals
                if Menu.Visuals.Local.RangeCircle == true and pLocalFuture then
                    draw.Color(255, 255, 255, 255)

                    -- Create a cone: traces start from view position (eye level) to ground level circle
                    local viewPos = pLocalOrigin          -- Trace start from eye level (origin + viewOffset)
                    local center = pLocalFuture - Vheight -- Circle center at predicted ground level (feet)
                    -- Use TotalSwingRange directly (it's already calculated correctly)
                    local radius = TotalSwingRange
                    local segments = 32 -- Number of segments to draw the circle
                    local angleStep = (2 * math.pi) / segments

                    -- Determine the color of the circle based on CurrentTarget
                    local circleColor = CurrentTarget and { 0, 255, 0, 255 } or
                        { 255, 255, 255, 255 } -- Green if TargetPlayer exists, otherwise white

                    -- Set the drawing color
                    draw.Color(table.unpack(circleColor))

                    local vertices = {} -- Table to store adjusted vertices

                    -- Calculate vertices and adjust based on trace results
                    for i = 1, segments do
                        local angle = angleStep * i
                        local circlePoint = center + Vector3(math.cos(angle), math.sin(angle), 0) * radius

                        local trace = engine.TraceLine(viewPos, circlePoint, MASK_SHOT_HULL) --engine.TraceHull(viewPos, circlePoint, vHitbox[1], vHitbox[2], MASK_SHOT_HULL)
                        local endPoint = trace.fraction < 1.0 and trace.endpos or circlePoint

                        vertices[i] = client.WorldToScreen(endPoint)
                    end

                    -- Draw the circle using adjusted vertices
                    for i = 1, segments do
                        local j = (i % segments) + 1 -- Wrap around to the first vertex after the last one
                        if vertices[i] and vertices[j] then
                            draw.Line(vertices[i][1], vertices[i][2], vertices[j][1], vertices[j][2])
                        end
                    end
                end
                if Menu.Visuals.Local.path.enable == true and pLocalFuture then
                    local style = Menu.Visuals.Local.path.Style
                    local width1 = Menu.Visuals.Local.path.width
                    if style == 1 then
                        local lastLeftBaseScreen, lastRightBaseScreen = nil, nil
                        -- Pavement Style
                        for i = 1, #pLocalPath - 1 do
                            local startPos = pLocalPath[i]
                            local endPos = pLocalPath[i + 1]

                            if startPos and endPos then
                                local leftBase, rightBase = drawPavement(startPos, endPos, width1)

                                if leftBase and rightBase then
                                    local screenLeftBase = client.WorldToScreen(leftBase)
                                    local screenRightBase = client.WorldToScreen(rightBase)

                                    if screenLeftBase and screenRightBase then
                                        if lastLeftBaseScreen and lastRightBaseScreen then
                                            draw.Line(lastLeftBaseScreen[1], lastLeftBaseScreen[2], screenLeftBase[1],
                                                screenLeftBase[2])
                                            draw.Line(lastRightBaseScreen[1], lastRightBaseScreen[2], screenRightBase[1],
                                                screenRightBase[2])
                                        end

                                        lastLeftBaseScreen = screenLeftBase
                                        lastRightBaseScreen = screenRightBase
                                    end
                                end
                            end
                        end

                        -- Draw the final line segment
                        if lastLeftBaseScreen and lastRightBaseScreen and #pLocalPath > 0 then
                            local finalPos = pLocalPath[#pLocalPath]
                            local screenFinalPos = client.WorldToScreen(finalPos)

                            if screenFinalPos then
                                draw.Line(lastLeftBaseScreen[1], lastLeftBaseScreen[2], screenFinalPos[1],
                                    screenFinalPos[2])
                                draw.Line(lastRightBaseScreen[1], lastRightBaseScreen[2], screenFinalPos[1],
                                    screenFinalPos[2])
                            end
                        end
                    elseif style == 2 then
                        local lastLeftBaseScreen, lastRightBaseScreen = nil, nil

                        -- Start from the second element (i = 2)
                        for i = 2, #pLocalPath - 1 do
                            local startPos = pLocalPath[i]
                            local endPos = pLocalPath[i + 1]

                            if startPos and endPos then
                                local leftBase, rightBase = arrowPathArrow2(startPos, endPos, width1)

                                if leftBase and rightBase then
                                    local screenLeftBase = client.WorldToScreen(leftBase)
                                    local screenRightBase = client.WorldToScreen(rightBase)

                                    if screenLeftBase and screenRightBase then
                                        if lastLeftBaseScreen and lastRightBaseScreen then
                                            draw.Line(lastLeftBaseScreen[1], lastLeftBaseScreen[2], screenLeftBase[1],
                                                screenLeftBase[2])
                                            draw.Line(lastRightBaseScreen[1], lastRightBaseScreen[2], screenRightBase[1],
                                                screenRightBase[2])
                                        end

                                        lastLeftBaseScreen = screenLeftBase
                                        lastRightBaseScreen = screenRightBase
                                    end
                                end
                            end
                        end
                    elseif style == 3 then
                        -- Arrows Style
                        for i = 1, #pLocalPath - 1 do
                            local startPos = pLocalPath[i]
                            local endPos = pLocalPath[i + 1]

                            if startPos and endPos then
                                arrowPathArrow(startPos, endPos, width1)
                            end
                        end
                    elseif style == 4 then
                        -- L Line Style
                        for i = 1, #pLocalPath - 1 do
                            local pos1 = pLocalPath[i]
                            local pos2 = pLocalPath[i + 1]

                            if pos1 and pos2 then
                                L_line(pos1, pos2, width1) -- Adjust the size for the perpendicular segment as needed
                            end
                        end
                    elseif style == 5 then
                        -- Draw a dashed line for pLocalPath
                        for i = 1, #pLocalPath - 1 do
                            local pos1 = pLocalPath[i]
                            local pos2 = pLocalPath[i + 1]

                            local screenPos1 = client.WorldToScreen(pos1)
                            local screenPos2 = client.WorldToScreen(pos2)

                            if screenPos1 ~= nil and screenPos2 ~= nil and i % 2 == 1 then
                                draw.Line(screenPos1[1], screenPos1[2], screenPos2[1], screenPos2[2])
                            end
                        end
                    elseif style == 6 then
                        -- Draw a dashed line for pLocalPath
                        for i = 1, #pLocalPath - 1 do
                            local pos1 = pLocalPath[i]
                            local pos2 = pLocalPath[i + 1]

                            local screenPos1 = client.WorldToScreen(pos1)
                            local screenPos2 = client.WorldToScreen(pos2)

                            if screenPos1 ~= nil and screenPos2 ~= nil then
                                draw.Line(screenPos1[1], screenPos1[2], screenPos2[1], screenPos2[2])
                            end
                        end
                    end
                end
                ---------------------------------------------------------sphere
                if Menu.Visuals.Sphere == true then
                    -- Function to draw the sphere
                    local function draw_sphere()
                        local playerYaw = engine.GetViewAngles().yaw
                        local cos_yaw = math.cos(math.rad(playerYaw))
                        local sin_yaw = math.sin(math.rad(playerYaw))

                        local playerForward = Vector3(-cos_yaw, -sin_yaw, 0) -- Forward vector based on player's yaw

                        for _, vertex in ipairs(sphere_cache.vertices) do
                            local rotated_vertex1 = Vector3(-vertex[1].x * cos_yaw + vertex[1].y * sin_yaw,
                                -vertex[1].x * sin_yaw - vertex[1].y * cos_yaw, vertex[1].z)
                            local rotated_vertex2 = Vector3(-vertex[2].x * cos_yaw + vertex[2].y * sin_yaw,
                                -vertex[2].x * sin_yaw - vertex[2].y * cos_yaw, vertex[2].z)
                            local rotated_vertex3 = Vector3(-vertex[3].x * cos_yaw + vertex[3].y * sin_yaw,
                                -vertex[3].x * sin_yaw - vertex[3].y * cos_yaw, vertex[3].z)
                            local rotated_vertex4 = Vector3(-vertex[4].x * cos_yaw + vertex[4].y * sin_yaw,
                                -vertex[4].x * sin_yaw - vertex[4].y * cos_yaw, vertex[4].z)

                            local worldPos1 = sphere_cache.center + rotated_vertex1 * sphere_cache.radius
                            local worldPos2 = sphere_cache.center + rotated_vertex2 * sphere_cache.radius
                            local worldPos3 = sphere_cache.center + rotated_vertex3 * sphere_cache.radius
                            local worldPos4 = sphere_cache.center + rotated_vertex4 * sphere_cache.radius

                            -- Trace from the center to the vertices with a hull size of 18x18
                            local hullSize = Vector3(18, 18, 18)
                            local trace1 = engine.TraceHull(sphere_cache.center, worldPos1, -hullSize, hullSize,
                                MASK_SHOT_HULL)
                            local trace2 = engine.TraceHull(sphere_cache.center, worldPos2, -hullSize, hullSize,
                                MASK_SHOT_HULL)
                            local trace3 = engine.TraceHull(sphere_cache.center, worldPos3, -hullSize, hullSize,
                                MASK_SHOT_HULL)
                            local trace4 = engine.TraceHull(sphere_cache.center, worldPos4, -hullSize, hullSize,
                                MASK_SHOT_HULL)

                            local endPos1 = trace1.fraction < 1.0 and trace1.endpos or worldPos1
                            local endPos2 = trace2.fraction < 1.0 and trace2.endpos or worldPos2
                            local endPos3 = trace3.fraction < 1.0 and trace3.endpos or worldPos3
                            local endPos4 = trace4.fraction < 1.0 and trace4.endpos or worldPos4

                            local screenPos1 = client.WorldToScreen(endPos1)
                            local screenPos2 = client.WorldToScreen(endPos2)
                            local screenPos3 = client.WorldToScreen(endPos3)
                            local screenPos4 = client.WorldToScreen(endPos4)

                            -- Calculate normal vector of the square
                            local normal = Normalize(rotated_vertex2 - rotated_vertex1):Cross(rotated_vertex3 -
                                rotated_vertex1)

                            -- Draw square only if its normal faces towards the player
                            if normal:Dot(playerForward) > 0.1 then
                                if screenPos1 and screenPos2 and screenPos3 and screenPos4 then
                                    -- Draw the square
                                    drawPolygon({ screenPos1, screenPos2, screenPos3, screenPos4 })

                                    -- Optionally, draw lines between the vertices of the square for wireframe visualization
                                    draw.Color(255, 255, 255, 25) -- Set color and alpha for lines
                                    draw.Line(screenPos1[1], screenPos1[2], screenPos2[1], screenPos2[2])
                                    draw.Line(screenPos2[1], screenPos2[2], screenPos3[1], screenPos3[2])
                                    draw.Line(screenPos3[1], screenPos3[2], screenPos4[1], screenPos4[2])
                                    draw.Line(screenPos4[1], screenPos4[2], screenPos1[1], screenPos1[2])
                                end
                            end
                        end
                    end

                    -- Example draw call
                    sphere_cache.center = pLocalOrigin -- Replace with actual player origin
                    -- Use TotalSwingRange directly (it's already calculated correctly)
                    sphere_cache.radius = TotalSwingRange
                    draw_sphere()
                end

                -- enemy
                if vPlayerFuture then
                    -- Draw lines between the predicted positions
                    if Menu.Visuals.Target.path.enable == true then
                        local style = Menu.Visuals.Target.path.Style
                        local width = Menu.Visuals.Target.path.width

                        if style == 1 then
                            local lastLeftBaseScreen, lastRightBaseScreen = nil, nil
                            -- Pavement Style
                            for i = 1, #vPlayerPath - 1 do
                                local startPos = vPlayerPath[i]
                                local endPos = vPlayerPath[i + 1]

                                if startPos and endPos then
                                    local leftBase, rightBase = drawPavement(startPos, endPos, width)

                                    if leftBase and rightBase then
                                        local screenLeftBase = client.WorldToScreen(leftBase)
                                        local screenRightBase = client.WorldToScreen(rightBase)

                                        if screenLeftBase and screenRightBase then
                                            if lastLeftBaseScreen and lastRightBaseScreen then
                                                draw.Line(lastLeftBaseScreen[1], lastLeftBaseScreen[2], screenLeftBase
                                                    [1],
                                                    screenLeftBase[2])
                                                draw.Line(lastRightBaseScreen[1], lastRightBaseScreen[2],
                                                    screenRightBase[1],
                                                    screenRightBase[2])
                                            end

                                            lastLeftBaseScreen = screenLeftBase
                                            lastRightBaseScreen = screenRightBase
                                        end
                                    end
                                end
                            end

                            -- Draw the final line segment
                            if lastLeftBaseScreen and lastRightBaseScreen and #vPlayerPath > 0 then
                                local finalPos = vPlayerPath[#vPlayerPath]
                                local screenFinalPos = client.WorldToScreen(finalPos)

                                if screenFinalPos then
                                    draw.Line(lastLeftBaseScreen[1], lastLeftBaseScreen[2], screenFinalPos[1],
                                        screenFinalPos[2])
                                    draw.Line(lastRightBaseScreen[1], lastRightBaseScreen[2], screenFinalPos[1],
                                        screenFinalPos[2])
                                end
                            end
                        elseif style == 2 then
                            local lastLeftBaseScreen, lastRightBaseScreen = nil, nil

                            -- Start from the second element (i = 2)
                            for i = 2, #vPlayerPath - 1 do
                                local startPos = vPlayerPath[i]
                                local endPos = vPlayerPath[i + 1]

                                if startPos and endPos then
                                    local leftBase, rightBase = arrowPathArrow2(startPos, endPos, width)

                                    if leftBase and rightBase then
                                        local screenLeftBase = client.WorldToScreen(leftBase)
                                        local screenRightBase = client.WorldToScreen(rightBase)

                                        if screenLeftBase and screenRightBase then
                                            if lastLeftBaseScreen and lastRightBaseScreen then
                                                draw.Line(lastLeftBaseScreen[1], lastLeftBaseScreen[2], screenLeftBase
                                                    [1],
                                                    screenLeftBase[2])
                                                draw.Line(lastRightBaseScreen[1], lastRightBaseScreen[2],
                                                    screenRightBase[1],
                                                    screenRightBase[2])
                                            end

                                            lastLeftBaseScreen = screenLeftBase
                                            lastRightBaseScreen = screenRightBase
                                        end
                                    end
                                end
                            end
                        elseif style == 3 then
                            -- Arrows Style
                            for i = 1, #vPlayerPath - 1 do
                                local startPos = vPlayerPath[i]
                                local endPos = vPlayerPath[i + 1]

                                if startPos and endPos then
                                    arrowPathArrow(startPos, endPos, width)
                                end
                            end
                        elseif style == 4 then
                            -- L Line Style
                            for i = 1, #vPlayerPath - 1 do
                                local pos1 = vPlayerPath[i]
                                local pos2 = vPlayerPath[i + 1]

                                if pos1 and pos2 then
                                    L_line(pos1, pos2, width) -- Adjust the size for the perpendicular segment as needed
                                end
                            end
                        elseif style == 5 then
                            -- Draw a dashed line for vPlayerPath
                            for i = 1, #vPlayerPath - 1 do
                                local pos1 = vPlayerPath[i]
                                local pos2 = vPlayerPath[i + 1]

                                local screenPos1 = client.WorldToScreen(pos1)
                                local screenPos2 = client.WorldToScreen(pos2)

                                if screenPos1 ~= nil and screenPos2 ~= nil and i % 2 == 1 then
                                    draw.Line(screenPos1[1], screenPos1[2], screenPos2[1], screenPos2[2])
                                end
                            end
                        elseif style == 6 then
                            -- Draw a dashed line for vPlayerPath
                            for i = 1, #vPlayerPath - 1 do
                                local pos1 = vPlayerPath[i]
                                local pos2 = vPlayerPath[i + 1]

                                local screenPos1 = client.WorldToScreen(pos1)
                                local screenPos2 = client.WorldToScreen(pos2)

                                if screenPos1 ~= nil and screenPos2 ~= nil then
                                    draw.Line(screenPos1[1], screenPos1[2], screenPos2[1], screenPos2[2])
                                end
                            end
                        end
                    end

                    if aimposVis then
                        --draw predicted local position with strafe prediction
                        local screenPos = client.WorldToScreen(aimposVis)
                        if screenPos ~= nil then
                            draw.Line(screenPos[1] + 10, screenPos[2], screenPos[1] - 10, screenPos[2])
                            draw.Line(screenPos[1], screenPos[2] - 10, screenPos[1], screenPos[2] + 10)
                        end
                    end

                    -- Calculate min and max points
                    local minPoint = drawVhitbox[1]
                    local maxPoint = drawVhitbox[2]

                    -- Calculate vertices of the AABB
                    -- Assuming minPoint and maxPoint are the minimum and maximum points of the AABB:
                    local vertices = {
                        Vector3(minPoint.x, minPoint.y, minPoint.z), -- Bottom-back-left
                        Vector3(minPoint.x, maxPoint.y, minPoint.z), -- Bottom-front-left
                        Vector3(maxPoint.x, maxPoint.y, minPoint.z), -- Bottom-front-right
                        Vector3(maxPoint.x, minPoint.y, minPoint.z), -- Bottom-back-right
                        Vector3(minPoint.x, minPoint.y, maxPoint.z), -- Top-back-left
                        Vector3(minPoint.x, maxPoint.y, maxPoint.z), -- Top-front-left
                        Vector3(maxPoint.x, maxPoint.y, maxPoint.z), -- Top-front-right
                        Vector3(maxPoint.x, minPoint.y, maxPoint.z)  -- Top-back-right
                    }

                    -- Convert 3D coordinates to 2D screen coordinates
                    for i, vertex in ipairs(vertices) do
                        vertices[i] = client.WorldToScreen(vertex)
                    end

                    -- Draw lines between vertices to visualize the box
                    if vertices[1] and vertices[2] and vertices[3] and vertices[4] and vertices[5] and vertices[6] and vertices[7] and vertices[8] then
                        -- Draw front face
                        draw.Line(vertices[1][1], vertices[1][2], vertices[2][1], vertices[2][2])
                        draw.Line(vertices[2][1], vertices[2][2], vertices[3][1], vertices[3][2])
                        draw.Line(vertices[3][1], vertices[3][2], vertices[4][1], vertices[4][2])
                        draw.Line(vertices[4][1], vertices[4][2], vertices[1][1], vertices[1][2])

                        -- Draw back face
                        draw.Line(vertices[5][1], vertices[5][2], vertices[6][1], vertices[6][2])
                        draw.Line(vertices[6][1], vertices[6][2], vertices[7][1], vertices[7][2])
                        draw.Line(vertices[7][1], vertices[7][2], vertices[8][1], vertices[8][2])
                        draw.Line(vertices[8][1], vertices[8][2], vertices[5][1], vertices[5][2])

                        -- Draw connecting lines
                        draw.Line(vertices[1][1], vertices[1][2], vertices[5][1], vertices[5][2])
                        draw.Line(vertices[2][1], vertices[2][2], vertices[6][1], vertices[6][2])
                        draw.Line(vertices[3][1], vertices[3][2], vertices[7][1], vertices[7][2])
                        draw.Line(vertices[4][1], vertices[4][2], vertices[8][1], vertices[8][2])
                    end
                end
            end
        end
    end
end

--[[ Remove the menu when unloaded ]]                         --
local function OnUnload()                                     -- Called when the script is unloaded
    UnloadLib()                                               --unloading lualib
    CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) --saving the config
    client.Command('play "ui/buttonclickrelease"', true)      -- Play the "buttonclickrelease" sound
end

local function damageLogger(event)
    UpdateServerCvars() -- Update cvars on event
    if (event:GetName() == 'player_hurt') then
        local victim = entities.GetByUserID(event:GetInt("userid"))
        local attacker = entities.GetByUserID(event:GetInt("attacker"))
        local localPlayer = entities.GetLocalPlayer()

        if (attacker == nil or not localPlayer or localPlayer:GetName() ~= attacker:GetName()) then
            return
        end
        local damage = event:GetInt("damageamount")
        if damage <= victim:GetHealth() then return end

        -- Trigger recharge if instant attack is enabled and warp ticks are below threshold
        if Menu.Misc.InstantAttack and warp.GetChargedTicks() < 13
            and not warp.IsWarping() then
            warp.TriggerCharge(24) -- Trigger charge to max ticks
            tickCounterrecharge = 0
        end
    end
end

--[[ Unregister previous callbacks ]]                            --
callbacks.Unregister("CreateMove", "MCT_CreateMove")             -- Unregister the "CreateMove" callback
callbacks.Unregister("FireGameEvent", "adaamaXDgeLogger")
callbacks.Unregister("Unload", "MCT_Unload")                     -- Unregister the "Unload" callback
callbacks.Unregister("Draw", "MCT_Draw")                         -- Unregister the "Draw" callback
--[[ Register callbacks ]]                                       --
callbacks.Register("CreateMove", "MCT_CreateMove", OnCreateMove) -- Register the "CreateMove" callback
callbacks.Register("FireGameEvent", "adaamaXDgeLogger", damageLogger)
callbacks.Register("Unload", "MCT_Unload", OnUnload)             -- Register the "Unload" callback
callbacks.Register("Draw", "MCT_Draw", doDraw)                   -- Register the "Draw" callback
--[[ Play sound when loaded ]]                                   --
client.Command('play "ui/buttonclick"', true)                    -- Play the "buttonclick" sound when the script is loaded
