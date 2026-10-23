--[[
    Better Safehouse (Build 42) - Optional PhunZones2 integration

    Safe when PhunZones2 is not installed:
      - no hard dependency in mod.info
      - runtime checks are wrapped and cached
]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse.PhunZones = BetterSafehouse.PhunZones or {}

local cachedCore = nil
local requireAttempted = false

local function trimText(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

local function asBoolean(value)
    if value == true then return true end
    if value == false or value == nil then return false end
    if type(value) == "number" then return value ~= 0 end
    if type(value) == "string" then
        local lowered = value:lower()
        return lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "on"
    end
    return false
end

local function getCore()
    if BetterSafehouse.PhunZones.isEnabled and not BetterSafehouse.PhunZones.isEnabled() then
        return nil
    end

    if cachedCore and cachedCore.getLocation and cachedCore.getIntersectingZones then
        return cachedCore
    end

    local live = rawget(_G, "PhunZones")
    if live and live.getLocation and live.getIntersectingZones then
        cachedCore = live
        return cachedCore
    end

    if not requireAttempted then
        requireAttempted = true
        pcall(require, "PhunZones/process")
        live = rawget(_G, "PhunZones")
        if live and live.getLocation and live.getIntersectingZones then
            cachedCore = live
            return cachedCore
        end
    end

    return nil
end

function BetterSafehouse.PhunZones.isEnabled()
    if BetterSafehouse.getSandboxBool then
        return BetterSafehouse.getSandboxBool("PhunZones2NoSafehouseBlock", true)
    end
    return true
end

function BetterSafehouse.PhunZones.getCore()
    return getCore()
end

function BetterSafehouse.PhunZones.isAvailable()
    return getCore() ~= nil
end

function BetterSafehouse.PhunZones.isNoSafehouseZone(zone)
    return type(zone) == "table" and asBoolean(zone.nosafehouse)
end

function BetterSafehouse.PhunZones.getBlockedZoneAt(squareOrX, y)
    local core = getCore()
    if not core or not core.getLocation or squareOrX == nil then return nil end

    local ok, zone = pcall(function()
        if y == nil then
            return core.getLocation(squareOrX)
        end
        return core.getLocation(squareOrX, y)
    end)

    if ok and BetterSafehouse.PhunZones.isNoSafehouseZone(zone) then
        return zone
    end

    return nil
end

function BetterSafehouse.PhunZones.getBlockedZoneInRect(x1, y1, x2, y2)
    local core = getCore()
    if not core or not core.getIntersectingZones then return nil end

    x1 = math.floor(tonumber(x1) or 0)
    y1 = math.floor(tonumber(y1) or 0)
    x2 = math.floor(tonumber(x2) or 0)
    y2 = math.floor(tonumber(y2) or 0)

    if x2 < x1 then x1, x2 = x2, x1 end
    if y2 < y1 then y1, y2 = y2, y1 end

    local ok, zones = pcall(function()
        return core.getIntersectingZones(x1, y1, x2, y2)
    end)

    if not ok or type(zones) ~= "table" then
        return nil
    end

    for _, zone in ipairs(zones) do
        if BetterSafehouse.PhunZones.isNoSafehouseZone(zone) then
            return zone
        end
    end

    return nil
end

function BetterSafehouse.PhunZones.getZoneLabel(zone)
    if type(zone) ~= "table" then
        return "PhunZones 2"
    end

    local label = trimText(zone.title)
        or trimText(zone.zone)
        or trimText(zone.key)
        or trimText(zone.region)

    if label and label ~= "_default" then
        return label
    end

    return "PhunZones 2"
end

function BetterSafehouse.PhunZones.getMessageArgs(zone)
    return { BetterSafehouse.PhunZones.getZoneLabel(zone) }
end

function BetterSafehouse.PhunZones.getBlockMessage(zone)
    local label = BetterSafehouse.PhunZones.getZoneLabel(zone)

    if getText then
        local ok, translated = pcall(getText, "IGUI_BetterSafehouse_PhunZones_NoSafehouse", label)
        if ok and translated and translated ~= "" and translated ~= "IGUI_BetterSafehouse_PhunZones_NoSafehouse" then
            return translated
        end
    end

    return "PhunZones 2 area (" .. tostring(label) .. "): safehouse blocked in this zone."
end

return BetterSafehouse.PhunZones
