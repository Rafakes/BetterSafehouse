--[[
    Better Safehouse (Build 42 MP) - Sub-owner (Subdono) - Shared

    Role model:
        Owner    : full vanilla powers (release, change owner, change title, add/remove).
        SubOwner : may ADD and REMOVE plain members only.
                   May NOT: remove the owner, remove another sub-owner, promote/demote,
                   change owner, change title or release the safehouse.
        Member   : no management powers.
        Admin    : (Capability.CanSetupSafehouses) always treated as >= Owner.

    Why a custom net path is required (B42.19 engine facts):
        - SafehouseChangeMemberPacket (vanilla "remove") is validated by AntiCheatSafeHouseMember,
          which rejects the packet unless the sender IS the target or IS the owner.
        - SafehouseInvitePacket (vanilla "add") is validated by AntiCheatSafeHouseOwner,
          which rejects the packet unless the sender IS the owner.
      A sub-owner is neither, so BOTH vanilla packets are silently dropped for them.
      Every sub-owner action therefore travels as a server-validated client command.

    This file is loaded early (02_) and holds only helpers + the client-side cache.
    The authoritative state lives on the server (see BetterSafehouse_SubOwner_Server.lua).
--]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse.SubOwner = BetterSafehouse.SubOwner or {}

local SO = BetterSafehouse.SubOwner

-- Net module reused from the rest of the mod, so a single OnClientCommand/OnServerCommand
-- handler family keeps working.
SO.MODULE = "BetterSafehouse"

-- ModData tag holding the authoritative registry (server-side, persisted in global_mod_data.bin).
SO.MODDATA_TAG = "BetterSafehouse_SubOwners"

-- Companion tag: the last observed non-owner member set per safehouse. Diffing it against the
-- live member set lets the server detect a member who LEFT and REJOINED through the vanilla
-- invite path (a Java packet Lua cannot hook) and strip their stale rank.
SO.MODDATA_TAG_MEMBERS = "BetterSafehouse_SubOwnersMembers"

-- =========================================================
-- Sandbox
-- =========================================================

function SO.isEnabled()
    if not BetterSafehouse.getSandboxBool then return true end
    return BetterSafehouse.getSandboxBool("EnableSubOwners", true)
end

---Maximum sub-owners per safehouse (0 = unlimited).
function SO.getMaxSubOwners()
    if not BetterSafehouse.getSandboxInt then return 0 end
    local v = BetterSafehouse.getSandboxInt("MaxSubOwners", 0) or 0
    if v < 0 then v = 0 end
    return v
end

-- =========================================================
-- Small utilities
-- =========================================================

function SO.cleanName(u)
    u = tostring(u or "")
    u = u:gsub("^%s+", ""):gsub("%s+$", "")
    if #u > 64 then u = u:sub(1, 64) end
    return u
end

---SafeHouse has no getZ() in B42; the whole mod addresses safehouses with z = 0.
---Kept as a defensive read so a future build that adds getZ() keeps working.
function SO.safehouseZ(sh)
    if sh and sh.getZ then
        local ok, z = pcall(function() return sh:getZ() end)
        if ok and type(z) == "number" then return z end
    end
    return 0
end

---Wire payload used to address a safehouse (client -> server and server -> client).
---The server resolves it back to a SafeHouse via bounds lookup.
function SO.boundsOf(sh)
    if not sh or not sh.getX then return nil end
    local ok, b = pcall(function()
        return { x = sh:getX(), y = sh:getY(), w = sh:getW(), h = sh:getH(), z = SO.safehouseZ(sh) }
    end)
    if not ok or not b then return nil end
    return b
end

---Stable string key for the CLIENT-side cache (bounds based).
function SO.boundsKey(x, y, w, h, z)
    return string.format("%d:%d:%d:%d:%d",
        math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0),
        math.floor(tonumber(w) or 0), math.floor(tonumber(h) or 0),
        math.floor(tonumber(z) or 0))
end

function SO.safehouseCacheKey(sh)
    local b = SO.boundsOf(sh)
    if not b then return nil end
    return SO.boundsKey(b.x, b.y, b.w, b.h, b.z)
end

---True if `username` is the owner of `sh`.
function SO.isOwner(sh, username)
    if not sh or not username or username == "" then return false end
    local ok, owner = pcall(function() return sh:getOwner() end)
    if not ok or not owner then return false end
    return tostring(owner) == tostring(username)
end

---True if `username` currently appears in the safehouse player list (owner included:
---the engine keeps the owner inside getPlayers()).
function SO.isInPlayerList(sh, username)
    if not sh or not sh.getPlayers or not username or username == "" then return false end
    local ok, players = pcall(function() return sh:getPlayers() end)
    if not ok or not players then return false end
    local ok2, has = pcall(function() return players:contains(tostring(username)) end)
    if ok2 then return has == true end
    return false
end

---True if `username` is a member that is NOT the owner.
function SO.isPlainMemberSlot(sh, username)
    return SO.isInPlayerList(sh, username) and not SO.isOwner(sh, username)
end

---Admin check (same semantics the rest of the mod uses: vanilla treats
---Capability.CanSetupSafehouses as "privileged" on the safehouse panel).
function SO.isPrivileged(playerObj)
    if not playerObj then return false end

    if playerObj.getRole and Capability and Capability.CanSetupSafehouses then
        local ok, v = pcall(function()
            return playerObj:getRole():hasCapability(Capability.CanSetupSafehouses)
        end)
        if ok and v == true then return true end
    end

    if playerObj.isAccessLevel then
        local ok, v = pcall(function() return playerObj:isAccessLevel("Admin") end)
        if ok and v == true then return true end
    end

    if playerObj.getAccessLevel then
        local ok, lvl = pcall(function() return playerObj:getAccessLevel() end)
        if ok and lvl then
            lvl = tostring(lvl):lower()
            if lvl == "admin" then return true end
        end
    end

    return false
end

-- =========================================================
-- Sub-owner list helpers (pure: operate on a plain array of usernames)
-- =========================================================

function SO.listContains(list, username)
    if type(list) ~= "table" or not username or username == "" then return false end
    for i = 1, #list do
        if tostring(list[i]) == tostring(username) then return true end
    end
    return false
end

---Drop names that are no longer valid sub-owners (left the safehouse, or became the owner).
---Self-healing: it means we never have to hook every vanilla membership path.
function SO.pruneList(sh, list)
    local out = {}
    if type(list) ~= "table" or not sh then return out end
    for i = 1, #list do
        local u = SO.cleanName(list[i])
        if u ~= "" and SO.isPlainMemberSlot(sh, u) and not SO.listContains(out, u) then
            out[#out + 1] = u
        end
    end
    return out
end

-- =========================================================
-- CLIENT cache (filled by the server replies; never trusted for authority)
-- =========================================================

SO._cache = SO._cache or {}   -- boundsKey -> { subs = { "user", ... } }

function SO.setCachedSubs(x, y, w, h, z, subs)
    local key = SO.boundsKey(x, y, w, h, z)
    local clean = {}
    if type(subs) == "table" then
        for i = 1, #subs do
            local u = SO.cleanName(subs[i])
            if u ~= "" then clean[#clean + 1] = u end
        end
        if #clean == 0 then
            -- Net-deserialized tables (PZNetKahluaTableImpl) may not report '#'; walk pairs.
            for _, v in pairs(subs) do
                local u = SO.cleanName(v)
                if u ~= "" and not SO.listContains(clean, u) then clean[#clean + 1] = u end
            end
        end
    end
    SO._cache[key] = { subs = clean }
end

---Returns the cached sub-owner array for `sh`, or nil when the client has not
---received it yet (caller must treat nil as "unknown" -> no powers granted).
function SO.getCachedSubs(sh)
    local key = SO.safehouseCacheKey(sh)
    if not key then return nil end
    local entry = SO._cache[key]
    if not entry then return nil end
    return entry.subs
end

---Client-side view of "is `username` a sub-owner of `sh`".
---Returns false while the list is still unknown, so the UI stays locked until the
---server answers (fail-closed).
function SO.isSubOwnerCached(sh, username)
    if not SO.isEnabled() then return false end
    username = SO.cleanName(username)
    if username == "" then return false end
    if SO.isOwner(sh, username) then return false end
    if not SO.isPlainMemberSlot(sh, username) then return false end

    local subs = SO.getCachedSubs(sh)
    if not subs then return false end
    return SO.listContains(subs, username)
end

---Can `playerObj` add/remove plain members of `sh`? (client-side view, for UI gating only)
function SO.canManageMembersCached(sh, playerObj)
    if not sh or not playerObj then return false end
    if SO.isPrivileged(playerObj) then return true end

    local username = playerObj.getUsername and playerObj:getUsername() or nil
    if not username then return false end

    if SO.isOwner(sh, username) then return true end
    return SO.isSubOwnerCached(sh, username)
end

---Is `playerObj` acting purely as a sub-owner (i.e. not owner and not admin)?
---This is the case where vanilla packets are dropped by the anti-cheat and every
---action must be routed through our server commands.
function SO.actsAsSubOwnerOnly(sh, playerObj)
    if not sh or not playerObj then return false end
    if SO.isPrivileged(playerObj) then return false end

    local username = playerObj.getUsername and playerObj:getUsername() or nil
    if not username then return false end
    if SO.isOwner(sh, username) then return false end

    return SO.isSubOwnerCached(sh, username)
end

return BetterSafehouse.SubOwner

