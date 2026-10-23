if isServer() and not isClient() then
    return
end

require "BetterSafehouse/BetterSafehouse_Expansion_Shared"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISPanel"
require "ISUI/ISCollapsableWindow"

local RSE = BetterSafehouse.Expansion

-- =========================================================
-- Resize window visual style (vanilla PZ only, no external UI framework
-- dependency). Centralized here so every button/label/panel in this window
-- shares one consistent palette instead of scattering slightly different
-- literal colors across each factory/refresh function.
-- =========================================================
local UI_CARD_BG = { r = 1, g = 1, b = 1, a = 0.045 }
local UI_CARD_BORDER = { r = 1, g = 1, b = 1, a = 0.10 }
local UI_COLOR_META = { r = 0.62, g = 0.64, b = 0.68 }
local UI_COLOR_HEADER = { r = 0.80, g = 0.86, b = 1.0 }

local UI_BTN_BG = { r = 0.20, g = 0.21, b = 0.26, a = 1.0 }
local UI_BTN_HOVER = { r = 0.28, g = 0.30, b = 0.36, a = 1.0 }
local UI_BTN_BORDER = { r = 1, g = 1, b = 1, a = 0.32 }
local UI_BTN_BORDER_BLOCKED = { r = 0.46, g = 0.47, b = 0.52, a = 0.42 }
local UI_BTN_BG_BLOCKED = { r = 0.09, g = 0.09, b = 0.11, a = 1.0 }

local UI_ACCENT_GREEN = { r = 0.18, g = 0.48, b = 0.32, a = 1.0 }
local UI_ACCENT_GREEN_HOVER = { r = 0.24, g = 0.58, b = 0.40, a = 1.0 }
local UI_ACCENT_RED = { r = 0.58, g = 0.23, b = 0.26, a = 1.0 }
local UI_ACCENT_RED_HOVER = { r = 0.68, g = 0.30, b = 0.32, a = 1.0 }

local function styleButton(button, bg, hover, border)
    button.backgroundColor = bg
    button.backgroundColorMouseOver = hover
    button.borderColor = border
end

-- Vanilla ISButton:setEnable(false) hardcodes a vivid red border and black
-- background (see ISButton.lua), ignoring whatever style styleButton() set.
-- With every temporarily-blocked "+"/"-" showing that same alarm red, a row
-- reads as "nothing here works" even when other sides (or "-") are still
-- fully usable. Re-apply our own colors right after so disabled just means
-- greyed-out, not a stop sign.
local function applyButtonEnableStyle(button, enabled)
    if not button then return end

    if button.setEnable then
        button:setEnable(enabled)
    else
        button.enable = enabled
    end

    local border = enabled and UI_BTN_BORDER or UI_BTN_BORDER_BLOCKED
    local bg = enabled and UI_BTN_BG or UI_BTN_BG_BLOCKED
    if button.setBorderRGBA then button:setBorderRGBA(border.r, border.g, border.b, border.a) end
    if button.setBackgroundRGBA then button:setBackgroundRGBA(bg.r, bg.g, bg.b, bg.a) end
    if button.setTextureRGBA then
        if enabled then
            button:setTextureRGBA(1, 1, 1, 1)
        else
            button:setTextureRGBA(0.55, 0.55, 0.55, 1)
        end
    end
end

RSE.ClientPreview = RSE.ClientPreview or {
    oldRect = nil,
    newRect = nil,
    mode = "expand",
    z = 0,
    appliedSquares = {},
    lastRefreshMs = 0,
    throttleMs = 150,
}

local function previewKey(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function getBetterSafehouseViewer()
    local betterSafehouse = rawget(_G, "BetterSafehouse")
    if not betterSafehouse then
        return nil
    end

    if type(betterSafehouse.Viewer) ~= "table" then
        return nil
    end

    return betterSafehouse.Viewer
end

local function betterSafehouseHasAppliedHighlight(key)
    local viewer = getBetterSafehouseViewer()
    if not viewer or type(viewer.appliedSquares) ~= "table" then
        return false
    end

    return viewer.appliedSquares[key] == true
end

-- Must match BetterSafehouse_Viewer.lua's own applyHighlightToSquare() color
-- exactly. When the resize preview releases a square that the persistent
-- "Visualizar esta safehouse" viewer also owns, this is what puts it back —
-- the viewer's own onTick loop skips squares already in appliedSquares, so
-- a mismatched color here stays wrong until the viewer's tracked safehouse
-- id/z changes and forces a full re-mark (e.g. reopening the resize window
-- happens to coincide with that, which is why it looked "fixed" by reopening).
local VIEWER_HIGHLIGHT_R, VIEWER_HIGHLIGHT_G, VIEWER_HIGHLIGHT_B, VIEWER_HIGHLIGHT_A = 0.2, 0.5, 0.95, 0.55

local function applyBetterSafehouseHighlightToSquare(square)
    if not square then return end

    local floor = square.getFloor and square:getFloor() or nil
    if floor and floor.setHighlightColor then
        floor:setHighlightColor(VIEWER_HIGHLIGHT_R, VIEWER_HIGHLIGHT_G, VIEWER_HIGHLIGHT_B, VIEWER_HIGHLIGHT_A)
    end
    if floor and floor.setHighlighted then
        floor:setHighlighted(true, false)
    end
    if square.setHighlight then
        square:setHighlight(true)
    end
end

local function unhighlightSquareByKey(key)
    local x, y, z = tostring(key or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not x then return end

    local cell = getCell and getCell() or nil
    if not cell then return end

    local square = cell:getGridSquare(tonumber(x), tonumber(y), tonumber(z))
    if not square then return end

    if betterSafehouseHasAppliedHighlight(key) then
        applyBetterSafehouseHighlightToSquare(square)
        return
    end

    local floor = square.getFloor and square:getFloor() or nil
    if floor and floor.setHighlighted then
        floor:setHighlighted(false, false)
    end
    if square.setHighlight then
        square:setHighlight(false)
    end
end

local function clearPreviewSquares()
    for key, _ in pairs(RSE.ClientPreview.appliedSquares or {}) do
        unhighlightSquareByKey(key)
    end
    RSE.ClientPreview.appliedSquares = {}
end

local function tableHasEntries(values)
    if type(values) ~= "table" then
        return false
    end

    for _, _ in pairs(values) do
        return true
    end

    return false
end

-- Chebyshev distance from (x, y) to the CURRENT (pre-resize) rect: 0 if the
-- tile is still inside it, otherwise how many tiles outside its nearest edge
-- it sits. Used to make the expand preview grow more intense the further a
-- tile is being pulled from the safehouse's existing border.
local function distanceOutsideRect(rect, x, y)
    if not rect then return 0 end

    local dx = 0
    if x < rect.x then
        dx = rect.x - x
    elseif x > rect.x2 then
        dx = x - rect.x2
    end

    local dy = 0
    if y < rect.y then
        dy = rect.y - y
    elseif y > rect.y2 then
        dy = y - rect.y2
    end

    return math.max(dx, dy)
end

-- Largest single-side delta between the current and previewed rect — used to
-- normalize the expand-preview gradient (the outermost ring of tiles always
-- reaches full intensity, regardless of how many tiles were queued).
local function maxRectDelta(oldRect, newRect)
    if not oldRect or not newRect then return 1 end

    local left = math.max(0, oldRect.x - newRect.x)
    local top = math.max(0, oldRect.y - newRect.y)
    local right = math.max(0, newRect.x2 - oldRect.x2)
    local bottom = math.max(0, newRect.y2 - oldRect.y2)

    return math.max(1, left, top, right, bottom)
end

local function applyPreviewToSquare(square, mode, x, y, oldRect, maxDepth)
    if not square then return end

    local floor = square.getFloor and square:getFloor() or nil
    local r, g, b, a

    if RSE.isShrinkMode(mode) then
        -- Removal keeps a distinct warning color instead of the safehouse blue.
        r, g, b, a = 1.0, 0.12, 0.12, 0.74
    else
        -- Same blue family as the safehouse Viewer highlight, growing stronger
        -- (more opaque) the further out a tile sits, like the border is being
        -- visibly dragged outward as the queued amount grows.
        r, g, b = 0.2, 0.5, 0.95
        local depth = math.max(1, distanceOutsideRect(oldRect, x, y))
        local intensity = math.min(1, depth / math.max(1, maxDepth or depth))
        a = 0.35 + (0.85 - 0.35) * intensity
    end

    if floor and floor.setHighlightColor then
        floor:setHighlightColor(r, g, b, a)
    end
    if floor and floor.setHighlighted then
        floor:setHighlighted(true, false)
    end
    if square.setHighlight then
        square:setHighlight(true)
    end
end

function RSE.clearClientPreview()
    RSE.ClientPreview.oldRect = nil
    RSE.ClientPreview.newRect = nil
    RSE.ClientPreview.mode = "expand"
    RSE.ClientPreview.lastRefreshMs = 0
    clearPreviewSquares()
end

function RSE.setClientPreview(oldRect, newRect, z, mode)
    if not oldRect or not newRect then
        RSE.clearClientPreview()
        return
    end

    RSE.ClientPreview.oldRect = RSE.copyRect(oldRect)
    RSE.ClientPreview.newRect = RSE.copyRect(newRect)
    RSE.ClientPreview.mode = RSE.normalizeResizeMode(mode) or "expand"
    RSE.ClientPreview.z = math.floor(tonumber(z) or 0)
    RSE.ClientPreview.lastRefreshMs = 0
    clearPreviewSquares()
end

local function previewOnTick()
    local oldRect = RSE.ClientPreview.oldRect
    local newRect = RSE.ClientPreview.newRect
    local mode = RSE.ClientPreview.mode

    if not oldRect or not newRect then
        if tableHasEntries(RSE.ClientPreview.appliedSquares) then
            clearPreviewSquares()
        end
        return
    end

    local now = 0
    if getTimestampMs then
        local okNow, value = pcall(function()
            return getTimestampMs()
        end)
        if okNow and type(value) == "number" then
            now = value
        end
    end

    if now > 0 and (now - (RSE.ClientPreview.lastRefreshMs or 0)) < (RSE.ClientPreview.throttleMs or 150) then
        return
    end

    RSE.ClientPreview.lastRefreshMs = now

    local cell = getCell and getCell() or nil
    if not cell then return end

    local wanted = {}
    local targetZ = RSE.ClientPreview.z or 0
    local maxDepth = maxRectDelta(oldRect, newRect)

    RSE.forEachPreviewTile(oldRect, newRect, mode, function(x, y)
        local key = previewKey(x, y, targetZ)
        wanted[key] = true

        if not RSE.ClientPreview.appliedSquares[key] then
            local square = cell:getGridSquare(x, y, targetZ)
            if square then
                applyPreviewToSquare(square, mode, x, y, oldRect, maxDepth)
                RSE.ClientPreview.appliedSquares[key] = true
            end
        end

        return true
    end)

    for key, _ in pairs(RSE.ClientPreview.appliedSquares) do
        if not wanted[key] then
            unhighlightSquareByKey(key)
            RSE.ClientPreview.appliedSquares[key] = nil
        end
    end
end

local function sayLocalMessage(message)
    message = tostring(message or "")
    if message == "" then return end

    local playerObj = getPlayer and getPlayer() or nil
    if playerObj and HaloTextHelper and HaloTextHelper.addText then
        HaloTextHelper.addText(playerObj, message)
        return
    end

    if playerObj and playerObj.Say then
        playerObj:Say(message)
        return
    end

    print("[BetterSafehouse][Expansion] " .. message)
end

local function localizeServerResult(args)
    if not args then return "" end

    local fallback = tostring(args.msg or "")
    if args.key then
        return RSE.getTextOrFallback(args.key, fallback ~= "" and fallback or tostring(args.key), (table.unpack or unpack)(args.args or {}))
    end

    return fallback
end

local function tryCall(obj, method)
    if obj and obj[method] then
        pcall(function()
            obj[method](obj)
        end)
        return true
    end
    return false
end

local function setElementVisible(element, visible)
    if not element then return end

    visible = visible == true
    if element.setVisible then
        pcall(function()
            element:setVisible(visible)
        end)
        return
    end

    element.visible = visible
end

local function setElementBounds(element, x, y, width, height)
    if not element then return end

    if x ~= nil then
        if element.setX then element:setX(x) else element.x = x end
    end
    if y ~= nil then
        if element.setY then element:setY(y) else element.y = y end
    end
    if width ~= nil then
        if element.setWidth then element:setWidth(width) else element.width = width end
    end
    if height ~= nil then
        if element.setHeight then element:setHeight(height) else element.height = height end
    end
end

local function setButtonTitle(button, title)
    if not button then return end

    title = tostring(title or "")
    if button.setTitle then
        pcall(function()
            button:setTitle(title)
        end)
        return
    end

    button.title = title
end

local function tryRefreshSafehouseUI()
    if triggerEvent then
        pcall(function()
            triggerEvent("OnSafehousesChanged")
        end)
    end

    local candidates = {}

    local function addCandidate(ui)
        if not ui or candidates[ui] then return end
        candidates[ui] = true
    end

    if ISSafehouseUI and ISSafehouseUI.instance then
        addCandidate(ISSafehouseUI.instance)
    end
    if ISSafehousesList and ISSafehousesList.instance then
        addCandidate(ISSafehousesList.instance)
    end
    if ISAdminPanelUI and ISAdminPanelUI.instance then
        addCandidate(ISAdminPanelUI.instance)
    end

    if UIManager and UIManager.getUI and instanceof then
        local okList, uiList = pcall(function()
            return UIManager.getUI()
        end)
        if okList and uiList and uiList.size and uiList.get then
            for index = 0, uiList:size() - 1 do
                local ui = uiList:get(index)
                if ui and (instanceof(ui, "ISSafehouseUI") or instanceof(ui, "ISSafehousesList")) then
                    addCandidate(ui)
                end
            end
        end
    end

    for ui, _ in pairs(candidates) do
        tryCall(ui, "populateList")
        tryCall(ui, "populate")
        tryCall(ui, "refresh")
        tryCall(ui, "update")
    end
end

local function refreshSafehouseDetailLabels(ui)
    if not ui or not ui.safehouse then return end

    local safehouse = ui.safehouse

    if ui.title and ui.title.setName and safehouse.getTitle then
        pcall(function()
            ui.title:setName(safehouse:getTitle())
        end)
    end

    if ui.owner and ui.owner.setName and safehouse.getOwner then
        pcall(function()
            ui.owner:setName(safehouse:getOwner())
        end)
    end

    if ui.pos and ui.pos.setName and safehouse.getX and safehouse.getY and getText then
        pcall(function()
            ui.pos:setName(getText("IGUI_SafehouseUI_Pos2", safehouse:getX(), safehouse:getY()))
        end)
    end

    if ui.points and ui.points.setName and safehouse.getHitPoints then
        pcall(function()
            ui.points:setName(tostring(safehouse:getHitPoints()))
        end)
    end
end

local function updateBetterSafehouseViewerTarget(oldRect, newRect)
    local betterSafehouse = rawget(_G, "BetterSafehouse")
    if not betterSafehouse then return end

    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj then return end

    if not betterSafehouse.getClientViewerTarget or not betterSafehouse.setClientViewerTarget then
        return
    end

    local okTarget, target = pcall(function()
        return betterSafehouse.getClientViewerTarget(playerObj)
    end)
    if not okTarget or type(target) ~= "table" then
        return
    end

    local tx = math.floor(tonumber(target.x) or 0)
    local ty = math.floor(tonumber(target.y) or 0)
    local tw = math.floor(tonumber(target.w) or 0)
    local th = math.floor(tonumber(target.h) or 0)

    if tx == oldRect.x and ty == oldRect.y and tw == oldRect.w and th == oldRect.h then
        pcall(function()
            betterSafehouse.setClientViewerTarget(playerObj, {
                x = newRect.x,
                y = newRect.y,
                w = newRect.w,
                h = newRect.h,
                z = tonumber(target.z) or (playerObj.getZ and playerObj:getZ() or 0),
            })
        end)
    end
end

local function mutateSafehouseObject(safehouse, newRect, onlineId)
    if not safehouse or not safehouse.setX or not safehouse.setY or not safehouse.setW or not safehouse.setH then
        return false
    end

    local ok = pcall(function()
        safehouse:setX(newRect.x)
        safehouse:setY(newRect.y)
        safehouse:setW(newRect.w)
        safehouse:setH(newRect.h)
        if safehouse.setOnlineID and type(onlineId) == "number" then
            safehouse:setOnlineID(onlineId)
        end
    end)

    return ok == true
end

local function collectSafehouseCandidates(oldRect, oldOnlineId)
    local candidates = {}

    local function addCandidate(safehouse)
        if not safehouse then return end
        if RSE.safehouseMatchesRect(safehouse, oldRect) then
            candidates[safehouse] = true
            return
        end

        if oldOnlineId and safehouse.getOnlineID then
            local okId, value = pcall(function()
                return safehouse:getOnlineID()
            end)
            if okId and value == oldOnlineId then
                candidates[safehouse] = true
            end
        end
    end

    if ISSafehouseUI and ISSafehouseUI.instance and ISSafehouseUI.instance.safehouse then
        addCandidate(ISSafehouseUI.instance.safehouse)
    end
    if ISSafehousesListUI and ISSafehousesListUI.instance and ISSafehousesListUI.instance.selectedSafehouse then
        addCandidate(ISSafehousesListUI.instance.selectedSafehouse)
    end
    if ISSafehousesList and ISSafehousesList.instance and ISSafehousesList.instance.selectedSafehouse then
        addCandidate(ISSafehousesList.instance.selectedSafehouse)
    end

    if SafeHouse and SafeHouse.getSafeHouse and oldOnlineId then
        local okById, safehouse = pcall(function()
            return SafeHouse.getSafeHouse(oldOnlineId)
        end)
        if okById and safehouse then
            addCandidate(safehouse)
        end
    end

    local list = RSE.getSafehouseList()
    for _, safehouse in RSE.eachSafehouse(list) do
        addCandidate(safehouse)
    end

    return candidates
end

local function expansionLimitStateFromPayload(args)
    if type(args) ~= "table" then return nil end

    local currentRect = RSE.makeRect(args.x, args.y, args.w, args.h)
    if not RSE.rectIsValid(currentRect) then return nil end

    local baseRect = RSE.makeRect(args.baseX, args.baseY, args.baseW, args.baseH)
    if not RSE.rectIsValid(baseRect) then
        baseRect = RSE.copyRect(currentRect)
    end

    return {
        currentRect = currentRect,
        baseRect = baseRect,
        baseArea = math.floor(tonumber(args.baseArea) or RSE.getSafehouseArea(baseRect)),
        flow = tostring(args.flow or ""),
        roleName = tostring(args.roleName or ""),
        maxExtraTiles = tonumber(args.maxExtraTiles),
        maxTotalTiles = tonumber(args.maxTotalTiles),
        userMaxBorderTiles = tonumber(args.userMaxBorderTiles),
        userAlreadyExpanded = args.userAlreadyExpanded == true,
    }
end

local function limitStateMatchesRect(state, rect)
    return state and rect
        and state.currentRect
        and state.currentRect.x == rect.x
        and state.currentRect.y == rect.y
        and state.currentRect.w == rect.w
        and state.currentRect.h == rect.h
end

local function applySafehouseResized(args)
    if not args then return end

    local oldRect = RSE.makeRect(args.oldX, args.oldY, args.oldW, args.oldH)
    local newRect = RSE.makeRect(args.x, args.y, args.w, args.h)
    local oldOnlineId = math.floor(tonumber(args.oldOnlineID) or 0)
    local newOnlineId = math.floor(tonumber(args.onlineID) or 0)

    local mutatedRef = nil
    local candidates = collectSafehouseCandidates(oldRect, oldOnlineId > 0 and oldOnlineId or nil)
    for safehouse, _ in pairs(candidates) do
        if mutateSafehouseObject(safehouse, newRect, newOnlineId > 0 and newOnlineId or nil) and not mutatedRef then
            mutatedRef = safehouse
        end
    end

    updateBetterSafehouseViewerTarget(oldRect, newRect)

    if BSExpansionSafehouseWindow and BSExpansionSafehouseWindow.instance and BSExpansionSafehouseWindow.instance.safehouse then
        if RSE.safehouseMatchesRect(BSExpansionSafehouseWindow.instance.safehouse, oldRect) and mutatedRef then
            BSExpansionSafehouseWindow.instance.safehouse = mutatedRef
            BSExpansionSafehouseWindow.instance.expansionLimitState = expansionLimitStateFromPayload(args)
            BSExpansionSafehouseWindow.instance.limitStateRequested = false
            pcall(function()
                BSExpansionSafehouseWindow.instance:updatePreview()
            end)
        end
    end

    if ISSafehouseUI and ISSafehouseUI.instance then
        refreshSafehouseDetailLabels(ISSafehouseUI.instance)
    end

    tryRefreshSafehouseUI()
end

local function walkChildren(root, callback)
    if not root or not root.children or not callback then
        return nil
    end

    for _, child in pairs(root.children) do
        if child then
            local result = callback(child, root)
            if result ~= nil then
                return result
            end

            local nested = walkChildren(child, callback)
            if nested ~= nil then
                return nested
            end
        end
    end

    return nil
end

local function findButtonByHeuristic(root, checker)
    local result = walkChildren(root, function(child, parent)
        if child and child.Type == "ISButton" and checker(child) then
            return {
                btn = child,
                parent = child.parent or parent or root,
            }
        end
        return nil
    end)

    return result
end

local function findReferenceButton(root)
    local refresh = findButtonByHeuristic(root, function(child)
        local internal = RSE.lowerString(child.internal or "")
        local title = RSE.lowerString(child.title or "")
        return internal == "refresh"
            or internal == "refreshlist"
            or title:find("refresh", 1, true) ~= nil
            or title:find("atualizar", 1, true) ~= nil
    end)
    if refresh then return refresh end

    return findButtonByHeuristic(root, function(child)
        local internal = RSE.lowerString(child.internal or "")
        local title = RSE.lowerString(child.title or "")
        return internal == "ok"
            or internal == "close"
            or title == "ok"
            or title:find("close", 1, true) ~= nil
            or title:find("fechar", 1, true) ~= nil
    end)
end

local function getExpandButtonWidth()
    local label = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_ExpandSafehouse_Button", "Resize Safehouse")
    local width = 150

    if getTextManager and getTextManager() and getTextManager().MeasureStringX then
        local okMeasure, measured = pcall(function()
            return getTextManager():MeasureStringX(UIFont.Small, label)
        end)
        if okMeasure and type(measured) == "number" then
            width = math.max(width, math.floor(measured) + 28)
        end
    end

    return width
end

local function updateExpandButtonState(ui)
    if not ui or not ui.BS_expansionButton then return end

    local playerObj = getPlayer and getPlayer() or nil
    local resizeFlow = playerObj and RSE.getPlayerResizeFlowForSafehouse(playerObj, ui.safehouse) or nil
    local button = ui.BS_expansionButton
    local enabled = false
    local tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_ExpandSafehouse_Button_tooltip", "Owner-only safehouse resize.")

    if not RSE.isEnabled() then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_DisabledBySandbox", "Safehouse resize is disabled in sandbox.")
    elseif not playerObj or not ui.safehouse then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse", "Invalid safehouse.")
    elseif not RSE.canResizeSafehouse(playerObj, ui.safehouse) then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_OwnerOnly", "Only the safehouse owner can resize it.")
    elseif not resizeFlow then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_RoleDenied", "Your role cannot resize safehouses.")
    elseif RSE.isPlayerUserBorderExpansionActiveForSafehouse(playerObj, ui.safehouse) and not RSE.isUserFlowUsingAdvancedMode() and RSE.getUserMaxBorderTilesFromOriginal() < 1 then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_UserBorder_NoActionsConfigured", "The user system has no valid sandbox limit.")
    else
        enabled = true
    end

    if button.setEnable then
        button:setEnable(enabled)
    else
        button.enable = enabled
    end

    if button.setTooltip then
        button:setTooltip(tooltip)
    else
        button.tooltip = tooltip
    end
end

local function repositionExpandButton(ui)
    if not ui or not ui.BS_expansionButton then return end

    local button = ui.BS_expansionButton
    local ref = findReferenceButton(ui)
    local width = getExpandButtonWidth()
    local height = 24
    local parent = ui
    local x = 10
    local y = (ui.height or 0) - height - 38

    if ref and ref.btn and ref.btn.getX and ref.btn.getY then
        parent = ref.parent or ref.btn.parent or ui

        if button.parent ~= parent then
            pcall(function()
                if button.parent and button.parent.removeChild then
                    button.parent:removeChild(button)
                end
            end)
            pcall(function()
                parent:addChild(button)
            end)
        end

        local refX = ref.btn.getX and ref.btn:getX() or ref.btn.x or 0
        local refY = ref.btn.getY and ref.btn:getY() or ref.btn.y or 0
        local refH = ref.btn.getHeight and ref.btn:getHeight() or ref.btn.height or height
        local parentW = parent.getWidth and parent:getWidth() or parent.width or width + 20

        x = refX - width - 10
        if x < 10 then x = 10 end
        if x + width > parentW - 10 then
            x = math.max(10, parentW - width - 10)
        end

        y = refY
        height = refH
    end

    if button.setX then button:setX(x) else button.x = x end
    if button.setY then button:setY(y) else button.y = y end
    if button.setWidth then button:setWidth(width) else button.width = width end
    if button.setHeight then button:setHeight(height) else button.height = height end
    if button.bringToTop then
        pcall(function()
            button:bringToTop()
        end)
    end
end

local function onExpandButtonClicked(ui)
    if not ui or not ui.safehouse then return end

    if BSExpansionSafehouseWindow and BSExpansionSafehouseWindow.instance then
        pcall(function()
            BSExpansionSafehouseWindow.instance:close()
        end)
    end

    local window = nil
    if RSE.openExpandWindow then
        window = RSE.openExpandWindow(ui.safehouse, ui)
    end

    if window and window.parentUI ~= ui then
        window.parentUI = ui
    end
end

local function installExpandButton(ui)
    if not ui or ui.BS_expansionButton then return end
    if not ISButton or not ui.safehouse then return end

    local label = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_ExpandSafehouse_Button", "Resize Safehouse")
    local button = ISButton:new(10, 10, getExpandButtonWidth(), 24, label, ui, onExpandButtonClicked)
    button:initialise()
    button.internal = "BS_EXPAND_SAFEHOUSE"

    local ref = findReferenceButton(ui)
    local parent = (ref and ref.parent) or ui
    if parent and parent.addChild then
        parent:addChild(button)
    else
        ui:addChild(button)
    end

    ui.BS_expansionButton = button
    repositionExpandButton(ui)
    updateExpandButtonState(ui)
end

local function patchISSafehouseUI()
    if not ISSafehouseUI then return end
    if ISSafehouseUI._BSExpansionPatched then return end

    ISSafehouseUI._BSExpansionPatched = true

    local oldCreateChildren = ISSafehouseUI.createChildren
    if oldCreateChildren then
        ISSafehouseUI.createChildren = function(self, ...)
            local result = oldCreateChildren(self, ...)
            pcall(function() installExpandButton(self) end)
            pcall(function() repositionExpandButton(self) end)
            pcall(function() updateExpandButtonState(self) end)
            return result
        end
    end

    local oldPopulateList = ISSafehouseUI.populateList
    if oldPopulateList then
        ISSafehouseUI.populateList = function(self, ...)
            local result = oldPopulateList(self, ...)
            pcall(function() installExpandButton(self) end)
            pcall(function() repositionExpandButton(self) end)
            pcall(function() updateExpandButtonState(self) end)
            return result
        end
    end
end

Events.OnGameStart.Add(patchISSafehouseUI)
pcall(patchISSafehouseUI)

BSExpansionSafehouseWindow = ISCollapsableWindow:derive("BSExpansionSafehouseWindow")
BSExpansionSafehouseWindow.instance = nil

function BSExpansionSafehouseWindow:new(x, y, width, height, safehouse, parentUI)
    local window = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(window, self)
    self.__index = self

    local playerObj = getPlayer and getPlayer() or nil

    window.safehouse = safehouse
    window.parentUI = parentUI
    window.selectedAction = nil
    window.sideAmounts = { N = 0, S = 0, E = 0, W = 0 }
    window.stepSize = 1
    window.selectedMode = "expand"
    window.previewSteps = 1
    local isUserFlow = RSE.isPlayerUserBorderExpansionActiveForSafehouse(playerObj, safehouse) == true
    window.userAdvancedModeActive = isUserFlow and RSE.isUserFlowUsingAdvancedMode()
    window.userBorderRestrictionsActive = isUserFlow and not window.userAdvancedModeActive
    window.pendingRequest = false
    window.previewRect = nil
    window.previewMessageKey = nil
    window.previewMessageText = nil
    window.expansionLimitState = nil
    window.limitStateRequested = false
    window.moveWithMouse = true
    window.resizable = false
    window.pin = false
    window.title = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_WindowTitle", "Resize Safehouse")

    return window
end

function BSExpansionSafehouseWindow:initialise()
    ISCollapsableWindow.initialise(self)
end

function BSExpansionSafehouseWindow:getCurrentRect()
    return RSE.rectFromSafehouse(self.safehouse)
end

function BSExpansionSafehouseWindow:requestExpansionLimitState(force)
    if self.limitStateRequested and force ~= true then return end

    local currentRect = self:getCurrentRect()
    local playerObj = getPlayer and getPlayer() or nil
    if not currentRect or not playerObj then return end

    self.limitStateRequested = true
    sendClientCommand(playerObj, RSE.NET_MODULE, "RequestExpansionLimitState", {
        x = currentRect.x,
        y = currentRect.y,
        w = currentRect.w,
        h = currentRect.h,
    })
end

function BSExpansionSafehouseWindow:isUserBorderRestrictedMode()
    return self.userBorderRestrictionsActive == true
end

function BSExpansionSafehouseWindow:isUserAdvancedMode()
    return self.userAdvancedModeActive == true
end

-- Role and user-advanced flows let the player toggle any combination of
-- N/S/E/W and apply them together; the simple user flow keeps its own
-- single-selection model (self.selectedAction) untouched.
function BSExpansionSafehouseWindow:hasSelectedSide()
    local amounts = self.sideAmounts
    if type(amounts) ~= "table" then return false end
    return (tonumber(amounts.N) or 0) > 0
        or (tonumber(amounts.S) or 0) > 0
        or (tonumber(amounts.E) or 0) > 0
        or (tonumber(amounts.W) or 0) > 0
end

function BSExpansionSafehouseWindow:getSideAmountsSummary()
    local amounts = self.sideAmounts
    local n = math.max(0, math.floor(tonumber(amounts and amounts.N) or 0))
    local s = math.max(0, math.floor(tonumber(amounts and amounts.S) or 0))
    local e = math.max(0, math.floor(tonumber(amounts and amounts.E) or 0))
    local w = math.max(0, math.floor(tonumber(amounts and amounts.W) or 0))

    if n == 0 and s == 0 and e == 0 and w == 0 then
        return RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_NoSidesSelected", "none")
    end

    return RSE.getTextOrFallback(
        "IGUI_BetterSafehouse_Expansion_Resize_SideAmountsSummary",
        "N: %1 | S: %2 | E: %3 | W: %4",
        tostring(n), tostring(s), tostring(e), tostring(w)
    )
end

function BSExpansionSafehouseWindow:getActionDisplayName(action)
    action = tostring(action or "")
    if action == "ALL" and self:isUserBorderRestrictedMode() then
        return RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_UserBorder_AllAction", "Whole border")
    end

    return action
end

function BSExpansionSafehouseWindow:hasConfiguredUserBorderActions()
    if not self:isUserBorderRestrictedMode() then
        return true
    end

    return RSE.getUserMaxBorderTilesFromOriginal() > 0
end

function BSExpansionSafehouseWindow:isAllowedUserBorderAction(action)
    if not self:isUserBorderRestrictedMode() then
        return true
    end

    action = tostring(action or "")
    return action == "ALL"
end

function BSExpansionSafehouseWindow:getOrderedAllowedUserBorderActions()
    if not self:isUserBorderRestrictedMode() then
        return {}
    end

    if self:hasConfiguredUserBorderActions() then
        return { "ALL" }
    end

    return {}
end

function BSExpansionSafehouseWindow:getUserAllowedBorderSummary()
    local labels = {}
    for _, action in ipairs(self:getOrderedAllowedUserBorderActions()) do
        table.insert(labels, self:getActionDisplayName(action))
    end

    return table.concat(labels, ", ")
end

function BSExpansionSafehouseWindow:syncUserBorderRestrictionSelection()
    if not self:isUserBorderRestrictedMode() then
        return
    end

    self.selectedMode = "expand"
    if not self:hasConfiguredUserBorderActions() then
        self.selectedAction = nil
        return
    end

    if self.selectedAction and self:isAllowedUserBorderAction(self.selectedAction) then
        return
    end

    self.selectedAction = "ALL"
end

function BSExpansionSafehouseWindow:getPreviewStepCount(allowZero)
    return RSE.normalizeResizeSteps(self.previewSteps, allowZero == true)
end

-- Simple user flow only now; the role/user-advanced flow uses independent
-- per-side amounts (self.sideAmounts) instead of one shared total step.
function BSExpansionSafehouseWindow:getPreviewTotalStep()
    return self:getPreviewStepCount(false) or 0
end

function BSExpansionSafehouseWindow:getPreviewLimitBlockReason(currentRect, previewRect, previewMode, suppressRequest)
    if not currentRect or not previewRect or RSE.isShrinkMode(previewMode) then return nil end

    local state = self.expansionLimitState
    if not limitStateMatchesRect(state, currentRect) then
        if suppressRequest ~= true then
            self:requestExpansionLimitState(false)
        end
        return RSE.getTextOrFallback(
            "IGUI_BetterSafehouse_Expansion_Resize_WaitingLimitSync",
            "Syncing expansion limit with server."
        )
    end

    if state.flow == "role" or (state.flow == "user" and self:isUserAdvancedMode()) then
        local maxTotalTiles = tonumber(state.maxTotalTiles)
        if maxTotalTiles and maxTotalTiles > 0 then
            local totalTiles = RSE.getSafehouseArea(previewRect)
            if totalTiles > maxTotalTiles then
                return RSE.getTextOrFallback(
                    "IGUI_BetterSafehouse_Expansion_Resize_MaxTotalTilesReached",
                    "Maximum safehouse size reached: %1/%2 total tiles.",
                    tostring(totalTiles),
                    tostring(maxTotalTiles)
                )
            end
        end

        local maxExtraTiles = tonumber(state.maxExtraTiles)
        if maxExtraTiles then
            local baseArea = math.max(0, math.floor(tonumber(state.baseArea) or RSE.getSafehouseArea(currentRect)))
            local extraTiles = RSE.getExtraTilesBeyondBaseArea(baseArea, previewRect)
            if extraTiles > maxExtraTiles then
                return RSE.getTextOrFallback(
                    "IGUI_BetterSafehouse_Expansion_Resize_MaxExtraTilesReached",
                    "Expansion limit reached: %1/%2 extra tiles.",
                    tostring(extraTiles),
                    tostring(maxExtraTiles)
                )
            end
        end
    elseif state.flow == "user" then
        if state.userAlreadyExpanded == true then
            return RSE.getTextOrFallback(
                "IGUI_BetterSafehouse_Expansion_Resize_UserAlreadyExpanded",
                "You already used your one-time user safehouse expansion."
            )
        end

        local maxTotalTiles = tonumber(state.maxTotalTiles)
        if maxTotalTiles and maxTotalTiles > 0 then
            local totalTiles = RSE.getSafehouseArea(previewRect)
            if totalTiles > maxTotalTiles then
                return RSE.getTextOrFallback(
                    "IGUI_BetterSafehouse_Expansion_Resize_MaxTotalTilesReached",
                    "Maximum safehouse size reached: %1/%2 total tiles.",
                    tostring(totalTiles),
                    tostring(maxTotalTiles)
                )
            end
        end

        local maxBorderTiles = tonumber(state.userMaxBorderTiles)
        local baseRect = state.baseRect
        if maxBorderTiles and RSE.rectIsValid(baseRect) then
            local border = RSE.getBorderExpansionFromBase(baseRect, previewRect)
            if (not border) or border.max > maxBorderTiles then
                return RSE.getTextOrFallback(
                    "IGUI_BetterSafehouse_Expansion_Resize_UserBorderLimitReached",
                    "Border expansion limit reached: %1/%2.",
                    tostring(border and border.max or "?"),
                    tostring(maxBorderTiles)
                )
            end
        end
    end

    return nil
end

-- Role / user-advanced flow only: how much of the total-size and
-- extra-tiles-beyond-base limits the CURRENT preview (or, absent a preview,
-- the current rect) would use, plus a traffic-light color for it (green =
-- plenty of room, yellow = close to the cap, red = at/over it).
function BSExpansionSafehouseWindow:getLimitStatusInfo(currentRect)
    local greenColor = { r = 0.45, g = 0.85, b = 0.45 }
    local yellowColor = { r = 0.95, g = 0.72, b = 0.25 }
    local redColor = { r = 0.95, g = 0.30, b = 0.30 }
    local neutralColor = { r = 0.75, g = 0.78, b = 0.85 }

    if self:isUserBorderRestrictedMode() or not currentRect then
        return "", neutralColor
    end

    local state = self.expansionLimitState
    if not limitStateMatchesRect(state, currentRect) then
        return RSE.getTextOrFallback(
            "IGUI_BetterSafehouse_Expansion_Resize_SyncingLimit",
            "Syncing expansion limit with server."
        ), neutralColor
    end

    local referenceRect = self.previewRect or currentRect
    local totalTiles = RSE.getSafehouseArea(referenceRect)
    local baseArea = math.max(0, math.floor(tonumber(state.baseArea) or 0))
    local extraTiles = RSE.getExtraTilesBeyondBaseArea(baseArea, referenceRect)

    local maxTotal = tonumber(state.maxTotalTiles)
    local maxExtra = tonumber(state.maxExtraTiles)
    local unlimitedText = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_Unlimited", "unlimited")

    local totalText, totalRatio
    if maxTotal and maxTotal > 0 then
        totalText = tostring(totalTiles) .. "/" .. tostring(maxTotal)
        totalRatio = totalTiles / maxTotal
    else
        totalText = tostring(totalTiles) .. "/" .. unlimitedText
        totalRatio = 0
    end

    local extraText, extraRatio
    if maxExtra and maxExtra > 0 then
        extraText = tostring(extraTiles) .. "/" .. tostring(maxExtra)
        extraRatio = extraTiles / maxExtra
    else
        extraText = tostring(extraTiles) .. "/" .. unlimitedText
        extraRatio = 0
    end

    local text = RSE.getTextOrFallback(
        "IGUI_BetterSafehouse_Expansion_Resize_LimitStatus",
        "Limit: %1 total | %2 extra",
        totalText,
        extraText
    )

    local ratio = math.max(totalRatio, extraRatio)
    local color = greenColor
    if ratio >= 1.0 then
        color = redColor
        text = text .. " " .. RSE.getTextOrFallback(
            "IGUI_BetterSafehouse_Expansion_Resize_LimitReachedSuffix",
            "- LIMIT REACHED"
        )
    elseif ratio >= 0.8 then
        color = yellowColor
    end

    return text, color
end

-- Simple user flow only (single fixed "ALL" action, forced expand).
function BSExpansionSafehouseWindow:canPreviewStepCount(stepCount)
    if not self.selectedAction then return false end

    local currentRect = self:getCurrentRect()
    local totalStep = RSE.normalizeResizeSteps(stepCount, false)
    local previewRect = RSE.calcResizedRect(currentRect, self.selectedAction, totalStep, "expand")
    if not previewRect then return false end

    return self:getPreviewLimitBlockReason(currentRect, previewRect, "expand", true) == nil
end

-- Role / user-advanced flows: each side has its own independent amount.
function BSExpansionSafehouseWindow:canPreviewSideAmounts(candidateAmounts)
    local currentRect = self:getCurrentRect()
    local previewRect = RSE.calcPerSideResizedRect(currentRect, candidateAmounts, self.selectedMode)
    if not previewRect then return false end

    return self:getPreviewLimitBlockReason(currentRect, previewRect, self.selectedMode, true) == nil
end

function BSExpansionSafehouseWindow:canPreviewSideAmount(side, candidateAmount)
    local amounts = {
        N = (self.sideAmounts and self.sideAmounts.N) or 0,
        S = (self.sideAmounts and self.sideAmounts.S) or 0,
        E = (self.sideAmounts and self.sideAmounts.E) or 0,
        W = (self.sideAmounts and self.sideAmounts.W) or 0,
    }
    amounts[side] = candidateAmount
    return self:canPreviewSideAmounts(amounts)
end

-- Fires the head-level + interface warning exactly once, at the moment a
-- "+" control flips from usable to blocked (never on window-open, never on
-- every refresh tick while it stays blocked). `candidateRect` is the rect
-- that specific click would have produced; getPreviewLimitBlockReason gives
-- back the localized, specific reason (total cap vs extra-tiles cap vs
-- user-border cap) so the player knows exactly which limit stopped them.
function BSExpansionSafehouseWindow:announceIfNewlyBlocked(key, isEnabled, currentRect, candidateRect, mode)
    self._prevButtonEnabled = self._prevButtonEnabled or {}
    local wasEnabled = self._prevButtonEnabled[key]
    self._prevButtonEnabled[key] = isEnabled == true

    if wasEnabled ~= true or isEnabled ~= false then return end
    if not currentRect or not candidateRect then return end

    local reason = self:getPreviewLimitBlockReason(currentRect, candidateRect, mode, true)
    if not reason then return end

    sayLocalMessage(reason)
    if self.limitLabel then
        self.limitLabel.r, self.limitLabel.g, self.limitLabel.b = UI_ACCENT_RED_HOVER.r, UI_ACCENT_RED_HOVER.g, UI_ACCENT_RED_HOVER.b
    end
end

function BSExpansionSafehouseWindow:refreshStepButtons()
    if self:isUserBorderRestrictedMode() then
        local queuedSteps = self:getPreviewStepCount(true) or 0
        local hasAction = self.selectedAction ~= nil
        local maxSteps = math.min(
            math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200)),
            math.max(1, RSE.getUserMaxBorderTilesFromOriginal())
        )

        if self.stepValueLabel and self.stepValueLabel.setName then
            self.stepValueLabel:setName(RSE.getTextOrFallback(
                "IGUI_BetterSafehouse_Expansion_Resize_StepCounter",
                "x%1",
                tostring(queuedSteps)
            ))
        end

        if self.decreaseStepButton then
            applyButtonEnableStyle(self.decreaseStepButton, hasAction and queuedSteps > 0)
        end

        if self.increaseStepButton then
            local canIncrease = hasAction and queuedSteps < maxSteps and self:canPreviewStepCount(queuedSteps + 1)
            applyButtonEnableStyle(self.increaseStepButton, canIncrease)

            if hasAction then
                local currentRect = self:getCurrentRect()
                local candidateRect = currentRect and RSE.calcResizedRect(currentRect, self.selectedAction, queuedSteps + 1, "expand")
                self:announceIfNewlyBlocked("stepInc", canIncrease, currentRect, candidateRect, "expand")
            end
        end
        return
    end

    local stepSize = math.max(1, math.floor(tonumber(self.stepSize) or 1))
    local maxAmount = math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200))

    if self.stepValueLabel and self.stepValueLabel.setName then
        self.stepValueLabel:setName(RSE.getTextOrFallback(
            "IGUI_BetterSafehouse_Expansion_Resize_StepSizeCounter",
            "%1 tiles/click",
            tostring(stepSize)
        ))
    end

    if self.decreaseStepButton then
        applyButtonEnableStyle(self.decreaseStepButton, stepSize > 1)
    end

    if self.increaseStepButton then
        applyButtonEnableStyle(self.increaseStepButton, stepSize < maxAmount)
    end

    local currentRect = self:getCurrentRect()
    for _, side in ipairs({ "N", "S", "E", "W" }) do
        local row = self.sideRows and self.sideRows[side]
        if row then
            local amount = math.max(0, math.floor(tonumber(self.sideAmounts and self.sideAmounts[side]) or 0))
            if row.valueLabel and row.valueLabel.setName then
                row.valueLabel:setName(tostring(amount))
                if row.valueSlotX and row.valueSlotW and row.valueLabel.setX then
                    row.valueLabel:setX(row.valueSlotX + math.floor((row.valueSlotW - row.valueLabel.width) / 2))
                end
            end
            if row.decreaseButton then
                applyButtonEnableStyle(row.decreaseButton, amount > 0)
            end
            if row.increaseButton then
                local candidateNext = math.min(maxAmount, amount + stepSize)
                local canIncrease = candidateNext > amount and self:canPreviewSideAmount(side, candidateNext)
                applyButtonEnableStyle(row.increaseButton, canIncrease)

                if currentRect then
                    local candidateAmounts = {
                        N = (self.sideAmounts and self.sideAmounts.N) or 0,
                        S = (self.sideAmounts and self.sideAmounts.S) or 0,
                        E = (self.sideAmounts and self.sideAmounts.E) or 0,
                        W = (self.sideAmounts and self.sideAmounts.W) or 0,
                    }
                    candidateAmounts[side] = candidateNext
                    local candidateRect = RSE.calcPerSideResizedRect(currentRect, candidateAmounts, self.selectedMode)
                    self:announceIfNewlyBlocked(side .. "_inc", canIncrease, currentRect, candidateRect, self.selectedMode)
                end
            end
        end
    end
end

function BSExpansionSafehouseWindow:updateStatusText()
    local currentRect = self:getCurrentRect()
    if not currentRect then
        if self.currentLabel and self.currentLabel.setName then
            self.currentLabel:setName(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse", "Invalid safehouse."))
        end
        if self.stepLabel and self.stepLabel.setName then
            self.stepLabel:setName("")
        end
        if self.limitLabel and self.limitLabel.setName then
            self.limitLabel:setName("")
        end
        if self.previewLabel and self.previewLabel.setName then
            self.previewLabel:setName("")
        end
        return
    end

    local displayedStep = self:isUserBorderRestrictedMode() and 1 or math.max(0, math.floor(tonumber(self.stepSize) or 0))
    local currentArea = RSE.getSafehouseArea(currentRect)
    local currentText = RSE.getTextOrFallback(
        "IGUI_BetterSafehouse_Expansion_Expand_CurrentStatus",
        "Current: %1x%2 (%3 tiles) | Step: %4",
        tostring(currentRect.w),
        tostring(currentRect.h),
        tostring(currentArea),
        tostring(displayedStep)
    )

    if self.currentLabel and self.currentLabel.setName then
        self.currentLabel:setName(currentText)
    end

    if self.stepLabel and self.stepLabel.setName then
        if self:isUserBorderRestrictedMode() then
            if not self:hasConfiguredUserBorderActions() then
                self.stepLabel:setName(RSE.getTextOrFallback(
                    "IGUI_BetterSafehouse_Expansion_UserBorder_NoActionsConfigured",
                    "Sandbox error: no valid border action is configured for user."
                ))
            else
                self.stepLabel:setName(RSE.getTextOrFallback(
                    "IGUI_BetterSafehouse_Expansion_UserBorder_Description",
                    "user expands the whole safehouse outward on every border. Border limit: %1.",
                    tostring(RSE.getUserMaxBorderTilesFromOriginal())
                ))
            end
        else
            self.stepLabel:setName(self:getSideAmountsSummary())
        end
    end

    if self.limitLabel and self.limitLabel.setName then
        local limitText, limitColor = self:getLimitStatusInfo(currentRect)
        self.limitLabel:setName(limitText)
        self.limitLabel.r, self.limitLabel.g, self.limitLabel.b = limitColor.r, limitColor.g, limitColor.b
    end

    if self.previewLabel and self.previewLabel.setName then
        local statusColor = { r = 0.75, g = 0.78, b = 0.85 }

        if self.previewRect then
            local changedTiles = RSE.countPreviewTiles(currentRect, self.previewRect, self.selectedMode)
            local previewKey = "IGUI_BetterSafehouse_Expansion_Resize_PreviewStatusAdd"
            local fallback = "Result: %1x%2 | Added tiles: %3"
            if RSE.isShrinkMode(self.selectedMode) then
                previewKey = "IGUI_BetterSafehouse_Expansion_Resize_PreviewStatusRemove"
                fallback = "Result: %1x%2 | Removed tiles: %3"
            end

            self.previewLabel:setName(RSE.getTextOrFallback(
                previewKey,
                fallback,
                tostring(self.previewRect.w),
                tostring(self.previewRect.h),
                tostring(changedTiles)
            ))
            statusColor = { r = 0.45, g = 0.90, b = 0.45 }
        elseif self.previewMessageText then
            self.previewLabel:setName(tostring(self.previewMessageText))
            statusColor = { r = 0.95, g = 0.30, b = 0.30 }
        elseif self.previewMessageKey then
            self.previewLabel:setName(RSE.getTextOrFallback(
                self.previewMessageKey,
                self.previewMessageKey
            ))
        elseif self:isUserBorderRestrictedMode() then
            self.previewLabel:setName(RSE.getTextOrFallback(
                "IGUI_BetterSafehouse_Expansion_UserBorder_SelectAllowedAction",
                "Select one of the sandbox-allowed borders."
            ))
        else
            self.previewLabel:setName(RSE.getTextOrFallback(
                "IGUI_BetterSafehouse_Expansion_Expand_SelectDirection",
                "Select how to resize the safehouse."
            ))
        end

        self.previewLabel.r, self.previewLabel.g, self.previewLabel.b = statusColor.r, statusColor.g, statusColor.b
    end
end

function BSExpansionSafehouseWindow:refreshActionButtons()
    -- Non-restricted flow no longer creates action buttons (side amounts are
    -- shown via the per-side stepper rows instead), so this loop is only
    -- ever populated in the restricted flow.
    for action, button in pairs(self.actionButtons or {}) do
        local selected = (action == self.selectedAction)
        button.backgroundColor = selected and UI_ACCENT_GREEN or UI_BTN_BG
        button.backgroundColorMouseOver = selected and UI_ACCENT_GREEN_HOVER or UI_BTN_HOVER
        button.borderColor = { r = 1, g = 1, b = 1, a = selected and 0.55 or 0.16 }
    end
end

function BSExpansionSafehouseWindow:refreshModeButtons()
    for mode, button in pairs(self.modeButtons or {}) do
        local selected = (mode == self.selectedMode)
        local colorSelected = UI_ACCENT_GREEN
        local colorSelectedHover = UI_ACCENT_GREEN_HOVER
        if mode == "shrink" then
            colorSelected = UI_ACCENT_RED
            colorSelectedHover = UI_ACCENT_RED_HOVER
        end

        button.backgroundColor = selected and colorSelected or UI_BTN_BG
        button.backgroundColorMouseOver = selected and colorSelectedHover or UI_BTN_HOVER
        button.borderColor = { r = 1, g = 1, b = 1, a = selected and 0.55 or 0.16 }
    end
end

function BSExpansionSafehouseWindow:updatePreview()
    local currentRect = self:getCurrentRect()
    self:syncUserBorderRestrictionSelection()
    local restricted = self:isUserBorderRestrictedMode()
    if restricted then
        self.selectedMode = "expand"
    end
    local hasSelection
    if restricted then
        hasSelection = self.selectedAction ~= nil
    else
        hasSelection = self:hasSelectedSide()
    end
    -- Non-restricted flow no longer has a single "queued amount" to check —
    -- hasSelection already means at least one side's own amount is > 0.
    local queuedAmount = restricted and (self:getPreviewStepCount(true) or 0) or 1

    self.previewRect = nil
    self.previewMessageKey = nil
    self.previewMessageText = nil
    if self.applyButton and self.applyButton.setEnable then
        self.applyButton:setEnable(false)
    end

    if not currentRect or not hasSelection then
        if currentRect and restricted then
            if not self:hasConfiguredUserBorderActions() then
                self.previewMessageKey = "IGUI_BetterSafehouse_Expansion_UserBorder_NoActionsConfigured"
            else
                self.previewMessageKey = "IGUI_BetterSafehouse_Expansion_UserBorder_SelectAllowedAction"
            end
        end
        RSE.clearClientPreview()
        self:updateStatusText()
        self:refreshActionButtons()
        self:refreshModeButtons()
        self:refreshStepButtons()
        return
    end

    if queuedAmount <= 0 then
        self.previewMessageKey = "IGUI_BetterSafehouse_Expansion_Resize_NoQueuedSteps"
        RSE.clearClientPreview()
        self:updateStatusText()
        self:refreshActionButtons()
        self:refreshModeButtons()
        self:refreshStepButtons()
        return
    end

    local previewMode = restricted and "expand" or self.selectedMode
    local previewRect
    if restricted then
        previewRect = RSE.calcResizedRect(currentRect, self.selectedAction, self:getPreviewTotalStep(), previewMode)
    else
        previewRect = RSE.calcPerSideResizedRect(currentRect, self.sideAmounts, previewMode)
    end
    if not previewRect then
        self.previewMessageKey = "IGUI_BetterSafehouse_Expansion_Resize_InvalidResult"
        RSE.clearClientPreview()
        self:updateStatusText()
        self:refreshActionButtons()
        self:refreshModeButtons()
        self:refreshStepButtons()
        return
    end

    local limitBlockReason = self:getPreviewLimitBlockReason(currentRect, previewRect, previewMode, false)
    if limitBlockReason then
        self.previewMessageText = limitBlockReason
        RSE.clearClientPreview()
        self:updateStatusText()
        self:refreshActionButtons()
        self:refreshModeButtons()
        self:refreshStepButtons()
        return
    end

    self.previewRect = previewRect

    local playerObj = getPlayer and getPlayer() or nil
    local targetZ = playerObj and playerObj.getZ and playerObj:getZ() or 0
    RSE.setClientPreview(currentRect, previewRect, targetZ, previewMode)

    if self.applyButton and self.applyButton.setEnable then
        self.applyButton:setEnable(self.pendingRequest ~= true)
    end

    self:updateStatusText()
    self:refreshActionButtons()
    self:refreshModeButtons()
    self:refreshStepButtons()
end

function BSExpansionSafehouseWindow:onSelectAction(button)
    if not button then return end
    local action = tostring(button.internal or "")

    if self:isUserBorderRestrictedMode() then
        if not self:isAllowedUserBorderAction(action) then
            return
        end

        self.selectedAction = action
        self.selectedMode = "expand"
        if (self:getPreviewStepCount(true) or 0) < 1 then
            self.previewSteps = 1
        end
        self.pendingRequest = false
        self:updatePreview()
        return
    end

    -- Non-restricted flow no longer uses action buttons — side selection is
    -- driven by the per-side stepper rows (see onIncreaseSideAmount/onDecreaseSideAmount).
end

function BSExpansionSafehouseWindow:onSelectMode(button)
    if self:isUserBorderRestrictedMode() then
        self.selectedMode = "expand"
        self:updatePreview()
        return
    end

    if not button then return end
    self.selectedMode = RSE.normalizeResizeMode(button.internal) or "expand"
    self.pendingRequest = false
    self:updatePreview()
end

function BSExpansionSafehouseWindow:changePreviewSteps(delta)
    if self:isUserBorderRestrictedMode() then
        if not self.selectedAction then return end

        local current = self:getPreviewStepCount(true) or 0
        local nextValue = current + math.floor(tonumber(delta) or 0)
        local maxSteps = math.min(
            math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200)),
            math.max(1, RSE.getUserMaxBorderTilesFromOriginal())
        )

        if nextValue < 0 then
            nextValue = 0
        elseif nextValue > maxSteps then
            nextValue = maxSteps
        end

        self.previewSteps = nextValue
        self.pendingRequest = false
        self:updatePreview()
        return
    end

    -- Non-restricted flow: this control is the "step size" — how many tiles
    -- each side's own +/- click moves — not an amount applied directly.
    local current = math.max(1, math.floor(tonumber(self.stepSize) or 1))
    local nextValue = current + math.floor(tonumber(delta) or 0)
    local maxAmount = math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200))

    if nextValue < 1 then
        nextValue = 1
    elseif nextValue > maxAmount then
        nextValue = maxAmount
    end

    self.stepSize = nextValue
    self:refreshStepButtons()
end

function BSExpansionSafehouseWindow:onIncreasePreviewSteps()
    self:changePreviewSteps(1)
end

function BSExpansionSafehouseWindow:onDecreasePreviewSteps()
    self:changePreviewSteps(-1)
end

function BSExpansionSafehouseWindow:changeSideAmount(side, deltaClicks)
    if type(self.sideAmounts) ~= "table" then
        self.sideAmounts = { N = 0, S = 0, E = 0, W = 0 }
    end
    if self.sideAmounts[side] == nil then return end

    local stepSize = math.max(1, math.floor(tonumber(self.stepSize) or 1))
    local current = math.max(0, math.floor(tonumber(self.sideAmounts[side]) or 0))
    local nextValue = current + (math.floor(tonumber(deltaClicks) or 0) * stepSize)
    local maxAmount = math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200))

    if nextValue < 0 then
        nextValue = 0
    elseif nextValue > maxAmount then
        nextValue = maxAmount
    end

    self.sideAmounts[side] = nextValue
    self.pendingRequest = false
    self:updatePreview()
end

function BSExpansionSafehouseWindow:onIncreaseSideAmount(button)
    if not button then return end
    self:changeSideAmount(tostring(button.internal or ""), 1)
end

function BSExpansionSafehouseWindow:onDecreaseSideAmount(button)
    if not button then return end
    self:changeSideAmount(tostring(button.internal or ""), -1)
end

function BSExpansionSafehouseWindow:onApply()
    local currentRect = self:getCurrentRect()
    self:syncUserBorderRestrictionSelection()
    local restricted = self:isUserBorderRestrictedMode()
    local mode = restricted and "expand" or self.selectedMode

    if not currentRect or self.pendingRequest then
        return
    end

    local previewRect
    local netArgs = {
        x = currentRect.x,
        y = currentRect.y,
        w = currentRect.w,
        h = currentRect.h,
        mode = mode,
    }

    if restricted then
        local action = self.selectedAction
        local queuedSteps = self:getPreviewStepCount(false)
        if not action or not queuedSteps then
            return
        end

        if not self:hasConfiguredUserBorderActions() then
            return
        end

        if not self:isAllowedUserBorderAction(action) then
            return
        end

        previewRect = RSE.calcResizedRect(currentRect, action, self:getPreviewTotalStep(), mode)
        netArgs.action = action
        netArgs.steps = queuedSteps
    else
        if not self:hasSelectedSide() then
            return
        end

        previewRect = RSE.calcPerSideResizedRect(currentRect, self.sideAmounts, mode)
        if not previewRect then
            return
        end

        netArgs.amountN = math.max(0, math.floor(tonumber(self.sideAmounts.N) or 0))
        netArgs.amountS = math.max(0, math.floor(tonumber(self.sideAmounts.S) or 0))
        netArgs.amountE = math.max(0, math.floor(tonumber(self.sideAmounts.E) or 0))
        netArgs.amountW = math.max(0, math.floor(tonumber(self.sideAmounts.W) or 0))
    end

    local limitBlockReason = self:getPreviewLimitBlockReason(currentRect, previewRect, mode, false)
    if limitBlockReason then
        self.previewRect = nil
        self.previewMessageText = limitBlockReason
        RSE.clearClientPreview()
        self:updateStatusText()
        self:refreshStepButtons()
        return
    end

    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj then
        return
    end

    self.pendingRequest = true
    if self.applyButton and self.applyButton.setEnable then
        self.applyButton:setEnable(false)
    end

    sendClientCommand(playerObj, RSE.NET_MODULE, "ExpansionResize", netArgs)
end

function BSExpansionSafehouseWindow:onCancel()
    self:close()
end

function BSExpansionSafehouseWindow:createActionButton(action, x, y, width, height)
    local button = ISButton:new(x, y, width, height, self:getActionDisplayName(action), self, BSExpansionSafehouseWindow.onSelectAction)
    button:initialise()
    button.internal = action
    styleButton(button, UI_BTN_BG, UI_BTN_HOVER, UI_BTN_BORDER)
    self:addChild(button)
    self.actionButtons[action] = button
end

-- Role / user-advanced flow: one row per cardinal side, each with its own
-- independent "-" / value / "+" stepper (mirrors the repurposed top stepper,
-- one per side).
function BSExpansionSafehouseWindow:createSideStepperRow(side, y, fontH)
    local stepButtonW = 38
    local stepButtonH = 28
    local valueW = 50
    local labelW = 22
    local gap = 8

    local rowW = labelW + gap + stepButtonW + gap + valueW + gap + stepButtonW
    local startX = math.floor((self.width - rowW) / 2)

    local sideLabel = ISLabel:new(startX, y + 4, fontH, side, 1, 1, 1, 1, UIFont.Small, true)
    sideLabel:initialise()
    self:addChild(sideLabel)

    local decX = startX + labelW + gap
    local decreaseButton = ISButton:new(decX, y, stepButtonW, stepButtonH, "-", self, BSExpansionSafehouseWindow.onDecreaseSideAmount)
    decreaseButton:initialise()
    decreaseButton.internal = side
    styleButton(decreaseButton, UI_BTN_BG, UI_BTN_HOVER, UI_BTN_BORDER)
    decreaseButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_DecreaseSideAmount", "Remove one step from this side."))
    self:addChild(decreaseButton)

    -- ISLabel with bLeft=true always sits flush-left at its x — it never
    -- centers within a wider reserved slot, so a 1-2 digit number just hugs
    -- the "-" button instead of sitting in the middle of the "-"/"+" gap.
    -- Center it manually: reposition x after every setName() using the
    -- label's own (freshly re-measured) width against this fixed slot.
    local valueX = decX + stepButtonW + gap
    local valueLabel = ISLabel:new(valueX, y + 4, fontH, "0", 1, 1, 1, 1, UIFont.Small, true)
    valueLabel:initialise()
    valueLabel:setX(valueX + math.floor((valueW - valueLabel.width) / 2))
    self:addChild(valueLabel)

    local incX = valueX + valueW + gap
    local increaseButton = ISButton:new(incX, y, stepButtonW, stepButtonH, "+", self, BSExpansionSafehouseWindow.onIncreaseSideAmount)
    increaseButton:initialise()
    increaseButton.internal = side
    styleButton(increaseButton, UI_BTN_BG, UI_BTN_HOVER, UI_BTN_BORDER)
    increaseButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_IncreaseSideAmount", "Add one step to this side."))
    self:addChild(increaseButton)

    self.sideRows = self.sideRows or {}
    self.sideRows[side] = {
        label = sideLabel,
        decreaseButton = decreaseButton,
        valueLabel = valueLabel,
        valueSlotX = valueX,
        valueSlotW = valueW,
        increaseButton = increaseButton,
    }
end

function BSExpansionSafehouseWindow:createModeButton(mode, label, x, y, width, height)
    local button = ISButton:new(x, y, width, height, label, self, BSExpansionSafehouseWindow.onSelectMode)
    button:initialise()
    button.internal = mode
    styleButton(button, UI_BTN_BG, UI_BTN_HOVER, UI_BTN_BORDER)
    self:addChild(button)
    self.modeButtons[mode] = button
end

function BSExpansionSafehouseWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    self.actionButtons = {}
    self.modeButtons = {}
    self:setResizable(false)
    self.backgroundColor = { r = 0.06, g = 0.065, b = 0.075, a = 0.96 }
    self.borderColor = { r = 0.72, g = 0.74, b = 0.80, a = 0.36 }

    local pad = 16
    local fontH = 14
    if getTextManager and getTextManager() and getTextManager().getFontHeight then
        local okFont, value = pcall(function()
            return getTextManager():getFontHeight(UIFont.Small)
        end)
        if okFont and type(value) == "number" and value > 0 then
            fontH = value
        end
    end
    local fontHMedium = 20
    if getTextManager and getTextManager() and getTextManager().getFontHeight then
        local okFontM, valueM = pcall(function()
            return getTextManager():getFontHeight(UIFont.Medium)
        end)
        if okFontM and type(valueM) == "number" and valueM > 0 then
            fontHMedium = valueM
        end
    end

    -- Info card: groups the four status lines into one subtle panel instead
    -- of leaving them floating directly on the window background. Sized from
    -- the actual line count/spacing instead of a fixed guess, so the four
    -- lines (current/step/limit/preview) never crowd or spill past the card's
    -- bottom edge — everything below shifts down by the same amount so the
    -- rest of the layout's relative spacing is unchanged.
    local cardTop = 30
    local cardLineGap = 24
    local cardFirstLineY = 42
    local cardBottomPad = 16
    local cardHeight = (cardFirstLineY - cardTop) + (3 * cardLineGap) + fontH + cardBottomPad
    local layoutShift = cardHeight - 96

    local infoCard = ISPanel:new(10, cardTop, self.width - 20, cardHeight)
    infoCard.backgroundColor = UI_CARD_BG
    infoCard.borderColor = UI_CARD_BORDER
    infoCard:initialise()
    self:addChild(infoCard)

    self.currentLabel = ISLabel:new(pad, cardFirstLineY, fontH, "", 1, 1, 1, 1, UIFont.Small, true)
    self.currentLabel:initialise()
    self:addChild(self.currentLabel)

    self.stepLabel = ISLabel:new(pad, cardFirstLineY + cardLineGap, fontH, "", 0.72, 0.84, 1.0, 1, UIFont.Small, true)
    self.stepLabel:initialise()
    self:addChild(self.stepLabel)

    self.limitLabel = ISLabel:new(pad, cardFirstLineY + (cardLineGap * 2), fontH, "", 0.75, 0.78, 0.85, 1, UIFont.Small, true)
    self.limitLabel:initialise()
    if self.limitLabel.setTooltip then
        self.limitLabel:setTooltip(RSE.getTextOrFallback(
            "IGUI_BetterSafehouse_Expansion_Resize_LimitStatus_tooltip",
            "Total: every tile the safehouse would occupy after this resize, capped at the server's maximum safehouse size. Extra: how many of those tiles sit beyond the safehouse's original footprint, capped separately - this recalculates from the current size, so shrinking back down frees it up again."
        ))
    end
    self:addChild(self.limitLabel)

    self.previewLabel = ISLabel:new(pad, cardFirstLineY + (cardLineGap * 3), fontH, "", 0.98, 0.84, 0.48, 1, UIFont.Small, true)
    self.previewLabel:initialise()
    self:addChild(self.previewLabel)

    local hintLabel = ISLabel:new(
        pad,
        132 + layoutShift,
        fontH,
        RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_PreviewHint", "Preview highlights the tiles that will change."),
        UI_COLOR_META.r, UI_COLOR_META.g, UI_COLOR_META.b, 1,
        UIFont.Small,
        true
    )
    hintLabel:initialise()
    self:addChild(hintLabel)

    local modeTop = 156 + layoutShift
    local modeW = 128
    local modeH = 28
    local modeGap = 12
    local totalModeW = (modeW * 2) + modeGap
    local modeX = math.floor((self.width - totalModeW) / 2)

    self:createModeButton(
        "expand",
        RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_ModeExpand", "Expand"),
        modeX,
        modeTop,
        modeW,
        modeH
    )
    self:createModeButton(
        "shrink",
        RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_ModeShrink", "Shrink"),
        modeX + modeW + modeGap,
        modeTop,
        modeW,
        modeH
    )

    local stepControlTop = 198 + layoutShift
    local stepButtonW = 38
    local stepButtonH = 28
    local stepValueW = 70
    local stepGap = 12
    local totalStepControlsW = (stepButtonW * 2) + stepValueW + (stepGap * 2)
    local stepStartX = math.floor((self.width - totalStepControlsW) / 2)

    local restrictedFlow = self:isUserBorderRestrictedMode()

    self.decreaseStepButton = ISButton:new(stepStartX, stepControlTop, stepButtonW, stepButtonH, "-", self, BSExpansionSafehouseWindow.onDecreasePreviewSteps)
    self.decreaseStepButton:initialise()
    styleButton(self.decreaseStepButton, UI_BTN_BG, UI_BTN_HOVER, UI_BTN_BORDER)
    if restrictedFlow then
        self.decreaseStepButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_RemoveStep", "Remove one queued step from the preview."))
    else
        self.decreaseStepButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_DecreaseStepSize", "Decrease tiles added per click."))
    end
    self:addChild(self.decreaseStepButton)

    self.stepValueLabel = ISLabel:new(stepStartX + stepButtonW + stepGap, stepControlTop + 4, fontH, "", 1, 1, 1, 1, UIFont.Small, true)
    self.stepValueLabel:initialise()
    self:addChild(self.stepValueLabel)

    self.increaseStepButton = ISButton:new(stepStartX + stepButtonW + stepGap + stepValueW + stepGap, stepControlTop, stepButtonW, stepButtonH, "+", self, BSExpansionSafehouseWindow.onIncreasePreviewSteps)
    self.increaseStepButton:initialise()
    styleButton(self.increaseStepButton, UI_BTN_BG, UI_BTN_HOVER, UI_BTN_BORDER)
    if restrictedFlow then
        self.increaseStepButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_AddStep", "Add one more queued step to the preview."))
    else
        self.increaseStepButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_IncreaseStepSize", "Increase tiles added per click."))
    end
    self:addChild(self.increaseStepButton)

    if restrictedFlow then
        local gridTop = 244 + layoutShift
        local buttonW = 82
        local buttonH = 31
        local gap = 10
        local totalW = (buttonW * 3) + (gap * 2)
        local startX = math.floor((self.width - totalW) / 2)

        local rows = {
            { "NW", "N",  "NE" },
            { "W",  "ALL","E"  },
            { "SW", "S",  "SE" },
        }

        for rowIndex, row in ipairs(rows) do
            for colIndex, action in ipairs(row) do
                local x = startX + ((colIndex - 1) * (buttonW + gap))
                local y = gridTop + ((rowIndex - 1) * (buttonH + gap))
                self:createActionButton(action, x, y, buttonW, buttonH)
            end
        end

        for _, button in pairs(self.modeButtons) do
            setElementVisible(button, false)
        end

        for action, button in pairs(self.actionButtons) do
            local isCardinal = action == "N" or action == "S" or action == "E" or action == "W"
            local isAll = action == "ALL"
            local isVisible = self:hasConfiguredUserBorderActions()
                and (isAll or isCardinal)
                and self:isAllowedUserBorderAction(action)

            setElementVisible(button, isVisible)
            if isVisible and isAll then
                setButtonTitle(button, RSE.getTextOrFallback(
                    "IGUI_BetterSafehouse_Expansion_UserBorder_AllAction",
                    "Whole border"
                ))
                setElementBounds(
                    button,
                    math.floor((self.width - 240) / 2),
                    gridTop + buttonH + gap,
                    240,
                    34
                )
            end
        end

        self.selectedMode = "expand"
        self:syncUserBorderRestrictionSelection()
    else
        -- Role / user-advanced: each side gets its own independent stepper
        -- row instead of a toggle button, stacked vertically since a "-"/
        -- value/"+" row needs more width than the old cross-shaped grid cells.
        -- Grouped under its own header + card so it reads as one section,
        -- distinct from the step-size control above it.
        local sideSectionCard = ISPanel:new(10, 236 + layoutShift, self.width - 20, 186)
        sideSectionCard.backgroundColor = UI_CARD_BG
        sideSectionCard.borderColor = UI_CARD_BORDER
        sideSectionCard:initialise()
        self:addChild(sideSectionCard)

        local sectionHeaderText = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_PerSideSectionTitle", "Adjust each side")
        local sectionHeaderW = 200
        local okTm, tm = pcall(getTextManager)
        if okTm and tm and tm.MeasureStringX then
            local okW, measuredW = pcall(function() return tm:MeasureStringX(UIFont.Medium, sectionHeaderText) end)
            if okW and type(measuredW) == "number" and measuredW > 0 then
                sectionHeaderW = measuredW
            end
        end

        local sectionHeaderLabel = ISLabel:new(
            math.floor((self.width - sectionHeaderW) / 2),
            244 + layoutShift,
            fontHMedium,
            sectionHeaderText,
            UI_COLOR_HEADER.r, UI_COLOR_HEADER.g, UI_COLOR_HEADER.b, 1,
            UIFont.Medium,
            true
        )
        sectionHeaderLabel:initialise()
        self:addChild(sectionHeaderLabel)

        local rowsTop = 272 + layoutShift
        local rowH = 28
        local rowGap = 10

        for i, side in ipairs({ "N", "S", "E", "W" }) do
            self:createSideStepperRow(side, rowsTop + ((i - 1) * (rowH + rowGap)), fontH)
        end
    end

    self.applyButton = ISButton:new(
        self.width - 216,
        self.height - 44,
        96,
        28,
        RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_Apply", "Apply"),
        self,
        BSExpansionSafehouseWindow.onApply
    )
    self.applyButton:initialise()
    styleButton(self.applyButton, UI_ACCENT_GREEN, UI_ACCENT_GREEN_HOVER, { r = 1, g = 1, b = 1, a = 0.22 })
    self:addChild(self.applyButton)

    self.cancelButton = ISButton:new(
        self.width - 110,
        self.height - 44,
        92,
        28,
        RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Generic_Close", "Close"),
        self,
        BSExpansionSafehouseWindow.onCancel
    )
    self.cancelButton:initialise()
    styleButton(self.cancelButton, UI_BTN_BG, UI_BTN_HOVER, { r = 1, g = 1, b = 1, a = 0.22 })
    self:addChild(self.cancelButton)

    if self:isUserBorderRestrictedMode() then
        self:updatePreview()
        return
    end

    self:updateStatusText()
    self:refreshActionButtons()
    self:refreshModeButtons()
    self:refreshStepButtons()
    if self.applyButton and self.applyButton.setEnable then
        self.applyButton:setEnable(false)
    end
end

function BSExpansionSafehouseWindow:prerender()
    ISCollapsableWindow.prerender(self)
end

function BSExpansionSafehouseWindow:close()
    RSE.clearClientPreview()
    if BSExpansionSafehouseWindow.instance == self then
        BSExpansionSafehouseWindow.instance = nil
    end
    self:setVisible(false)
    if self.removeFromUIManager then
        self:removeFromUIManager()
    end
end

function RSE.openExpandWindow(safehouse, parentUI)
    local width = 430
    -- +22 vs the old 488: the top status card grew to stop its four lines
    -- (current/step/limit/preview) from crowding/spilling past its bottom
    -- edge (see the cardHeight/layoutShift computation in createChildren) —
    -- everything below it shifts down by the same amount, so the window
    -- needs to grow to match or the bottom section gets clipped.
    local height = 510
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local x = math.floor((screenW - width) / 2)
    local y = math.floor((screenH - height) / 2)

    if parentUI and parentUI.getX and parentUI.getY then
        x = math.floor(parentUI:getX() + 32)
        y = math.floor(parentUI:getY() + 32)
    end

    if x + width > screenW then
        x = math.max(0, screenW - width)
    end
    if y + height > screenH then
        y = math.max(0, screenH - height)
    end

    local window = BSExpansionSafehouseWindow:new(x, y, width, height, safehouse, parentUI)
    window:initialise()
    window:instantiate()
    window:addToUIManager()
    window:setVisible(true)

    BSExpansionSafehouseWindow.instance = window
    window:requestExpansionLimitState(true)

    -- Turn the safehouse boundary viewer on automatically so the player can
    -- see the resize preview against the current claimed area. Its auto-off
    -- timer is held off automatically while this window stays open/visible
    -- (see isExpansionUIOpen() in BetterSafehouse_Viewer.lua).
    local playerObj = getPlayer and getPlayer() or nil
    if playerObj and BetterSafehouse.activateViewerForSafehouse then
        BetterSafehouse.activateViewerForSafehouse(safehouse, playerObj)
    end

    return window
end

local function onServerCommand(module, command, args)
    if module ~= RSE.NET_MODULE then return end

    if command == "ExpansionLimitState" then
        if BSExpansionSafehouseWindow and BSExpansionSafehouseWindow.instance then
            BSExpansionSafehouseWindow.instance.expansionLimitState = expansionLimitStateFromPayload(args)
            BSExpansionSafehouseWindow.instance.limitStateRequested = false
            pcall(function()
                BSExpansionSafehouseWindow.instance:updatePreview()
            end)
        end
        return
    end

    if command == "ExpansionResult" then
        if BSExpansionSafehouseWindow and BSExpansionSafehouseWindow.instance then
            local instance = BSExpansionSafehouseWindow.instance
            if args and args.ok then
                if instance:isUserBorderRestrictedMode() then
                    -- One-time flow: nothing left to do with this window.
                    pcall(function()
                        instance:close()
                    end)
                else
                    -- Role / user-advanced: keep the window open so the player
                    -- can queue up another combination of sides without
                    -- reopening it from scratch.
                    instance.pendingRequest = false
                    instance.sideAmounts = { N = 0, S = 0, E = 0, W = 0 }
                    pcall(function()
                        instance:updatePreview()
                    end)
                end
            else
                instance.pendingRequest = false
                pcall(function()
                    instance:updatePreview()
                end)
            end
        else
            RSE.clearClientPreview()
        end

        local text = localizeServerResult(args)
        if text ~= "" then
            sayLocalMessage(text)
        end
        return
    end

    if command == "ExpansionSafehouseResized" then
        applySafehouseResized(args)
        return
    end
end

if not RSE._ClientEventsInstalled then
    Events.OnTick.Add(previewOnTick)
    Events.OnServerCommand.Add(onServerCommand)
    RSE._ClientEventsInstalled = true
end
