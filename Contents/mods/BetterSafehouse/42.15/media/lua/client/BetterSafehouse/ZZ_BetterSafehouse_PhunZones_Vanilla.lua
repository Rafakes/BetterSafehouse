--[[
    Better Safehouse (Build 42) - PhunZones2 vanilla claim patch

    Optional integration kept separate on purpose:
      - easy to remove later
      - obeys Sandbox option BetterSafehouse.PhunZones2NoSafehouseBlock
]]

BetterSafehouse = BetterSafehouse or {}

local function attachTooltip(option, message)
    if not option or not message then return end
    if not ISWorldObjectContextMenu or not ISWorldObjectContextMenu.addToolTip then return end

    local tip = ISWorldObjectContextMenu.addToolTip()
    if not tip then return end
    if tip.setVisible then tip:setVisible(false) end
    tip.description = message
    option.toolTip = tip
end

local function getSquareFromWorldobjects(worldobjects)
    if not worldobjects then return nil end
    for _, wo in ipairs(worldobjects) do
        if wo and wo.getSquare then
            local ok, sq = pcall(function() return wo:getSquare() end)
            if ok and sq then return sq end
        end
    end
    return nil
end

local function getBuildingBoundsFromSquare(square)
    if not square then return nil end
    local building = square:getBuilding()
    if not building then return nil end
    local def = building:getDef()
    if not def then return nil end

    local x = def.getX and def:getX() or nil
    local y = def.getY and def:getY() or nil
    local w = def.getW and def:getW() or nil
    local h = def.getH and def:getH() or nil

    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return nil end

    return x, y, x + w - 1, y + h - 1
end

local function getBlockMessage(square)
    if not BetterSafehouse or not BetterSafehouse.PhunZones then return nil end
    if not BetterSafehouse.PhunZones.isEnabled or not BetterSafehouse.PhunZones.isEnabled() then return nil end

    local blockedZone = nil
    local x1, y1, x2, y2 = getBuildingBoundsFromSquare(square)
    if x1 and BetterSafehouse.PhunZones.getBlockedZoneInRect then
        blockedZone = BetterSafehouse.PhunZones.getBlockedZoneInRect(x1, y1, x2, y2)
    end
    if not blockedZone and BetterSafehouse.PhunZones.getBlockedZoneAt then
        blockedZone = BetterSafehouse.PhunZones.getBlockedZoneAt(square)
    end

    if blockedZone and BetterSafehouse.PhunZones.getBlockMessage then
        return BetterSafehouse.PhunZones.getBlockMessage(blockedZone)
    end

    return nil
end

local function onFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    if test then return end
    if not context or not context.options then return end
    if not ISWorldObjectContextMenu or not ISWorldObjectContextMenu.onTakeSafeHouse then return end

    local clickedSquare = getSquareFromWorldobjects(worldobjects)
    if not clickedSquare then return end

    local message = getBlockMessage(clickedSquare)
    if not message then return end

    for _, option in ipairs(context.options) do
        if option and option.onSelect == ISWorldObjectContextMenu.onTakeSafeHouse then
            if not option.notAvailable then
                option.notAvailable = true
                attachTooltip(option, message)
            end
            break
        end
    end
end

local function patchOnTakeSafeHouse()
    if not ISWorldObjectContextMenu or not ISWorldObjectContextMenu.onTakeSafeHouse then return end
    if ISWorldObjectContextMenu._BetterSafehousePhunZonesVanillaPatched then return end
    ISWorldObjectContextMenu._BetterSafehousePhunZonesVanillaPatched = true

    local previous = ISWorldObjectContextMenu.onTakeSafeHouse

    ISWorldObjectContextMenu.onTakeSafeHouse = function(worldobjects, square, player)
        local message = getBlockMessage(square)
        if message then
            local playerObj = type(player) == "number"
                and (getSpecificPlayer and getSpecificPlayer(player))
                or (getPlayer and getPlayer() or nil)
            if playerObj and playerObj.Say then
                pcall(function() playerObj:Say(message) end)
            end
            print("[BetterSafehouse][PhunZones2][Vanilla] blocked - " .. tostring(message))
            return false
        end

        return previous(worldobjects, square, player)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
Events.OnGameStart.Add(patchOnTakeSafeHouse)
