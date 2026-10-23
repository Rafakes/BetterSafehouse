--[[
    Better Safehouse - Viewer toggle inside the CLIENT user panel (ISUserPanelUI)
    B42 MP-friendly patch inspired by ServerTweaker's approach (B41):
      - Wraps ISUserPanelUI.create or createChildren (whichever exists)
      - Adds a tickbox below "Mostrar Informações do Servidor"
      - Stores per-player preference in player modData
      - Respects server sandbox option BetterSafehouse.EnableSafehouseViewer
--]]

BetterSafehouse = BetterSafehouse or {}

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

local function isUIElement(o)
    return type(o) == "table" and o.getX and o.getY and o.getWidth and o.getHeight
end

local function getLabelText()
    -- Prefer IGUI keys (in-game UI). Fallbacks keep the mod usable even if translations are missing.
    local txt = getTextOrNull and getTextOrNull("IGUI_BetterSafehouse_ViewerToggle") or nil
    if txt and txt ~= "" then return txt end
    txt = getTextOrNull and getTextOrNull("UI_BetterSafehouse_ViewerToggle") or nil
    if txt and txt ~= "" then return txt end
    return "Show safehouse area"
end

local function getTooltipText(enabledByServer)
    if not enabledByServer then
        local txt = getTextOrNull and getTextOrNull("IGUI_BetterSafehouse_ViewerToggle_disabledByServer") or nil
        if txt and txt ~= "" then return txt end
        return "Disabled in the server sandbox options."
    end
    local txt = getTextOrNull and getTextOrNull("IGUI_BetterSafehouse_ViewerToggle_tooltip") or nil
    if txt and txt ~= "" then return txt end
    return "Highlights the tiles inside your current safehouse on the ground."
end

local function findCloseButton(self)
    -- Different builds/UI mods can name this differently.
    local candidates = {
        self.closeBtn, self.closeButton, self.btnClose, self.close, self.ok, self.okBtn
    }
    for _,c in ipairs(candidates) do
        if isUIElement(c) and c.setY then
            return c
        end
    end

    -- Fallback: scan children for an ISButton with label "FECHAR"/"Close"/etc.
    if self and self.children then
        for _,child in pairs(self.children) do
            if child and child.Type == "ISButton" and child.setY and child.title then
                local t = tostring(child.title)
                if t:lower():find("fechar") or t:lower():find("close") or t:lower():find("ok") then
                    return child
                end
            end
        end
    end

    return nil
end

local function addViewerTickBox(self)
    if not self or self._BetterSafehouseViewerTickAdded then return end
    self._BetterSafehouseViewerTickAdded = true

    -- Anchor under existing vanilla tickboxes, like ServerTweaker does.
    local anchor = self.showServerInfo or self.showConnectionInfo
    local x = 20
    local y = 0
    local w = (self.getWidth and self:getWidth() or 360) - 40
    local h = math.max(22, FONT_HGT_SMALL + 6)

    if isUIElement(anchor) then
        x = anchor:getX()
        y = anchor:getY() + anchor:getHeight() + 6
        w = anchor:getWidth()
    else
        -- Fallback positioning similar to vanilla layout.
        y = 70 + (h + 5) * 4
    end

    local tick = ISTickBox:new(x, y, w, h, "", self, BetterSafehouse.onUserPanelViewerToggle)
    tick:initialise()
    tick:instantiate()

    tick:addOption(getLabelText())

    local playerObj = getPlayer()
    tick.selected[1] = BetterSafehouse.getClientViewerPref(playerObj)

    local enabledByServer = BetterSafehouse.isViewerEnabledBySandbox()
    if tick.setEnabled then tick:setEnabled(enabledByServer) else tick.enable = enabledByServer end
    tick.tooltip = getTooltipText(enabledByServer)


    -- If server disabled the viewer, keep the toggle OFF and ensure no overlay remains.
    if not enabledByServer then
        tick.selected[1] = false
        local pl = getPlayer()
        if pl then BetterSafehouse.setClientViewerPref(pl, false) end
        if BetterSafehouse.Viewer and BetterSafehouse.Viewer.clear then
            BetterSafehouse.Viewer.clear()
        end
    end
    self:addChild(tick)
    self.safehouseWhitelistViewerTick = tick

    -- If it collides with close button, push it down and resize panel.
    local closeBtn = findCloseButton(self)
    if closeBtn and isUIElement(closeBtn) then
        local tickBottom = y + h + 10
        if closeBtn:getY() < tickBottom then
            local delta = tickBottom - closeBtn:getY()
            closeBtn:setY(closeBtn:getY() + delta)
            if self.setHeight and self.getHeight then
                self:setHeight(self:getHeight() + delta)
            end
        end
    end
end

-- Callback signature for ISTickBox: (self, optionIndex, selected)
function BetterSafehouse:onUserPanelViewerToggle(option, enabled)
    local playerObj = getPlayer()
    if not playerObj then return end

    -- If server/sandbox disabled the viewer, force OFF and clear any overlay.
    local allow = BetterSafehouse.isViewerEnabledBySandbox()
    local ena = (enabled == true) and allow

    BetterSafehouse.setClientViewerPref(playerObj, ena)

    if not ena then
        -- IMPORTANT: clear squares already highlighted, otherwise they stay permanently.
        if BetterSafehouse.Viewer and BetterSafehouse.Viewer.clear then
            BetterSafehouse.Viewer.clear()
        end
        return
    end

    -- Force immediate refresh by clearing viewer cache
    if BetterSafehouse.Viewer then
        BetterSafehouse.Viewer.lastSafehouseId = nil
        BetterSafehouse.Viewer.lastZ = nil
        BetterSafehouse.Viewer.lastApplyMs = 0
    end
end


local function patchUserPanel()
    if not ISUserPanelUI then return end
    if ISUserPanelUI._BetterSafehouseViewerTogglePatched then return end

    -- Prefer patching create() like ServerTweaker. Fallback to createChildren().
    local methodName = nil
    if ISUserPanelUI.create then methodName = "create"
    elseif ISUserPanelUI.createChildren then methodName = "createChildren"
    else return end

    local original = ISUserPanelUI[methodName]
    ISUserPanelUI._BetterSafehouseViewerTogglePatched = true

    ISUserPanelUI[methodName] = function(self, ...)
        if original then original(self, ...) end
        addViewerTickBox(self)
    end
end

Events.OnGameBoot.Add(patchUserPanel)
Events.OnGameStart.Add(patchUserPanel)
