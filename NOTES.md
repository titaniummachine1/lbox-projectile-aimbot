# Implementation Notes

## Project Structure

```
src/
├── constants/          # Static values (game constants, weapon offsets)
├── core/              # Prediction framework (contexts, tick simulation, latency, strafe)
├── utils/             # Math utilities (ballistics, angles, vectors)
├── main.lua           # Entry point
├── menu.lua           # UI
├── config.lua         # Config management
└── [legacy modules]
```

## Key Architecture

**Tick-Based Prediction:**

- `PredictionContext.createContext()` - Setup dynamic state (cvars, time)
- `PredictionContext.createPlayerContext()` - Player state snapshot
- `PlayerTick.simulateTick()` - Single tick simulation
- `PlayerTick.simulatePath()` - Multi-tick path

**Backward Compatible:**

- Old `playersim.lua` wraps new architecture
- Old `utils/math.lua` wraps organized utils

## Fedoraware Improvements (To Integrate)

### Critical #1: Full Latency Compensation

```lua
-- Current (incomplete):
local time = (distance / speed) + netchannel:GetLatency(E_Flows.FLOW_INCOMING)

-- Fixed (add to main.lua):
local Latency = require("core.latency")
local time = Latency.getAdjustedPredictionTime(distance, speed)
```

**Impact:** ⭐⭐⭐ Massive - fixes long-range/high-ping hits

### Critical #2: Weapon-Specific Offsets

```lua
-- Add to main.lua before ballistic solve:
local WeaponOffsets = require("constants.weapon_offsets")
local weaponDefIndex = weapon:GetPropInt("m_iItemDefinitionIndex")
firePos = WeaponOffsets.getFirePosition(plocal, eyePos, angle, weaponDefIndex) or firePos
```

**Impact:** ⭐⭐ Good - better accuracy for rockets/pipes

### Optional: Strafe Prediction

Record velocity history, predict angular change. Requires integration into prediction loop.
**Impact:** ⭐⭐ Good for strafing targets

## Menu Integration

Menu requires TimMenu installed at `%localappdata%\\lmaobox\\Scripts\\TimMenu.lua`.

If missing, script fails immediately with clear error message.

## Common Issues

**Crash on unload:** Environment handles cleanup automatically. Don't manually destroy physics objects or access GUI state in unload callbacks.

**Lua syntax:** No `continue` keyword - use inverted conditions instead.

**Menu crashes:** Only draw when `gui.IsMenuOpen()` is true. Use safety checks and pcall.

## Module Guidelines

1. **Module layout:** Imports → Constants → Helpers → Public API
2. **Guard clauses:** Assert external inputs at function entry
3. **Named functions:** No anonymous (except one-liner callbacks)
4. **No magic numbers:** Extract to constants
5. **Comments explain "why"** not "what"
