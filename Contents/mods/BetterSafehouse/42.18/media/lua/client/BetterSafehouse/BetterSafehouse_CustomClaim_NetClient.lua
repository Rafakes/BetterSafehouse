--[[
    Better Safehouse (Build 42) - Custom Claim system (Client Net)

    Purpose:
      - Receive server-authoritative results
      - Update local SafeHouse list immediately (UI + client-side checks) when a safehouse is created on server
--]]

local function findSafehouseByRect(x1, y1, w, h)
    if not SafeHouse or not SafeHouse.getSafehouseList then return nil end
    local ok, list = pcall(function() return SafeHouse.getSafehouseList() end)
    if not ok or not list then return nil end

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

local function tryRefreshSafehouseUI()
    -- We keep this defensive: UI classes may change between B42 patches.
    if triggerEvent then
        pcall(function() triggerEvent("OnSafehousesChanged") end)
    end

    local function tryCall(obj, method)
        if obj and obj[method] then
            pcall(function() obj[method](obj) end)
            return true
        end
        return false
    end

    -- Common candidates (best-effort)
    local candidates = {}

    if ISSafehousesListUI and ISSafehousesListUI.instance then
        table.insert(candidates, ISSafehousesListUI.instance)
    end
    if ISAdminPanelUI and ISAdminPanelUI.instance then
        table.insert(candidates, ISAdminPanelUI.instance)
    end
    if ISSafehouseUI and ISSafehouseUI.instance then
        table.insert(candidates, ISSafehouseUI.instance)
    end

    for _, ui in ipairs(candidates) do
        tryCall(ui, "populateList")
        tryCall(ui, "populate")
        tryCall(ui, "refresh")
        tryCall(ui, "update")
    end
end

local function applySafehouseAdded(args)
    if not args then return end

    local x = math.floor(tonumber(args.x) or 0)
    local y = math.floor(tonumber(args.y) or 0)
    local w = math.floor(tonumber(args.w) or 0)
    local h = math.floor(tonumber(args.h) or 0)
    local owner = args.owner

    if not SafeHouse then return end

    -- Avoid duplicates
    local sh = findSafehouseByRect(x, y, w, h)
    if not sh then
        local fn = SafeHouse.addSafeHouse or SafeHouse.addSafehouse
        if fn then
            -- B42.13.x:
            -- SafeHouse.addSafeHouse does NOT accept a 6th boolean argument anymore.
            -- Calling it with 6 args spams "No implementation found" exceptions on client/server logs.
            pcall(function() return fn(x, y, w, h, owner) end)
        end
        sh = findSafehouseByRect(x, y, w, h)
    end

    if sh and args.title and sh.setTitle then
        pcall(function() sh:setTitle(args.title) end)
    end

    local playerObj = getPlayer and getPlayer() or nil
    local username = playerObj and playerObj.getUsername and playerObj:getUsername() or nil
    if sh and playerObj and username and owner and tostring(owner) == tostring(username) then
        if BetterSafehouse.activateViewerForSafehouse then
            pcall(function() BetterSafehouse.activateViewerForSafehouse(sh, playerObj) end)
        end
    end

    tryRefreshSafehouseUI()
end

local function sayLocal(msg)
    local playerObj = getPlayer()
    if playerObj and playerObj.Say then
        playerObj:Say(msg)
    else
        print("[BetterSafehouse][CustomClaim] " .. tostring(msg))
    end
end

local function onServerCommand(module, command, args)
    if module ~= BetterSafehouse.CustomClaim.NET_MODULE then return end

    if command == "ClaimResult" then
        local ok = args and args.ok
        local msg = ""
        if args and args.key then
            msg = getText(args.key, (table.unpack or unpack)(args.args or {}))
        else
            msg = tostring(args and args.msg or (ok and getText("IGUI_BetterSafehouse_Claim_GenericSuccess") or getText("IGUI_BetterSafehouse_Claim_GenericFailed")))
        end
        sayLocal(msg)
        return
    end

    if command == "SafehouseAdded" then
        applySafehouseAdded(args)
        return
    end
end

Events.OnServerCommand.Add(onServerCommand)
