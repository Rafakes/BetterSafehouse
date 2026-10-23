--[[
    Better Safehouse (Build 42 MP) - Sub-owner (Subdono) - SERVER (authoritative)

    Storage
    -------
    Registry lives in global ModData (tag BetterSafehouse_SubOwners), which the engine
    persists to <save>/global_mod_data.bin.

        registry[key] = { "username1", "username2", ... }

    key = the safehouse getDatetimeCreated() timestamp, formatted with %.0f.
    Why that key and not the obvious ones (verified in the 42.19 source):
      * SafeHouse.getId()       -> rebuilt as "x,y at <now>" inside the constructor and NOT
                                   written by save(); it changes on every server restart.
      * SafeHouse.getOnlineID() -> Cantor pairing of (x,y), computed once in the constructor.
                                   It goes stale after our own AdminExpand moves x/y, and it is
                                   recomputed on load -> inconsistent.
      * bounds (x,y,w,h)        -> mutated by AdminExpand.
      * datetimeCreated         -> set on claim (setDatetimeCreated(0) means "now"), written by
                                   save() and restored by load(); untouched by expansion, owner
                                   change and title change. This is the only stable identity.

    Self-healing
    ------------
    A stored name only counts as a sub-owner while it is still a non-owner member of that
    safehouse. Lists are pruned (and written back) on every read/write, plus a periodic sweep,
    so we do not have to hook the vanilla membership paths we cannot reach from Lua.

    Authority
    ---------
    Nothing here trusts the client: bounds, target and permissions are all re-resolved and
    re-checked server-side on every command.
--]]

local BetterSafehouse = require("BetterSafehouse/00_BetterSafehouse_Shared") or BetterSafehouse
local SO = BetterSafehouse and BetterSafehouse.SubOwner or nil

-- Loud load marker: if this line is absent from the server console at boot, the server is
-- running an OLD copy of the mod and every SubOwner command will be ignored in silence
-- (cmd.txt still logs the packets -- that logging is engine-level, independent of Lua).
print("[BetterSafehouse][SubOwner] server file loaded (shared module present=" .. tostring(SO ~= nil) .. ")")

if not SO then
    print("[BetterSafehouse][SubOwner] ERROR: 02_BetterSafehouse_SubOwner_Shared.lua did not load; sub-owner system DISABLED")
    return
end

local function log(msg)
    print("[BetterSafehouse][SubOwner][S] " .. tostring(msg))
end

-- =========================================================
-- Safehouse lookup (mirrors BetterSafehouse_Server.lua)
-- =========================================================

local function eachSafehouse(list)
    if not list then return function() return nil end end

    if type(list) == "table" then
        return ipairs(list)
    end

    local okSize, n = pcall(function() return list:size() end)
    if okSize and type(n) == "number" and n > 0 then
        local i = 0
        return function()
            if i < n then
                local v = nil
                local okGet = pcall(function() v = list:get(i) end)
                i = i + 1
                if okGet then return i, v end
            end
            return nil
        end
    end

    return function() return nil end
end

local function getSafehouseList()
    if not SafeHouse or not SafeHouse.getSafehouseList then return nil end
    local ok, list = pcall(function() return SafeHouse.getSafehouseList() end)
    if not ok then return nil end
    return list
end

local function findSafehouseByBounds(x, y, w, h, z)
    local list = getSafehouseList()
    if not list then return nil end
    for _, sh in eachSafehouse(list) do
        if sh and sh.getX and sh.getY and sh.getW and sh.getH then
            local okx, sx = pcall(function() return sh:getX() end)
            local oky, sy = pcall(function() return sh:getY() end)
            local okw, sw = pcall(function() return sh:getW() end)
            local okh, shh = pcall(function() return sh:getH() end)
            if okx and oky and okw and okh then
                if sx == x and sy == y and sw == w and shh == h and SO.safehouseZ(sh) == (z or 0) then
                    return sh
                end
            end
        end
    end
    return nil
end

local function findOnlinePlayerByUsername(username)
    username = SO.cleanName(username)
    if username == "" then return nil end
    local online = getOnlinePlayers()
    if not online then return nil end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        if p and p.getUsername and tostring(p:getUsername()) == username then
            return p
        end
    end
    return nil
end

-- =========================================================
-- Registry (ModData)
-- =========================================================

local function registry()
    if not ModData or not ModData.getOrCreate then return nil end
    local ok, t = pcall(function() return ModData.getOrCreate(SO.MODDATA_TAG) end)
    if not ok or not t then return nil end
    return t
end

local function membersReg()
    if not ModData or not ModData.getOrCreate then return nil end
    local ok, t = pcall(function() return ModData.getOrCreate(SO.MODDATA_TAG_MEMBERS) end)
    if not ok or not t then return nil end
    return t
end

local function keyFor(sh)
    if not sh or not sh.getDatetimeCreated then return nil end
    local ok, created = pcall(function() return sh:getDatetimeCreated() end)
    if not ok or type(created) ~= "number" or created <= 0 then return nil end
    return string.format("%.0f", created)
end

---Two safehouses claimed inside the same millisecond would collide on the key.
---Astronomically unlikely, but cheap to rule out: nudge the duplicate by 1ms
---(datetimeCreated is only ever displayed as a date, so this is invisible in-game).
---NOTE: never pass 0 to setDatetimeCreated -- the engine reads 0 as "use current time".
---When we nudge, MIGRATE any registry entries to the new key so we never orphan a stored list,
---and prefer to nudge the safehouse that has NO data at the shared key.
local function migrateKey(oldKey, newKey)
    for _, reg in ipairs({ registry(), membersReg() }) do
        if reg and reg[oldKey] ~= nil then
            reg[newKey] = reg[oldKey]
            reg[oldKey] = nil
        end
    end
end

local function ensureUniqueKeys()
    local list = getSafehouseList()
    if not list then return end

    local seen = {}   -- key -> the safehouse currently holding it
    for _, sh in eachSafehouse(list) do
        local k = keyFor(sh)
        if k then
            local prevHolder = seen[k]
            if prevHolder then
                -- Collision. Nudge the safehouse we just reached (`sh`); the earlier holder keeps
                -- the key. migrateKey moves `sh`'s own stored data along with it, so nothing is
                -- orphaned regardless of which side happened to own the shared key.
                local nudged = sh

                local guard = 0
                while k and seen[k] and guard < 1000 do
                    local ok, created = pcall(function() return nudged:getDatetimeCreated() end)
                    if not ok or type(created) ~= "number" or created <= 0 then break end
                    local newCreated = created + 1
                    pcall(function() nudged:setDatetimeCreated(newCreated) end)
                    local newKey = keyFor(nudged)
                    if newKey and newKey ~= k then
                        migrateKey(k, newKey)   -- move nudged's data (if any) to its new key
                        k = newKey
                    end
                    guard = guard + 1
                end

                if guard > 0 then
                    log(string.format("duplicate creation timestamp resolved for safehouse '%s' -> key=%s",
                        tostring(nudged:getTitle()), tostring(k)))
                end
                seen[k] = nudged
            else
                seen[k] = sh
            end
        end
    end
end

local _initDone = false
local function ensureInit()
    if _initDone then return end
    _initDone = true
    ensureUniqueKeys()
end

---Raw stored list for `sh` as a plain Lua array (no pruning).
local function rawSubs(sh)
    local reg = registry()
    local key = keyFor(sh)
    if not reg or not key then return {}, nil, nil end

    local stored = reg[key]
    local out = {}
    if type(stored) == "table" then
        for i = 1, #stored do
            local u = SO.cleanName(stored[i])
            if u ~= "" then out[#out + 1] = u end
        end
    end
    return out, reg, key
end

local function listsEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

---Write the sub-owner list of `sh` back to the registry (pruned first).
---Declared before reconcileRejoins/getSubs because Lua binds `local function`
---references by declaration order.
local function setSubs(sh, subs)
    ensureInit()
    local reg = registry()
    local key = keyFor(sh)
    if not reg or not key then return false end

    local pruned = SO.pruneList(sh, subs)
    if #pruned == 0 then
        reg[key] = nil
    else
        reg[key] = pruned
    end
    return true
end

---Current non-owner members of `sh`, as a plain array.
local function currentMembers(sh)
    local out = {}
    if not sh or not sh.getPlayers then return out end
    local ok, players = pcall(function() return sh:getPlayers() end)
    if not ok or not players then return out end
    local ok2, n = pcall(function() return players:size() end)
    if not ok2 or type(n) ~= "number" then return out end
    for i = 0, n - 1 do
        local okG, u = pcall(function() return players:get(i) end)
        if okG and u then
            u = SO.cleanName(u)
            if u ~= "" and not SO.isOwner(sh, u) and not SO.listContains(out, u) then
                out[#out + 1] = u
            end
        end
    end
    return out
end

---Detect leave->rejoin and strip stale ranks.
---A member who currently holds a rank but was ABSENT from the previously recorded member set
---has left and come back (through the vanilla invite path we cannot hook), so their rank is
---dropped. Then the member snapshot is refreshed. Called from getSubs (panel opens + commands)
---and from the periodic sweep, so the exposure window is at most one sweep interval.
local function reconcileRejoins(sh)
    local mreg = membersReg()
    local key = keyFor(sh)
    if not mreg or not key then return end

    -- Only safehouses that actually HAVE sub-owners need rejoin detection. For everyone
    -- else this is two table lookups and out -- keeps the periodic sweep O(1) per
    -- unranked safehouse (the common case on a 150-player server).
    local raw = rawSubs(sh)
    if #raw == 0 then
        if mreg[key] ~= nil then mreg[key] = nil end
        return
    end

    local current = currentMembers(sh)
    local currentSet = {}
    for i = 1, #current do currentSet[current[i]] = true end

    local prev = mreg[key]
    if type(prev) == "table" then
        local prevSet = {}
        for i = 1, #prev do prevSet[SO.cleanName(prev[i])] = true end

        local kept = {}
        local dropped = nil
        for i = 1, #raw do
            local s = raw[i]
            -- present now, but not present at the last snapshot => rejoined in the gap.
            if currentSet[s] and not prevSet[s] then
                dropped = (dropped and (dropped .. ", ") or "") .. s
            else
                kept[#kept + 1] = s
            end
        end

        if dropped then
            setSubs(sh, kept)
            log(string.format("rank stripped after leave/rejoin: %s (safehouse '%s')",
                dropped, tostring(sh:getTitle())))
        end
    end

    -- Refresh the snapshot (store nil for empty to keep the table small).
    if #current == 0 then
        mreg[key] = nil
    else
        mreg[key] = current
    end
end

---Authoritative sub-owner list of `sh`, pruned (and written back when it changed).
local function getSubs(sh)
    ensureInit()
    reconcileRejoins(sh)
    local raw, reg, key = rawSubs(sh)
    local pruned = SO.pruneList(sh, raw)

    if reg and key and not listsEqual(raw, pruned) then
        if #pruned == 0 then
            reg[key] = nil
        else
            reg[key] = pruned
        end
    end

    return pruned
end

---True if `username` is a sub-owner of `sh` (server truth). Exposed so the invite
---handler in BetterSafehouse_Server.lua can reuse it.
function SO.serverIsSubOwner(sh, username)
    if not SO.isEnabled() then return false end
    username = SO.cleanName(username)
    if username == "" or not sh then return false end
    if SO.isOwner(sh, username) then return false end
    if not SO.isPlainMemberSlot(sh, username) then return false end
    return SO.listContains(getSubs(sh), username)
end

---Server truth for "may add/remove plain members".
function SO.serverCanManageMembers(sh, playerObj)
    if not sh or not playerObj then return false end
    if SO.isPrivileged(playerObj) then return true end

    local username = playerObj.getUsername and tostring(playerObj:getUsername()) or nil
    if not username then return false end

    if SO.isOwner(sh, username) then return true end
    return SO.serverIsSubOwner(sh, username)
end

---A player who just joined a safehouse can never be a sub-owner: drop any stale entry.
---Called from our own add path (BetterSafehouse_Server.lua invite accept).
function SO.onMemberJoined(sh, username)
    if not isServer() then return end
    username = SO.cleanName(username)
    if not sh or username == "" then return end

    local subs = getSubs(sh)
    if not SO.listContains(subs, username) then return end

    local out = {}
    for i = 1, #subs do
        if subs[i] ~= username then out[#out + 1] = subs[i] end
    end
    setSubs(sh, out)
    log(string.format("stale sub-owner entry dropped for re-joining member '%s'", username))
end

-- =========================================================
-- Networking
-- =========================================================

local function sendResult(playerObj, ok, key, args)
    if not isServer() or not playerObj then return end
    sendServerCommand(playerObj, SO.MODULE, "SubOwnerResult", { ok = ok == true, key = key, args = args })
end

local function subOwnersPayload(sh)
    local b = SO.boundsOf(sh)
    if not b then return nil end
    b.subs = getSubs(sh)
    return b
end

---Reply to the player who asked (panel opened).
local function sendSubOwnersTo(playerObj, sh)
    if not isServer() or not playerObj or not sh then return end
    local payload = subOwnersPayload(sh)
    if not payload then return end
    sendServerCommand(playerObj, SO.MODULE, "SubOwnersList", payload)
end

---Push the new list to everyone so any open safehouse panel refreshes.
---Promote/demote/remove are rare, so a broadcast is cheaper than tracking watchers.
local function broadcastSubOwners(sh)
    if not isServer() or not sh then return end
    local payload = subOwnersPayload(sh)
    if not payload then return end

    local online = getOnlinePlayers()
    if not online then return end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        if p then
            sendServerCommand(p, SO.MODULE, "SubOwnersChanged", payload)
        end
    end
end

-- =========================================================
-- Command handlers
-- =========================================================

---Resolve + validate the safehouse referenced by a client payload.
---Returns sh, or nil (a failure result has already been sent).
local function resolveSafehouse(playerObj, args)
    local x = tonumber(args.x); local y = tonumber(args.y)
    local w = tonumber(args.w); local h = tonumber(args.h)
    local z = tonumber(args.z) or 0

    if not x or not y or not w or not h then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_InvalidSafehouse")
        return nil
    end

    local sh = findSafehouseByBounds(x, y, w, h, z)
    if not sh then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SafehouseNotFoundServer")
        return nil
    end

    return sh
end

local function handleSubOwnersRequest(playerObj, args)
    if not playerObj or not args then return end
    if not SO.isEnabled() then return end

    local x = tonumber(args.x); local y = tonumber(args.y)
    local w = tonumber(args.w); local h = tonumber(args.h)
    local z = tonumber(args.z) or 0
    if not x or not y or not w or not h then return end

    local sh = findSafehouseByBounds(x, y, w, h, z)
    if not sh then return end   -- silent: this is a passive UI query, not an action

    -- Only reveal the roster to people who belong to this safehouse (or admins). A non-member
    -- knowing another group's bounds must not be able to enumerate its internal roles.
    local username = playerObj.getUsername and playerObj:getUsername() or nil
    if not (SO.isPrivileged(playerObj) or (username and SO.isInPlayerList(sh, username))) then
        return   -- silent, same as not-found
    end

    sendSubOwnersTo(playerObj, sh)
end

---Promote a plain member to sub-owner. OWNER or ADMIN only.
local function handlePromote(playerObj, args)
    if not playerObj or not args then return end

    if not SO.isEnabled() then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_DisabledInSandbox")
        return
    end

    local sh = resolveSafehouse(playerObj, args)
    if not sh then return end

    local actor = SO.cleanName(playerObj:getUsername())
    -- Only the owner (or an admin) can change ranks. A sub-owner explicitly cannot.
    if not (SO.isPrivileged(playerObj) or SO.isOwner(sh, actor)) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_OnlyOwnerCanPromote")
        return
    end

    local target = SO.cleanName(args.username)
    if target == "" then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_InvalidPlayer")
        return
    end

    if SO.isOwner(sh, target) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_CannotPromoteOwner")
        return
    end

    if not SO.isPlainMemberSlot(sh, target) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_NotAMember")
        return
    end

    local subs = getSubs(sh)
    if SO.listContains(subs, target) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_AlreadySubOwner")
        return
    end

    local max = SO.getMaxSubOwners()
    if max > 0 and #subs >= max then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_MaxReached", { tostring(#subs), tostring(max) })
        return
    end

    subs[#subs + 1] = target
    if not setSubs(sh, subs) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_GenericFailed")
        return
    end

    log(string.format("'%s' promoted '%s' to sub-owner of '%s' (owner=%s)",
        actor, target, tostring(sh:getTitle()), tostring(sh:getOwner())))

    broadcastSubOwners(sh)
    sendResult(playerObj, true, "IGUI_BetterSafehouse_SubOwner_Promoted", { target })

    local targetPlayer = findOnlinePlayerByUsername(target)
    if targetPlayer then
        sendResult(targetPlayer, true, "IGUI_BetterSafehouse_SubOwner_YouWerePromoted", { tostring(sh:getTitle()) })
    end
end

---Demote a sub-owner back to plain member. OWNER or ADMIN only.
local function handleDemote(playerObj, args)
    if not playerObj or not args then return end

    if not SO.isEnabled() then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_DisabledInSandbox")
        return
    end

    local sh = resolveSafehouse(playerObj, args)
    if not sh then return end

    local actor = SO.cleanName(playerObj:getUsername())
    if not (SO.isPrivileged(playerObj) or SO.isOwner(sh, actor)) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_OnlyOwnerCanDemote")
        return
    end

    local target = SO.cleanName(args.username)
    if target == "" then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_InvalidPlayer")
        return
    end

    local subs = getSubs(sh)
    if not SO.listContains(subs, target) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_NotSubOwner")
        return
    end

    local out = {}
    for i = 1, #subs do
        if subs[i] ~= target then out[#out + 1] = subs[i] end
    end

    if not setSubs(sh, out) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_GenericFailed")
        return
    end

    log(string.format("'%s' demoted '%s' from sub-owner of '%s' (owner=%s)",
        actor, target, tostring(sh:getTitle()), tostring(sh:getOwner())))

    broadcastSubOwners(sh)
    sendResult(playerObj, true, "IGUI_BetterSafehouse_SubOwner_Demoted", { target })

    local targetPlayer = findOnlinePlayerByUsername(target)
    if targetPlayer then
        sendResult(targetPlayer, true, "IGUI_BetterSafehouse_SubOwner_YouWereDemoted", { tostring(sh:getTitle()) })
    end
end

---Remove a plain member. Owner/admin may use it too, but it exists because the vanilla
---SafehouseChangeMemberPacket is refused by AntiCheatSafeHouseMember for a sub-owner.
local function handleRemoveMember(playerObj, args)
    if not playerObj or not args then return end

    if not SO.isEnabled() then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_DisabledInSandbox")
        return
    end

    local sh = resolveSafehouse(playerObj, args)
    if not sh then return end

    local actor = SO.cleanName(playerObj:getUsername())
    if not SO.serverCanManageMembers(sh, playerObj) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_NoPermission")
        return
    end

    local target = SO.cleanName(args.username)
    if target == "" then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_InvalidPlayer")
        return
    end

    -- Never let this path strip the owner: SafeHouse keeps the owner inside getPlayers(),
    -- so removePlayer(owner) would leave the safehouse in a broken half-owned state.
    if SO.isOwner(sh, target) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_CannotRemoveOwner")
        return
    end

    if target == actor then
        -- Leaving is the vanilla "Quit safehouse" button; it is allowed for everyone
        -- and the anti-cheat accepts it, so we do not duplicate it here.
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_CannotRemoveSelf")
        return
    end

    if not SO.isPlainMemberSlot(sh, target) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_NotAMember")
        return
    end

    -- A sub-owner outranks plain members only.
    local actorIsBoss = SO.isPrivileged(playerObj) or SO.isOwner(sh, actor)
    if not actorIsBoss and SO.serverIsSubOwner(sh, target) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_SubOwner_CannotRemoveSubOwner")
        return
    end

    -- Drop the rank first, so the registry cannot keep a ghost entry if anything below fails.
    if SO.serverIsSubOwner(sh, target) then
        local subs = getSubs(sh)
        local out = {}
        for i = 1, #subs do
            if subs[i] ~= target then out[#out + 1] = subs[i] end
        end
        setSubs(sh, out)
    end

    -- Vanilla removal: removePlayer + SafehouseSync to every client (+ trespass teleport-out).
    -- This is exactly what SafehouseChangeMemberPacket.processServer does.
    local kicked = pcall(function() SafeHouse.kickUserFromSafehouse(sh, target) end)
    if not kicked then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_GenericFailed")
        return
    end

    log(string.format("'%s' removed member '%s' from '%s' (owner=%s)",
        actor, target, tostring(sh:getTitle()), tostring(sh:getOwner())))

    broadcastSubOwners(sh)
    sendResult(playerObj, true, "IGUI_BetterSafehouse_SubOwner_MemberRemoved", { target })

    local targetPlayer = findOnlinePlayerByUsername(target)
    if targetPlayer then
        sendResult(targetPlayer, true, "IGUI_BetterSafehouse_SubOwner_YouWereRemoved", { tostring(sh:getTitle()) })
    end
end

-- =========================================================
-- Maintenance sweep
-- =========================================================

---Prune ranks of players who left, and drop records of safehouses that no longer exist
---(vanilla release goes through a Java packet we cannot hook from Lua).
local function sweep()
    if not isServer() then return end
    ensureInit()

    local reg = registry()
    if not reg then return end

    local list = getSafehouseList()
    if not list then return end

    local live = {}
    for _, sh in eachSafehouse(list) do
        local key = keyFor(sh)
        if key then
            live[key] = true
            getSubs(sh)   -- prunes + writes back
        end
    end

    local orphans = {}
    for key, _ in pairs(reg) do
        if not live[key] then
            orphans[#orphans + 1] = key
        end
    end

    for i = 1, #orphans do
        reg[orphans[i]] = nil
    end

    -- Same for the membership-snapshot table (released safehouses leave records behind).
    local mreg = membersReg()
    if mreg then
        local mOrphans = {}
        for key, _ in pairs(mreg) do
            if not live[key] then mOrphans[#mOrphans + 1] = key end
        end
        for i = 1, #mOrphans do mreg[mOrphans[i]] = nil end
    end

    if #orphans > 0 then
        log(string.format("sweep dropped %d orphan record(s)", #orphans))
    end
end

---Lightweight pass: only the leave/rejoin reconciliation, run often so the exposure window
---for a vanilla re-add is at most one minute (vs the 10-minute full sweep). Cheap: it compares
---small member sets and only writes when a rank is actually stripped or the snapshot changed.
local function reconcileSweep()
    if not isServer() then return end
    ensureInit()
    local list = getSafehouseList()
    if not list then return end
    for _, sh in eachSafehouse(list) do
        if keyFor(sh) then
            reconcileRejoins(sh)
        end
    end
end

-- =========================================================
-- Wiring
-- =========================================================

local function onClientCommand(module, command, playerObj, args)
    if module ~= SO.MODULE then return end
    if command == "SubOwnersRequest" then return handleSubOwnersRequest(playerObj, args) end

    if command == "SubOwnerPromote" or command == "SubOwnerDemote" or command == "SubOwnerRemoveMember" then
        local who = (playerObj and playerObj.getUsername) and tostring(playerObj:getUsername()) or "?"
        log(string.format("received %s from '%s' (target=%s)", command, who, tostring(args and args.username)))
    end

    if command == "SubOwnerPromote" then return handlePromote(playerObj, args) end
    if command == "SubOwnerDemote" then return handleDemote(playerObj, args) end
    if command == "SubOwnerRemoveMember" then return handleRemoveMember(playerObj, args) end
end

Events.OnClientCommand.Add(onClientCommand)

Events.OnServerStarted.Add(function()
    ensureInit()
    sweep()
end)

Events.EveryOneMinute.Add(reconcileSweep)
Events.EveryTenMinutes.Add(sweep)

