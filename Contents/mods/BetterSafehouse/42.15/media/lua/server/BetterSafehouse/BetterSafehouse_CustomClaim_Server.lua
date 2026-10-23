--[[
    Better Safehouse (Build 42) - Custom Claim system (Server)

    Server responsibilities:
      - Validate requests (anti-spam, distance, overlap, already has safehouse, item requirement)
      - Consume item (authoritative)
      - Create safehouse and sync
--]]

BetterSafehouse_CustomClaim_Server = BetterSafehouse_CustomClaim_Server or {}

local lastReqByUser = {} -- username -> timestampMs

local function log(msg)
    print("[BetterSafehouse][CustomClaim][S] " .. tostring(msg))
end

local function _unpack(t)
    return (table.unpack or unpack)(t or {})
end


function BetterSafehouse_CustomClaim_Server._isAdminServer(playerObj)
    if not playerObj then return false end

    if playerObj.isAccessLevel then
        local ok, v = pcall(function() return playerObj:isAccessLevel("Admin") end)
        if ok and v == true then return true end
        local ok2, v2 = pcall(function() return playerObj:isAccessLevel("GM") end)
        if ok2 and v2 == true then return true end
    end

    if playerObj.getAccessLevel then
        local ok, lvl = pcall(function() return playerObj:getAccessLevel() end)
        if ok and lvl then
            lvl = tostring(lvl)
            if lvl == "Admin" or lvl == "GM" then return true end
        end
    end

    return false
end

-- Sends a localized message to the client.
-- IMPORTANT (MP): we send translation keys so each client can localize in their own language.
-- Payload is backwards compatible (also includes msg when provided).
local function sendResult(playerObj, ok, key, args, fallbackMsg)
    if isServer() then
        local payload = { ok = ok == true, key = key, args = args }
        if fallbackMsg then payload.msg = fallbackMsg end
        sendServerCommand(playerObj, BetterSafehouse.CustomClaim.NET_MODULE, "ClaimResult", payload)
    else
        local msg = fallbackMsg
        if key and getText then
            msg = getText(key, _unpack(args))
        end
        if playerObj and playerObj.Say and msg then playerObj:Say(msg) end
    end
end

local function invHasFullType(container, fullType)
    if not container or not fullType then return false end
    local items = container:getItems()
    if not items then return false end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it.getFullType and it:getFullType() == fullType then
            return true
        end
        if it and it.getInventory then
            local sub = it:getInventory()
            if sub and invHasFullType(sub, fullType) then
                return true
            end
        end
    end
    return false
end

local function invRemoveOneFullType(container, fullType)
    if not container or not fullType then return false end
    local items = container:getItems()
    if not items then return false end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it.getFullType and it:getFullType() == fullType then
            container:Remove(it)
            if sendRemoveItemFromContainer then
                sendRemoveItemFromContainer(container, it)
            end
            return true
        end
        if it and it.getInventory then
            local sub = it:getInventory()
            if sub and invRemoveOneFullType(sub, fullType) then
                return true
            end
        end
    end
    return false
end
-- =========================
-- Custom Claim Location Restrictions (server-side, MP-safe)
-- =========================
-- Restriction distance (tiles) is configurable via Sandbox.
local DEFAULT_RESTRICT_RADIUS = 10

local function getRestrictRadius()
    local radius = DEFAULT_RESTRICT_RADIUS
    if SandboxVars and SandboxVars.BetterSafehouse and SandboxVars.BetterSafehouse.CustomClaimRestrictDistance ~= nil then
        local v = tonumber(SandboxVars.BetterSafehouse.CustomClaimRestrictDistance)
        if v then radius = math.floor(v) end
    end
    if radius < 0 then radius = 0 end
    if radius > 200 then radius = 200 end
    return radius
end

local function getSquareSafe(x, y, z)
    if not getCell then return nil end
    local cell = getCell()
    if not cell then return nil end
    return cell:getGridSquare(x, y, z or 0)
end

local function squareHasRoadTexture(square)
    if not square then return false end

    local function norm(name)
        if not name then return nil end
        name = tostring(name)
        return string.lower(name)
    end

    -- Roads in PZ can have several sprite-name prefixes depending on tileset.
    -- We want to block asphalt-like roads and markings (original requirement: blends_street*),
    -- but also catch common vanilla street/highway tile names.
    local function isAsphaltRoadFloorName(name)
        name = norm(name)
        if not name then return false end

        -- Primary: user requirement
        if string.find(name, "blends_street", 1, true) then return true end

        -- Common vanilla naming patterns (highways/streets/markings)
        if string.sub(name, 1, 7) == "street_" then return true end
        if string.find(name, "street_highway", 1, true) then return true end
        if string.find(name, "street_traffic", 1, true) then return true end
        if string.find(name, "street_line", 1, true) then return true end
        if string.find(name, "trafficlines", 1, true) then return true end

        -- Conservative fallback: many asphalt floors include these tokens
        if string.find(name, "asphalt", 1, true) then return true end

        return false
    end

    -- For non-floor objects, keep it strict to avoid matching e.g. streetlights.
    local function isRoadObjectName(name)
        name = norm(name)
        if not name then return false end
        if string.find(name, "blends_street", 1, true) then return true end
        if string.sub(name, 1, 7) == "street_" then return true end
        return false
    end

    local function spriteHasRoadProp(obj)
        if not obj or not obj.getSprite then return false end
        local ok, sprite = pcall(function() return obj:getSprite() end)
        if not ok or not sprite then return false end

        local ok2, props = pcall(function() return sprite:getProperties() end)
        if not ok2 or not props or not props.Is then return false end

        local ok3, isRoad = pcall(function()
            return props:Is("Street") or props:Is("street") or props:Is("Road") or props:Is("road")
        end)
        return ok3 and isRoad == true
    end

    -- In PZ, the road texture is usually on the floor sprite.
    local floor = nil
    if square.getFloor then
        local ok, v = pcall(function() return square:getFloor() end)
        if ok then floor = v end
    end

    local function getTexName(obj)
        if not obj then return nil end
        local tn = nil

        if obj.getTextureName then
            local ok, v = pcall(function() return obj:getTextureName() end)
            if ok then tn = v end
        end

        if (not tn or tn == "") and obj.getSprite then
            local okSpr, spr = pcall(function() return obj:getSprite() end)
            if okSpr and spr and spr.getName then
                local okName, v = pcall(function() return spr:getName() end)
                if okName then tn = v end
            end
        end

        return tn
    end

    local tn = getTexName(floor)
    if isAsphaltRoadFloorName(tn) or spriteHasRoadProp(floor) then
        return true
    end

    -- Fallback: scan objects on the square (rare, but keeps compatibility with some tiles/mods)
    local objs = square:getObjects()
    if not objs then return false end

    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        tn = getTexName(obj)
        if isRoadObjectName(tn) or spriteHasRoadProp(obj) then
            return true
        end
    end

    return false
end

local function safehouseAtSquare(square)
    if not SafeHouse or not square then return nil end
    local fn = SafeHouse.getSafeHouse or SafeHouse.getSafehouse
    if not fn then return nil end
    local ok, sh = pcall(function() return fn(square) end)
    if ok then return sh end
    return nil
end

local function validateLocationRestrictionsRect(playerObj, x1, y1, x2, y2, z)
    -- IMPORTANT:
    -- Restrictions are measured from the EDGE of the claimed safehouse area.
    -- We expand the rectangle by the configured radius and scan that region.

    local LOCATION_RADIUS = getRestrictRadius()

    local ex1, ey1 = x1 - LOCATION_RADIUS, y1 - LOCATION_RADIUS
    local ex2, ey2 = x2 + LOCATION_RADIUS, y2 + LOCATION_RADIUS

    -- 1) Building restriction (inside claim OR within expanded radius)
    for ix = ex1, ex2 do
        for iy = ey1, ey2 do
            local sq = getSquareSafe(ix, iy, z)
            if sq and sq.getBuilding and sq:getBuilding() then
                return false, "IGUI_BetterSafehouse_Claim_TooCloseBuilding", nil
            end
        end
    end

    -- 2) Existing safehouse restriction (within expanded radius from claim edge)
    if SafeHouse and SafeHouse.getSafehouseList then
        local list = SafeHouse.getSafehouseList()
        if list then
            for i = 0, list:size() - 1 do
                local sh = list:get(i)
                if sh then
                    local ox1, oy1 = sh:getX(), sh:getY()
                    local ox2, oy2 = sh:getX2(), sh:getY2()
                    if BetterSafehouse.CustomClaim.rectsOverlap(ex1, ey1, ex2, ey2, ox1, oy1, ox2, oy2) then
                        return false, "IGUI_BetterSafehouse_Claim_TooCloseSafehouse", nil
                    end
                end
            end
        end
    end

    -- 3) Asphalt road restriction (blends_street*) within expanded radius from claim edge
    for ix = ex1, ex2 do
        for iy = ey1, ey2 do
            local sq = getSquareSafe(ix, iy, z)
            if sq and squareHasRoadTexture(sq) then
                -- Debug info (server console) to help identify missed road sprites.
                local floorName = nil
                if sq.getFloor then
                    local okF, f = pcall(function() return sq:getFloor() end)
                    if okF and f and f.getSprite then
                        local okS, spr = pcall(function() return f:getSprite() end)
                        if okS and spr and spr.getName then
                            local okN, nm = pcall(function() return spr:getName() end)
                            if okN then floorName = nm end
                        end
                    end
                end
                log("Road blocked at " .. tostring(ix) .. "," .. tostring(iy) .. " floor=" .. tostring(floorName))
                return false, "IGUI_BetterSafehouse_Claim_TooCloseRoad", nil
            end
        end
    end

    return true, nil, nil
end


local function anyOtherPlayerInsideRect(owner, x1, y1, x2, y2, z)
    local players = getOnlinePlayers()
    if not players then return false end

    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p ~= owner and p:getZ() == z then
            local px, py = p:getX(), p:getY()
            if px >= x1 and px <= x2 and py >= y1 and py <= y2 then
                return true
            end
        end
    end
    return false
end

local function findSafehouseByRect(x1, y1, w, h)
    if not SafeHouse or not SafeHouse.getSafehouseList then return nil end
    local list = SafeHouse.getSafehouseList()
    if not list then return nil end
    local x2 = x1 + w - 1
    local y2 = y1 + h - 1
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        if sh and sh.getX and sh.getY and sh.getX2 and sh.getY2 then
            if sh:getX() == x1 and sh:getY() == y1 and sh:getX2() == x2 and sh:getY2() == y2 then
                return sh
            end
        end
    end
    return nil
end

local function userOwnsAnySafehouse(username)
    if not SafeHouse or not SafeHouse.getSafehouseList then return false end
    local list = SafeHouse.getSafehouseList()
    if not list then return false end

    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        if sh and sh.getOwner then
            local ok, owner = pcall(function() return sh:getOwner() end)
            if ok and owner == username then
                return true
            end
        end
    end
    return false
end

local function createSafehouse(x1, y1, w, h, username, playerObj)
    if not SafeHouse then return nil end

    -- B42.13.1 note:
    -- The Lua-exposed overload that works reliably here is the 5-arg form:
    --   addSafeHouse(x, y, w, h, owner)
    -- B42.13.x: passing an extra boolean triggers "No implementation found" errors; use 5 args only.
    local fn = SafeHouse.addSafeHouse or SafeHouse.addSafehouse
    if not fn then return nil end

    x1 = math.floor(tonumber(x1) or 0)
    y1 = math.floor(tonumber(y1) or 0)
    w  = math.floor(tonumber(w)  or 0)
    h  = math.floor(tonumber(h)  or 0)

    local ok, res = pcall(function() return fn(x1, y1, w, h, username) end)
    if ok then
        local sh = res or findSafehouseByRect(x1, y1, w, h)
        if sh then return sh end
        -- Last chance: the call might not return a value but still create the safehouse.
        return findSafehouseByRect(x1, y1, w, h)
    end

    -- If SafeHouse.setLocation() fails with a null ChooseGameInfo.Map, it usually means the
    -- area isn't associated with any registered World Map (common on poorly migrated standalone maps).
    local err = tostring(res)
    if err:find("ChooseGameInfo$Map", 1, true)
        or err:find("getZoomX", 1, true)
        or err:find("SafeHouse.setLocation", 1, true)
    then
        return nil, "MAP_METADATA_MISSING"
    end

    return nil
end



local function broadcastSafehouseAdded(x1, y1, w, h, owner, title)
    if not isServer() then return end
    if not sendServerCommand then return end

    local payload = {
        x = x1, y = y1, w = w, h = h,
        owner = owner,
        title = title,
    }

    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return end

    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            sendServerCommand(p, BetterSafehouse.CustomClaim.NET_MODULE, "SafehouseAdded", payload)
        end
    end
end

function BetterSafehouse_CustomClaim_Server._handleClaimRequestLocal(playerObj, args)
    BetterSafehouse_CustomClaim_Server._handleClaim(playerObj, args)
end

function BetterSafehouse_CustomClaim_Server._handleClaim(playerObj, args)
    local cfg = BetterSafehouse.CustomClaim.getConfig()

    if cfg.conflict or cfg.mode == "invalid" then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_CustomClaim_Conflict")
        return
    end

    if not cfg.enabled then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_CustomClaim_Disabled")
        return
    end

    if not playerObj or playerObj:isDead() then return end
    if not args or args.x == nil or args.y == nil or args.z == nil or not args.sizeId then return end

    local username = playerObj:getUsername()
    local now = getTimestampMs()

    -- Anti-spam server-side
    local last = lastReqByUser[username] or 0
    local cdMs = 2000 -- fixed server-side anti-spam (2s)
    if cdMs > 0 and (now - last) < cdMs then
        return
    end
    lastReqByUser[username] = now

    local size = nil
    if cfg.mode == "item" then
        size = BetterSafehouse.CustomClaim.getItemSizeById(args.sizeId, cfg)
    elseif cfg.mode == "free" then
        -- Free-mode size is defined by sandbox. When FreeAnywhere="All", the client may pick among allowed options (server validates).
        if cfg.freeMode == BetterSafehouse.CustomClaim.FREE_MODE.All then
            size = BetterSafehouse.CustomClaim.getFreeSizeByRequestId(args.sizeId, cfg)
        else
            -- Ignore any client-provided sizeId
            size = BetterSafehouse.CustomClaim.getFreeSizeFromSandbox(cfg)
        end
    end

    if not size then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_InvalidSizeOrDisabled")
        return
    end

    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if not sq then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_InvalidSquare")
        return
    end
    -- Engine limitation: 1 owner safehouse.
    -- Important: SafeHouse.hasSafehouse(playerObj) may return true even if the player is ONLY a member.
    -- When EnhancedInvites is enabled, being a member must NOT block creating your own safehouse.
    local enhancedInvites = false
    if BetterSafehouse and BetterSafehouse.getSandboxBool then
        enhancedInvites = BetterSafehouse.getSandboxBool("EnhancedInvites", true) == true
    end

    if enhancedInvites then
        if userOwnsAnySafehouse(username) then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_AlreadyHasSafehouse")
            return
        end
    else
        if SafeHouse and SafeHouse.hasSafehouse and SafeHouse.hasSafehouse(playerObj) then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_AlreadyHasSafehouse")
            return
        end
    end


    -- Calculate rect centered on the *player* for better precision (B42)
    -- We still use args.x/args.y for distance validation (anti-remote-claim),
    -- but the safehouse rectangle itself is centered on the player's current tile.
    local psq = playerObj:getSquare()
    local centerX, centerY, centerZ
    if psq then
        centerX, centerY, centerZ = psq:getX(), psq:getY(), psq:getZ()
    else
        -- MP edge-case: getSquare() can be nil for a tick while the player/chunks load.
        -- Using playerObj:getX()/getY() here may yield stale/invalid coords (0,0), which can crash SafeHouse.setLocation().
        centerX, centerY, centerZ = sq:getX(), sq:getY(), sq:getZ()
    end




    local w, h = size.w, size.h

    local sizeLabel = size.label
    local x1 = math.floor(centerX - math.floor(w / 2))
    local y1 = math.floor(centerY - math.floor(h / 2))
    local x2 = x1 + w - 1
    local y2 = y1 + h - 1
    local z  = centerZ or args.z

    -- Optional: location restrictions (server-authoritative)
    if cfg.restrictLocations then
        local okLoc, keyLoc, argsLoc = validateLocationRestrictionsRect(playerObj, x1, y1, x2, y2, z)
        if not okLoc then
            sendResult(playerObj, false, keyLoc or "IGUI_BetterSafehouse_Claim_InvalidLocation", argsLoc)
            return
        end
    end

    -- Guard against an engine NPE in SafeHouse.setLocation() when the rect falls outside a valid map area.
    -- This can happen in MP if chunks aren't loaded yet or if the rect crosses an invalid/out-of-bounds region.
    local function rectCornersLoaded(rx1, ry1, rx2, ry2)
        local cell = getCell()
        if not cell then return false end
        local z0 = 0 -- SafeHouse is 2D; validate on ground floor
        return cell:getGridSquare(rx1, ry1, z0) ~= nil
           and cell:getGridSquare(rx2, ry1, z0) ~= nil
           and cell:getGridSquare(rx1, ry2, z0) ~= nil
           and cell:getGridSquare(rx2, ry2, z0) ~= nil
    end

    if not rectCornersLoaded(x1, y1, x2, y2) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_AreaNotLoaded")
        return
    end

    if anyOtherPlayerInsideRect(playerObj, x1, y1, x2, y2, z) then
        sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_OtherPlayerInArea")
        return
    end

    -- Overlap check
    if SafeHouse and SafeHouse.getSafehouseList then
        local list = SafeHouse.getSafehouseList()
        if list then
            for i = 0, list:size() - 1 do
                local sh = list:get(i)
                if sh then
                    local ox1, oy1 = sh:getX(), sh:getY()
                    local ox2, oy2 = sh:getX2(), sh:getY2()
                    if BetterSafehouse.CustomClaim.rectsOverlap(x1, y1, x2, y2, ox1, oy1, ox2, oy2) then
                        sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_CollidesOtherSafehouse")
                        return
                    end
                end
            end
        end
    end

    -- Item requirement (authoritative) - only in item mode
    local inv = playerObj:getInventory()
    if cfg.mode == "item" then
        if not invHasFullType(inv, size.item) then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_NeedItem", { tostring(size.item) })
            return
        end

        if not invRemoveOneFullType(inv, size.item) then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_ConsumeItemFailed")
            return
        end
    end

    local sh, shErr = createSafehouse(x1, y1, w, h, username, playerObj)
    if not sh then
        -- Refund item if the engine/API refused the safehouse creation (item mode only).
        if cfg.mode == "item" then
            pcall(function()
                if inv and inv.AddItem then
                    local it = inv:AddItem(size.item)
                    if it and sendAddItemToContainer then
                        sendAddItemToContainer(inv, it)
                    end
                end
            end)
        end
        if shErr == "MAP_METADATA_MISSING" then
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_MapNoMetadata")
        else
            sendResult(playerObj, false, "IGUI_BetterSafehouse_Claim_CreateFailed")
        end
        return
    end

    local titleStr = "Safehouse " .. username .. " [" .. sizeLabel .. "]"
    if sh.setTitle then
        sh:setTitle(titleStr)
    end
    if sh.syncSafehouse then
        pcall(function() sh:syncSafehouse() end)
    end
    if sh.sync then
        pcall(function() sh:sync() end)
    end

    -- B42 MP: vanilla safehouses created from Lua may not replicate immediately to clients.
    -- We broadcast a lightweight packet so clients can update their local SafeHouse list + UI instantly.
    broadcastSafehouseAdded(x1, y1, w, h, username, titleStr)

    log("Claim OK user=" .. tostring(username) .. " size=" .. tostring(sizeLabel) ..
        " rect=("..x1..","..y1..") "..w.."x"..h)
    sendResult(playerObj, true, "IGUI_BetterSafehouse_Claim_Created", { tostring(sizeLabel) })
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= BetterSafehouse.CustomClaim.NET_MODULE then return end
    if command ~= "Claim" then return end
    BetterSafehouse_CustomClaim_Server._handleClaim(playerObj, args)
end

Events.OnClientCommand.Add(onClientCommand)
