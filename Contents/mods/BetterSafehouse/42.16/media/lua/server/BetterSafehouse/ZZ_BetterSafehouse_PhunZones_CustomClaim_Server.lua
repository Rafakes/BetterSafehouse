--[[
    Better Safehouse (Build 42) - PhunZones2 custom claim server patch

    Optional integration kept separate on purpose:
      - easy to remove later
      - obeys Sandbox option BetterSafehouse.PhunZones2NoSafehouseBlock
]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse_CustomClaim_Server = BetterSafehouse_CustomClaim_Server or {}

local function _unpack(t)
    return (table.unpack or unpack)(t or {})
end

local function sendClaimBlocked(playerObj, key, args, fallbackMsg)
    if isServer and isServer() then
        sendServerCommand(playerObj, BetterSafehouse.CustomClaim.NET_MODULE, "ClaimResult", {
            ok = false,
            key = key,
            args = args,
            msg = fallbackMsg
        })
        return
    end

    local msg = fallbackMsg
    if key and getText then
        msg = getText(key, _unpack(args))
    end
    if playerObj and playerObj.Say and msg then
        playerObj:Say(msg)
    end
end

local function getSquareSafe(x, y, z)
    local cell = getCell and getCell() or nil
    if not cell then return nil end
    return cell:getGridSquare(x, y, z or 0)
end

local function resolveSize(args, cfg)
    if not args or not cfg then return nil end

    if cfg.mode == "item" then
        return BetterSafehouse.CustomClaim.getItemSizeById(args.sizeId, cfg)
    end

    if cfg.mode == "free" then
        if cfg.freeMode == BetterSafehouse.CustomClaim.FREE_MODE.All then
            return BetterSafehouse.CustomClaim.getFreeSizeByRequestId(args.sizeId, cfg)
        end
        return BetterSafehouse.CustomClaim.getFreeSizeFromSandbox(cfg)
    end

    return nil
end

local function getClaimRect(playerObj, sq, args, size)
    if not playerObj or not size then return nil end

    local psq = playerObj.getSquare and playerObj:getSquare() or nil
    local centerX, centerY, centerZ
    if psq then
        centerX, centerY, centerZ = psq:getX(), psq:getY(), psq:getZ()
    elseif sq then
        centerX, centerY, centerZ = sq:getX(), sq:getY(), sq:getZ()
    else
        return nil
    end

    local w = math.floor(tonumber(size.w) or 0)
    local h = math.floor(tonumber(size.h) or 0)
    if w <= 0 or h <= 0 then return nil end

    local x1 = math.floor(centerX - math.floor(w / 2))
    local y1 = math.floor(centerY - math.floor(h / 2))
    local x2 = x1 + w - 1
    local y2 = y1 + h - 1
    local z = centerZ or (args and args.z) or 0

    return x1, y1, x2, y2, z
end

local function wrapHandleClaim()
    if BetterSafehouse_CustomClaim_Server._BetterSafehousePhunZonesWrapped then return end
    if type(BetterSafehouse_CustomClaim_Server._handleClaim) ~= "function" then return end

    local original = BetterSafehouse_CustomClaim_Server._handleClaim
    BetterSafehouse_CustomClaim_Server._BetterSafehousePhunZonesWrapped = true

    BetterSafehouse_CustomClaim_Server._handleClaim = function(playerObj, args)
        if BetterSafehouse
            and BetterSafehouse.PhunZones
            and BetterSafehouse.PhunZones.isEnabled
            and BetterSafehouse.PhunZones.isEnabled()
            and BetterSafehouse.PhunZones.getBlockedZoneInRect
            and BetterSafehouse.PhunZones.getBlockMessage then

            local cfg = BetterSafehouse.CustomClaim
                and BetterSafehouse.CustomClaim.getConfig
                and BetterSafehouse.CustomClaim.getConfig()
                or nil
            local size = resolveSize(args, cfg)
            local sq = args and getSquareSafe(args.x, args.y, args.z) or nil
            local x1, y1, x2, y2 = getClaimRect(playerObj, sq, args, size)

            if x1 then
                local blockedZone = BetterSafehouse.PhunZones.getBlockedZoneInRect(x1, y1, x2, y2)
                if blockedZone then
                    local msgArgs = BetterSafehouse.PhunZones.getMessageArgs
                        and BetterSafehouse.PhunZones.getMessageArgs(blockedZone)
                        or nil
                    local fallbackMsg = BetterSafehouse.PhunZones.getBlockMessage(blockedZone)
                    sendClaimBlocked(playerObj, "IGUI_BetterSafehouse_PhunZones_NoSafehouse", msgArgs, fallbackMsg)
                    return
                end
            end
        end

        return original(playerObj, args)
    end
end

wrapHandleClaim()

if Events then
    if Events.OnInitGlobalModData then
        Events.OnInitGlobalModData.Add(wrapHandleClaim)
    end
    if Events.OnGameStart then
        Events.OnGameStart.Add(wrapHandleClaim)
    end
end
