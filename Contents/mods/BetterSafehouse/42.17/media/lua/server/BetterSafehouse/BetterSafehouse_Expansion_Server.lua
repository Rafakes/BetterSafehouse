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

    for username, lock in pairs(state.expandedSafehouseLocks) do
        local lockKey = type(lock) == "table" and lock.key or nil
        local lockOnlineId = type(lock) == "table" and tonumber(lock.onlineID) or nil
        local lockActive = lockKey and active[lockKey] == true
        if not lockActive and lockOnlineId then
            lockActive = activeOnlineIds[lockOnlineId] == true
        end

        if not lockActive then
            state.expandedSafehouseLocks[username] = nil
        end
    end
end

local function getBaseRect(rect)
    pruneState()
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
        if okOwner and tostring(owner or "") == username then
            return lock, safehouse
        end

        state.expandedSafehouseLocks[username] = nil
        persistState()
        return nil
    end

    state.expandedSafehouseLocks[username] = nil
    persistState()
    return nil
end

local function setSafehouseLock(username, safehouse, rect)
    username = RSE.trimString(username)
    if username == "" or not RSE.rectIsValid(rect) then
        return
    end

    local state = getState()
    state.expandedSafehouseLocks[username] = {
        key = RSE.makeSafehouseKey(rect),
        rect = copyRectPayload(rect),
        onlineID = getSafehouseOnlineId(safehouse, rect),
    }
    persistState()
end

local function updateLocksAfterResize(oldRect, newRect, oldOnlineId, newOnlineId)
    local state = getState()
    local oldKey = RSE.makeSafehouseKey(oldRect)
    local changed = false

    for _, lock in pairs(state.expandedSafehouseLocks) do
        if type(lock) == "table" then
            local sameKey = tostring(lock.key or "") == oldKey
            local sameOnlineId = oldOnlineId and tonumber(lock.onlineID) == tonumber(oldOnlineId)
            if sameKey or sameOnlineId then
                lock.key = RSE.makeSafehouseKey(newRect)
                lock.rect = copyRectPayload(newRect)
                lock.onlineID = newOnlineId or lock.onlineID
                changed = true
            end
        end
    end

    if changed then
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

local function isRequesterNearSafehouse(playerObj, rect)
    if not playerObj or not rect then
        return false
    end

    local px = math.floor(tonumber(playerObj:getX()) or 0)
    local py = math.floor(tonumber(playerObj:getY()) or 0)

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
        return props:get("MaterialType")
    end)
    if ok and value and tostring(value) ~= "" then
        return tostring(value)
    end

    return nil
end

local function isAsphaltRoadFloor(square, blockedLookup)
    local spriteName = getSquareFloorSpriteName(square) or ""
    if spriteName == "" then
        return false
    end

    local normalized = RSE.lowerString(spriteName)
    return blockedLookup and blockedLookup[normalized] == true
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

        local px = math.floor(tonumber(playerObj:getX()) or 0)
        local py = math.floor(tonumber(playerObj:getY()) or 0)

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

    if WarManager.isWarClaimed then
        local okClaimed, claimed = pcall(function()
            return WarManager.isWarClaimed(oldOnlineId)
        end)
        if okClaimed and claimed == false then
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
    local action = tostring(args.action or "")
    local mode = RSE.normalizeResizeMode(args.mode)
    local stepCount = RSE.normalizeResizeSteps(args.steps, false)

    if not RSE.rectIsValid(requestedRect) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse")
        return
    end

    if not mode then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_InvalidMode")
        return
    end

    if not stepCount then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_InvalidSteps")
        return
    end

    if not RSE.ACTIONS[action] then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidAction")
        return
    end

    local safehouse = RSE.findSafehouseByRect(requestedRect)
    if not safehouse then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse")
        return
    end

    if not RSE.isSafehouseOwner(playerObj, safehouse) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_NotOwner")
        return
    end

    local roleName = RSE.getPlayerRoleName(playerObj)
    if not roleName or roleName == "" then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_MissingRole")
        return
    end

    local resizeFlow = RSE.getResizeFlowForRoleName(roleName)
    if not resizeFlow then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_RoleDenied")
        return
    end

    if resizeFlow == "user" then
        if RSE.getUserMaxBorderTilesFromOriginal() < 1 then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_UserBorder_NoActionsConfigured")
            return
        end

        if mode ~= "expand" then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_UserBorder_ShrinkDenied")
            return
        end

        if action ~= "ALL" then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_UserBorder_ActionDenied")
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

    local totalStep = stepCount
    if resizeFlow == "role" then
        totalStep = RSE.getTotalResizeStep(RSE.getExpandStepTiles(), stepCount)
    end

    if totalStep <= 0 then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Expand_InvalidStep")
        return
    end

    local newRect = RSE.calcResizedRect(oldRect, action, totalStep, mode)
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
        if activeLock and not lockMatchesSafehouse(activeLock, safehouse, oldRect) then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Expansion_Resize_OtherSafehouseLocked")
            return
        end

        if resizeFlow == "role" then
            local maxExtraTiles = RSE.getEffectiveMaxExtraTilesForRole(roleName)
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
        setSafehouseLock(RSE.getPlayerUsername(playerObj), safehouse, newRect)
    end

    local payload = getRectPayload(newRect) or {}
    payload.oldX = oldRect.x
    payload.oldY = oldRect.y
    payload.oldW = oldRect.w
    payload.oldH = oldRect.h
    payload.oldOnlineID = oldOnlineId
    payload.onlineID = newOnlineId
    payload.mode = mode
    payload.steps = stepCount
    payload.flow = resizeFlow
    payload.baseArea = storedBaseArea
    payload.baseX = storedBaseRect and storedBaseRect.x or nil
    payload.baseY = storedBaseRect and storedBaseRect.y or nil
    payload.baseW = storedBaseRect and storedBaseRect.w or nil
    payload.baseH = storedBaseRect and storedBaseRect.h or nil
    payload.maxExtraTiles = RSE.getEffectiveMaxExtraTilesForRole(roleName)
    payload.userMaxBorderTiles = resizeFlow == "user" and RSE.getUserMaxBorderTilesFromOriginal() or nil

    broadcastSafehouseResized(payload)

    log(string.format("Resized safehouse owner=%s flow=%s mode=%s action=%s steps=%d from=%s to=%s baseArea=%d maxExtra=%s userMaxBorder=%s",
        tostring(RSE.getPlayerUsername(playerObj) or "?"),
        tostring(resizeFlow),
        tostring(mode),
        tostring(action),
        stepCount,
        RSE.makeSafehouseKey(oldRect),
        RSE.makeSafehouseKey(newRect),
        storedBaseArea,
        tostring(payload.maxExtraTiles),
        tostring(payload.userMaxBorderTiles)))

    sendResult(playerObj, true, getSuccessKey(mode))
end

function Server.init()
    getState()
    pruneState()
    persistState()
end

function Server.onClientCommand(module, command, playerObj, args)
    if module ~= RSE.NET_MODULE then return end
    if command ~= "ExpansionResize" then return end
    handleResize(playerObj, args)
end

if not Server._eventsInstalled then
    Events.OnInitGlobalModData.Add(Server.init)
    Events.OnClientCommand.Add(Server.onClientCommand)
    Server._eventsInstalled = true
end
