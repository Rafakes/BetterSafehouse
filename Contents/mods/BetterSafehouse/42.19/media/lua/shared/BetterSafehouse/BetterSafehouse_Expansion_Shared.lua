BetterSafehouse = BetterSafehouse or {}
BetterSafehouse.Expansion = BetterSafehouse.Expansion or {}

local RSE = BetterSafehouse.Expansion

RSE.NET_MODULE = "BetterSafehouse"
RSE.MOD_DATA_KEY = "BetterSafehouseExpansionState"
-- Hand-verified real road tiles only — see the comment above
-- isAsphaltRoadFloor() in BetterSafehouse_Expansion_Server.lua for why this
-- can't be widened by pattern/property matching (driveway/garage tiles
-- share the exact same textures with no distinguishing flag). 85 and 96
-- added after in-game confirmation; extend the same way, one verified name
-- at a time, never by guessing a range.
RSE.DEFAULT_BLOCKED_ROAD_TILE_NAMES = "blends_street_01_1,blends_street_01_2,blends_street_01_3,blends_street_01_4,blends_street_01_8,blends_street_01_9,blends_street_01_10,blends_street_01_11,blends_street_01_17,blends_street_01_18A,blends_street_01_19,blends_street_01_20,blends_street_01_24,blends_street_01_25,blends_street_01_26,blends_street_01_27E,blends_street_01_33,blends_street_01_34,blends_street_01_35,blends_street_01_36,blends_street_01_40,blends_street_01_41,blends_street_01_42,blends_street_01_43,blends_street_01_49A,blends_street_01_50,blends_street_01_51l,blends_street_01_52,blends_street_01_65,blends_street_01_66A,blends_street_01_67,blends_street_01_68j,blends_street_01_81A,blends_street_01_82,blends_street_01_83,blends_street_01_84,blends_street_01_85,blends_street_01_96,blends_street_01_97,blends_street_01_98,blends_street_01_99,blends_street_01_100"
RSE.ACTIONS = {
    N = true,
    S = true,
    E = true,
    W = true,
    NW = true,
    NE = true,
    SW = true,
    SE = true,
    ALL = true,
}
RSE.RESIZE_MODES = {
    expand = true,
    shrink = true,
}
RSE.MAX_RESIZE_STEPS = 200
-- Admins always get unlimited expansion, regardless of sandbox caps. A large
-- finite number is used instead of math.huge so it survives client/server
-- command serialization cleanly.
RSE.UNLIMITED_TILES = 999999999

local function unpackArgs(values)
    return (table.unpack or unpack)(values or {})
end

local function sbGetOptionValue(fullName)
    if not getSandboxOptions then return nil end
    local opts = getSandboxOptions()
    if not opts or not opts.getOptionByName then return nil end

    local ok, opt = pcall(function()
        return opts:getOptionByName(fullName)
    end)
    if not ok or not opt then return nil end

    if opt.getValue then
        local okValue, value = pcall(function()
            return opt:getValue()
        end)
        if okValue then
            return value
        end
    end

    return nil
end

function RSE.getSandboxStoredValue(modKey)
    if SandboxVars and SandboxVars.BetterSafehouse then
        return SandboxVars.BetterSafehouse[modKey]
    end

    return nil
end

function RSE.trimString(value)
    value = tostring(value or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

function RSE.stripWrappingQuotes(value)
    value = RSE.trimString(value)
    if string.len(value) >= 2 then
        local first = string.sub(value, 1, 1)
        local last = string.sub(value, -1)
        if (first == "\"" and last == "\"") or (first == "'" and last == "'") then
            return RSE.trimString(string.sub(value, 2, -2))
        end
    end

    return value
end

function RSE.normalizeListString(value)
    return RSE.stripWrappingQuotes(value)
end

function RSE.normalizeListItem(value)
    return RSE.stripWrappingQuotes(value)
end

function RSE.lowerString(value)
    return string.lower(RSE.trimString(value))
end

function RSE.upperString(value)
    return string.upper(RSE.trimString(value))
end

function RSE.startsWith(value, prefix)
    value = tostring(value or "")
    prefix = tostring(prefix or "")
    return prefix ~= "" and string.sub(value, 1, string.len(prefix)) == prefix
end

local function isMissingText(value, key)
    if type(value) ~= "string" or value == "" then return true end
    if value == key then return true end
    return string.sub(value, 1, 6) == "ERROR:"
end

local function formatFallbackText(text, ...)
    local result = tostring(text or "")
    for i = 1, select("#", ...) do
        result = result:gsub("%%" .. tostring(i), tostring(select(i, ...)))
    end
    return result
end

-- Translator formats the entry on every lookup, so a key that carries %1/%2
-- must be requested together with its arguments. Probing it first (the old
-- getTextOrNull(key) existence check) makes the game log
-- MissingFormatArgumentException: "Missing arguments for ...".
function RSE.getTextOrFallback(key, fallback, ...)
    local args = { ... }

    if select("#", ...) > 0 then
        if getText then
            local okText, translated = pcall(function()
                return getText(key, unpackArgs(args))
            end)
            if okText and not isMissingText(translated, key) then
                return translated
            end
        end
    elseif getTextOrNull then
        local okExisting, existing = pcall(function()
            return getTextOrNull(key)
        end)
        if okExisting and not isMissingText(existing, key) then
            return existing
        end
    end

    return formatFallbackText(fallback or key, ...)
end

function RSE.getSandboxBool(modKey, default)
    if SandboxVars and SandboxVars.BetterSafehouse and SandboxVars.BetterSafehouse[modKey] ~= nil then
        return SandboxVars.BetterSafehouse[modKey] == true
    end

    local value = sbGetOptionValue("BetterSafehouse." .. tostring(modKey))
    if value ~= nil then
        return value == true
    end

    return default == true
end

function RSE.getSandboxInt(modKey, default)
    if SandboxVars and SandboxVars.BetterSafehouse and SandboxVars.BetterSafehouse[modKey] ~= nil then
        local value = SandboxVars.BetterSafehouse[modKey]
        if type(value) == "number" then
            return math.floor(value)
        end
    end

    local value = sbGetOptionValue("BetterSafehouse." .. tostring(modKey))
    if type(value) == "number" then
        return math.floor(value)
    end

    return math.floor(default or 0)
end

function RSE.getSandboxString(modKey, default)
    if SandboxVars and SandboxVars.BetterSafehouse and SandboxVars.BetterSafehouse[modKey] ~= nil then
        local value = SandboxVars.BetterSafehouse[modKey]
        if type(value) == "string" then
            return value
        end
    end

    local value = sbGetOptionValue("BetterSafehouse." .. tostring(modKey))
    if type(value) == "string" then
        return value
    end

    return tostring(default or "")
end

function RSE.isEnabled()
    return RSE.getSandboxBool("ExpansionEnabled", true)
end

function RSE.normalizeResizeSteps(stepCount, allowZero)
    local value = math.floor(tonumber(stepCount) or 0)
    local minimum = allowZero and 0 or 1

    if value < minimum then
        return nil
    end

    local maximum = math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200))
    if value > maximum then
        value = maximum
    end

    return value
end

function RSE.getRoleMaxExtraTilesFromOriginal()
    local value = RSE.getSandboxInt("ExpansionRoleMaxExtraTilesFromOriginal", 600)
    if value < 0 then value = 0 end
    return value
end

function RSE.getRoleMaxTotalTiles()
    local value = RSE.getSandboxInt("ExpansionRoleMaxTotalTiles", 500)
    if value < 0 then value = 0 end
    return value
end

function RSE.isRoleSystemEnabled()
    return RSE.getSandboxBool("ExpansionRoleSystemEnabled", true)
end

function RSE.getUserMaxBorderTilesFromOriginal()
    local value = RSE.getSandboxInt("ExpansionUserMaxBorderTilesFromOriginal", 1)
    if value < 0 then value = 0 end
    return value
end

function RSE.getUserMaxTotalTiles()
    local value = RSE.getSandboxInt("ExpansionUserMaxTotalTiles", 500)
    if value < 0 then value = 0 end
    return value
end

function RSE.isUserBorderModeEnabled()
    return RSE.getSandboxBool("ExpansionUserBorderModeEnabled", true)
end

function RSE.isUserAdvancedModeEnabled()
    return RSE.getSandboxBool("ExpansionUserAdvancedModeEnabled", false)
end

function RSE.isUserFlowUsingAdvancedMode()
    return RSE.isUserAdvancedModeEnabled()
end

function RSE.getUserAdvancedMaxExtraTilesFromOriginal()
    local value = RSE.getSandboxInt("ExpansionUserMaxExtraTilesFromOriginal", 600)
    if value < 0 then value = 0 end
    return value
end

function RSE.getMaxTotalTilesForFlow(resizeFlow, playerObj)
    if playerObj and RSE.isStrictAdmin(playerObj) then
        return 0 -- 0 = no cap, per this system's own convention
    end

    if resizeFlow == "role" then
        return RSE.getRoleMaxTotalTiles()
    end
    return RSE.getUserMaxTotalTiles()
end

function RSE.shouldBlockAsphaltRoads()
    return RSE.getSandboxBool("ExpansionBlockRoadTiles", false)
end

function RSE.getBlockedRoadTileNamesRaw()
    return RSE.getSandboxString("ExpansionBlockedRoadTileNames", "")
end

local function addTileNamesToLookup(lookup, rawList)
    local raw = RSE.normalizeListString(rawList)
    for tileName in string.gmatch(raw, "[^,\r\n;]+") do
        local normalized = RSE.lowerString(RSE.normalizeListItem(tileName))
        if normalized ~= "" then
            lookup[normalized] = true
        end
    end
end

function RSE.getBlockedRoadTileLookup()
    local lookup = {}
    addTileNamesToLookup(lookup, RSE.DEFAULT_BLOCKED_ROAD_TILE_NAMES)
    addTileNamesToLookup(lookup, RSE.getBlockedRoadTileNamesRaw())
    return lookup
end

function RSE.isBlockedRoadTileName(spriteName)
    local normalized = RSE.lowerString(spriteName)
    if normalized == "" then
        return false
    end

    local lookup = RSE.getBlockedRoadTileLookup()
    return lookup[normalized] == true
end

function RSE.getAllowedRoleNamesRaw()
    return RSE.getSandboxString("ExpansionAllowedRoleNames", "VIP")
end

function RSE.isUserRoleName(roleName)
    return RSE.lowerString(roleName) == "user"
end

function RSE.getAllowedRoleLookup()
    local lookup = {}
    local raw = RSE.normalizeListString(RSE.getAllowedRoleNamesRaw())

    for roleName in string.gmatch(tostring(raw or ""), "[^,;]+") do
        local normalized = RSE.lowerString(RSE.normalizeListItem(roleName))
        if normalized ~= "" and not RSE.isUserRoleName(normalized) then
            lookup[normalized] = true
        end
    end

    return lookup
end

function RSE.getSupporterRoleLookup()
    return RSE.getAllowedRoleLookup()
end

function RSE.isRoleNameAllowed(roleName)
    local normalized = RSE.lowerString(roleName)
    if normalized == "" then return false end

    local lookup = RSE.getAllowedRoleLookup()
    return lookup[normalized] == true
end

function RSE.isSupporterRoleName(roleName)
    local normalized = RSE.lowerString(roleName)
    if normalized == "" or RSE.isUserRoleName(normalized) then
        return false
    end

    local lookup = RSE.getSupporterRoleLookup()
    return lookup[normalized] == true
end

function RSE.getEffectiveMaxExtraTilesForRole(roleName)
    if RSE.isSupporterRoleName(roleName) then
        return RSE.getRoleMaxExtraTilesFromOriginal()
    end

    return nil
end

function RSE.getResizeFlowForRoleName(roleName)
    if RSE.isUserRoleName(roleName) then
        if RSE.isUserBorderModeEnabled() or RSE.isUserAdvancedModeEnabled() then
            return "user"
        end
        return nil
    end

    if RSE.isSupporterRoleName(roleName) then
        if RSE.isRoleSystemEnabled() then
            return "role"
        end
        return nil
    end

    return nil
end

function RSE.getPlayerResizeFlow(playerObj)
    local roleName = RSE.getPlayerRoleName(playerObj)
    if not roleName or roleName == "" then
        return nil
    end

    return RSE.getResizeFlowForRoleName(roleName)
end

function RSE.getPlayerResizeFlowForSafehouse(playerObj, sh)
    if RSE.isStrictAdmin(playerObj) then
        return "role"
    end

    return RSE.getPlayerResizeFlow(playerObj)
end

function RSE.getEffectiveMaxExtraTilesForPlayer(playerObj)
    if RSE.isStrictAdmin(playerObj) then
        return RSE.UNLIMITED_TILES
    end

    return RSE.getEffectiveMaxExtraTilesForRole(RSE.getPlayerRoleName(playerObj))
end

function RSE.isPlayerUserBorderExpansionActive(playerObj)
    return RSE.getPlayerResizeFlow(playerObj) == "user"
end

function RSE.isPlayerUserBorderExpansionActiveForSafehouse(playerObj, sh)
    return RSE.getPlayerResizeFlowForSafehouse(playerObj, sh) == "user"
end

function RSE.getBorderExpansionFromBase(baseRect, rect)
    if not RSE.rectIsValid(baseRect) or not RSE.rectIsValid(rect) then
        return nil
    end

    local left = baseRect.x - rect.x
    local top = baseRect.y - rect.y
    local right = rect.x2 - baseRect.x2
    local bottom = rect.y2 - baseRect.y2

    return {
        left = left,
        top = top,
        right = right,
        bottom = bottom,
        max = math.max(left, top, right, bottom),
    }
end

function RSE.getPlayerUsername(playerObj)
    if not playerObj then return nil end
    if playerObj.getUsername then
        local ok, username = pcall(function()
            return playerObj:getUsername()
        end)
        if ok and username and tostring(username) ~= "" then
            return tostring(username)
        end
    end
    return nil
end

function RSE.getPlayerRole(playerObj)
    if not playerObj then return nil end

    if playerObj.getRole then
        local ok, role = pcall(function()
            return playerObj:getRole()
        end)
        if ok and role then
            return role
        end
    end

    if playerObj.role then
        return playerObj.role
    end

    return nil
end

function RSE.getPlayerRoleName(playerObj)
    local role = RSE.getPlayerRole(playerObj)
    if not role then return nil end

    if role.getName then
        local ok, name = pcall(function()
            return role:getName()
        end)
        if ok and name and tostring(name) ~= "" then
            return tostring(name)
        end
    end

    if role.name ~= nil and tostring(role.name) ~= "" then
        return tostring(role.name)
    end

    return nil
end

function RSE.isPlayerRoleAllowed(playerObj)
    return RSE.getPlayerResizeFlow(playerObj) ~= nil
end

function RSE.isStrictAdmin(playerObj)
    if not playerObj then return false end

    if playerObj.isAccessLevel then
        local okAdmin, isAdmin = pcall(function()
            return playerObj:isAccessLevel("Admin")
        end)
        if okAdmin and isAdmin == true then
            return true
        end
    end

    if playerObj.getAccessLevel then
        local okLevel, level = pcall(function()
            return playerObj:getAccessLevel()
        end)
        if okLevel and level and RSE.lowerString(level) == "admin" then
            return true
        end
    end

    return false
end

function RSE.playerHasSafehouseBypass(playerObj)
    if not playerObj then return false end

    if RSE.isStrictAdmin(playerObj) then
        return true
    end

    if playerObj.isAccessLevel then
        local okGM, isGM = pcall(function()
            return playerObj:isAccessLevel("GM")
        end)
        if okGM and isGM == true then
            return true
        end
    end

    if playerObj.getAccessLevel then
        local okLevel, level = pcall(function()
            return playerObj:getAccessLevel()
        end)
        if okLevel and level then
            level = RSE.lowerString(level)
            if level == "admin" or level == "gm" then
                return true
            end
        end
    end

    local role = RSE.getPlayerRole(playerObj)
    if role and role.hasCapability and Capability and Capability.CanGoInsideSafehouses then
        local okCap, hasCap = pcall(function()
            return role:hasCapability(Capability.CanGoInsideSafehouses)
        end)
        if okCap and hasCap == true then
            return true
        end
    end

    return false
end

function RSE.getSafehouseList()
    if not SafeHouse then return nil end

    if SafeHouse.getSafehouseList then
        local ok, list = pcall(function()
            return SafeHouse.getSafehouseList()
        end)
        if ok then return list end
    end

    if SafeHouse.getSafeHouseList then
        local ok, list = pcall(function()
            return SafeHouse.getSafeHouseList()
        end)
        if ok then return list end
    end

    return nil
end

function RSE.eachSafehouse(list)
    if not list then
        return function() return nil end
    end

    if type(list) == "table" then
        return ipairs(list)
    end

    local okSize, size = pcall(function()
        return list:size()
    end)
    if okSize and type(size) == "number" and size > 0 then
        local index = 0
        return function()
            if index >= size then
                return nil
            end

            local value = nil
            local okGet = pcall(function()
                value = list:get(index)
            end)
            index = index + 1

            if okGet then
                return index, value
            end

            return nil
        end
    end

    return function() return nil end
end

function RSE.makeRect(x, y, w, h)
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)

    return {
        x = x,
        y = y,
        w = w,
        h = h,
        x2 = x + w,
        y2 = y + h,
    }
end

function RSE.copyRect(rect)
    if not rect then return nil end
    return RSE.makeRect(rect.x, rect.y, rect.w, rect.h)
end

function RSE.rectIsValid(rect)
    return rect and rect.w > 0 and rect.h > 0
end

function RSE.rectFromSafehouse(sh)
    if not sh or not sh.getX or not sh.getY or not sh.getW or not sh.getH then
        return nil
    end

    local okX, x = pcall(function() return sh:getX() end)
    local okY, y = pcall(function() return sh:getY() end)
    local okW, w = pcall(function() return sh:getW() end)
    local okH, h = pcall(function() return sh:getH() end)
    if not okX or not okY or not okW or not okH then
        return nil
    end

    return RSE.makeRect(x, y, w, h)
end

function RSE.getSafehouseArea(rect)
    if not rect then return 0 end
    return math.max(0, math.floor(tonumber(rect.w) or 0)) * math.max(0, math.floor(tonumber(rect.h) or 0))
end

function RSE.getExtraTilesBeyondBaseArea(baseArea, rect)
    baseArea = math.max(0, math.floor(tonumber(baseArea) or 0))
    local extraTiles = RSE.getSafehouseArea(rect) - baseArea
    if extraTiles < 0 then
        extraTiles = 0
    end
    return extraTiles
end

function RSE.makeSafehouseKey(x, y, w, h)
    if type(x) == "table" then
        local rect = x
        return string.format("%d:%d:%d:%d", rect.x or 0, rect.y or 0, rect.w or 0, rect.h or 0)
    end

    return string.format("%d:%d:%d:%d",
        math.floor(tonumber(x) or 0),
        math.floor(tonumber(y) or 0),
        math.floor(tonumber(w) or 0),
        math.floor(tonumber(h) or 0))
end

function RSE.rectContainsPoint(rect, x, y)
    if not rect then return false end
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    return x >= rect.x and x < rect.x2 and y >= rect.y and y < rect.y2
end

function RSE.rectsOverlap(a, b)
    if not a or not b then return false end
    return a.x < b.x2 and a.x2 > b.x and a.y < b.y2 and a.y2 > b.y
end

function RSE.safehouseMatchesRect(sh, x, y, w, h)
    local wanted = x
    if type(x) ~= "table" then
        wanted = RSE.makeRect(x, y, w, h)
    end

    local rect = RSE.rectFromSafehouse(sh)
    if not rect or not wanted then return false end

    return rect.x == wanted.x and rect.y == wanted.y and rect.w == wanted.w and rect.h == wanted.h
end

function RSE.findSafehouseByRect(x, y, w, h)
    local wanted = x
    if type(x) ~= "table" then
        wanted = RSE.makeRect(x, y, w, h)
    end

    local list = RSE.getSafehouseList()
    if not list then return nil end

    for _, sh in RSE.eachSafehouse(list) do
        if RSE.safehouseMatchesRect(sh, wanted) then
            return sh
        end
    end

    return nil
end

function RSE.normalizeResizeMode(mode)
    local normalized = RSE.lowerString(mode)
    if normalized == "" then
        return "expand"
    end

    if RSE.RESIZE_MODES[normalized] then
        return normalized
    end

    return nil
end

function RSE.isShrinkMode(mode)
    return RSE.normalizeResizeMode(mode) == "shrink"
end

function RSE.calcResizedRect(rect, action, step, mode)
    if not RSE.rectIsValid(rect) then return nil end

    step = math.floor(tonumber(step) or 0)
    action = tostring(action or "")
    mode = RSE.normalizeResizeMode(mode)

    if step <= 0 or not RSE.ACTIONS[action] or not mode then
        return nil
    end

    local x = rect.x
    local y = rect.y
    local w = rect.w
    local h = rect.h

    if mode == "expand" then
        if action == "N" then
            y = y - step
            h = h + step
        elseif action == "S" then
            h = h + step
        elseif action == "E" then
            w = w + step
        elseif action == "W" then
            x = x - step
            w = w + step
        elseif action == "NW" then
            x = x - step
            y = y - step
            w = w + step
            h = h + step
        elseif action == "NE" then
            y = y - step
            w = w + step
            h = h + step
        elseif action == "SW" then
            x = x - step
            w = w + step
            h = h + step
        elseif action == "SE" then
            w = w + step
            h = h + step
        elseif action == "ALL" then
            x = x - step
            y = y - step
            w = w + (step * 2)
            h = h + (step * 2)
        end
    else
        if action == "N" then
            y = y + step
            h = h - step
        elseif action == "S" then
            h = h - step
        elseif action == "E" then
            w = w - step
        elseif action == "W" then
            x = x + step
            w = w - step
        elseif action == "NW" then
            x = x + step
            y = y + step
            w = w - step
            h = h - step
        elseif action == "NE" then
            y = y + step
            w = w - step
            h = h - step
        elseif action == "SW" then
            x = x + step
            w = w - step
            h = h - step
        elseif action == "SE" then
            w = w - step
            h = h - step
        elseif action == "ALL" then
            x = x + step
            y = y + step
            w = w - (step * 2)
            h = h - (step * 2)
        end
    end

    local newRect = RSE.makeRect(x, y, w, h)
    if not RSE.rectIsValid(newRect) then
        return nil
    end

    return newRect
end

-- Generalizes calcResizedRect's cardinal deltas to an arbitrary combination of
-- sides (N/S/E/W independently toggled), used by the role/advanced-user flows
-- so a player can grow/shrink several sides in a single request. N and S only
-- ever touch the height from opposite ends, and E and W only ever touch the
-- width from opposite ends, so any combination composes without conflict.
function RSE.calcMultiSideResizedRect(rect, sides, amount, mode)
    if not RSE.rectIsValid(rect) or type(sides) ~= "table" then return nil end

    amount = math.floor(tonumber(amount) or 0)
    mode = RSE.normalizeResizeMode(mode)

    if amount <= 0 or not mode then
        return nil
    end

    if not (sides.N or sides.S or sides.E or sides.W) then
        return nil
    end

    local sign = (mode == "shrink") and -1 or 1
    local x = rect.x
    local y = rect.y
    local w = rect.w
    local h = rect.h

    if sides.N then
        y = y - (sign * amount)
        h = h + (sign * amount)
    end
    if sides.S then
        h = h + (sign * amount)
    end
    if sides.W then
        x = x - (sign * amount)
        w = w + (sign * amount)
    end
    if sides.E then
        w = w + (sign * amount)
    end

    local newRect = RSE.makeRect(x, y, w, h)
    if not RSE.rectIsValid(newRect) then
        return nil
    end

    return newRect
end

-- Per-side variant of calcMultiSideResizedRect: each side carries its own tile
-- count instead of one shared amount applied to whichever sides are toggled.
-- Still composes without conflict for the same reason (N/S only ever touch
-- height, E/W only ever touch width, from opposite ends).
function RSE.calcPerSideResizedRect(rect, amounts, mode)
    if not RSE.rectIsValid(rect) or type(amounts) ~= "table" then return nil end

    mode = RSE.normalizeResizeMode(mode)
    if not mode then return nil end

    local n = math.max(0, math.floor(tonumber(amounts.N) or 0))
    local s = math.max(0, math.floor(tonumber(amounts.S) or 0))
    local e = math.max(0, math.floor(tonumber(amounts.E) or 0))
    local w = math.max(0, math.floor(tonumber(amounts.W) or 0))

    if n <= 0 and s <= 0 and e <= 0 and w <= 0 then
        return nil
    end

    local sign = (mode == "shrink") and -1 or 1
    local x = rect.x
    local y = rect.y
    local width = rect.w
    local height = rect.h

    if n > 0 then
        y = y - (sign * n)
        height = height + (sign * n)
    end
    if s > 0 then
        height = height + (sign * s)
    end
    if w > 0 then
        x = x - (sign * w)
        width = width + (sign * w)
    end
    if e > 0 then
        width = width + (sign * e)
    end

    local newRect = RSE.makeRect(x, y, width, height)
    if not RSE.rectIsValid(newRect) then
        return nil
    end

    return newRect
end

function RSE.forEachRectTile(rect, callback)
    if not RSE.rectIsValid(rect) or not callback then
        return false
    end

    for y = rect.y, rect.y2 - 1 do
        for x = rect.x, rect.x2 - 1 do
            if callback(x, y) == false then
                return false
            end
        end
    end

    return true
end

function RSE.forEachAddedTile(oldRect, newRect, callback)
    if not RSE.rectIsValid(newRect) or not callback then
        return false
    end

    return RSE.forEachRectTile(newRect, function(x, y)
        if not oldRect or not RSE.rectContainsPoint(oldRect, x, y) then
            return callback(x, y)
        end
        return true
    end)
end

function RSE.forEachRemovedTile(oldRect, newRect, callback)
    if not RSE.rectIsValid(oldRect) or not callback then
        return false
    end

    return RSE.forEachRectTile(oldRect, function(x, y)
        if not newRect or not RSE.rectContainsPoint(newRect, x, y) then
            return callback(x, y)
        end
        return true
    end)
end

function RSE.forEachPreviewTile(oldRect, newRect, mode, callback)
    if RSE.isShrinkMode(mode) then
        return RSE.forEachRemovedTile(oldRect, newRect, callback)
    end

    return RSE.forEachAddedTile(oldRect, newRect, callback)
end

function RSE.countAddedTiles(oldRect, newRect)
    local count = 0
    RSE.forEachAddedTile(oldRect, newRect, function()
        count = count + 1
        return true
    end)
    return count
end

function RSE.countRemovedTiles(oldRect, newRect)
    local count = 0
    RSE.forEachRemovedTile(oldRect, newRect, function()
        count = count + 1
        return true
    end)
    return count
end

function RSE.countPreviewTiles(oldRect, newRect, mode)
    if RSE.isShrinkMode(mode) then
        return RSE.countRemovedTiles(oldRect, newRect)
    end

    return RSE.countAddedTiles(oldRect, newRect)
end

function RSE.safehouseHasUser(sh, username)
    username = RSE.trimString(username)
    if not sh or username == "" then return false end

    if sh.getOwner then
        local okOwner, owner = pcall(function()
            return sh:getOwner()
        end)
        if okOwner and owner == username then
            return true
        end
    end

    if sh.hasPlayer then
        local okHas, hasPlayer = pcall(function()
            return sh:hasPlayer(username)
        end)
        if okHas and hasPlayer == true then
            return true
        end
    end

    if sh.playerAllowed then
        local okAllowed, allowed = pcall(function()
            return sh:playerAllowed(username)
        end)
        if okAllowed and allowed == true then
            return true
        end
    end

    if sh.getPlayers then
        local okPlayers, players = pcall(function()
            return sh:getPlayers()
        end)
        if okPlayers and players then
            if type(players) == "table" then
                for _, value in ipairs(players) do
                    if tostring(value) == username then
                        return true
                    end
                end
            elseif players.size and players.get then
                for index = 0, players:size() - 1 do
                    if tostring(players:get(index)) == username then
                        return true
                    end
                end
            end
        end
    end

    return false
end

function RSE.isSafehouseOwner(playerObj, sh)
    local username = RSE.getPlayerUsername(playerObj)
    if not username or not sh or not sh.getOwner then
        return false
    end

    local ok, owner = pcall(function()
        return sh:getOwner()
    end)
    return ok and owner == username
end

function RSE.canResizeSafehouse(playerObj, sh)
    return RSE.isSafehouseOwner(playerObj, sh) or RSE.isStrictAdmin(playerObj)
end

return RSE
