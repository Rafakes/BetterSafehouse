--[[
    Better Safehouse (Build 42) - Shared helpers
    Multiplayer-safe: contains ONLY helper functions and sandbox-reading utilities.

    Loads early (00_) so client + server scripts can depend on it.
--]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse.Viewer = BetterSafehouse.Viewer or {}

local function sbGetOptionValue(fullName)
    if not getSandboxOptions then return nil end
    local opts = getSandboxOptions()
    if not opts or not opts.getOptionByName then return nil end
    local ok, opt = pcall(function() return opts:getOptionByName(fullName) end)
    if not ok or not opt then return nil end
    if opt.getValue then
        local ok2, v = pcall(function() return opt:getValue() end)
        if ok2 then return v end
    end
    return nil
end

---Get a sandbox boolean (server-synced in MP). Fallbacks to default if missing.
---@param modKey string  -- e.g. "EnableSafehouseViewer"
---@param default boolean
function BetterSafehouse.getSandboxBool(modKey, default)
    -- Preferred: SandboxVars table (server-synced)
    if SandboxVars and SandboxVars.BetterSafehouse and SandboxVars.BetterSafehouse[modKey] ~= nil then
        return SandboxVars.BetterSafehouse[modKey] == true
    end
    -- Fallback: query sandbox options object by name
    local v = sbGetOptionValue("BetterSafehouse." .. tostring(modKey))
    if v ~= nil then return v == true end
    return default == true
end

---Get a sandbox integer. Fallbacks to default if missing.
---@param modKey string
---@param default number
function BetterSafehouse.getSandboxInt(modKey, default)
    if SandboxVars and SandboxVars.BetterSafehouse and SandboxVars.BetterSafehouse[modKey] ~= nil then
        local v = SandboxVars.BetterSafehouse[modKey]
        if type(v) == "number" then return math.floor(v) end

---Get a sandbox string. Fallbacks to default if missing.
---@param modKey string
---@param default string
function BetterSafehouse.getSandboxString(modKey, default)
    if SandboxVars and SandboxVars.BetterSafehouse and SandboxVars.BetterSafehouse[modKey] ~= nil then
        local v = SandboxVars.BetterSafehouse[modKey]
        if type(v) == "string" then return v end
    end
    local v = sbGetOptionValue("BetterSafehouse." .. tostring(modKey))
    if type(v) == "string" then return v end
    return default
end

    end
    local v = sbGetOptionValue("BetterSafehouse." .. tostring(modKey))
    if type(v) == "number" then return math.floor(v) end
    return math.floor(default or 0)
end

-- =========================
-- Viewer (client preference)
-- =========================

local PREF_KEY = "BetterSafehouse_ViewerEnabled"

---Server-side sandbox toggle for the viewer overlay.
function BetterSafehouse.isViewerEnabledBySandbox()
    return BetterSafehouse.getSandboxBool("EnableSafehouseViewer", true)
end

---Per-player client preference.
function BetterSafehouse.getClientViewerPref(playerObj)
    -- Default OFF on login: only enable after player explicitly toggles the checkbox.
    if not playerObj or not playerObj.getModData then return false end
    local md = playerObj:getModData()
    return md[PREF_KEY] == true
end

function BetterSafehouse.setClientViewerPref(playerObj, enabled)
    if not playerObj or not playerObj.getModData then return end
    playerObj:getModData()[PREF_KEY] = enabled == true
end

-- =========================================================
-- Viewer overlay default OFF on session start (SP/host/MP)
-- We force-disable the ground marking when the player joins.
-- It will only turn on after the player explicitly toggles it.
-- =========================================================
local function BS_viewerResetOnJoin(playerNum, playerObj)
    if isDedicatedServer and isDedicatedServer() then return end

    local pl = playerObj or (getPlayer and getPlayer() or nil)
    if not pl then return end

    -- Clear any remembered target + disable pref for this session.
    BetterSafehouse.setClientViewerPref(pl, false)
    if BetterSafehouse.setClientViewerTarget then
        pcall(function() BetterSafehouse.setClientViewerTarget(pl, nil) end)
    end

    -- Remove any already-highlighted squares (safety).
    if BetterSafehouse.Viewer and BetterSafehouse.Viewer.clear then
        pcall(function() BetterSafehouse.Viewer.clear() end)
    end
end

if Events and not BetterSafehouse._viewerResetHooked then
    BetterSafehouse._viewerResetHooked = true
    if Events.OnCreatePlayer then Events.OnCreatePlayer.Add(BS_viewerResetOnJoin) end
    if Events.OnGameStart then Events.OnGameStart.Add(function() BS_viewerResetOnJoin(nil, getPlayer and getPlayer() or nil) end) end
end




local TARGET_KEY = "BetterSafehouse_ViewerTarget"

---Per-player client viewer target (optional).
-- When set, the viewer will highlight THIS safehouse rectangle (useful for admins or multi-safehouse members).
-- Stored in player modData so it stays client-side and MP-safe.
function BetterSafehouse.getClientViewerTarget(playerObj)
    if not playerObj or not playerObj.getModData then return nil end
    local md = playerObj:getModData()
    local t = md[TARGET_KEY]
    if type(t) ~= "table" then return nil end
    if type(t.x) ~= "number" or type(t.y) ~= "number" or type(t.w) ~= "number" or type(t.h) ~= "number" then
        return nil
    end
    if type(t.z) ~= "number" then t.z = 0 end
    return t
end

function BetterSafehouse.setClientViewerTarget(playerObj, target)
    if not playerObj or not playerObj.getModData then return end
    local md = playerObj:getModData()
    if target == nil then
        md[TARGET_KEY] = nil
        return
    end
    md[TARGET_KEY] = {
        x = tonumber(target.x) or 0,
        y = tonumber(target.y) or 0,
        w = tonumber(target.w) or 0,
        h = tonumber(target.h) or 0,
        z = tonumber(target.z) or 0,
    }
end

---True if the current client viewer target matches the given safehouse (by bounds).
function BetterSafehouse.viewerTargetMatchesSafehouse(playerObj, sh)
    local t = BetterSafehouse.getClientViewerTarget(playerObj)
    if not t or not sh then return false end

    local okx, x = pcall(function() return sh:getX() end); if not okx then return false end
    local oky, y = pcall(function() return sh:getY() end); if not oky then return false end
    local okw, w = pcall(function() return sh:getW() end); if not okw then return false end
    local okh, h = pcall(function() return sh:getH() end); if not okh then return false end

    if x ~= t.x or y ~= t.y or w ~= t.w or h ~= t.h then return false end

    if sh.getZ then
        local okz, z = pcall(function() return sh:getZ() end)
        if okz and type(z) == "number" and type(t.z) == "number" then
            return z == t.z
        end
    end

    return true
end


-- =========================
-- Safehouse helpers
-- =========================

---Compare safehouses robustly across builds.
function BetterSafehouse.sameSafehouse(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end

    local function getId(sh)
        if sh.getId then
            local ok, v = pcall(function() return sh:getId() end)
            if ok and v ~= nil then return tostring(v) end
        end
        return nil
    end

    local ida, idb = getId(a), getId(b)
    if ida and idb then return ida == idb end

    -- Fallback: compare bounds
    local function bounds(sh)
        local ok, x = pcall(function() return sh:getX() end); if not ok then x = nil end
        local ok2, y = pcall(function() return sh:getY() end); if not ok2 then y = nil end
        local ok3, w = pcall(function() return sh:getW() end); if not ok3 then w = nil end
        local ok4, h = pcall(function() return sh:getH() end); if not ok4 then h = nil end
        local ok5, z = pcall(function() return sh.getZ and sh:getZ() or 0 end); if not ok5 then z = 0 end
        return x, y, w, h, z
    end

    local ax, ay, aw, ah, az = bounds(a)
    local bx, by, bw, bh, bz = bounds(b)
    if ax and bx then
        return ax == bx and ay == by and aw == bw and ah == bh and az == bz
    end
    return false
end


-- =========================================================
-- Safehouse membership counting (B42 client+server)
-- Used to enforce "max joined safehouses" limits.
-- =========================================================

---Return a (java) list of all safehouses, or nil.
function BetterSafehouse.getSafehouseList()
    if not SafeHouse or not SafeHouse.getSafehouseList then return nil end
    local ok, list = pcall(function() return SafeHouse.getSafehouseList() end)
    if not ok then return nil end
    return list
end

---Checks if a SafeHouse contains the given username (owner or member).
---@param sh any
---@param username string
function BetterSafehouse.safehouseHasUser(sh, username)
    if not sh or not username then return false end

    -- Owner check (if available)
    if sh.getOwner then
        local ok, owner = pcall(function() return sh:getOwner() end)
        if ok and owner == username then return true end
    end

    -- Fast check (if available)
    if sh.hasPlayer then
        local ok, has = pcall(function() return sh:hasPlayer(username) end)
        if ok and has then return true end
    end

    -- Fallback: scan player list
    if sh.getPlayers then
        local ok, players = pcall(function() return sh:getPlayers() end)
        if ok and players then
            if type(players) == "table" then
                for _, u in ipairs(players) do
                    if u == username then return true end
                end
            elseif players.size and players.get then
                for i = 0, players:size() - 1 do
                    if players:get(i) == username then return true end
                end
            end
        end
    end

    return false
end

---Counts how many safehouses the username participates in (owner OR member).
---@param username string
---@return integer
function BetterSafehouse.countSafehousesForUsername(username)
    if not username then return 0 end
    local list = BetterSafehouse.getSafehouseList()
    if not list then return 0 end

    local count = 0

    -- Java ArrayList
    if list.size and list.get then
        for i = 0, list:size() - 1 do
            local sh = list:get(i)
            if BetterSafehouse.safehouseHasUser(sh, username) then
                count = count + 1
            end
        end
        return count
    end

    -- Lua table (just in case)
    if type(list) == "table" then
        for _, sh in ipairs(list) do
            if BetterSafehouse.safehouseHasUser(sh, username) then
                count = count + 1
            end
        end
    end

    return count
end

---Returns the configured membership limit (0 = unlimited).
function BetterSafehouse.getMaxJoinedSafehouses()
    -- Only applies when EnhancedInvites is enabled (as requested).
    if not BetterSafehouse.getSandboxBool or not BetterSafehouse.getSandboxInt then return 0 end
    if not BetterSafehouse.getSandboxBool("EnhancedInvites", true) then return 0 end
    return BetterSafehouse.getSandboxInt("MaxJoinedSafehouses", 0) or 0
end

---When enabled, selecting respawn in one safehouse clears this username from all other safehouse respawn lists.
function BetterSafehouse.isSingleRespawnSafehouseEnabled()
    if not BetterSafehouse.getSandboxBool then return true end
    return BetterSafehouse.getSandboxBool("SingleRespawnSafehouseEnabled", true)
end

---True if the username is allowed to join one more safehouse.
function BetterSafehouse.canJoinAnotherSafehouse(username)
    local max = BetterSafehouse.getMaxJoinedSafehouses()
    if not max or max <= 0 then return true end
    local cur = BetterSafehouse.countSafehousesForUsername(username)
    return cur < max
end

-- Return module table for require()
return BetterSafehouse
