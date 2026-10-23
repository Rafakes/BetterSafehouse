if isServer() and not isClient() then
    return
end

require "BetterSafehouse/BetterSafehouse_Expansion_Shared"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISCollapsableWindow"

local RSE = BetterSafehouse.Expansion

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

local function applyBetterSafehouseHighlightToSquare(square)
    if not square then return end

    local floor = square.getFloor and square:getFloor() or nil
    if floor and floor.setHighlightColor then
        floor:setHighlightColor(0.15, 0.45, 1.0, 0.55)
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

local function applyPreviewToSquare(square, mode)
    if not square then return end

    local floor = square.getFloor and square:getFloor() or nil
    local r = 0.15
    local g = 1.0
    local b = 0.18
    local a = 0.72

    if RSE.isShrinkMode(mode) then
        r = 1.0
        g = 0.12
        b = 0.12
        a = 0.74
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

    RSE.forEachPreviewTile(oldRect, newRect, mode, function(x, y)
        local key = previewKey(x, y, targetZ)
        wanted[key] = true

        if not RSE.ClientPreview.appliedSquares[key] then
            local square = cell:getGridSquare(x, y, targetZ)
            if square then
                applyPreviewToSquare(square, mode)
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
    local roleName = playerObj and RSE.getPlayerRoleName(playerObj) or nil
    local button = ui.BS_expansionButton
    local enabled = false
    local tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_ExpandSafehouse_Button_tooltip", "Owner-only safehouse resize.")

    if not RSE.isEnabled() then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_DisabledBySandbox", "Safehouse resize is disabled in sandbox.")
    elseif not playerObj or not ui.safehouse then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse", "Invalid safehouse.")
    elseif not RSE.isSafehouseOwner(playerObj, ui.safehouse) then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_OwnerOnly", "Only the safehouse owner can resize it.")
    elseif not roleName or not RSE.getPlayerResizeFlow(playerObj) then
        tooltip = RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Expand_RoleDenied", "Your role cannot resize safehouses.")
    elseif RSE.isPlayerUserBorderExpansionActive(playerObj) and RSE.getUserMaxBorderTilesFromOriginal() < 1 then
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
    window.selectedMode = "expand"
    window.previewSteps = 1
    window.userBorderRestrictionsActive = RSE.isPlayerUserBorderExpansionActive(playerObj) == true
    window.pendingRequest = false
    window.previewRect = nil
    window.previewMessageKey = nil
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

function BSExpansionSafehouseWindow:isUserBorderRestrictedMode()
    return self.userBorderRestrictionsActive == true
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

function BSExpansionSafehouseWindow:getPreviewTotalStep()
    if self:isUserBorderRestrictedMode() then
        return self:getPreviewStepCount(false) or 0
    end

    return RSE.getTotalResizeStep(RSE.getExpandStepTiles(), self:getPreviewStepCount(false))
end

function BSExpansionSafehouseWindow:refreshStepButtons()
    local queuedSteps = self:getPreviewStepCount(true) or 0
    local hasAction = self.selectedAction ~= nil
    local maxSteps = math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200))
    if self:isUserBorderRestrictedMode() then
        maxSteps = math.min(maxSteps, math.max(1, RSE.getUserMaxBorderTilesFromOriginal()))
    end

    if self.stepValueLabel and self.stepValueLabel.setName then
        self.stepValueLabel:setName(RSE.getTextOrFallback(
            "IGUI_BetterSafehouse_Expansion_Resize_StepCounter",
            "x%1",
            tostring(queuedSteps)
        ))
    end

    if self.decreaseStepButton and self.decreaseStepButton.setEnable then
        self.decreaseStepButton:setEnable(hasAction and queuedSteps > 0)
    end

    if self.increaseStepButton and self.increaseStepButton.setEnable then
        self.increaseStepButton:setEnable(hasAction and queuedSteps < maxSteps)
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
        if self.previewLabel and self.previewLabel.setName then
            self.previewLabel:setName("")
        end
        return
    end

    local displayedStep = self:isUserBorderRestrictedMode() and 1 or RSE.getExpandStepTiles()
    local currentText = RSE.getTextOrFallback(
        "IGUI_BetterSafehouse_Expansion_Expand_CurrentStatus",
        "Current: %1x%2 | Step: %3",
        tostring(currentRect.w),
        tostring(currentRect.h),
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
            local queuedSteps = self:getPreviewStepCount(true) or 0
            local totalChange = self:getPreviewTotalStep()
            self.stepLabel:setName(RSE.getTextOrFallback(
                "IGUI_BetterSafehouse_Expansion_Resize_StepSummary",
                "Queued steps: %1 | Total change: %2",
                tostring(queuedSteps),
                tostring(totalChange)
            ))
        end
    end

    if self.previewLabel and self.previewLabel.setName then
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
    end
end

function BSExpansionSafehouseWindow:refreshActionButtons()
    local colorSelected = { r = 0.18, g = 0.48, b = 0.32, a = 1.0 }
    local colorDefault = { r = 0.20, g = 0.21, b = 0.26, a = 1.0 }
    local hover = { r = 0.28, g = 0.30, b = 0.36, a = 1.0 }

    for action, button in pairs(self.actionButtons or {}) do
        local selected = (action == self.selectedAction)
        button.backgroundColor = selected and colorSelected or colorDefault
        button.backgroundColorMouseOver = hover
        button.borderColor = { r = 1, g = 1, b = 1, a = selected and 0.55 or 0.16 }
    end
end

function BSExpansionSafehouseWindow:refreshModeButtons()
    local hover = { r = 0.28, g = 0.30, b = 0.36, a = 1.0 }

    for mode, button in pairs(self.modeButtons or {}) do
        local selected = (mode == self.selectedMode)
        local colorSelected = { r = 0.18, g = 0.48, b = 0.32, a = 1.0 }
        if mode == "shrink" then
            colorSelected = { r = 0.58, g = 0.23, b = 0.26, a = 1.0 }
        end

        button.backgroundColor = selected and colorSelected or { r = 0.20, g = 0.21, b = 0.26, a = 1.0 }
        button.backgroundColorMouseOver = hover
        button.borderColor = { r = 1, g = 1, b = 1, a = selected and 0.55 or 0.16 }
    end
end

function BSExpansionSafehouseWindow:updatePreview()
    local currentRect = self:getCurrentRect()
    self:syncUserBorderRestrictionSelection()
    if self:isUserBorderRestrictedMode() then
        self.selectedMode = "expand"
    end
    local queuedSteps = self:getPreviewStepCount(true) or 0

    self.previewRect = nil
    self.previewMessageKey = nil
    if self.applyButton and self.applyButton.setEnable then
        self.applyButton:setEnable(false)
    end

    if not currentRect or not self.selectedAction then
        if currentRect and self:isUserBorderRestrictedMode() then
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

    if queuedSteps <= 0 then
        self.previewMessageKey = "IGUI_BetterSafehouse_Expansion_Resize_NoQueuedSteps"
        RSE.clearClientPreview()
        self:updateStatusText()
        self:refreshActionButtons()
        self:refreshModeButtons()
        self:refreshStepButtons()
        return
    end

    local previewMode = self:isUserBorderRestrictedMode() and "expand" or self.selectedMode
    local previewRect = RSE.calcResizedRect(currentRect, self.selectedAction, self:getPreviewTotalStep(), previewMode)
    if not previewRect then
        self.previewMessageKey = "IGUI_BetterSafehouse_Expansion_Resize_InvalidResult"
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
    if self:isUserBorderRestrictedMode() and not self:isAllowedUserBorderAction(action) then
        return
    end

    self.selectedAction = action
    if self:isUserBorderRestrictedMode() then
        self.selectedMode = "expand"
    end
    if (self:getPreviewStepCount(true) or 0) < 1 then
        self.previewSteps = 1
    end
    self.pendingRequest = false
    self:updatePreview()
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
    if not self.selectedAction then
        return
    end

    local current = self:getPreviewStepCount(true) or 0
    local nextValue = current + math.floor(tonumber(delta) or 0)
    local maxSteps = math.max(1, math.floor(tonumber(RSE.MAX_RESIZE_STEPS) or 200))
    if self:isUserBorderRestrictedMode() then
        maxSteps = math.min(maxSteps, math.max(1, RSE.getUserMaxBorderTilesFromOriginal()))
    end

    if nextValue < 0 then
        nextValue = 0
    elseif nextValue > maxSteps then
        nextValue = maxSteps
    end

    self.previewSteps = nextValue
    self.pendingRequest = false
    self:updatePreview()
end

function BSExpansionSafehouseWindow:onIncreasePreviewSteps()
    self:changePreviewSteps(1)
end

function BSExpansionSafehouseWindow:onDecreasePreviewSteps()
    self:changePreviewSteps(-1)
end

function BSExpansionSafehouseWindow:onApply()
    local currentRect = self:getCurrentRect()
    self:syncUserBorderRestrictionSelection()

    local action = self.selectedAction
    local mode = self:isUserBorderRestrictedMode() and "expand" or self.selectedMode
    local queuedSteps = self:getPreviewStepCount(false)
    if not currentRect or not action or self.pendingRequest or not queuedSteps then
        return
    end

    if self:isUserBorderRestrictedMode() then
        if not self:hasConfiguredUserBorderActions() then
            return
        end

        if not self:isAllowedUserBorderAction(action) then
            return
        end
    end

    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj then
        return
    end

    self.pendingRequest = true
    if self.applyButton and self.applyButton.setEnable then
        self.applyButton:setEnable(false)
    end

    sendClientCommand(playerObj, RSE.NET_MODULE, "ExpansionResize", {
        x = currentRect.x,
        y = currentRect.y,
        w = currentRect.w,
        h = currentRect.h,
        action = action,
        mode = mode,
        steps = queuedSteps,
    })
end

function BSExpansionSafehouseWindow:onCancel()
    self:close()
end

function BSExpansionSafehouseWindow:createActionButton(action, x, y, width, height)
    local button = ISButton:new(x, y, width, height, self:getActionDisplayName(action), self, BSExpansionSafehouseWindow.onSelectAction)
    button:initialise()
    button.internal = action
    button.backgroundColor = { r = 0.20, g = 0.21, b = 0.26, a = 1.0 }
    button.backgroundColorMouseOver = { r = 0.28, g = 0.30, b = 0.36, a = 1.0 }
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.16 }
    self:addChild(button)
    self.actionButtons[action] = button
end

function BSExpansionSafehouseWindow:createModeButton(mode, label, x, y, width, height)
    local button = ISButton:new(x, y, width, height, label, self, BSExpansionSafehouseWindow.onSelectMode)
    button:initialise()
    button.internal = mode
    button.backgroundColor = { r = 0.20, g = 0.21, b = 0.26, a = 1.0 }
    button.backgroundColorMouseOver = { r = 0.28, g = 0.30, b = 0.36, a = 1.0 }
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.16 }
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

    local pad = 18
    local fontH = 14
    if getTextManager and getTextManager() and getTextManager().getFontHeight then
        local okFont, value = pcall(function()
            return getTextManager():getFontHeight(UIFont.Small)
        end)
        if okFont and type(value) == "number" and value > 0 then
            fontH = value
        end
    end

    self.currentLabel = ISLabel:new(pad, 40, fontH, "", 1, 1, 1, 1, UIFont.Small, true)
    self.currentLabel:initialise()
    self:addChild(self.currentLabel)

    self.stepLabel = ISLabel:new(pad, 62, fontH, "", 0.72, 0.84, 1.0, 1, UIFont.Small, true)
    self.stepLabel:initialise()
    self:addChild(self.stepLabel)

    self.previewLabel = ISLabel:new(pad, 84, fontH, "", 0.98, 0.84, 0.48, 1, UIFont.Small, true)
    self.previewLabel:initialise()
    self:addChild(self.previewLabel)

    local hintLabel = ISLabel:new(
        pad,
        106,
        fontH,
        RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_PreviewHint", "Preview highlights the tiles that will change."),
        0.70, 0.72, 0.76, 1,
        UIFont.Small,
        true
    )
    hintLabel:initialise()
    self:addChild(hintLabel)

    local modeTop = 134
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

    local stepControlTop = 176
    local stepButtonW = 38
    local stepButtonH = 28
    local stepValueW = 70
    local stepGap = 12
    local totalStepControlsW = (stepButtonW * 2) + stepValueW + (stepGap * 2)
    local stepStartX = math.floor((self.width - totalStepControlsW) / 2)

    self.decreaseStepButton = ISButton:new(stepStartX, stepControlTop, stepButtonW, stepButtonH, "-", self, BSExpansionSafehouseWindow.onDecreasePreviewSteps)
    self.decreaseStepButton:initialise()
    self.decreaseStepButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_RemoveStep", "Remove one queued step from the preview."))
    self:addChild(self.decreaseStepButton)

    self.stepValueLabel = ISLabel:new(stepStartX + stepButtonW + stepGap, stepControlTop + 4, fontH, "", 1, 1, 1, 1, UIFont.Small, true)
    self.stepValueLabel:initialise()
    self:addChild(self.stepValueLabel)

    self.increaseStepButton = ISButton:new(stepStartX + stepButtonW + stepGap + stepValueW + stepGap, stepControlTop, stepButtonW, stepButtonH, "+", self, BSExpansionSafehouseWindow.onIncreasePreviewSteps)
    self.increaseStepButton:initialise()
    self.increaseStepButton:setTooltip(RSE.getTextOrFallback("IGUI_BetterSafehouse_Expansion_Resize_AddStep", "Add one more queued step to the preview."))
    self:addChild(self.increaseStepButton)

    local gridTop = 222
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

    if self:isUserBorderRestrictedMode() then
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
    self.applyButton.backgroundColor = { r = 0.16, g = 0.42, b = 0.30, a = 1.0 }
    self.applyButton.backgroundColorMouseOver = { r = 0.22, g = 0.54, b = 0.40, a = 1.0 }
    self.applyButton.borderColor = { r = 1, g = 1, b = 1, a = 0.22 }
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
    self.cancelButton.backgroundColor = { r = 0.16, g = 0.17, b = 0.20, a = 1.0 }
    self.cancelButton.backgroundColorMouseOver = { r = 0.24, g = 0.25, b = 0.30, a = 1.0 }
    self.cancelButton.borderColor = { r = 1, g = 1, b = 1, a = 0.22 }
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
    local height = 388
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
    return window
end

local function onServerCommand(module, command, args)
    if module ~= RSE.NET_MODULE then return end

    if command == "ExpansionResult" then
        if BSExpansionSafehouseWindow and BSExpansionSafehouseWindow.instance then
            if args and args.ok then
                pcall(function()
                    BSExpansionSafehouseWindow.instance:close()
                end)
            else
                BSExpansionSafehouseWindow.instance.pendingRequest = false
                pcall(function()
                    BSExpansionSafehouseWindow.instance:updatePreview()
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
