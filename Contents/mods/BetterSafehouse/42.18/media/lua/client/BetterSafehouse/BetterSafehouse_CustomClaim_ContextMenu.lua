--[[
    Better Safehouse (Build 42) - Custom Claim system (Client Context Menu)

    Client responsibilities:
      - Show context menu options for claiming
      - Provide hover-preview (blue rectangle) while the menu is open
      - Send requests to server (server validates & applies)

    IMPORTANT: This file must never throw errors, otherwise it may break other context menus.
--]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse.CustomClaim = BetterSafehouse.CustomClaim or {}

-- -----------------------
-- Helpers / Translation
-- -----------------------
local function T(key, fallback)
    if getTextOrNull then
        local t = getTextOrNull(key)
        if t then return t end
    end
    return fallback
end

local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    if getTimeInMillis then return getTimeInMillis() end
    return 0
end

-- Inventory helper (client-side) - checks fullType including inside bags
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
    if type(playerIndex) == "number" then
        if getSpecificPlayer then return getSpecificPlayer(playerIndex) end
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
    if playerObj and playerObj.getSquare then return playerObj:getSquare() end
    return nil
end

-- -----------------------
-- Preview (blue overlay)
-- -----------------------
BetterSafehouse.CustomClaim.Preview = BetterSafehouse.CustomClaim.Preview or {
    squares = {},
    lastKey = nil,
    menu = nil,
    optToSize = nil,
}

local function keyOf(x,y,z) return tostring(x)..","..tostring(y)..","..tostring(z) end

local function clearPreview()
    local pv = BetterSafehouse.CustomClaim.Preview
    if not pv.squares then pv.squares = {} end
    for k, sq in pairs(pv.squares) do
        if sq and sq.getFloor then
            local floor = sq:getFloor()
            if floor and floor.setHighlighted then
                floor:setHighlighted(false)
            end
        end
        pv.squares[k] = nil
    end
    pv.lastKey = nil
end

local function applyBlueToSquare(sq)
    if not sq then return end
    local floor = sq:getFloor()
    if floor and floor.setHighlightColor then
        floor:setHighlightColor(0.15, 0.45, 1.0, 0.55)
    end
    if floor and floor.setHighlighted then
        floor:setHighlighted(true)
    end
end

local function previewRectCenteredOnPlayer(playerObj, w, h)
    if not playerObj then return end
    local psq = playerObj:getSquare()
    if not psq then return end
    local cx, cy, cz = psq:getX(), psq:getY(), psq:getZ()
    local x1 = math.floor(cx - math.floor(w / 2))
    local y1 = math.floor(cy - math.floor(h / 2))
    local x2 = x1 + w - 1
    local y2 = y1 + h - 1

    -- Avoid re-applying the same preview every tick
    local key = tostring(x1).."|"..tostring(y1).."|"..tostring(x2).."|"..tostring(y2).."|"..tostring(cz)
    local pv = BetterSafehouse.CustomClaim.Preview
    if pv.lastKey == key then return end
    pv.lastKey = key

    clearPreview()

    local cell = getCell and getCell()
    if not cell then return end
    for x = x1, x2 do
        for y = y1, y2 do
            local sq = cell:getGridSquare(x, y, cz)
            if sq then
                local k = keyOf(x,y,cz)
                pv.squares[k] = sq
                applyBlueToSquare(sq)
            end
        end
    end
end

-- Try to detect which option is hovered in the submenu (B42 UI differences safe)
local function getHoveredOption(menu)
    if not menu then return nil end

    -- Method
    if menu.getMouseOverOption then
        local ok, opt = pcall(function() return menu:getMouseOverOption() end)
        if ok and opt then return opt end
    end

    -- Field may be index or option
    local idx = menu.mouseOverOption or menu.mouseoveroption or menu.mouseOver or menu.mouseover
    if type(idx) == "number" then
        if menu.options and menu.options[idx] then return menu.options[idx] end
    elseif type(idx) == "table" then
        return idx
    end

    -- Selected index fallback
    local sidx = menu.selected or menu.selectedRow or menu.selectedIndex
    if type(sidx) == "number" and menu.options and menu.options[sidx] then
        return menu.options[sidx]
    end

    return nil
end

local function ensurePreviewTick()
    if BetterSafehouse.CustomClaim.Preview._tickAdded then return end
    BetterSafehouse.CustomClaim.Preview._tickAdded = true

    Events.OnTick.Add(function()
        local pv = BetterSafehouse.CustomClaim.Preview
        local menu = pv.menu
        if not menu or (menu.isVisible and not menu:isVisible()) then
            pv.menu = nil
            pv.optToSize = nil
            clearPreview()
            return
        end

        local hovered = getHoveredOption(menu)
        if not hovered or not pv.optToSize then
            clearPreview()
            return
        end

        local size = pv.optToSize[hovered]
        if not size then
            clearPreview()
            return
        end

        local playerObj = pv.playerObj
        if not playerObj then
            clearPreview()
            return
        end

        previewRectCenteredOnPlayer(playerObj, size.w, size.h)
    end)
end

-- -----------------------
-- Claim request
-- -----------------------
local lastSendMs = 0

local function requestClaim(playerObj, clickedSq, sizeId)
    if not playerObj or not clickedSq or not sizeId then return end

    local cfg = BetterSafehouse.CustomClaim.getConfig()
    if not cfg then return end
    -- Hide menu when no claim mode is active in Sandbox
    if (not cfg.itemEnabled) and (not cfg.freeEnabled) and (not cfg.conflict) then return end
    if cfg.conflict then
        playerObj:Say(T("IGUI_BetterSafehouse_CustomClaim_Conflict",
            "BetterSafehouse: Enable only ONE claim mode in Sandbox (item OR free)."))
        return
    end
    if not cfg.enabled then
        playerObj:Say(T("IGUI_BetterSafehouse_CustomClaim_Disabled",
            "BetterSafehouse: Custom claim is disabled in Sandbox."))
        return
    end

    local t = nowMs()
    if t > 0 and (t - lastSendMs) < 500 then return end
    lastSendMs = t

    if sendClientCommand then
        sendClientCommand(playerObj, BetterSafehouse.CustomClaim.NET_MODULE, "Claim", {
            x = clickedSq:getX(),
            y = clickedSq:getY(),
            z = clickedSq:getZ(),
            sizeId = sizeId,
            requestId = tostring(t) .. "-" .. tostring(ZombRand and ZombRand(1000000) or 0),
        })
    end
end

-- -----------------------
-- UI: custom size input (Admin)
-- -----------------------
local function isAdmin(playerObj)
    if not playerObj then return false end
    if playerObj.isAdmin and playerObj:isAdmin() then return true end
    if playerObj.isAccessLevel and playerObj:isAccessLevel("admin") then return true end
    return false
end

-- -----------------------
-- Context menu building
-- -----------------------
local function addSizeOptionWithPreview(sub, worldobjects, playerObj, clickedSq, label, size)
    local opt = sub:addOption(label, worldobjects, function()
        -- Clear preview before we actually claim (menu will close)
        clearPreview()
        requestClaim(playerObj, clickedSq, size.id)
    end)

    -- Register mapping for hover-preview tick
    local pv = BetterSafehouse.CustomClaim.Preview
    pv.optToSize = pv.optToSize or {}
    pv.optToSize[opt] = size
end

local function onFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    local ok, err = pcall(function()
        if test then return end
        if not context then return end

        local playerObj = getPlayerObj(playerIndex)
        if not playerObj or (playerObj.isDead and playerObj:isDead()) then return end

        local clickedSq = getSquareFromWorldobjects(worldobjects, playerObj)
        if not clickedSq then return end

        local cfg = BetterSafehouse.CustomClaim.getConfig()

        -- Only show this context-menu entry when at least one Custom Claim mode is enabled in Sandbox.
        -- (Otherwise players see "Better Safehouse" even when the feature is OFF.)
        if (not cfg) or ((not cfg.itemEnabled) and (not cfg.freeEnabled)) then return end

        -- Always add a top entry so players can find it
        local topLabel = T("IGUI_BetterSafehouse_CustomClaim_MenuTitle", "Better Safehouse")
        local topOpt = context:addOption(topLabel)

        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(topOpt, sub)

        if cfg.conflict then
            local opt = sub:addOption(T("IGUI_BetterSafehouse_CustomClaim_Conflict",
                "BetterSafehouse: Enable only ONE claim mode in Sandbox (item OR free)."), worldobjects, nil)
            opt.notAvailable = true
            return
        end

        if not cfg.enabled then
            local opt = sub:addOption(T("IGUI_BetterSafehouse_CustomClaim_Disabled",
                "BetterSafehouse: Custom claim is disabled in Sandbox."), worldobjects, nil)
            opt.notAvailable = true
            return
        end

        -- FREE mode: size is chosen by sandbox (server authoritative). Players do not pick sizes.
        if cfg.mode == "free" then

            local FM = BetterSafehouse.CustomClaim.FREE_MODE

            -- If FreeAnywhere="All", let the player pick among all allowed sizes (server validates).
            if cfg.freeMode == FM.All then
                local list = BetterSafehouse.CustomClaim.getFreeSizesForAll(cfg)
                if not list or #list == 0 then
                    local opt = sub:addOption(T("IGUI_BetterSafehouse_CustomClaim_Disabled",
                        "BetterSafehouse: Custom claim is disabled in Sandbox."), worldobjects, nil)
                    opt.notAvailable = true
                    return
                end

                for _, s in ipairs(list) do
                    local label
                    if s.custom then
                        label = T("IGUI_BetterSafehouse_CustomClaim_CustomSafehouse", "Custom safehouse")
                        label = label .. " (" .. tostring(s.label or "?") .. ")"
                    else
                        label = tostring(s.label or s.id)
                    end
                    addSizeOptionWithPreview(sub, worldobjects, playerObj, clickedSq, label, s)
                end
                return
            end

            -- Otherwise: size is chosen by sandbox (server authoritative). Players do not pick sizes.
            local freeSize = BetterSafehouse.CustomClaim.getFreeSizeFromSandbox(cfg)
            if not freeSize then
                local opt = sub:addOption(T("IGUI_BetterSafehouse_CustomClaim_Disabled",
                    "BetterSafehouse: Custom claim is disabled in Sandbox."), worldobjects, nil)
                opt.notAvailable = true
                return
            end

            local label = T("IGUI_BetterSafehouse_CustomClaim_Free", "Claim custom safehouse")
            label = label .. " (" .. tostring(freeSize.label or "?") .. ")"
            addSizeOptionWithPreview(sub, worldobjects, playerObj, clickedSq, label, freeSize)
            return


        end
        -- ITEM mode: show each size option and require its corresponding item.
        if cfg.mode == "item" then
            local inv = playerObj:getInventory()

            -- Preset items (Claim3x3, Claim7x7, etc.)
            for _, s in ipairs(BetterSafehouse.CustomClaim.SIZES) do
                if s and s.item then
                    local label = tostring(s.label or s.id)
                    if inv and invHasFullType(inv, s.item) then
                        addSizeOptionWithPreview(sub, worldobjects, playerObj, clickedSq, label, s)
                    else
                        local opt = sub:addOption(label .. " (" .. T("IGUI_BetterSafehouse_CustomClaim_NeedItem", "needs item") .. ")", worldobjects, nil)
                        opt.notAvailable = true
                        -- still allow hover preview for planning
                        local pv = BetterSafehouse.CustomClaim.Preview
                        pv.optToSize = pv.optToSize or {}
                        pv.optToSize[opt] = s
                    end
                end
            end

            -- Optional CUSTOM option (requires BetterSafehouse.customsafehouse)
            if cfg.itemCustomEnabled then
                local cs = BetterSafehouse.CustomClaim.getCustomSizeFromSandbox("BetterSafehouse.customsafehouse")
                local label = T("IGUI_BetterSafehouse_CustomClaim_CustomSafehouse", "Custom safehouse")
                label = label .. " (" .. tostring(cs.label or "?") .. ")"
                if inv and invHasFullType(inv, cs.item) then
                    addSizeOptionWithPreview(sub, worldobjects, playerObj, clickedSq, label, cs)
                else
                    local opt = sub:addOption(label .. " (" .. T("IGUI_BetterSafehouse_CustomClaim_NeedItem", "needs item") .. ")", worldobjects, nil)
                    opt.notAvailable = true
                    local pv = BetterSafehouse.CustomClaim.Preview
                    pv.optToSize = pv.optToSize or {}
                    pv.optToSize[opt] = cs
                end
            end
        end
    end)

    if not ok then
        -- Never break other context menus
        if getPlayer and getPlayer() and getPlayer().Say then
            getPlayer():Say(getText("IGUI_BetterSafehouse_ContextMenu_Error"))
        end
        print("[BetterSafehouse][CustomClaim][C] ContextMenu error: " .. tostring(err))
        clearPreview()
    end
end


Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
