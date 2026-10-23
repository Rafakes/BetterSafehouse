--[[
    Better Safehouse (B42 MP) - Server side

    AdminsFreeAddToSafehouse:
      When sandbox option BetterSafehouse.AdminsFreeAddToSafehouse is enabled,
      admins (GM) can add players to a safehouse via the safehouse UI without restrictions.

    This is inspired by ServerTweaker's "AdminsFreeAddToSafehouse" behavior, but executed server-side (MP-safe).
--]]

local BetterSafehouse = require("BetterSafehouse/00_BetterSafehouse_Shared") or BetterSafehouse

local PRIMARY_RESPAWN_DATA_KEY = "BetterSafehouse_PrimaryRespawns"
local PrimaryRespawnData = nil

local function getPrimaryRespawnData()
    if type(PrimaryRespawnData) ~= "table" then
        if ModData and ModData.getOrCreate then
            local ok, data = pcall(function() return ModData.getOrCreate(PRIMARY_RESPAWN_DATA_KEY) end)
            if ok and type(data) == "table" then
                PrimaryRespawnData = data
            end
        end
        if type(PrimaryRespawnData) ~= "table" then
            PrimaryRespawnData = {}
        end
    end
    return PrimaryRespawnData
end

local function savePrimaryRespawnData()
    if ModData and ModData.add then
        pcall(function() ModData.add(PRIMARY_RESPAWN_DATA_KEY, getPrimaryRespawnData()) end)
    end
end

local function initPrimaryRespawnData()
    PrimaryRespawnData = nil
    getPrimaryRespawnData()
end

if Events and Events.OnInitGlobalModData then
    Events.OnInitGlobalModData.Add(initPrimaryRespawnData)
end

local function getSafehouseList()
    if not SafeHouse then return nil end
    if SafeHouse.getSafehouseList then
        local ok, list = pcall(function() return SafeHouse.getSafehouseList() end)
        if ok then return list end
    end
    return nil
end


-- Safe iterator for SafeHouse.getSafehouseList() across different return types (Lua table or Java List)
local function eachSafehouse(list)
    if not list then
        return function() return nil end
    end

    -- Lua table (KahluaTableImpl / PZNetKahluaTableImpl also reports as table)
    if type(list) == "table" then
        return ipairs(list)
    end

    -- Java ArrayList / PZArrayList etc. (userdata): use :size() and :get(i)
    local okSize, n = pcall(function() return list:size() end)
    if okSize and type(n) == "number" and n > 0 then
        local i = 0
        return function()
            if i < n then
                local v = nil
                local okGet = pcall(function() v = list:get(i) end)
                i = i + 1
                if okGet then
                    return i, v
                end
            end
            return nil
        end
    end

    -- Unknown type
    return function() return nil end
end

local function isAdmin(playerObj)
    -- Only true "Admin" is allowed to run the offline-invite / free-add command.
    if not playerObj then return false end

    if playerObj.isAccessLevel then
        local ok, v = pcall(function() return playerObj:isAccessLevel("Admin") end)
        if ok and v == true then return true end
    end

    if playerObj.getAccessLevel then
        local ok, lvl = pcall(function() return playerObj:getAccessLevel() end)
        lvl = ok and lvl and tostring(lvl) or ""
        if lvl ~= "" and lvl:lower() == "admin" then return true end
    end

    if playerObj.isAdmin then
        -- Fallback: some builds expose isAdmin() only for true admins.
        local ok, v = pcall(function() return playerObj:isAdmin() end)
        if ok and v == true then return true end
    end

    return false
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
            local okz, sz = pcall(function()
                if sh.getZ then return sh:getZ() end
                return 0
            end)
            if okx and oky and okw and okh then
                if sx == x and sy == y and sw == w and shh == h and (sz or 0) == (z or 0) then
                    return sh
                end
            end
        end
    end
    return nil
end

-- Send a per-client localized message (key + args) so each player sees the correct language.
-- Payload remains backwards compatible (also includes msg when provided).
local function sendAdminAddResult(playerObj, ok, key, args, fallbackMsg)
    if not playerObj then return end
    local payload = { ok = ok == true, key = key, args = args }
    if fallbackMsg then payload.msg = fallbackMsg end
    sendServerCommand(playerObj, "BetterSafehouse", "AdminAddResult", payload)
end

local function sendAdminReleaseResult(playerObj, ok, key, args, fallbackMsg)
    if not playerObj then return end
    local payload = { ok = ok == true, key = key, args = args }
    if fallbackMsg then payload.msg = fallbackMsg end
    sendServerCommand(playerObj, "BetterSafehouse", "AdminReleaseResult", payload)
end

local function sendPrimaryRespawnResult(playerObj, ok, key, args, fallbackMsg)
    if not playerObj then return end
    local payload = { ok = ok == true, key = key, args = args }
    if fallbackMsg then payload.msg = fallbackMsg end
    sendServerCommand(playerObj, "BetterSafehouse", "PrimaryRespawnResult", payload)
end

local function broadcastSafehouseReleased(payload)
    if not payload then return end
    local online = getOnlinePlayers()
    if not online then return end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        if p then
            sendServerCommand(p, "BetterSafehouse", "SafehouseReleased", payload)
        end
    end
end


local function broadcastSafehouseMemberAdded(sh, addedUsername, prevOwner, changeOwnership)
    if not sh or not addedUsername then return end

    local z = 0
    if sh.getZ then
        local ok, zz = pcall(function() return sh:getZ() end)
        if ok and type(zz) == "number" then z = zz end
    end

    local owner = nil
    if sh.getOwner then
        local ok, o = pcall(function() return sh:getOwner() end)
        if ok then owner = o end
    end

    local payload = {
        x = sh:getX(), y = sh:getY(), w = sh:getW(), h = sh:getH(), z = z,
        username = tostring(addedUsername),
        changeOwnership = changeOwnership == true,
        owner = owner and tostring(owner) or nil,
        prevOwner = prevOwner and tostring(prevOwner) or nil,
    }

    local online = getOnlinePlayers()
    if not online then return end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        sendServerCommand(p, "BetterSafehouse", "SafehouseMemberAdded", payload)
    end

    print(string.format("[BetterSafehouse] SafehouseMemberAdded -> %s (owner=%s) rect=%d,%d,%d,%d",
        payload.username, tostring(payload.owner), payload.x, payload.y, payload.w, payload.h))
end

local function broadcastPrimaryRespawnChanged(payload)
    if not payload then return end
    local online = getOnlinePlayers()
    if not online then return end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        if p then
            sendServerCommand(p, "BetterSafehouse", "PrimaryRespawnChanged", payload)
        end
    end
end

local function handleAdminAdd(playerObj, args)
    if not playerObj or not args then return end

    -- sandbox gate
    if BetterSafehouse.getSandboxBool and (not BetterSafehouse.getSandboxBool("AdminsFreeAddToSafehouse", true)) then
        sendAdminAddResult(playerObj, false, "IGUI_BetterSafehouse_AdminAdd_DisabledInSandbox")
        return
    end

    -- permission gate
    if not isAdmin(playerObj) then
        sendAdminAddResult(playerObj, false, "IGUI_BetterSafehouse_NoPermission")
        return
    end

    local username = tostring(args.username or "")
    username = username:gsub("^%s+", ""):gsub("%s+$", "")
    if #username > 64 then username = username:sub(1, 64) end
    if username == "" then
        sendAdminAddResult(playerObj, false, "IGUI_BetterSafehouse_InvalidPlayer")
        return
    end

    local x = tonumber(args.x); local y = tonumber(args.y)
    local w = tonumber(args.w); local h = tonumber(args.h)
    local z = tonumber(args.z) or 0

    if not x or not y or not w or not h then
        sendAdminAddResult(playerObj, false, "IGUI_BetterSafehouse_InvalidSafehouse")
        return
    end

    local sh = findSafehouseByBounds(x, y, w, h, z)
    if not sh then
        sendAdminAddResult(playerObj, false, "IGUI_BetterSafehouse_SafehouseNotFoundServer")
        return
    end

    local changeOwnership = args.changeOwnership == true

    local prevOwnerForBroadcast = nil
    -- Execute
    if changeOwnership and sh.setOwner and sh.getOwner then
        local okPrev, prevOwner = pcall(function() return sh:getOwner() end)
        if okPrev then prevOwnerForBroadcast = prevOwner end

        -- Before transferring: reset safehouse to vanilla size if old owner had user expansion
        if okPrev and prevOwner and prevOwner ~= "" and prevOwner ~= username then
            if BetterSafehouseExpansion_Server and BetterSafehouseExpansion_Server.resetForOwnerChange then
                pcall(function()
                    BetterSafehouseExpansion_Server.resetForOwnerChange(sh, prevOwner)
                end)
            end
        end

        pcall(function() sh:setOwner(username) end)

        -- Keep previous owner inside as member (matches vanilla behavior)
        if okPrev and prevOwner and prevOwner ~= "" and prevOwner ~= username and sh.addPlayer then
            pcall(function() sh:addPlayer(prevOwner) end)
        end
    end

    if sh.addPlayer then
        pcall(function() sh:addPlayer(username) end)
    end

    if sh.syncSafehouse then
        pcall(function() sh:syncSafehouse() end)
    end

    broadcastSafehouseMemberAdded(sh, username, prevOwnerForBroadcast, changeOwnership)
    sendAdminAddResult(playerObj, true, "IGUI_BetterSafehouse_AdminAdd_PlayerAdded")
end

local function handleAdminRelease(playerObj, args)
    if not playerObj or not args then return end

    if BetterSafehouse.getSandboxBool and (not BetterSafehouse.getSandboxBool("AdminsCanReleaseAnySafehouse", false)) then
        sendAdminReleaseResult(playerObj, false, "IGUI_BetterSafehouse_AdminRelease_DisabledInSandbox")
        return
    end

    if not isAdmin(playerObj) then
        sendAdminReleaseResult(playerObj, false, "IGUI_BetterSafehouse_NoPermission")
        return
    end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local w = tonumber(args.w)
    local h = tonumber(args.h)
    local z = tonumber(args.z) or 0

    if not x or not y or not w or not h then
        sendAdminReleaseResult(playerObj, false, "IGUI_BetterSafehouse_InvalidSafehouse")
        return
    end

    local sh = findSafehouseByBounds(x, y, w, h, z)
    if not sh then
        sendAdminReleaseResult(playerObj, false, "IGUI_BetterSafehouse_SafehouseNotFoundServer")
        return
    end

    local releasePayload = {
        x = sh:getX(),
        y = sh:getY(),
        w = sh:getW(),
        h = sh:getH(),
        z = z,
    }

    local okRemove = false
    if SafeHouse and SafeHouse.removeSafeHouse then
        okRemove = pcall(function() SafeHouse.removeSafeHouse(sh) end)
    elseif sh.removeSafeHouse then
        okRemove = pcall(function() sh.removeSafeHouse(sh) end)
    end

    if not okRemove then
        sendAdminReleaseResult(playerObj, false, "IGUI_BetterSafehouse_AdminRelease_Failed")
        return
    end

    broadcastSafehouseReleased(releasePayload)

    local username = "unknown"
    if playerObj.getUsername then
        local okUser, name = pcall(function() return playerObj:getUsername() end)
        if okUser and name then username = tostring(name) end
    end

    print(string.format("[BetterSafehouse] AdminReleaseSafehouse by %s at %d,%d,%d,%d",
        username, x, y, w, h))

    sendAdminReleaseResult(playerObj, true, "IGUI_BetterSafehouse_AdminRelease_Released")
end

-- =========================================================
-- Custom safehouse invites (MP): allows inviting players who already own/belong to another safehouse.
-- Vanilla B42 server blocks the standard SafehouseInvitePacket in this case.
-- =========================================================

local PendingInvites = PendingInvites or {}  -- targetUsername -> { [requestId] = inviteData }
local LastInviteMs = LastInviteMs or {}      -- inviter>target -> ms

local function nowMs()
    if getTimestampMs then
        local ok, v = pcall(function() return getTimestampMs() end)
        if ok and type(v) == "number" then return v end
    end
    return os.time() * 1000
end

local function findOnlinePlayerByUsername(username)
    username = tostring(username or "")
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

local function sendInviteResult(playerObj, ok, key, args, fallbackMsg)
    if not playerObj then return end
    local payload = { ok = ok == true, key = key, args = args }
    if fallbackMsg then payload.msg = fallbackMsg end
    sendServerCommand(playerObj, "BetterSafehouse", "InviteResult", payload)
end

local INVITE_TTL_MS = 120000
local INVITE_COOLDOWN_MS = 1500

local function cleanupExpiredInvitesFor(username)
    local t = PendingInvites[username]
    if not t then return end
    local now = nowMs()
    for rid, inv in pairs(t) do
        if not inv or (now - (inv.t or 0)) > INVITE_TTL_MS then
            t[rid] = nil
        end
    end
end

local function playerIsSafehouseOwnerOrAdmin(playerObj, sh)
    if not playerObj or not sh then return false end
    if isAdmin(playerObj) then return true end
    if sh.getOwner and playerObj.getUsername then
        local okO, owner = pcall(function() return sh:getOwner() end)
        if okO and owner and tostring(owner) == tostring(playerObj:getUsername()) then
            return true
        end
    end
    return false
end

local function handleRequestInvite(playerObj, args)
    if not playerObj or not args then return end

    -- sandbox gate: only active when EnhancedInvites is enabled (as requested).
    if BetterSafehouse.getSandboxBool and (not BetterSafehouse.getSandboxBool("EnhancedInvites", true)) then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_DisabledInSandbox")
        return
    end

    local target = tostring(args.target or "")
    target = target:gsub("^%s+", ""):gsub("%s+$", "")
    if #target > 64 then target = target:sub(1, 64) end
    if target == "" then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_InvalidPlayer")
        return
    end

    local requestId = tostring(args.requestId or "")
    if requestId == "" then
        requestId = tostring(nowMs()) .. "_" .. tostring((ZombRand and ZombRand(1000000)) or math.random(1000000))
    end

    local x = tonumber(args.x); local y = tonumber(args.y)
    local w = tonumber(args.w); local h = tonumber(args.h)
    local z = tonumber(args.z) or 0
    if not x or not y or not w or not h then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_InvalidSafehouse")
        return
    end

    local sh = findSafehouseByBounds(x, y, w, h, z)
    if not sh then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_SafehouseNotFoundServer")
        return
    end

    if not playerIsSafehouseOwnerOrAdmin(playerObj, sh) then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_NoPermission")
        return
    end

    local targetPlayer = findOnlinePlayerByUsername(target)
    if not targetPlayer then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_PlayerNotOnline")
        return
    end

    -- anti-spam
    local inviter = playerObj:getUsername()
    local key = tostring(inviter) .. ">" .. tostring(target)
    local now = nowMs()
    if LastInviteMs[key] and (now - LastInviteMs[key]) < INVITE_COOLDOWN_MS then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_Cooldown")
        return
    end
    LastInviteMs[key] = now

    -- don't invite if already in THIS safehouse
    if BetterSafehouse.safehouseHasUser and BetterSafehouse.safehouseHasUser(sh, target) then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_AlreadyMember")
        return
    end

    -- membership limit pre-check (server authoritative)
    if BetterSafehouse.canJoinAnotherSafehouse and (not BetterSafehouse.canJoinAnotherSafehouse(target)) then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_TargetMaxJoined")
        return
    end

    PendingInvites[target] = PendingInvites[target] or {}
    cleanupExpiredInvitesFor(target)
    PendingInvites[target][requestId] = {
        t = now,
        inviter = inviter,
        x = x, y = y, w = w, h = h, z = z,
    }

    local title = nil
    if sh.getTitle then
        local okT, tt = pcall(function() return sh:getTitle() end)
        if okT and tt and tt ~= "" then title = tostring(tt) end
    end

    sendServerCommand(targetPlayer, "BetterSafehouse", "InviteReceived", {
        requestId = requestId,
        from = tostring(inviter),
        title = title,
        x = x, y = y, w = w, h = h, z = z,
    })

    sendInviteResult(playerObj, true, "IGUI_BetterSafehouse_Invite_Sent")
end

local function handleAcceptInvite(playerObj, args)
    if not playerObj or not args then return end
    local username = tostring(playerObj:getUsername() or "")
    local requestId = tostring(args.requestId or "")
    if requestId == "" then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_Invalid")
        return
    end

    cleanupExpiredInvitesFor(username)
    local invT = PendingInvites[username]
    local inv = invT and invT[requestId] or nil
    if not inv then
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_Invite_Expired")
        return
    end

    local sh = findSafehouseByBounds(inv.x, inv.y, inv.w, inv.h, inv.z or 0)
    if not sh then
        invT[requestId] = nil
        sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_SafehouseNotFound")
        return
    end

    -- membership limit (server authoritative)
    local maxJoined = BetterSafehouse.getMaxJoinedSafehouses and BetterSafehouse.getMaxJoinedSafehouses() or 0
    if maxJoined and maxJoined > 0 and BetterSafehouse.safehouseHasUser and BetterSafehouse.countSafehousesForUsername then
        if not BetterSafehouse.safehouseHasUser(sh, username) then
            local curJoined = BetterSafehouse.countSafehousesForUsername(username) or 0
            if curJoined >= maxJoined then
                invT[requestId] = nil
                sendInviteResult(playerObj, false, "IGUI_BetterSafehouse_MaxJoinedReached", { tostring(curJoined), tostring(maxJoined) })
                return
            end
        end
    end

    if sh.addPlayer then
        pcall(function() sh:addPlayer(username) end)
    end
    if sh.syncSafehouse then
        pcall(function() sh:syncSafehouse() end)
    end

    broadcastSafehouseMemberAdded(sh, username, nil, false)
    sendInviteResult(playerObj, true, "IGUI_BetterSafehouse_Invite_JoinedSafehouse")

    local inviterPlayer = inv.inviter and findOnlinePlayerByUsername(inv.inviter) or nil
    if inviterPlayer then
        sendInviteResult(inviterPlayer, true, "IGUI_BetterSafehouse_Invite_AcceptedBy", { tostring(username) })
    end

    invT[requestId] = nil
end

local function handleDeclineInvite(playerObj, args)
    if not playerObj or not args then return end
    local username = tostring(playerObj:getUsername() or "")
    local requestId = tostring(args.requestId or "")

    cleanupExpiredInvitesFor(username)
    local invT = PendingInvites[username]
    local inv = invT and requestId ~= "" and invT[requestId] or nil
    if invT and requestId ~= "" then invT[requestId] = nil end

    sendInviteResult(playerObj, true, "IGUI_BetterSafehouse_Invite_Declined")

    local inviterPlayer = inv and inv.inviter and findOnlinePlayerByUsername(inv.inviter) or nil
    if inviterPlayer then
        sendInviteResult(inviterPlayer, true, "IGUI_BetterSafehouse_Invite_DeclinedBy", { tostring(username) })
    end
end

local function safehouseRespawnEnabled(sh, username)
    if not sh or not sh.isRespawnInSafehouse then return false end
    local ok, enabled = pcall(function() return sh:isRespawnInSafehouse(username) end)
    return ok and enabled == true
end

local function getSafehouseZ(sh)
    if not sh or not sh.getZ then return 0 end
    local ok, z = pcall(function() return sh:getZ() end)
    return ok and tonumber(z) or 0
end

local function getSafehouseRespawnPoint(sh)
    if not sh or not sh.getX or not sh.getY or not sh.getW or not sh.getH then return nil end
    local ok, x, y, w, h = pcall(function()
        return sh:getX(), sh:getY(), sh:getW(), sh:getH()
    end)
    if not ok or not x or not y or not w or not h then return nil end

    return {
        x = math.floor(tonumber(x) + (tonumber(w) / 2)),
        y = math.floor(tonumber(y) + (tonumber(h) / 2)),
        z = getSafehouseZ(sh),
    }
end

local function userCanRespawnInSafehouse(sh, username)
    if not sh or not username or username == "" then return false end
    return BetterSafehouse.safehouseHasUser and BetterSafehouse.safehouseHasUser(sh, username) == true
end

local function findVanillaRespawnSafehouse(username)
    local list = getSafehouseList()
    for _, sh in eachSafehouse(list) do
        if sh and safehouseRespawnEnabled(sh, username) and userCanRespawnInSafehouse(sh, username) then
            return sh
        end
    end
    return nil
end

local function findPrimaryRespawnSafehouse(username, data)
    if type(data) ~= "table" then return nil end

    local safeX = tonumber(data.safeX)
    local safeY = tonumber(data.safeY)
    local safeW = tonumber(data.safeW)
    local safeH = tonumber(data.safeH)
    local safeZ = tonumber(data.safeZ) or 0
    if safeX and safeY and safeW and safeH then
        local exact = findSafehouseByBounds(safeX, safeY, safeW, safeH, safeZ)
        if exact and userCanRespawnInSafehouse(exact, username) then
            return exact
        end
    end

    local px = tonumber(data.x)
    local py = tonumber(data.y)
    if not px or not py then return nil end

    local list = getSafehouseList()
    for _, sh in eachSafehouse(list) do
        if sh and userCanRespawnInSafehouse(sh, username) then
            local ok, x, y, w, h = pcall(function()
                return sh:getX(), sh:getY(), sh:getW(), sh:getH()
            end)
            if ok and x and y and w and h and px >= x and px < (x + w) and py >= y and py < (y + h) then
                return sh
            end
        end
    end

    return nil
end

local function setPrimaryRespawnRecord(username, sh, enabled)
    local data = getPrimaryRespawnData()
    if enabled ~= true then
        data[username] = nil
        savePrimaryRespawnData()
        return true
    end

    local point = getSafehouseRespawnPoint(sh)
    if not point then return false end

    data[username] = {
        enabled = true,
        pending = false,
        x = point.x,
        y = point.y,
        z = point.z,
        safeX = sh:getX(),
        safeY = sh:getY(),
        safeW = sh:getW(),
        safeH = sh:getH(),
        safeZ = getSafehouseZ(sh),
    }
    savePrimaryRespawnData()
    return true
end

local function setSafehouseRespawn(sh, username, enabled)
    if not sh or not sh.setRespawnInSafehouse then return false end
    local ok = pcall(function() sh:setRespawnInSafehouse(enabled == true, username) end)
    if not ok then return false end
    if sh.syncSafehouse then
        pcall(function() sh:syncSafehouse() end)
    end
    return true
end

local function serverAllowsSafehouseRespawn()
    if not getServerOptions then return true end
    local opts = getServerOptions()
    if not opts or not opts.getBoolean then return true end
    local ok, enabled = pcall(function() return opts:getBoolean("SafehouseAllowRespawn") end)
    if not ok then return true end
    return enabled == true
end

local function handleSetPrimaryRespawnSafehouse(playerObj, args)
    if not playerObj or not args then return end

    if BetterSafehouse.isSingleRespawnSafehouseEnabled and not BetterSafehouse.isSingleRespawnSafehouseEnabled() then
        sendPrimaryRespawnResult(playerObj, false, "IGUI_BetterSafehouse_PrimaryRespawn_DisabledInSandbox")
        return
    end

    if not serverAllowsSafehouseRespawn() then
        sendPrimaryRespawnResult(playerObj, false, "IGUI_BetterSafehouse_PrimaryRespawn_RespawnDisabled")
        return
    end

    local username = playerObj.getUsername and tostring(playerObj:getUsername() or "") or ""
    if username == "" then
        sendPrimaryRespawnResult(playerObj, false, "IGUI_BetterSafehouse_InvalidPlayer")
        return
    end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local w = tonumber(args.w)
    local h = tonumber(args.h)
    local z = tonumber(args.z) or 0
    local enabled = args.enabled == true

    if not x or not y or not w or not h then
        sendPrimaryRespawnResult(playerObj, false, "IGUI_BetterSafehouse_InvalidSafehouse")
        return
    end

    local target = findSafehouseByBounds(x, y, w, h, z)
    if not target then
        sendPrimaryRespawnResult(playerObj, false, "IGUI_BetterSafehouse_SafehouseNotFoundServer")
        return
    end

    if not userCanRespawnInSafehouse(target, username) then
        sendPrimaryRespawnResult(playerObj, false, "IGUI_BetterSafehouse_PrimaryRespawn_NotMember")
        return
    end

    local changed = 0
    local list = getSafehouseList()
    for _, sh in eachSafehouse(list) do
        if sh then
            local isTarget = BetterSafehouse.sameSafehouse and BetterSafehouse.sameSafehouse(sh, target) or sh == target
            if isTarget then
                if safehouseRespawnEnabled(sh, username) ~= enabled then
                    if setSafehouseRespawn(sh, username, enabled) then
                        changed = changed + 1
                    end
                end
            elseif enabled and safehouseRespawnEnabled(sh, username) then
                if setSafehouseRespawn(sh, username, false) then
                    changed = changed + 1
                end
            end
        end
    end

    local payload = {
        username = username,
        x = target:getX(),
        y = target:getY(),
        w = target:getW(),
        h = target:getH(),
        z = z,
        enabled = enabled,
        changed = changed,
    }

    broadcastPrimaryRespawnChanged(payload)
    setPrimaryRespawnRecord(username, target, enabled)

    if enabled then
        sendPrimaryRespawnResult(playerObj, true, "IGUI_BetterSafehouse_PrimaryRespawn_Set")
    else
        sendPrimaryRespawnResult(playerObj, true, "IGUI_BetterSafehouse_PrimaryRespawn_Cleared")
    end
end

local function handleFlagPrimaryRespawnDeath(playerObj, args)
    if not playerObj or not playerObj.getUsername then return end
    if BetterSafehouse.isSingleRespawnSafehouseEnabled and not BetterSafehouse.isSingleRespawnSafehouseEnabled() then return end
    if not serverAllowsSafehouseRespawn() then return end

    local username = tostring(playerObj:getUsername() or "")
    if username == "" then return end

    local data = getPrimaryRespawnData()
    local record = data[username]
    if type(record) ~= "table" or record.enabled ~= true then
        local sh = findVanillaRespawnSafehouse(username)
        if not sh or not setPrimaryRespawnRecord(username, sh, true) then return end
        record = data[username]
    end

    local sh = findPrimaryRespawnSafehouse(username, record)
    if not sh then
        data[username] = nil
        savePrimaryRespawnData()
        return
    end

    record.pending = true
    data[username] = record
    savePrimaryRespawnData()
end

local function handleCheckPrimaryRespawn(playerObj, args)
    if not playerObj or not playerObj.getUsername then return end

    local username = tostring(playerObj:getUsername() or "")
    if username == "" then return end

    local data = getPrimaryRespawnData()
    local record = data[username]
    if type(record) ~= "table" or record.enabled ~= true or record.pending ~= true then return end

    if BetterSafehouse.isSingleRespawnSafehouseEnabled and not BetterSafehouse.isSingleRespawnSafehouseEnabled() then
        record.pending = false
        data[username] = record
        savePrimaryRespawnData()
        return
    end

    if not serverAllowsSafehouseRespawn() then
        record.pending = false
        data[username] = record
        savePrimaryRespawnData()
        return
    end

    local sh = findPrimaryRespawnSafehouse(username, record)
    if not sh then
        data[username] = nil
        savePrimaryRespawnData()
        return
    end

    local point = getSafehouseRespawnPoint(sh)
    if not point then
        record.pending = false
        data[username] = record
        savePrimaryRespawnData()
        return
    end

    record.pending = false
    record.x = point.x
    record.y = point.y
    record.z = point.z
    record.safeX = sh:getX()
    record.safeY = sh:getY()
    record.safeW = sh:getW()
    record.safeH = sh:getH()
    record.safeZ = getSafehouseZ(sh)
    data[username] = record
    savePrimaryRespawnData()

    sendServerCommand(playerObj, "BetterSafehouse", "DoPrimaryRespawn", point)
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= "BetterSafehouse" then return end
    if command == "AdminAddToSafehouse" then return handleAdminAdd(playerObj, args) end
    if command == "AdminReleaseSafehouse" then return handleAdminRelease(playerObj, args) end
    if command == "RequestInvite" then return handleRequestInvite(playerObj, args) end
    if command == "AcceptInvite" then return handleAcceptInvite(playerObj, args) end
    if command == "DeclineInvite" then return handleDeclineInvite(playerObj, args) end
    if command == "SetPrimaryRespawnSafehouse" then return handleSetPrimaryRespawnSafehouse(playerObj, args) end
    if command == "FlagPrimaryRespawnDeath" then return handleFlagPrimaryRespawnDeath(playerObj, args) end
    if command == "CheckPrimaryRespawn" then return handleCheckPrimaryRespawn(playerObj, args) end
end
Events.OnClientCommand.Add(onClientCommand)


-- =================================================================
-- VANILLA SAFEHOUSE CLAIM RESTRICTIONS — SERVIDOR
-- Validação server-side: remove safehouse se exceder limite
-- E: cooldown de reivindicação (VanillaSafehouseClaimCooldownMinutes, minutos)
-- =================================================================

local function BS_getAreaLimitServer()
    if SandboxVars and SandboxVars.BetterSafehouse then
        local v = SandboxVars.BetterSafehouse.VanillaSafehouseAreaLimit
        if type(v) == "number" then return math.floor(v) end
    end
    return 0
end

local function BS_isVanillaEnabledServer()
    if SandboxVars and SandboxVars.BetterSafehouse then
        local v = SandboxVars.BetterSafehouse.VanillaSafehouseEnabled
        if v == false then return false end
    end
    return true
end

-- =================================================================
-- SISTEMA DE VALIDAÇÃO PÓS-CRIAÇÃO REMOVIDO
-- =================================================================
-- MOTIVO: A validação já acontece ANTES no CustomClaim_Server.lua
-- Se a safehouse foi criada, é porque já passou por todas as validações.
-- Não faz sentido remover uma safehouse DEPOIS de criada.
--
-- HISTÓRICO:
-- - Antes: sistema polling verificava safehouses criadas e removia se > limite
-- - Problema: causava frustração (safehouse aprovada depois removida)
-- - Solução: validação prévia com margem 40% + remoção deste código
-- =================================================================

-- =================================================================
-- COOLDOWN: Sistema server-side (autoritative)
-- Hook no SafeHouse creation (pós-criação)
-- =================================================================

local function BS_getCooldownMinutes()
    if SandboxVars and SandboxVars.BetterSafehouse then
        local v = SandboxVars.BetterSafehouse.VanillaSafehouseClaimCooldownMinutes
        if type(v) == "number" then return math.floor(v) end
        local legacy = SandboxVars.BetterSafehouse.VanillaSafehouseClaimCooldown
        if type(legacy) == "number" then return math.floor(legacy * 60) end
    end
    return 0
end

local function BS_handleSafehouseClaimed(sh)
    if not sh then return end
    
    local cooldownMinutes = BS_getCooldownMinutes()
    if cooldownMinutes <= 0 then return end
    
    local owner = sh:getOwner()
    if not owner or owner == "" then return end
    
    -- Buscar jogador online
    local playerObj = nil
    if getOnlinePlayers then
        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername() == owner then
                playerObj = p
                break
            end
        end
    end
    
    if not playerObj then return end
    
    -- Registrar timestamp: envia direto ao cliente via comando, sem tocar no ModData
    -- (transmitModData() foi removido — sobrescrevia ModData de outros mods)
    local nowMs = getTimeInMillis and getTimeInMillis() or 0
    sendServerCommand(playerObj, "BetterSafehouse", "CooldownSync", { ts = nowMs })
    
    print(string.format("[BetterSafehouse] Cooldown registrado para %s: %d minutos", 
        owner, cooldownMinutes))
end

-- Hook: OnSafehouseCreate ou polling fallback
if Events.OnSafehouseCreate then
    Events.OnSafehouseCreate.Add(BS_handleSafehouseClaimed)
    print("[BetterSafehouse] Cooldown: OnSafehouseCreate registrado")
else
    -- Fallback: polling para detectar novas safehouses
    local BS_knownSafehouses_Cooldown = {}
    local BS_lastCheckTime = 0
    local BS_CHECK_INTERVAL = 5  -- Verificar a cada 5 segundos
    
    local function BS_getSafehouseId_Cooldown(sh)
        if not sh then return nil end
        local ok, x, y, w, h = pcall(function()
            return sh:getX(), sh:getY(), sh:getW(), sh:getH()
        end)
        if not ok then return nil end
        return string.format("%d,%d,%d,%d", x, y, w, h)
    end
    
    local function BS_initKnownSafehouses_Cooldown()
        if not SafeHouse then return end
        local ok, list = pcall(function() return SafeHouse.getSafehouseList() end)
        if not ok or not list then return end
        local n = list.size and list:size() or #list
        for i = 0, n - 1 do
            local sh = list.get and list:get(i) or list[i + 1]
            if sh then
                local id = BS_getSafehouseId_Cooldown(sh)
                if id then
                    BS_knownSafehouses_Cooldown[id] = true
                end
            end
        end
        print("[BetterSafehouse] Cooldown: " .. tostring(n) .. " safehouses existentes indexadas")
    end
    
    local function BS_checkNewSafehouses_Cooldown()
        -- Throttle: só verifica a cada X segundos
        local now = os.time()
        if (now - BS_lastCheckTime) < BS_CHECK_INTERVAL then
            return
        end
        BS_lastCheckTime = now
        
        if not SafeHouse then return end
        local ok, list = pcall(function() return SafeHouse.getSafehouseList() end)
        if not ok or not list then return end
        
        local n = list.size and list:size() or #list
        for i = 0, n - 1 do
            local sh = list.get and list:get(i) or list[i + 1]
            if sh then
                local id = BS_getSafehouseId_Cooldown(sh)
                if id and not BS_knownSafehouses_Cooldown[id] then
                    BS_knownSafehouses_Cooldown[id] = true
                    BS_handleSafehouseClaimed(sh)
                end
            end
        end
    end
    
    Events.OnServerStarted.Add(BS_initKnownSafehouses_Cooldown)
    -- Usar OnTick com throttle ao invés de EveryOneMinute
    Events.OnTick.Add(BS_checkNewSafehouses_Cooldown)
    print("[BetterSafehouse] Cooldown: fallback polling registrado (check a cada " .. BS_CHECK_INTERVAL .. "s)")
end
