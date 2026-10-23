--[[
    Better Safehouse (Build 42) - PhunZones2 custom claim UI patch

    Optional integration kept separate on purpose:
      - easy to remove later
      - obeys Sandbox option BetterSafehouse.PhunZones2NoSafehouseBlock
]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse.CustomClaim = BetterSafehouse.CustomClaim or {}

-- Keys that carry %1/%2 must be looked up together with their arguments,
-- otherwise Translator logs MissingFormatArgumentException on every call.
local function T(key, fallback, ...)
    if select("#", ...) > 0 then
        if getText then
            local ok, t = pcall(getText, key, ...)
            if ok and type(t) == "string" and t ~= "" and t ~= key and t:sub(1, 6) ~= "ERROR:" then
                return t
            end
        end
        return fallback
    end
    if getTextOrNull then
        local ok, t = pcall(getTextOrNull, key)
        if ok and t then return t end
    end
    if getText then
        local ok, t = pcall(getText, key)
        if ok and t and t ~= key then return t end
    end
    return fallback
end

local function attachTooltip(option, message)
    if not option or not message then return end
    if not ISWorldObjectContextMenu or not ISWorldObjectContextMenu.addToolTip then return end

    local tip = ISWorldObjectContextMenu.addToolTip()
    if not tip then return end
    if tip.setVisible then tip:setVisible(false) end
    tip.description = message
    option.toolTip = tip
end

local function clearSubMenu(option)
    if not option or not option.subOption or not option.subOption.options then return end
    for i = #option.subOption.options, 1, -1 do
        table.remove(option.subOption.options, i)
    end
    option.subOption = nil
end

local function submenuHasEnabled(sub)
    if not sub or not sub.options then return false end
    for _, opt in ipairs(sub.options) do
        if opt and not opt.isDivider then
            if (not opt.notAvailable) or opt.subOption then
                return true
            end
        end
    end
    return false
end

local function invHasFullType(container, fullType)
    if not container or not fullType then return false end
    local items = container.getItems and container:getItems() or nil
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

local function getPlayerObj(playerIndex)
    if type(playerIndex) == "number" and getSpecificPlayer then
        return getSpecificPlayer(playerIndex)
    end
    return playerIndex
end

local function getSquareFromWorldobjects(worldobjects, playerObj)
    if worldobjects then
        for _, wo in ipairs(worldobjects) do
            if wo and wo.getSquare then
                local sq = wo:getSquare()
                if sq then return sq end
            end
        end
    end
    if playerObj and playerObj.getSquare then
        return playerObj:getSquare()
    end
    return nil
end

local function getPhunZonesMessage(zone)
    if BetterSafehouse and BetterSafehouse.PhunZones and BetterSafehouse.PhunZones.getBlockMessage then
        return BetterSafehouse.PhunZones.getBlockMessage(zone)
    end
    local label = "PhunZones 2"
    if BetterSafehouse and BetterSafehouse.PhunZones and BetterSafehouse.PhunZones.getZoneLabel then
        local okLabel, value = pcall(BetterSafehouse.PhunZones.getZoneLabel, zone)
        if okLabel and value and value ~= "" then label = tostring(value) end
    end
    return T("IGUI_BetterSafehouse_PhunZones_NoSafehouse",
        "PhunZones 2 area (" .. label .. "): safehouse creation is blocked here.",
        label)
end

local function getBlockedZoneForSize(playerObj, size)
    if not playerObj or not size then return nil end
    if not BetterSafehouse or not BetterSafehouse.PhunZones then return nil end
    if not BetterSafehouse.PhunZones.isEnabled or not BetterSafehouse.PhunZones.isEnabled() then return nil end
    if not BetterSafehouse.PhunZones.getBlockedZoneInRect then return nil end

    local psq = playerObj.getSquare and playerObj:getSquare() or nil
    if not psq then return nil end

    local w = math.floor(tonumber(size.w) or 0)
    local h = math.floor(tonumber(size.h) or 0)
    if w <= 0 or h <= 0 then return nil end

    local cx, cy = psq:getX(), psq:getY()
    local x1 = math.floor(cx - math.floor(w / 2))
    local y1 = math.floor(cy - math.floor(h / 2))
    local x2 = x1 + w - 1
    local y2 = y1 + h - 1

    return BetterSafehouse.PhunZones.getBlockedZoneInRect(x1, y1, x2, y2)
end

local function buildEnabledOptionSizeMap(playerObj, cfg)
    local result = {}
    if not playerObj or not cfg then return result end

    local function add(label, size)
        if label and size then
            result[label] = size
        end
    end

    if cfg.mode == "free" then
        local FM = BetterSafehouse.CustomClaim.FREE_MODE
        if cfg.freeMode == FM.All then
            local list = BetterSafehouse.CustomClaim.getFreeSizesForAll(cfg) or {}
            for _, s in ipairs(list) do
                local label = s.custom
                    and (T("IGUI_BetterSafehouse_CustomClaim_CustomSafehouse", "Custom safehouse")
                        .. " (" .. tostring(s.label or "?") .. ")")
                    or tostring(s.label or s.id)
                add(label, s)
            end
        else
            local freeSize = BetterSafehouse.CustomClaim.getFreeSizeFromSandbox(cfg)
            if freeSize then
                add(T("IGUI_BetterSafehouse_CustomClaim_Free", "Claim custom safehouse")
                    .. " (" .. tostring(freeSize.label or "?") .. ")", freeSize)
            end
        end
        return result
    end

    if cfg.mode == "item" then
        local inv = playerObj.getInventory and playerObj:getInventory() or nil
        if not inv then return result end

        for _, s in ipairs(BetterSafehouse.CustomClaim.SIZES or {}) do
            if s and s.item and invHasFullType(inv, s.item) then
                add(tostring(s.label or s.id), s)
            end
        end

        if cfg.itemCustomEnabled then
            local cs = BetterSafehouse.CustomClaim.getCustomSizeFromSandbox("BetterSafehouse.customsafehouse")
            if cs and cs.item and invHasFullType(inv, cs.item) then
                add(T("IGUI_BetterSafehouse_CustomClaim_CustomSafehouse", "Custom safehouse")
                    .. " (" .. tostring(cs.label or "?") .. ")", cs)
            end
        end
    end

    return result
end

local function findRootOption(context)
    if not context or not context.options then return nil end
    local topLabel = T("IGUI_BetterSafehouse_CustomClaim_MenuTitle", "Better Safehouse")
    for _, opt in ipairs(context.options) do
        if opt and opt.name == topLabel and opt.subOption then
            return opt
        end
    end
    return nil
end

local function disableRootOption(rootOpt, message)
    if not rootOpt then return end
    rootOpt.notAvailable = true
    attachTooltip(rootOpt, message)
    clearSubMenu(rootOpt)
end

local function onFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    if test then return end
    if not BetterSafehouse or not BetterSafehouse.PhunZones then return end
    if not BetterSafehouse.PhunZones.isEnabled or not BetterSafehouse.PhunZones.isEnabled() then return end

    local cfg = BetterSafehouse.CustomClaim and BetterSafehouse.CustomClaim.getConfig and BetterSafehouse.CustomClaim.getConfig() or nil
    if not cfg or not cfg.enabled or cfg.conflict then return end

    local playerObj = getPlayerObj(playerIndex)
    if not playerObj or (playerObj.isDead and playerObj:isDead()) then return end

    local rootOpt = findRootOption(context)
    if not rootOpt then return end

    local clickedSq = getSquareFromWorldobjects(worldobjects, playerObj)
    if clickedSq and BetterSafehouse.PhunZones.getBlockedZoneAt then
        local blockedZone = BetterSafehouse.PhunZones.getBlockedZoneAt(clickedSq)
        if blockedZone then
            disableRootOption(rootOpt, getPhunZonesMessage(blockedZone))
            return
        end
    end

    local sizeMap = buildEnabledOptionSizeMap(playerObj, cfg)
    if not rootOpt.subOption or not rootOpt.subOption.options then return end

    local firstBlockedZone = nil
    for _, opt in ipairs(rootOpt.subOption.options) do
        if opt and not opt.notAvailable and opt.name then
            local size = sizeMap[opt.name]
            if size then
                local blockedZone = getBlockedZoneForSize(playerObj, size)
                if blockedZone then
                    opt.notAvailable = true
                    attachTooltip(opt, getPhunZonesMessage(blockedZone))
                    if not firstBlockedZone then
                        firstBlockedZone = blockedZone
                    end
                end
            end
        end
    end

    if firstBlockedZone and not submenuHasEnabled(rootOpt.subOption) then
        disableRootOption(rootOpt, getPhunZonesMessage(firstBlockedZone))
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
