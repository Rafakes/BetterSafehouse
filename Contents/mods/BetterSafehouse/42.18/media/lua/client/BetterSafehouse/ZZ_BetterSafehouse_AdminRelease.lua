local BetterSafehouse = require("BetterSafehouse/00_BetterSafehouse_Shared") or BetterSafehouse

local MODULE = "BetterSafehouse"
local COMMAND = "AdminReleaseSafehouse"

local function getLocalPlayer()
    if getPlayer then
        local ok, playerObj = pcall(getPlayer)
        if ok and playerObj then return playerObj end
    end
    if getSpecificPlayer then
        local ok, playerObj = pcall(function() return getSpecificPlayer(0) end)
        if ok and playerObj then return playerObj end
    end
    return nil
end

local function isAdminClient(playerObj)
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
        local ok, v = pcall(function() return playerObj:isAdmin() end)
        if ok and v == true then return true end
    end

    return false
end

local function isSafehouseOwner(sh, playerObj)
    if not sh or not playerObj then return false end

    if sh.isOwner then
        local ok, isOwner = pcall(function() return sh:isOwner(playerObj) end)
        if ok then return isOwner == true end
    end

    if sh.getOwner and playerObj.getUsername then
        local okOwner, owner = pcall(function() return sh:getOwner() end)
        local okUser, username = pcall(function() return playerObj:getUsername() end)
        if okOwner and okUser and owner and username then
            return tostring(owner) == tostring(username)
        end
    end

    return false
end

local function getSafehouseArgs(sh)
    if not sh or not sh.getX or not sh.getY or not sh.getW or not sh.getH then
        return nil
    end

    local okx, x = pcall(function() return sh:getX() end)
    local oky, y = pcall(function() return sh:getY() end)
    local okw, w = pcall(function() return sh:getW() end)
    local okh, h = pcall(function() return sh:getH() end)
    if not okx or not oky or not okw or not okh then
        return nil
    end

    local z = 0
    if sh.getZ then
        local okz, zz = pcall(function() return sh:getZ() end)
        if okz and type(zz) == "number" then z = zz end
    end

    return {
        x = x,
        y = y,
        w = w,
        h = h,
        z = z,
    }
end

local function shouldUseAdminRelease(sh, playerObj)
    if not sh or not playerObj then return false end
    if not BetterSafehouse.getSandboxBool or not BetterSafehouse.getSandboxBool("AdminsCanReleaseAnySafehouse", false) then
        return false
    end
    if not isAdminClient(playerObj) then
        return false
    end
    if isSafehouseOwner(sh, playerObj) then
        return false
    end
    return true
end

local function patchSendSafehouseRelease()
    if BetterSafehouse._adminReleasePatched then return end
    if type(sendSafehouseRelease) ~= "function" then return end

    BetterSafehouse._adminReleasePatched = true
    local vanillaSendSafehouseRelease = sendSafehouseRelease

    sendSafehouseRelease = function(sh, ...)
        local playerObj = getLocalPlayer()
        if shouldUseAdminRelease(sh, playerObj) then
            local args = getSafehouseArgs(sh)
            if args and sendClientCommand then
                sendClientCommand(playerObj, MODULE, COMMAND, args)
                return
            end
        end

        return vanillaSendSafehouseRelease(sh, ...)
    end
end

local function boot()
    patchSendSafehouseRelease()
end

Events.OnGameBoot.Add(boot)
Events.OnGameStart.Add(boot)

boot()
