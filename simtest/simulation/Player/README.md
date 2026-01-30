# Player Simulation Modules

Clean, organized player movement simulation system.

## Active Modules

### Core Simulation
- **movement_sim.lua** - Ground/air movement physics, collision detection
  - Simple wall/ground collision based on trace hulls
  - Gravity application when airborne
  - Stable stair walking (< 45° walkable)

### State Management
- **player_sim_state.lua** - Cached player state per entity
  - Static data: mins, maxs, index (cached per entity)
  - Dynamic data: origin, velocity, yaw (updated per frame)
  - Global sim context: cvars (updated every 1 second)

### Input Estimation
- **wishdir_estimator.lua** - Estimates movement direction from velocity
  - Snaps velocity to 8 directions (forward, back, left, right, diagonals)
  - Does NOT use player's actual input
  - Returns view-relative wishdir

### Strafe Prediction
- **strafe_prediction.lua** - Calculates average yaw rotation from movement history
  - Records movement samples (position, velocity, mode)
  - Detects strafe patterns and calculates yaw delta per tick
  - Used for predicting strafing players

- **strafe_rotation.lua** - Accumulates rotation angle across ticks
  - Prevents rotation reset on wall collision
  - Applies rotation when accumulated angle >= 1.0°
  - (Currently not integrated - using simple rotation in movement_sim)

## Deprecated Modules (deprecated/)

Old overcomplicated simulation code moved here:
- player_tick.lua (600+ lines, broken ground detection)
- prediction_context.lua (replaced by player_sim_state)
- movedata.lua (unused)
- player.lua (unused)
- history/ (old wishdir tracker that used player's actual input)

## Usage Example

```lua
local MovementSim = require("simulation.Player.movement_sim")
local PlayerSimState = require("simulation.Player.player_sim_state")
local WishdirEstimator = require("simulation.Player.wishdir_estimator")

-- Get or create cached state
local state = PlayerSimState.getOrCreate(entity)
local simCtx = PlayerSimState.getSimContext()

-- Estimate wishdir from velocity
local vel = entity:EstimateAbsVelocity()
state.relativeWishDir = WishdirEstimator.estimateFromVelocity(vel, state.yaw)

-- Simulate movement
for tick = 1, 66 do
    MovementSim.simulateTick(state, simCtx)
end
```

## Design Principles

1. **Simple over complex** - Basic physics, no overcomplicated friction/acceleration
2. **Estimate, don't cheat** - Derive wishdir from velocity, not player's actual input
3. **Cache static data** - Don't rebuild context every frame
4. **Fail loud** - Assert on missing data, no silent fallbacks
5. **Clean interfaces** - Each module has single clear purpose
