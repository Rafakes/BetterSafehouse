--[[
    Better Safehouse - Safehouse Viewer (Client)
    Highlights your safehouse border on the ground when enabled.
--]]

BetterSafehouse = BetterSafehouse or {}

BetterSafehouse.Viewer = BetterSafehouse.Viewer or {
    lastSafehouseId = nil,
    lastZ = nil,
    lastApplyMs = 0,
    throttleMs = 500,
    appliedSquares = {},
}

local function keyOf(x,y,z) return tostring(x)..","..tostring(y)..","..tostring(z) end

local function clearApplied()
    local cell = getCell()
    if not cell then return end
    for k,_ in pairs(BetterSafehouse.Viewer.appliedSquares or {}) do
        local x,y,z = k:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
        if x and y and z then
            x = tonumber(x); y = tonumber(y); z = tonumber(z)
            local sq = cell:getGridSquare(x,y,z)
            if sq then
                if sq.setHighlight then sq:setHighlight(false) end
                local floor = sq:getFloor()
                if floor and floor.setHighlighted then floor:setHighlighted(false) end
            end
        end
    end
    BetterSafehouse.Viewer.appliedSquares = {}
end

local function applyHighlightToSquare(sq)
    if not sq then return end
    local floor = sq:getFloor()
    -- Blue safehouse highlight (RGBA)
    -- Uses IsoObject:setHighlightColor(), available in b42.
    if floor and floor.setHighlightColor then
        -- A slightly transparent blue so it doesn't overpower floor textures
        floor:setHighlightColor(0.15, 0.45, 1.0, 0.55)
    end
    if floor and floor.setHighlighted then
        floor:setHighlighted(true, false)
    end
    if sq.setHighlight then
        sq:setHighlight(true)
    end
end

local function getSafehouseList()
    if not SafeHouse then return nil end
    -- B41 used getSafehouseList(), some builds use getSafeHouseList()
    if SafeHouse.getSafehouseList then
        local ok, list = pcall(SafeHouse.getSafehouseList)
        if ok then return list end
    end
    if SafeHouse.getSafeHouseList then
        local ok, list = pcall(SafeHouse.getSafeHouseList)
        if ok then return list end
    end
    return nil
end

local function safehouseBounds(sh)
    -- Return x1,y1,x2,y2.
    -- NOTE (B42): Some builds expose getX2/getY2 as EXCLUSIVE bounds (x+w, y+h),
    -- while getW/getH are sizes. To avoid a +1 tile outside, we reconcile using W/H when possible.
    local x1 = sh:getX()
    local y1 = sh:getY()

    local w, h = nil, nil
    if sh.getW then
        local ok, v = pcall(function() return sh:getW() end)
        if ok and type(v) == "number" then w = v end
    end
    if sh.getH then
        local ok, v = pcall(function() return sh:getH() end)
        if ok and type(v) == "number" then h = v end
    end

    local x2, y2 = nil, nil
    if sh.getX2 then
        local ok, v = pcall(function() return sh:getX2() end)
        if ok and type(v) == "number" then x2 = v end
    end
    if sh.getY2 then
        local ok, v = pcall(function() return sh:getY2() end)
        if ok and type(v) == "number" then y2 = v end
    end

    -- Prefer W/H-derived inclusive bounds when available.
    if w then
        local expected = x1 + w - 1
        if x2 == nil then
            x2 = expected
        else
            -- If getX2 is exclusive (x1+w), convert to inclusive.
            if x2 == expected + 1 then x2 = expected end
        end
    end
    if h then
        local expected = y1 + h - 1
        if y2 == nil then
            y2 = expected
        else
            if y2 == expected + 1 then y2 = expected end
        end
    end

    if not x2 then x2 = x1 end
    if not y2 then y2 = y1 end

    return x1, y1, x2, y2
end

local function safehouseHasPlayer(sh, username)
    if not sh or not username then return false end

    -- owner checks
    if sh.isOwner then
        local ok, res = pcall(function() return sh:isOwner(username) end)
        if ok and res ~= nil then return res end
    end
    if sh.getOwner then
        local ok, owner = pcall(function() return sh:getOwner() end)
        if ok and owner then return owner == username end
    end

    -- allowed/member checks (different names across versions/mods)
    local methods = { "isAllowed", "isPlayerAllowed", "playerAllowed", "isMember", "isPlayerMember" }
    for _, m in ipairs(methods) do
        if sh[m] then
            local ok, res = pcall(function() return sh[m](sh, username) end)
            if ok and res ~= nil then return res end
        end
    end

    -- fallback: players list contains username
    if sh.getPlayers then
        local ok, players = pcall(function() return sh:getPlayers() end)
        if ok and players then
            if players.contains then
                local ok2, res = pcall(function() return players:contains(username) end)
                if ok2 and res ~= nil then return res end
            end
            if players.size and players.get then
                local ok2, size = pcall(function() return players:size() end)
                if ok2 and size then
                    for i = 0, size - 1 do
                        local ok3, v = pcall(function() return players:get(i) end)
                        if ok3 and v == username then return true end
                    end
                end
            end
        end
    end

    return false
end

local function getPlayerSafehouse(playerObj)
    -- IMPORTANT (B42 MP): SafeHouse.getSafeHouse(IsoPlayer) is NOT a valid overload.
    -- Calling it throws: "No implementation found for function: getSafeHouse(IsoPlayer)".
    -- So we only use safehouse list and filter by username.
    if not playerObj then return nil end

    local username = nil
    if playerObj.getUsername then
        local ok, u = pcall(function() return playerObj:getUsername() end)
        if ok then username = u end
    end
    if not username or username == "" then
        -- Not fully initialised yet (can happen right after connecting)
        return nil
    end

    local list = getSafehouseList()
    if not list then return nil end

    local px = playerObj:getX()
    local py = playerObj:getY()
    local pz = playerObj:getZ()

    local fallback = nil

    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        if sh and safehouseHasPlayer(sh, username) then
            local x1, y1, x2, y2 = safehouseBounds(sh)
            local shz = 0
            if sh.getZ then
                local okZ, z = pcall(function() return sh:getZ() end)
                if okZ and z ~= nil then shz = z end
            end
            if pz == shz and px >= x1 and px <= x2 and py >= y1 and py <= y2 then
                -- Prefer the safehouse the player is currently inside.
                return sh
            end
            if not fallback then fallback = sh end
        end
    end

    return fallback
end

local function shouldDraw(playerObj)
    if not BetterSafehouse.isViewerEnabledBySandbox() then return false end
    return BetterSafehouse.getClientViewerPref(playerObj) == true
end

local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    if getTimeInMillis then return getTimeInMillis() end
    return 0
end

local function onTick()
    local playerObj = getPlayer()
    if not playerObj then return end

    if not shouldDraw(playerObj) then
        if BetterSafehouse.Viewer.lastSafehouseId ~= nil then
            clearApplied()
            BetterSafehouse.Viewer.lastSafehouseId = nil
            BetterSafehouse.Viewer.lastZ = nil
        end
        return
    end

    local now = nowMs()
    if now - (BetterSafehouse.Viewer.lastApplyMs or 0) < (BetterSafehouse.Viewer.throttleMs or 500) then
        return
    end
    BetterSafehouse.Viewer.lastApplyMs = now

    local z = playerObj:getZ()

    -- Optional: a forced viewer target (set from the safehouse UI tab).
    local target = (BetterSafehouse.getClientViewerTarget and BetterSafehouse.getClientViewerTarget(playerObj)) or nil

    local id = nil
    local x1, y1, x2, y2 = nil, nil, nil, nil

    if target then
        local tx = math.floor(tonumber(target.x) or 0)
        local ty = math.floor(tonumber(target.y) or 0)
        local tx2 = target.x2 and math.floor(tonumber(target.x2) or 0) or nil
        local ty2 = target.y2 and math.floor(tonumber(target.y2) or 0) or nil
        local tw  = math.floor(tonumber(target.w) or 0)
        local th  = math.floor(tonumber(target.h) or 0)

        if tx2 and ty2 then
            -- x2/y2 provided (preferred): inclusive bounds
            if tx2 < tx or ty2 < ty then
                -- Bad target; clear and bail.
                if BetterSafehouse.Viewer.lastSafehouseId ~= nil then
                    clearApplied()
                    BetterSafehouse.Viewer.lastSafehouseId = nil
                    BetterSafehouse.Viewer.lastZ = nil
                end
                return
            end

            x1, y1 = tx, ty
            x2, y2 = tx2, ty2
            id = "BS_TARGET:" .. tostring(tx) .. "," .. tostring(ty) .. "," .. tostring(tx2) .. "," .. tostring(ty2)
        else
            -- w/h provided: treat as width/height in tiles (inclusive)
            if tw <= 0 or th <= 0 then
                -- Bad target; clear and bail.
                if BetterSafehouse.Viewer.lastSafehouseId ~= nil then
                    clearApplied()
                    BetterSafehouse.Viewer.lastSafehouseId = nil
                    BetterSafehouse.Viewer.lastZ = nil
                end
                return
            end

            x1, y1 = tx, ty
            x2, y2 = tx + tw - 1, ty + th - 1
            id = "BS_TARGET:" .. tostring(tx) .. "," .. tostring(ty) .. "," .. tostring(tw) .. "," .. tostring(th)
        end
        -- If the target safehouse was released/deleted, stop drawing and remove the ground highlight.
        -- (The viewer target stores raw bounds, so it can outlive the actual SafeHouse object.)
        local list = getSafehouseList()
        local exists = false
        if list then
            local okSize, sz = pcall(function() return list:size() end)
            if okSize and type(sz) == "number" then
                for i = 0, sz - 1 do
                    local sh = list:get(i)
                    if sh then
                        local sx1, sy1, sx2, sy2 = safehouseBounds(sh)
                        if sx1 == x1 and sy1 == y1 and sx2 == x2 and sy2 == y2 then
                            exists = true
                            break
                        end
                    end
                end
            elseif type(list) == "table" then
                for _, sh in ipairs(list) do
                    if sh then
                        local sx1, sy1, sx2, sy2 = safehouseBounds(sh)
                        if sx1 == x1 and sy1 == y1 and sx2 == x2 and sy2 == y2 then
                            exists = true
                            break
                        end
                    end
                end
            end
        end

        if not exists then
            clearApplied()
            BetterSafehouse.Viewer.lastSafehouseId = nil
            BetterSafehouse.Viewer.lastZ = nil
            if BetterSafehouse.setClientViewerTarget then
                pcall(function() BetterSafehouse.setClientViewerTarget(playerObj, nil) end)
            end
            return
        end

    else
        local sh = getPlayerSafehouse(playerObj)
        if not sh then
            if BetterSafehouse.Viewer.lastSafehouseId ~= nil then
                clearApplied()
                BetterSafehouse.Viewer.lastSafehouseId = nil
                BetterSafehouse.Viewer.lastZ = nil
            end
            return
        end

        -- Prefer getId() when available, but never assume it exists in all builds.
        id = (sh.getId and sh:getId()) or tostring(sh)
        x1, y1, x2, y2 = safehouseBounds(sh)
    end

    if BetterSafehouse.Viewer.lastSafehouseId ~= id or BetterSafehouse.Viewer.lastZ ~= z then
        clearApplied()
        BetterSafehouse.Viewer.lastSafehouseId = id
        BetterSafehouse.Viewer.lastZ = z
    end

    local cell = getCell()
    if not cell then return end

    local function mark(x,y)
        local key = keyOf(x,y,z)
        if BetterSafehouse.Viewer.appliedSquares[key] then return end
        local sq = cell:getGridSquare(x,y,z)
        if sq then
            applyHighlightToSquare(sq)
            BetterSafehouse.Viewer.appliedSquares[key] = true
        end
    end

    for y=y1, y2 do
        for x=x1, x2 do
            mark(x, y)
        end
    end
end

Events.OnTick.Add(onTick)

function BetterSafehouse.Viewer.clear()
    clearApplied()
    BetterSafehouse.Viewer.lastSafehouseId = nil
    BetterSafehouse.Viewer.lastZ = nil
end