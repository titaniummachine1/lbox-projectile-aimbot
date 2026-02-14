---@meta

---Represents an event when a temporary entity got created.
---Contains some useful information about the temporary entity that are not a part of the entity itself
---
---[View Docs](https://lmaobox.net/lua/Lua_Classes/EventInfo/)
---@class EventInfo
---@field classId integer
---@field fireDelay number
---@field flags integer
---@field data string Raw byes
local EventInfo = {}