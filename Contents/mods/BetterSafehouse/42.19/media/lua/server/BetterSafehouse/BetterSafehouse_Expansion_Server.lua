if not isServer() then
    return
end

require "BetterSafehouse/BetterSafehouse_Expansion_Shared"

local RSE = BetterSafehouse.Expansion

BetterSafehouseExpansion_Server = BetterSafehouseExpansion_Server or {}

local Server = BetterSafehouseExpansion_Server

Server.state = Server.state or nil
Server.lastRequestMsByUser = Server.lastRequestMsByUser or {}

local function nowMs()
    if getTimestampMs then
        local ok, value = pcall(function()
            return getTimestampMs()
        end)
        if ok and type(value) == "number" then
            return value
        end
    end

    return os.time() * 1000
end

local function log(message)
    print("[BetterSafehouse][Expansion][S] " .. tostring(message))
end

local function getState()
    if type(Server.state) ~= "table" then
        Server.state = ModData.getOrCreate(RSE.MOD_DATA_KEY)
    end

    if type(Server.state) ~= "table" then
        Server.state = {}
    end

    Server.state.meta = Server.state.meta or {}
    Server.state.meta.version = 3
    Server.state.baseAreas = Server.state.baseAreas or {}
    Server.state.baseRects = Server.state.baseRects or {}
    Server.state.expandedSafehouseLocks = Server.state.expandedSafehouseLocks or {}
    Server.state.userExpansionClaims = Server.state.userExpansionClaims or {}
    return Server.state
end

local function persistState()
    getState()
    ModData.add(RSE.MOD_DATA_KEY, Server.state)
end

local function copyRectPayload(rect)
    if not rect then return nil end
    return {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
    }
end

local function rectFromPayload(payload)
    if type(payload) ~= "table" then
        return nil
    end

    local rect = RSE.makeRect(payload.x, payload.y, payload.w, payload.h)
    if RSE.rectIsValid(rect) then
        return rect
    end

    return nil
end

-- Every other player/safehouse accessor in this file (getSafehouseOnlineId,
-- isWarBlocked, mutateSafehouseInPlace) wraps its native call in pcall since
-- a mid-teleport/mid-disconnect object can throw; an uncaught error here
-- would abort handleResize after isRateLimited already stamped the request,
-- leaving the client's pendingRequest stuck true with no reply ever sent.
local function safePlayerTilePos(playerObj)
    local okX, x = pcall(function() return playerObj:getX() end)
    local okY, y = pcall(function() return playerObj:getY() end)
    return math.floor(tonumber(okX and x or nil) or 0), math.floor(tonumber(okY and y or nil) or 0)
end

local function getSafehouseOwnerUsername(safehouse)
    if not safehouse or not safehouse.getOwner then return nil end
    local ok, owner = pcall(function() return safehouse:getOwner() end)
    if ok and owner and tostring(owner) ~= "" then
        return tostring(owner)
    end
    return nil
end

local function getSafehouseOnlineId(safehouse, rect)
    if safehouse and safehouse.getOnlineID then
        local ok, value = pcall(function()
            return safehouse:getOnlineID()
        end)
        if ok and type(value) == "number" then
            return value
        end
    end

    if rect and SafeHouse and SafeHouse.getOnlineID then
        local ok, value = pcall(function()
            return SafeHouse.getOnlineID(rect.x, rect.y)
        end)
        if ok and type(value) == "number" then
            return value
        end
    end

    return nil
end

local function sendResult(playerObj, ok, key, args, fallbackMsg)
    if not playerObj then return end

    local payload = {
        ok = ok == true,
        key = key,
        args = args,
        msg = fallbackMsg,
    }

    sendServerCommand(playerObj, RSE.NET_MODULE, "ExpansionResult", payload)
end

local function forEachOnlinePlayer(callback)
    if not callback then return end

    local players = getOnlinePlayers()
    if not players then return end

    if type(players) == "table" then
        for _, playerObj in ipairs(players) do
            if playerObj then
                callback(playerObj)
            end
        end
        return
    end

    if players.size and players.get then
        for index = 0, players:size() - 1 do
            local playerObj = players:get(index)
            if playerObj then
                callback(playerObj)
            end
        end
    end
end

local function broadcastSafehouseResized(payload)
    forEachOnlinePlayer(function(playerObj)
        sendServerCommand(playerObj, RSE.NET_MODULE, "ExpansionSafehouseResized", payload)
    end)
end

local function pruneState()
    local state = getState()
    local active = {}
    local activeOnlineIds = {}
    local list = RSE.getSafehouseList()

    for _, sh in RSE.eachSafehouse(list) do
        local rect = RSE.rectFromSafehouse(sh)
        if rect then
            active[RSE.makeSafehouseKey(rect)] = true
            local onlineId = getSafehouseOnlineId(sh, rect)
            if type(onlineId) == "number" then
                activeOnlineIds[onlineId] = true
            end
        end
    end

    if type(state.counts) == "table" then
        for key, _ in pairs(state.counts) do
            if not active[key] then
                state.counts[key] = nil
            end
        end
    end

    for key, _ in pairs(state.baseAreas) do
        if not active[key] then
            state.baseAreas[key] = nil
        end
    end

    for key, _ in pairs(state.baseRects) do
        if not active[key] then
            state.baseRects[key] = nil
        end
    end

    -- Per-user claims are pruned separately, only after the safehouse list has
    -- loaded. A deleted safehouse must not keep blocking a new one.
end

-- Decides whether a stored claim/lock still belongs to a real, currently
-- existing safehouse (checked by exact position: key or rect), so the
-- one-time "user" expansion bonus can be reused once its old safehouse is
-- truly gone. Deliberately does NOT match by onlineID alone anymore — see
-- the comment above pruneStaleUserExpansionState() for why that used to
-- cause the exact bug this function exists to prevent.
local function safehouseReferenceIsActive(ref)
    if type(ref) ~= "table" then
        return false
    end

    local refKey = tostring(ref.key or "")
    local refRect = rectFromPayload(ref.rect)
    local list = RSE.getSafehouseList()
    if not list then
        return true
    end

    for _, safehouse in RSE.eachSafehouse(list) do
        local rect = RSE.rectFromSafehouse(safehouse)
        if rect then
            if refKey ~= "" and refKey == RSE.makeSafehouseKey(rect) then
                return true
            end

            if refRect and RSE.safehouseMatchesRect(safehouse, refRect) then
                return true
            end
        end
    end

    return false
end

-- Frees up a player's one-time "user" expansion the moment its safehouse no
-- longer exists (removed via the game's own "Abandonar Base" button, expired,
-- deleted by an admin, etc.) — that button is vanilla, not this mod's, so
-- there is no event to react to; this is checked opportunistically instead
-- (see pruneStateThrottled, called from getBaseRect on every window-open and
-- every resize).
--
-- BUG THIS USED TO HAVE: safehouseReferenceIsActive() used to also treat a
-- claim as "still active" if some live safehouse merely shared its stored
-- onlineID. onlineID is a MAP-REGION id (same for every safehouse built in
-- that area), not a per-safehouse id — so after abandoning an expanded
-- safehouse and claiming a brand new one in the same neighborhood, the new
-- safehouse's onlineID matched the deleted one's stored onlineID, the old
-- claim was wrongly kept "active" forever, and the player got permanently
-- stuck seeing "you already used your one-time expansion" even with zero
-- safehouses left. Fixed by only matching on exact position (key or rect).
local function pruneStaleUserExpansionState()
    local state = getState()
    local changed = false

    if not RSE.getSafehouseList() then
        return false
    end

    for username, claim in pairs(state.userExpansionClaims) do
        if type(claim) ~= "table"
            or claim.legacyUserSafehouse == true
            or not safehouseReferenceIsActive(claim)
        then
            state.userExpansionClaims[username] = nil
            changed = true
        end
    end

    for username, lock in pairs(state.expandedSafehouseLocks) do
        if type(lock) ~= "table" or not safehouseReferenceIsActive(lock) then
            state.expandedSafehouseLocks[username] = nil
            changed = true
        end
    end

    if changed then
        persistState()
    end

    return changed
end

-- pruneState()/pruneStaleUserExpansionState() are both full scans of the
-- live safehouse list (the second one O(claims x safehouses)); getBaseRect
-- is called on every window-open, every apply, and every admin reset, so
-- re-running both every single time is wasted work on servers with many
-- safehouses/claims. Neither prune affects the specific key getBaseRect is
-- about to look up (that lookup runs unconditionally right after), so it's
-- safe to only re-run this background hygiene pass periodically.
local lastPruneRunMs = 0
local PRUNE_THROTTLE_MS = 5000

local function pruneStateThrottled()
    local now = nowMs()
    if now - lastPruneRunMs < PRUNE_THROTTLE_MS then
        return
    end
    lastPruneRunMs = now
    pruneState()
    pruneStaleUserExpansionState()
end

local function getBaseRect(rect)
    pruneStateThrottled()
    local state = getState()
    local key = RSE.makeSafehouseKey(rect)
    local baseRect = rectFromPayload(state.baseRects[key])
    if not baseRect then
        baseRect = RSE.copyRect(rect)
        state.baseRects[key] = copyRectPayload(baseRect)
        if math.floor(tonumber(state.baseAreas[key]) or 0) < 1 then
            state.baseAreas[key] = RSE.getSafehouseArea(baseRect)
        end
        persistState()
    end

    return baseRect
end

local function getBaseArea(rect)
    local state = getState()
    local key = RSE.makeSafehouseKey(rect)
    local baseArea = math.floor(tonumber(state.baseAreas[key]) or 0)
    if baseArea < 1 then
        baseArea = RSE.getSafehouseArea(getBaseRect(rect))
    end
    return baseArea
end

local function storeResizedState(oldRect, newRect)
    local state = getState()
    local oldKey = RSE.makeSafehouseKey(oldRect)
    local newKey = RSE.makeSafehouseKey(newRect)
    local baseArea = math.floor(tonumber(state.baseAreas[oldKey]) or 0)
    local baseRect = rectFromPayload(state.baseRects[oldKey])

    if baseArea < 1 then
        baseArea = RSE.getSafehouseArea(oldRect)
    end
    if not baseRect then
        baseRect = RSE.copyRect(oldRect)
    end

    if type(state.counts) == "table" then
        state.counts[oldKey] = nil
    end
    state.baseAreas[oldKey] = nil
    state.baseRects[oldKey] = nil
    state.baseAreas[newKey] = baseArea
    state.baseRects[newKey] = copyRectPayload(baseRect)
    persistState()

    return baseArea, baseRect
end

local function findSafehouseByOnlineId(onlineId)
    onlineId = tonumber(onlineId)
    if not onlineId then
        return nil
    end

    if SafeHouse and SafeHouse.getSafeHouse then
        local ok, safehouse = pcall(function()
            return SafeHouse.getSafeHouse(onlineId)
        end)
        if ok and safehouse then
            return safehouse
        end
    end

    local list = RSE.getSafehouseList()
    for _, safehouse in RSE.eachSafehouse(list) do
        if getSafehouseOnlineId(safehouse, RSE.rectFromSafehouse(safehouse)) == onlineId then
            return safehouse
        end
    end

    return nil
end

local function findSafehouseByLock(lock)
    if type(lock) ~= "table" then
        return nil
    end

    local byOnlineId = findSafehouseByOnlineId(lock.onlineID)
    if byOnlineId then
        return byOnlineId
    end

    local rect = rectFromPayload(lock.rect)
    if rect then
        return RSE.findSafehouseByRect(rect)
    end

    return nil
end

local function lockMatchesSafehouse(lock, safehouse, rect)
    if type(lock) ~= "table" or not safehouse then
        return false
    end

    local lockedSafehouse = findSafehouseByLock(lock)
    if lockedSafehouse and lockedSafehouse == safehouse then
        return true
    end

    local lockKey = tostring(lock.key or "")
    if lockKey ~= "" and rect and lockKey == RSE.makeSafehouseKey(rect) then
        return true
    end

    local lockOnlineId = tonumber(lock.onlineID)
    if lockOnlineId and lockOnlineId == getSafehouseOnlineId(safehouse, rect) then
        return true
    end

    return false
end

local function getActiveSafehouseLock(username)
    username = RSE.trimString(username)
    if username == "" then
        return nil
    end

    local state = getState()
    local lock = state.expandedSafehouseLocks[username]
    if type(lock) ~= "table" then
        return nil
    end

    local safehouse = findSafehouseByLock(lock)
    if safehouse then
        local okOwner, owner = pcall(function()
            if safehouse.getOwner then return safehouse:getOwner() end
            return nil
        end)
        if not okOwner or tostring(owner or "") ~= username then
            state.expandedSafehouseLocks[username] = nil
            persistState()
            return nil
        end

        return lock, safehouse
    end

    -- If the stored lock no longer resolves to a live safehouse, do not let an
    -- orphaned expansion record block role-based players from expanding a new one.
    state.expandedSafehouseLocks[username] = nil
    persistState()
    return nil
end

local function makeExpansionLock(username, safehouse, rect, flow)
    return {
        key = RSE.makeSafehouseKey(rect),
        rect = copyRectPayload(rect),
        onlineID = getSafehouseOnlineId(safehouse, rect),
        flow = flow,
        username = username,
        claimedAt = nowMs(),
    }
end

local function migrateLegacyUserSafehouses()
    local state = getState()
    local meta = state.meta or {}
    if math.floor(tonumber(meta.legacyUserSafehousesMigrationVersion) or 0) >= 1 then
        return
    end

    meta.legacyUserSafehousesMigrationVersion = 1
    meta.legacyUserSafehousesMigratedAt = nowMs()
    meta.legacyUserSafehousesMigratedCount = 0
    meta.legacyUserSafehousesMigrationSkipped = true
    state.meta = meta
    persistState()
    log("Legacy user safehouse migration skipped; existing safehouse owners remain eligible for user expansion.")
end

local function setSafehouseLock(username, safehouse, rect, flow)
    username = RSE.trimString(username)
    if username == "" or not RSE.rectIsValid(rect) then
        return
    end

    local state = getState()
    state.expandedSafehouseLocks[username] = makeExpansionLock(username, safehouse, rect, flow)
    persistState()
end

local function getUserExpansionClaim(username)
    username = RSE.trimString(username)
    if username == "" then return nil end

    pruneStaleUserExpansionState()

    local state = getState()
    local claim = state.userExpansionClaims[username]
    if type(claim) == "table" then
        if claim.legacyUserSafehouse == true or not safehouseReferenceIsActive(claim) then
            state.userExpansionClaims[username] = nil
            persistState()
            return nil
        end

        return claim
    end

    local legacyLock = state.expandedSafehouseLocks[username]
    if type(legacyLock) == "table" then
        if not safehouseReferenceIsActive(legacyLock) then
            state.expandedSafehouseLocks[username] = nil
            persistState()
            return nil
        end

        claim = {
            key = legacyLock.key,
            rect = legacyLock.rect,
            onlineID = legacyLock.onlineID,
            flow = legacyLock.flow or "legacy",
            migratedFromLock = true,
            claimedAt = legacyLock.claimedAt or nowMs(),
        }
        state.userExpansionClaims[username] = claim
        persistState()
        return claim
    end

    return nil
end

local function setUserExpansionClaim(username, safehouse, rect)
    username = RSE.trimString(username)
    if username == "" or not RSE.rectIsValid(rect) then return end

    local state = getState()
    state.userExpansionClaims[username] = makeExpansionLock(username, safehouse, rect, "user")
    persistState()
end

-- Moves every stored reference (key/rect/onlineID) that pointed at oldRect
-- onto newRect after a successful resize.
local function migrateSafehouseRefs(refs, oldKey, oldOnlineId, newRect, newOnlineId)
    local changed = false
    for _, ref in pairs(refs) do
        if type(ref) == "table" then
            local sameKey = tostring(ref.key or "") == oldKey
            local sameOnlineId = oldOnlineId and tonumber(ref.onlineID) == tonumber(oldOnlineId)
            if sameKey or sameOnlineId then
                ref.key = RSE.makeSafehouseKey(newRect)
                ref.rect = copyRectPayload(newRect)
                ref.onlineID = newOnlineId or ref.onlineID
                changed = true
            end
        end
    end
    return changed
end

local function updateLocksAfterResize(oldRect, newRect, oldOnlineId, newOnlineId)
    local state = getState()
    local oldKey = RSE.makeSafehouseKey(oldRect)

    -- Both tables are "reference to a live safehouse" records that must
    -- stay in sync with its current rect/onlineID. Previously only
    -- expandedSafehouseLocks was migrated here; a stale userExpansionClaims
    -- entry then failed safehouseReferenceIsActive's key/rect/onlineID
    -- match after any resize that changed the online ID, so
    -- pruneStaleUserExpansionState() deleted it as "orphaned" — silently
    -- resetting the one-time user-expansion flag.
    local changedLocks = migrateSafehouseRefs(state.expandedSafehouseLocks, oldKey, oldOnlineId, newRect, newOnlineId)
    local changedClaims = migrateSafehouseRefs(state.userExpansionClaims, oldKey, oldOnlineId, newRect, newOnlineId)

    if changedLocks or changedClaims then
        persistState()
    end
end

local function isRateLimited(playerObj)
    local username = RSE.getPlayerUsername(playerObj)
    if not username then
        return true
    end

    local now = nowMs()
    local last = Server.lastRequestMsByUser[username] or 0
    if (now - last) < 750 then
        return true
    end

    Server.lastRequestMsByUser[username] = now
    return false
end

local function getRectPayload(rect)
    if not rect then return nil end

    return {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
    }
end

local function sendExpansionLimitState(playerObj, safehouse, currentRect, roleName, resizeFlow)
    if not playerObj or not safehouse or not RSE.rectIsValid(currentRect) then return end

    local baseRect = getBaseRect(currentRect)
    local baseArea = getBaseArea(currentRect)
    local payload = getRectPayload(currentRect) or {}
    payload.flow = resizeFlow
    payload.roleName = roleName
    payload.baseArea = baseArea
    payload.baseX = baseRect and baseRect.x or nil
    payload.baseY = baseRect and baseRect.y or nil
    payload.baseW = baseRect and baseRect.w or nil
    payload.baseH = baseRect and baseRect.h or nil
    local isUserAdvanced = resizeFlow == "user" and RSE.isUserFlowUsingAdvancedMode()
    payload.maxExtraTiles = (resizeFlow == "role" and RSE.getEffectiveMaxExtraTilesForPlayer(playerObj))
        or (isUserAdvanced and RSE.getUserAdvancedMaxExtraTilesFromOriginal())
        or nil
    payload.maxTotalTiles = RSE.getMaxTotalTilesForFlow(resizeFlow, playerObj)
    payload.userMaxBorderTiles = (resizeFlow == "user" and not isUserAdvanced) and RSE.getUserMaxBorderTilesFromOriginal() or nil
    payload.userAlreadyExpanded = (resizeFlow == "user" and not isUserAdvanced) and getUserExpansionClaim(RSE.getPlayerUsername(playerObj)) ~= nil or nil

    sendServerCommand(playerObj, RSE.NET_MODULE, "ExpansionLimitState", payload)
end

local function handleLimitStateRequest(playerObj, args)
    if not playerObj or type(args) ~= "table" then return end

    local requestedRect = RSE.makeRect(args.x, args.y, args.w, args.h)
    if not RSE.rectIsValid(requestedRect) then return end

    local safehouse = RSE.findSafehouseByRect(requestedRect)
    if not safehouse or not RSE.canResizeSafehouse(playerObj, safehouse) then return end

    local roleName = RSE.getPlayerRoleName(playerObj)
    local resizeFlow = RSE.getPlayerResizeFlowForSafehouse(playerObj, safehouse)
    if not resizeFlow then return end

    sendExpansionLimitState(playerObj, safehouse, requestedRect, roleName, resizeFlow)
end

local function isRequesterNearSafehouse(playerObj, rect)
    if not playerObj or not rect then
        return false
    end

    local px, py = safePlayerTilePos(playerObj)

    return px >= (rect.x - 1)
        and px < (rect.x2 + 1)
        and py >= (rect.y - 1)
        and py < (rect.y2 + 1)
end

local function getSquareFloorSpriteName(square)
    if not square or not square.getFloor then
        return nil
    end

    local floor = square:getFloor()
    if not floor or not floor.getSprite then
        return nil
    end

    local sprite = floor:getSprite()
    if not sprite or not sprite.getName then
        return nil
    end

    return tostring(sprite:getName() or "")
end

-- Every vanilla road tile (across all 7 road tilesheets) carries a
-- "FloorMaterial" property valued "Road_01".."Road_07" (checked directly
-- against the game's own tile definitions, media/newtiledefinitions.tiles
-- .txt). Note this property does NOT distinguish real road from driveway/
-- garage pavement — both carry the same "Road_0X" values — see the comment
-- above isAsphaltRoadFloor() for why that's used anyway.
local function getSquareFloorMaterialType(square)
    if not square or not square.getFloor then
        return nil
    end

    local floor = square:getFloor()
    if not floor then
        return nil
    end

    local props = nil
    if floor.getProperties then
        props = floor:getProperties()
    end
    if not props and floor.getSprite and floor:getSprite() and floor:getSprite().getProperties then
        props = floor:getSprite():getProperties()
    end
    if not props or not props.get then
        return nil
    end

    local ok, value = pcall(function()
        return props:get("FloorMaterial")
    end)
    if ok and value and tostring(value) ~= "" then
        return tostring(value)
    end

    return nil
end

-- Deliberately broad, by server owner's choice: PZ reuses the exact same
-- "blends_street_01" asphalt/concrete tiles for both real public road
-- pavement AND private driveways/garage entrances (confirmed by hand —
-- indices 38/53 are driveway, 85/96 are real road — with no distinguishing
-- property between the two kinds; FloorMaterial is identically "Road_0X" on
-- both). Hand-curating an exact tile-name list to only match real road is
-- possible but impractically tedious (dozens of near-identical tiles to
-- check one at a time). Given that trade-off, this matches broadly instead
-- — FloorMaterial "Road_01".."Road_07" (every vanilla road tilesheet) plus
-- common name patterns for modded tiles that don't set FloorMaterial — and
-- knowingly also blocks driveways/garage pavement along with real road.
-- The whole feature stays opt-in behind the "Block roads" sandbox setting
-- (RSE.shouldBlockAsphaltRoads/ExpansionBlockRoadTiles) for exactly this
-- reason: the server owner decides whether that trade-off is worth it for
-- their map.
local function isAsphaltRoadFloor(square, blockedLookup)
    local materialType = RSE.lowerString(getSquareFloorMaterialType(square) or "")
    if materialType ~= "" and string.find(materialType, "^road_?%d*$") then
        return true
    end

    local spriteName = getSquareFloorSpriteName(square) or ""
    if spriteName == "" then
        return false
    end

    local normalized = RSE.lowerString(spriteName)
    if blockedLookup and blockedLookup[normalized] == true then
        return true
    end

    if string.find(normalized, "blends_street", 1, true) then return true end
    if string.sub(normalized, 1, 7) == "street_" then return true end
    if string.find(normalized, "asphalt", 1, true) then return true end
    if string.find(normalized, "trafficlines", 1, true) then return true end

    return false
end

local function isAddedAreaLoaded(oldRect, newRect)
    local cell = getCell and getCell() or nil
    if not cell then
        return false
    end

    local hasAddedTiles = false
    local loaded = true
    RSE.forEachAddedTile(oldRect, newRect, function(x, y)
        hasAddedTiles = true
        if cell:getGridSquare(x, y, 0) == nil then
            loaded = false
            return false
        end
        return true
    end)

    if not hasAddedTiles then
        return true
    end

    return loaded
end

local function findAddedAreaAsphaltTile(oldRect, newRect)
    local cell = getCell and getCell() or nil
    if not cell then
        return nil
    end

    local blockedLookup = RSE.getBlockedRoadTileLookup()
    local blocked = nil
    RSE.forEachAddedTile(oldRect, newRect, function(x, y)
        local square = cell:getGridSquare(x, y, 0)
        if square and isAsphaltRoadFloor(square, blockedLookup) then
            blocked = {
                x = x,
                y = y,
                spriteName = getSquareFloorSpriteName(square) or "",
            }
            return false
        end
        return true
    end)

    return blocked
end

local function findOverlappingSafehouse(newRect, ignoreSafehouse)
    local list = RSE.getSafehouseList()
    if not list then return nil end

    for _, sh in RSE.eachSafehouse(list) do
        if sh and sh ~= ignoreSafehouse then
            local rect = RSE.rectFromSafehouse(sh)
            if rect and RSE.rectsOverlap(newRect, rect) then
                return sh
            end
        end
    end

    return nil
end

local function isAuthorizedOccupant(playerObj, safehouse)
    if not playerObj or not safehouse then
        return false
    end

    local username = RSE.getPlayerUsername(playerObj)
    if username and RSE.safehouseHasUser(safehouse, username) then
        return true
    end

    return RSE.playerHasSafehouseBypass(playerObj)
end

local function findUnauthorizedPlayerInAddedArea(requester, safehouse, oldRect, newRect)
    local foundPlayer = nil

    forEachOnlinePlayer(function(playerObj)
        if foundPlayer or not playerObj or playerObj == requester then
            return
        end

        local px, py = safePlayerTilePos(playerObj)

        if RSE.rectContainsPoint(newRect, px, py)
            and (not RSE.rectContainsPoint(oldRect, px, py))
            and (not isAuthorizedOccupant(playerObj, safehouse))
        then
            foundPlayer = playerObj
        end
    end)

    return foundPlayer
end

local function isWarBlocked(safehouse, oldRect, newRect)
    if not safehouse or not WarManager or not SafeHouse or not SafeHouse.getOnlineID then
        return false
    end

    local oldOnlineId = nil
    if safehouse.getOnlineID then
        local okOld, value = pcall(function()
            return safehouse:getOnlineID()
        end)
        if okOld and type(value) == "number" then
            oldOnlineId = value
        end
    end

    if type(oldOnlineId) ~= "number" then
        oldOnlineId = SafeHouse.getOnlineID(oldRect.x, oldRect.y)
    end

    local newOnlineId = SafeHouse.getOnlineID(newRect.x, newRect.y)
    if oldOnlineId == newOnlineId then
        return false
    end

    if WarManager.isWarStarted then
        local okStarted, started = pcall(function()
            return WarManager.isWarStarted(oldOnlineId)
        end)
        if okStarted and started == true then
            return true
        end
    end

    return false
end

local function mutateSafehouseInPlace(safehouse, oldRect, newRect)
    if not safehouse then return false end
    if not safehouse.setX or not safehouse.setY or not safehouse.setW or not safehouse.setH then
        return false
    end

    local oldOnlineId = nil
    if safehouse.getOnlineID then
        local okOld, value = pcall(function()
            return safehouse:getOnlineID()
        end)
        if okOld and type(value) == "number" then
            oldOnlineId = value
        end
    end

    if type(oldOnlineId) ~= "number" and SafeHouse and SafeHouse.getOnlineID then
        oldOnlineId = SafeHouse.getOnlineID(oldRect.x, oldRect.y)
    end

    local newOnlineId = oldOnlineId
    if SafeHouse and SafeHouse.getOnlineID then
        newOnlineId = SafeHouse.getOnlineID(newRect.x, newRect.y)
    end

    local okMutation = pcall(function()
        safehouse:setX(newRect.x)
        safehouse:setY(newRect.y)
        safehouse:setW(newRect.w)
        safehouse:setH(newRect.h)

        if safehouse.setOnlineID and type(newOnlineId) == "number" then
            safehouse:setOnlineID(newOnlineId)
        end
    end)

    if not okMutation then
        pcall(function()
            safehouse:setX(oldRect.x)
            safehouse:setY(oldRect.y)
            safehouse:setW(oldRect.w)
            safehouse:setH(oldRect.h)
            if safehouse.setOnlineID and type(oldOnlineId) == "number" then
                safehouse:setOnlineID(oldOnlineId)
            end
        end)
        return false
    end

    if SafeHouse and SafeHouse.updateSafehousePlayersConnected then
        pcall(function()
            SafeHouse.updateSafehousePlayersConnected()
        end)
    end

    return true, newOnlineId, oldOnlineId
end

local function getSuccessKey(mode)
    if RSE.isShrinkMode(mode) then
        return "IGUI_BetterSafehouse_Expansion_Resize_SuccessShrunk"
    end

    return "IGUI_BetterSafehouse_Expansion_Resize_SuccessExpanded"
end

local function handleResize(playerObj, args)
    if not RSE.isEnabled() then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_DisabledBySandbox")
        return
    end

    if not playerObj then
        return
    end

    if isRateLimited(playerObj) then
        return
    end

    args = args or {}

    local requestedRect = RSE.makeRect(args.x, args.y, args.w, args.h)
    local mode = RSE.normalizeResizeMode(args.mode)

    if not RSE.rectIsValid(requestedRect) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse")
        return
    end

    if not mode then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_InvalidMode")
        return
    end

    local safehouse = RSE.findSafehouseByRect(requestedRect)
    if not safehouse then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse")
        return
    end

    if not RSE.canResizeSafehouse(playerObj, safehouse) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_NotOwner")
        return
    end

    local roleName = RSE.getPlayerRoleName(playerObj)
    if (not roleName or roleName == "") and not RSE.isStrictAdmin(playerObj) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_MissingRole")
        return
    end

    local resizeFlow = RSE.getPlayerResizeFlowForSafehouse(playerObj, safehouse)
    if not resizeFlow then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_RoleDenied")
        return
    end

    local isMultiSideFlow = resizeFlow == "role" or (resizeFlow == "user" and RSE.isUserFlowUsingAdvancedMode())

    if resizeFlow == "user" and not isMultiSideFlow then
        if RSE.getUserMaxBorderTilesFromOriginal() < 1 then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_UserBorder_NoActionsConfigured")
            return
        end

        if mode ~= "expand" then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_UserBorder_ShrinkDenied")
            return
        end
    end

    local oldRect = RSE.rectFromSafehouse(safehouse)
    if not oldRect then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse")
        return
    end

    if not isRequesterNearSafehouse(playerObj, oldRect) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_TooFar")
        return
    end

    local action, totalStep, newRect, logDetail

    if isMultiSideFlow then
        -- Each side now carries its own independent amount instead of one
        -- shared amount applied to whichever sides were toggled. 0 means
        -- "not moved" on that side; each active side is still clamped
        -- independently to MAX_RESIZE_STEPS.
        local maxAmount = math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200))
        local amounts = {
            N = math.floor(tonumber(args.amountN) or 0),
            S = math.floor(tonumber(args.amountS) or 0),
            E = math.floor(tonumber(args.amountE) or 0),
            W = math.floor(tonumber(args.amountW) or 0),
        }

        local sideNames = {}
        local totalAmount = 0
        for _, side in ipairs({ "N", "S", "E", "W" }) do
            if amounts[side] < 0 then amounts[side] = 0 end
            if amounts[side] > maxAmount then amounts[side] = maxAmount end
            if amounts[side] > 0 then
                sideNames[#sideNames + 1] = side .. "+" .. tostring(amounts[side])
                totalAmount = totalAmount + amounts[side]
            end
        end

        if #sideNames == 0 then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidAction")
            return
        end

        totalStep = totalAmount
        newRect = RSE.calcPerSideResizedRect(oldRect, amounts, mode)
        action = table.concat(sideNames, "+")
        logDetail = string.format("sides=%s", action)
    else
        action = tostring(args.action or "")
        local stepCount = RSE.normalizeResizeSteps(args.steps, false)
        if not stepCount then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_InvalidSteps")
            return
        end
        if not RSE.ACTIONS[action] then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidAction")
            return
        end
        if action ~= "ALL" then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_UserBorder_ActionDenied")
            return
        end

        totalStep = stepCount
        newRect = RSE.calcResizedRect(oldRect, action, totalStep, mode)
        logDetail = string.format("action=%s steps=%d", action, stepCount)
    end

    if not RSE.rectIsValid(newRect) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_InvalidResult")
        return
    end

    local addsTiles = RSE.countAddedTiles(oldRect, newRect) > 0
    local baseRect = getBaseRect(oldRect)
    local baseArea = getBaseArea(oldRect)

    if addsTiles then
        local username = RSE.getPlayerUsername(playerObj)
        local activeLock = username and getActiveSafehouseLock(username) or nil
        if resizeFlow == "user" and not RSE.isUserFlowUsingAdvancedMode() and username and getUserExpansionClaim(username) then
            sendResult(
                playerObj,
                false,
                "IGUI_BetterSafehouse_Expansion_Resize_UserAlreadyExpanded",
                nil,
                "You already used your one-time user safehouse expansion."
            )
            return
        end

        if activeLock and not (resizeFlow == "user" and not RSE.isUserFlowUsingAdvancedMode()) and not lockMatchesSafehouse(activeLock, safehouse, oldRect) then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_OtherSafehouseLocked")
            return
        end

        local maxTotalTiles = RSE.getMaxTotalTilesForFlow(resizeFlow, playerObj)
        if maxTotalTiles > 0 then
            local newTotalTiles = RSE.getSafehouseArea(newRect)
            if newTotalTiles > maxTotalTiles then
                sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_MaxTotalTilesReached", {
                    tostring(newTotalTiles),
                    tostring(maxTotalTiles),
                })
                return
            end
        end

        if resizeFlow == "role" then
            local maxExtraTiles = RSE.getEffectiveMaxExtraTilesForPlayer(playerObj)
            if type(maxExtraTiles) ~= "number" then
                sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_RoleDenied")
                return
            end

            local newExtraTiles = RSE.getExtraTilesBeyondBaseArea(baseArea, newRect)
            if newExtraTiles > maxExtraTiles then
                sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_MaxExtraTilesReached", {
                    tostring(newExtraTiles),
                    tostring(maxExtraTiles),
                })
                return
            end
        elseif resizeFlow == "user" and RSE.isUserFlowUsingAdvancedMode() then
            local maxExtraTiles = RSE.getUserAdvancedMaxExtraTilesFromOriginal()
            local newExtraTiles = RSE.getExtraTilesBeyondBaseArea(baseArea, newRect)
            if newExtraTiles > maxExtraTiles then
                sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_MaxExtraTilesReached", {
                    tostring(newExtraTiles),
                    tostring(maxExtraTiles),
                })
                return
            end
        elseif resizeFlow == "user" then
            local maxBorderTiles = RSE.getUserMaxBorderTilesFromOriginal()
            local border = RSE.getBorderExpansionFromBase(baseRect, newRect)
            if not border or border.left < 0 or border.top < 0 or border.right < 0 or border.bottom < 0 then
                sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_InvalidResult")
                return
            end

            if border.left > maxBorderTiles
                or border.top > maxBorderTiles
                or border.right > maxBorderTiles
                or border.bottom > maxBorderTiles
            then
                sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_UserBorderLimitReached", {
                    tostring(border.max),
                    tostring(maxBorderTiles),
                })
                return
            end
        end
    end

    if isWarBlocked(safehouse, oldRect, newRect) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_WarBlocked")
        return
    end

    if addsTiles and not isAddedAreaLoaded(oldRect, newRect) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_AreaNotLoaded")
        return
    end

    if addsTiles and RSE.shouldBlockAsphaltRoads() then
        local blockedTile = findAddedAreaAsphaltTile(oldRect, newRect)
        if blockedTile then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_AsphaltBlocked", {
                tostring(blockedTile.x),
                tostring(blockedTile.y),
            })
            return
        end
    end

    if addsTiles then
        local otherPlayer = findUnauthorizedPlayerInAddedArea(playerObj, safehouse, oldRect, newRect)
        if otherPlayer then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_OtherPlayerInArea", {
                tostring(RSE.getPlayerUsername(otherPlayer) or "?"),
            })
            return
        end
    end

    if addsTiles then
        local overlappingSafehouse = findOverlappingSafehouse(newRect, safehouse)
        if overlappingSafehouse then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_CollidesOtherSafehouse")
            return
        end
    end

    local okMutation, newOnlineId, oldOnlineId = mutateSafehouseInPlace(safehouse, oldRect, newRect)
    if not okMutation then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_ApplyFailed")
        return
    end

    local storedBaseArea, storedBaseRect = storeResizedState(oldRect, newRect)
    updateLocksAfterResize(oldRect, newRect, oldOnlineId, newOnlineId)
    if addsTiles then
        local username = RSE.getPlayerUsername(playerObj)
        local isBasicUserFlow = resizeFlow == "user" and not RSE.isUserFlowUsingAdvancedMode()

        -- The basic user flow tracks its own one-time use via
        -- userExpansionClaims below and explicitly skips the "other
        -- safehouse locked" check above (line ~1023) — it must not also
        -- write expandedSafehouseLocks, or it silently overwrites/clobbers
        -- a role-flow lock that belongs to this same username (see
        -- getActiveSafehouseLock/lockMatchesSafehouse), locking that
        -- player out of their own already-in-progress role expansion.
        if not isBasicUserFlow then
            -- canResizeSafehouse() lets an admin resize any safehouse, so
            -- the lock must track the safehouse's actual OWNER, not
            -- whoever issued the request — keying it by the admin's own
            -- name would misattribute the owner's expansion to the admin
            -- and wrongly lock the admin out of unrelated future resizes.
            local lockUsername = getSafehouseOwnerUsername(safehouse) or username
            setSafehouseLock(lockUsername, safehouse, newRect, resizeFlow)
        end

        if isBasicUserFlow then
            setUserExpansionClaim(username, safehouse, newRect)
        end
    end

    local payload = getRectPayload(newRect) or {}
    payload.oldX = oldRect.x
    payload.oldY = oldRect.y
    payload.oldW = oldRect.w
    payload.oldH = oldRect.h
    payload.oldOnlineID = oldOnlineId
    payload.onlineID = newOnlineId
    payload.mode = mode
    payload.steps = totalStep
    payload.flow = resizeFlow
    payload.baseArea = storedBaseArea
    payload.baseX = storedBaseRect and storedBaseRect.x or nil
    payload.baseY = storedBaseRect and storedBaseRect.y or nil
    payload.baseW = storedBaseRect and storedBaseRect.w or nil
    payload.baseH = storedBaseRect and storedBaseRect.h or nil
    local isUserAdvanced = resizeFlow == "user" and RSE.isUserFlowUsingAdvancedMode()
    payload.maxExtraTiles = (resizeFlow == "role" and RSE.getEffectiveMaxExtraTilesForPlayer(playerObj))
        or (isUserAdvanced and RSE.getUserAdvancedMaxExtraTilesFromOriginal())
        or nil
    payload.maxTotalTiles = RSE.getMaxTotalTilesForFlow(resizeFlow, playerObj)
    payload.userMaxBorderTiles = (resizeFlow == "user" and not isUserAdvanced) and RSE.getUserMaxBorderTilesFromOriginal() or nil

    broadcastSafehouseResized(payload)

    log(string.format("Resized safehouse owner=%s flow=%s mode=%s %s from=%s to=%s baseArea=%d maxExtra=%s userMaxBorder=%s",
        tostring(RSE.getPlayerUsername(playerObj) or "?"),
        tostring(resizeFlow),
        tostring(mode),
        tostring(logDetail),
        RSE.makeSafehouseKey(oldRect),
        RSE.makeSafehouseKey(newRect),
        storedBaseArea,
        tostring(payload.maxExtraTiles),
        tostring(payload.userMaxBorderTiles)))

    sendResult(playerObj, true, getSuccessKey(mode))
end

-- ===== DISPLAY INFO =====

local function findOnlinePlayerByUsernameLocal(username)
    username = RSE.trimString(username)
    if username == "" then return nil end
    local players = getOnlinePlayers()
    if not players then return nil end
    if players.size and players.get then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p.getUsername then
                local ok, name = pcall(function() return p:getUsername() end)
                if ok and tostring(name) == username then return p end
            end
        end
    end
    return nil
end

-- The owner may be offline when an admin opens this panel.  In that case the
-- IsoPlayer object does not exist, but B42 still keeps the assigned role in
-- the server whitelist database.
local function roleObjectToName(role)
    if not role then return nil end

    if role.getName then
        local gotName, name = pcall(function() return role:getName() end)
        if gotName and name and tostring(name) ~= "" then
            return tostring(name)
        end
    end

    if role.name ~= nil and tostring(role.name) ~= "" then
        return tostring(role.name)
    end

    return nil
end

local function getStoredRoleNameByUsernameLocal(username)
    username = RSE.trimString(username)
    if username == "" then return nil end

    local database = ServerWorldDatabase and ServerWorldDatabase.instance or nil
    if not database or not database.getUserRoleNameByUsername then return nil end

    -- getUserRoleNameByUsername() does a case-sensitive DB lookup, unlike
    -- login and most of the rest of the game, which treat usernames
    -- case-insensitively. safehouse:getOwner() may return a different
    -- capitalization than what's stored, so an exact-case miss shouldn't
    -- be treated as "this player has no role" — try lowercase too before
    -- giving up.
    local candidates = { username }
    local lowered = string.lower(username)
    if lowered ~= username then
        candidates[#candidates + 1] = lowered
    end

    for _, candidate in ipairs(candidates) do
        local ok, role = pcall(function()
            return database:getUserRoleNameByUsername(candidate)
        end)
        if ok and role then
            local name = roleObjectToName(role)
            if name then return name end
        end
    end

    return nil
end

local function handleDisplayInfoRequest(playerObj, args)
    if not playerObj or type(args) ~= "table" then return end
    local requestedRect = RSE.makeRect(args.x, args.y, args.w, args.h)
    if not RSE.rectIsValid(requestedRect) then return end

    -- Find the safehouse (any player can query display info for any safehouse)
    local safehouse = RSE.findSafehouseByRect(requestedRect)
    if not safehouse then return end

    local baseRect = getBaseRect(requestedRect)

    local ownerUsername = ""
    local ownerRoleName = ""
    if safehouse.getOwner then
        local ok, owner = pcall(function() return safehouse:getOwner() end)
        if ok and owner and owner ~= "" then
            ownerUsername = tostring(owner)
            local ownerPlayer = findOnlinePlayerByUsernameLocal(ownerUsername)
            if ownerPlayer then
                local rname = RSE.getPlayerRoleName(ownerPlayer)
                if rname then ownerRoleName = rname end
            end
            if ownerRoleName == "" then
                local rname = getStoredRoleNameByUsernameLocal(ownerUsername)
                if rname then ownerRoleName = rname end
            end
        end
    end

    local payload = {
        x = requestedRect.x, y = requestedRect.y,
        w = requestedRect.w, h = requestedRect.h,
        baseX = baseRect.x, baseY = baseRect.y,
        baseW = baseRect.w, baseH = baseRect.h,
        ownerUsername = ownerUsername,
        ownerRoleName = ownerRoleName,
    }
    sendServerCommand(playerObj, RSE.NET_MODULE, "SafehouseDisplayInfo", payload)
end

-- ===== ADMIN RESET =====

local function handleAdminReset(playerObj, args)
    if not playerObj or type(args) ~= "table" then return end

    if not RSE.isStrictAdmin(playerObj) then
        sendResult(playerObj, false, nil, nil, "No permission.")
        return
    end

    local requestedRect = RSE.makeRect(args.x, args.y, args.w, args.h)
    if not RSE.rectIsValid(requestedRect) then
        sendResult(playerObj, false, nil, nil, "Invalid safehouse.")
        return
    end

    local safehouse = RSE.findSafehouseByRect(requestedRect)
    if not safehouse then
        sendResult(playerObj, false, nil, nil, "Safehouse not found.")
        return
    end

    local state = getState()
    local key = RSE.makeSafehouseKey(requestedRect)
    local baseRect = rectFromPayload(state.baseRects[key])

    if not baseRect then
        sendResult(playerObj, true, nil, nil, "Safehouse already at vanilla size.")
        return
    end
    if requestedRect.x == baseRect.x and requestedRect.y == baseRect.y
        and requestedRect.w == baseRect.w and requestedRect.h == baseRect.h then
        sendResult(playerObj, true, nil, nil, "Safehouse already at vanilla size.")
        return
    end

    -- handleResize re-checks this before every mutation; this admin path
    -- calls mutateSafehouseInPlace() directly and skipped it, so a
    -- safehouse created on the stored baseRect footprint in the interim
    -- (or a stale/corrupted baseRect) could otherwise get silently
    -- overlapped by this reset.
    if findOverlappingSafehouse(baseRect, safehouse) then
        sendResult(playerObj, false, nil, nil, "Reset target overlaps another safehouse.")
        return
    end

    local ownerUsername = getSafehouseOwnerUsername(safehouse)

    local oldOnlineId = getSafehouseOnlineId(safehouse, requestedRect)
    local okMutation, newOnlineId, _ = mutateSafehouseInPlace(safehouse, requestedRect, baseRect)
    if not okMutation then
        sendResult(playerObj, false, nil, nil, "Failed to apply reset.")
        return
    end

    -- Clear all expansion state for old key
    local newKey = RSE.makeSafehouseKey(baseRect)
    state.baseAreas[key] = nil
    state.baseRects[key] = nil
    -- Reset base data for new key too so it's treated as vanilla
    state.baseAreas[newKey] = nil
    state.baseRects[newKey] = nil

    -- Clear owner expansion claims/locks
    if ownerUsername then
        state.expandedSafehouseLocks[ownerUsername] = nil
        state.userExpansionClaims[ownerUsername] = nil
    end
    persistState()

    local payload = getRectPayload(baseRect) or {}
    payload.oldX = requestedRect.x; payload.oldY = requestedRect.y
    payload.oldW = requestedRect.w; payload.oldH = requestedRect.h
    payload.oldOnlineID = oldOnlineId; payload.onlineID = newOnlineId
    payload.mode = "shrink"; payload.steps = 1; payload.flow = "admin_reset"
    payload.baseArea = RSE.getSafehouseArea(baseRect)
    payload.baseX = baseRect.x; payload.baseY = baseRect.y
    payload.baseW = baseRect.w; payload.baseH = baseRect.h

    broadcastSafehouseResized(payload)

    log(string.format("AdminResetSafehouse by %s: %s -> %s",
        tostring(RSE.getPlayerUsername(playerObj) or "?"),
        RSE.makeSafehouseKey(requestedRect), RSE.makeSafehouseKey(baseRect)))

    sendResult(playerObj, true, nil, nil, "Safehouse reset to vanilla size.")
end

-- ===== USER RELEASE CLEAR CLAIM =====
-- Called before the player voluntarily releases their safehouse so their user
-- expansion claim is freed and they can expand again elsewhere.

local function handleUserReleaseClearClaim(playerObj, args)
    if not playerObj or type(args) ~= "table" then return end
    local username = RSE.getPlayerUsername(playerObj)
    if not username then return end

    local requestedRect = RSE.makeRect(args.x, args.y, args.w, args.h)
    if not RSE.rectIsValid(requestedRect) then return end

    local safehouse = RSE.findSafehouseByRect(requestedRect)
    if not safehouse or not RSE.isSafehouseOwner(playerObj, safehouse) then return end

    local state = getState()
    local changed = false
    local currentKey = RSE.makeSafehouseKey(requestedRect)

    -- Only clear the claim/lock if it actually points at THIS safehouse — an
    -- owner with two safehouses could otherwise release the unexpanded one
    -- and wipe the claim that belongs to the other, already-expanded one.
    local claim = state.userExpansionClaims[username]
    if type(claim) == "table" and tostring(claim.key or "") == currentKey then
        state.userExpansionClaims[username] = nil
        changed = true
    end

    local lock = state.expandedSafehouseLocks[username]
    if type(lock) == "table" and tostring(lock.key or "") == currentKey then
        state.expandedSafehouseLocks[username] = nil
        changed = true
    end
    if changed then
        persistState()
        log("Cleared user expansion claim for " .. username .. " on safehouse release")
    end
end

function Server.clearExpansionStateForSafehouse(safehouse, ownerUsername)
    local rect = RSE.rectFromSafehouse(safehouse)
    if not rect then return false end

    ownerUsername = RSE.trimString(ownerUsername)
    if ownerUsername == "" and safehouse and safehouse.getOwner then
        local okOwner, owner = pcall(function()
            return safehouse:getOwner()
        end)
        if okOwner and owner and tostring(owner) ~= "" then
            ownerUsername = RSE.trimString(owner)
        end
    end

    local key = RSE.makeSafehouseKey(rect)
    local onlineId = getSafehouseOnlineId(safehouse, rect)
    local state = getState()
    local changed = false

    state.baseAreas[key] = nil
    state.baseRects[key] = nil

    local function refMatches(ref)
        if type(ref) ~= "table" then return false end
        if tostring(ref.key or "") == key then return true end
        if onlineId and tonumber(ref.onlineID) == tonumber(onlineId) then return true end

        local refRect = rectFromPayload(ref.rect)
        return refRect ~= nil
            and refRect.x == rect.x
            and refRect.y == rect.y
            and refRect.w == rect.w
            and refRect.h == rect.h
    end

    if ownerUsername ~= "" then
        if refMatches(state.userExpansionClaims[ownerUsername]) then
            state.userExpansionClaims[ownerUsername] = nil
            changed = true
        end
        if refMatches(state.expandedSafehouseLocks[ownerUsername]) then
            state.expandedSafehouseLocks[ownerUsername] = nil
            changed = true
        end
    end

    for username, claim in pairs(state.userExpansionClaims) do
        if refMatches(claim) then
            state.userExpansionClaims[username] = nil
            changed = true
        end
    end

    for username, lock in pairs(state.expandedSafehouseLocks) do
        if refMatches(lock) then
            state.expandedSafehouseLocks[username] = nil
            changed = true
        end
    end

    persistState()

    if changed then
        log("Cleared expansion state for released safehouse " .. key)
    end

    return changed
end

-- ===== OWNERSHIP TRANSFER RESET =====
-- Called by BetterSafehouse_Server when ownership changes hands.
-- Resets the safehouse to vanilla size and clears the old owner's user claim.

function Server.resetForOwnerChange(safehouse, oldOwnerUsername)
    if not safehouse or not oldOwnerUsername or oldOwnerUsername == "" then return end

    local currentRect = RSE.rectFromSafehouse(safehouse)
    if not currentRect then return end

    local state = getState()
    local key = RSE.makeSafehouseKey(currentRect)
    local baseRect = rectFromPayload(state.baseRects[key])

    if not baseRect then return end -- nothing to reset
    if currentRect.x == baseRect.x and currentRect.y == baseRect.y
        and currentRect.w == baseRect.w and currentRect.h == baseRect.h then
        -- Already vanilla size; just clear the claim
        state.userExpansionClaims[oldOwnerUsername] = nil
        state.expandedSafehouseLocks[oldOwnerUsername] = nil
        persistState()
        return
    end

    -- Only reset if the old owner was the one who user-expanded it
    local claim = state.userExpansionClaims[oldOwnerUsername]
    local lock  = state.expandedSafehouseLocks[oldOwnerUsername]
    local claimKey = claim and tostring(claim.key or "") or ""
    local lockKey  = lock  and tostring(lock.key  or "") or ""
    if claimKey ~= key and lockKey ~= key then return end -- not their expansion

    -- Same guard as handleAdminReset: this path also mutates directly,
    -- bypassing handleResize's overlap check.
    if findOverlappingSafehouse(baseRect, safehouse) then
        log("OwnerChangeReset skipped: baseRect overlaps another safehouse for " .. RSE.makeSafehouseKey(currentRect))
        return
    end

    local oldOnlineId = getSafehouseOnlineId(safehouse, currentRect)
    local okMutation, newOnlineId = mutateSafehouseInPlace(safehouse, currentRect, baseRect)
    if not okMutation then return end

    local newKey = RSE.makeSafehouseKey(baseRect)
    state.baseAreas[key]  = nil; state.baseRects[key]  = nil
    state.baseAreas[newKey] = nil; state.baseRects[newKey] = nil
    state.userExpansionClaims[oldOwnerUsername] = nil
    state.expandedSafehouseLocks[oldOwnerUsername] = nil
    persistState()

    local payload = getRectPayload(baseRect) or {}
    payload.oldX = currentRect.x; payload.oldY = currentRect.y
    payload.oldW = currentRect.w; payload.oldH = currentRect.h
    payload.oldOnlineID = oldOnlineId; payload.onlineID = newOnlineId
    payload.mode = "shrink"; payload.steps = 1; payload.flow = "owner_change_reset"
    payload.baseArea = RSE.getSafehouseArea(baseRect)
    payload.baseX = baseRect.x; payload.baseY = baseRect.y
    payload.baseW = baseRect.w; payload.baseH = baseRect.h

    broadcastSafehouseResized(payload)
    log(string.format("OwnerChangeReset: %s -> %s (old owner: %s)",
        RSE.makeSafehouseKey(currentRect), RSE.makeSafehouseKey(baseRect), oldOwnerUsername))
end

-- ===== CORE =====

function Server.init()
    getState()
    pruneState()
    migrateLegacyUserSafehouses()
    persistState()
end

function Server.onClientCommand(module, command, playerObj, args)
    if module ~= RSE.NET_MODULE then return end
    if command == "RequestExpansionLimitState"    then return handleLimitStateRequest(playerObj, args) end
    if command == "ExpansionResize"               then return handleResize(playerObj, args) end
    if command == "RequestSafehouseDisplayInfo"   then return handleDisplayInfoRequest(playerObj, args) end
    if command == "AdminResetSafehouse"           then return handleAdminReset(playerObj, args) end
    if command == "UserReleaseClearClaim"         then return handleUserReleaseClearClaim(playerObj, args) end
end

if not Server._eventsInstalled then
    Events.OnInitGlobalModData.Add(Server.init)
    Events.OnClientCommand.Add(Server.onClientCommand)
    Server._eventsInstalled = true
end
