if isServer() and not isClient() then
    return
end

require "BetterSafehouse/00_BetterSafehouse_Shared"
require "ISUI/ISPanel"
require "ISUI/ISLabel"
require "ISUI/ISButton"
require "ISUI/ISTickBox"
require "ISUI/UserPanel/ISSafehouseUI"

BetterSafehouse = BetterSafehouse or {}

local PANEL_WIDTH = 310
local PANEL_GAP = 8
local PAD = 10

local function fallbackFormat(text, ...)
    local result = tostring(text or "")
    local n = select("#", ...)
    for i = 1, n do
        result = result:gsub("%%" .. tostring(i), tostring(select(i, ...)))
    end
    return result
end

local function BS_isMissingText(value, key)
    if type(value) ~= "string" or value == "" then return true end
    if value == key then return true end
    return value:sub(1, 6) == "ERROR:"
end

-- Translator formats the entry on every lookup, so asking for a key that
-- carries %1/%2 without passing its arguments makes the game log
-- MissingFormatArgumentException ("Missing arguments for ..."). The arguments
-- must always travel with the lookup itself - never probe the key first.
local function BS_text(key, fallback, ...)
    if select("#", ...) > 0 then
        if getText then
            local ok, value = pcall(getText, key, ...)
            if ok and not BS_isMissingText(value, key) then return value end
        end
    elseif getTextOrNull then
        local ok, value = pcall(getTextOrNull, key)
        if ok and not BS_isMissingText(value, key) then return value end
    end
    return fallbackFormat(fallback or key, ...)
end

local function BS_isAdminClient(playerObj)
    if not playerObj then return false end
    if playerObj.isAccessLevel then
        local ok, value = pcall(function() return playerObj:isAccessLevel("Admin") end)
        if ok and value == true then return true end
    end
    if playerObj.getAccessLevel then
        local ok, level = pcall(function() return playerObj:getAccessLevel() end)
        level = ok and level and tostring(level) or ""
        if level ~= "" and level:lower() == "admin" then return true end
    end
    if playerObj.isAdmin then
        local ok, value = pcall(function() return playerObj:isAdmin() end)
        if ok and value == true then return true end
    end
    return false
end

local function BS_setVisible(control, visible)
    if not control then return end
    if control.setVisible then
        pcall(function() control:setVisible(visible == true) end)
    else
        control.visible = visible == true
    end
end

local function BS_setEnabled(control, enabled)
    if not control then return end
    if control.setEnable then
        pcall(function() control:setEnable(enabled == true) end)
    else
        control.enable = enabled == true
    end
end

local function BS_setTooltip(control, tooltip)
    if not control then return end
    if control.setTooltip then
        pcall(function() control:setTooltip(tooltip) end)
    else
        control.tooltip = tooltip
    end
end

local function BS_setLabel(label, text)
    if not label then return end
    if label.setNameWithoutMoving then
        pcall(function() label:setNameWithoutMoving(text) end)
    elseif label.setName then
        pcall(function() label:setName(text) end)
    else
        label.name = text
    end
end

local function BS_safehouseRect(sh)
    if not sh or not sh.getX or not sh.getY then return nil end
    local okX, x = pcall(function() return sh:getX() end)
    local okY, y = pcall(function() return sh:getY() end)
    if not okX or not okY then return nil end

    local w, h = nil, nil
    if sh.getW then
        local ok, value = pcall(function() return sh:getW() end)
        if ok and type(value) == "number" then w = value end
    end
    if sh.getH then
        local ok, value = pcall(function() return sh:getH() end)
        if ok and type(value) == "number" then h = value end
    end

    local x2, y2 = nil, nil
    if sh.getX2 then
        local ok, value = pcall(function() return sh:getX2() end)
        if ok and type(value) == "number" then x2 = value end
    end
    if sh.getY2 then
        local ok, value = pcall(function() return sh:getY2() end)
        if ok and type(value) == "number" then y2 = value end
    end

    if not x2 and w then x2 = x + w - 1 end
    if not y2 and h then y2 = y + h - 1 end
    if not x2 then x2 = x end
    if not y2 then y2 = y end
    if not w then w = x2 - x + 1 end
    if not h then h = y2 - y + 1 end

    local z = 0
    if sh.getZ then
        local ok, value = pcall(function() return sh:getZ() end)
        if ok and type(value) == "number" then z = value end
    end

    return { x = x, y = y, w = w, h = h, z = z }
end

local function BS_rectMatches(sh, rect)
    local sr = BS_safehouseRect(sh)
    if not sr or not rect then return false end
    return sr.x == rect.x and sr.y == rect.y and sr.w == rect.w and sr.h == rect.h and (sr.z or 0) == (rect.z or 0)
end

local function BS_safehouseFootprintText(sh)
    local rect = BS_safehouseRect(sh)
    if not rect then
        return BS_text("IGUI_BetterSafehouse_TileCount", "Tiles: %1 (%2x%3)", 0, 0, 0)
    end
    local count = math.max(0, rect.w or 0) * math.max(0, rect.h or 0)
    return BS_text("IGUI_BetterSafehouse_TileCount", "Tiles: %1 (%2x%3)", count, rect.w or 0, rect.h or 0)
end

local function BS_baseTileText(baseRect)
    if not baseRect then
        return BS_text("IGUI_BetterSafehouse_BaseTiles", "Tiles originais: %1 (%2x%3)", 0, 0, 0)
    end
    local w = math.max(0, baseRect.w or 0)
    local h = math.max(0, baseRect.h or 0)
    return BS_text("IGUI_BetterSafehouse_BaseTiles", "Tiles originais: %1 (%2x%3)", w * h, w, h)
end

local function BS_expandedTileText(sh, baseRect)
    local rect = BS_safehouseRect(sh)
    if not rect then
        return BS_text("IGUI_BetterSafehouse_ExpandedTiles", "Tiles expandidos: %1 (%2x%3)", 0, 0, 0)
    end
    local w = math.max(0, rect.w or 0)
    local h = math.max(0, rect.h or 0)
    return BS_text("IGUI_BetterSafehouse_ExpandedTiles", "Tiles expandidos: %1 (%2x%3)", w * h, w, h)
end

-- Returns r,g,b for a role name: yellow = supporter, green = user, white = other/nil
local function BS_getRoleColor(roleName)
    local RSE = BetterSafehouse and BetterSafehouse.Expansion or nil
    if not roleName or roleName == "" then
        return 0.75, 0.75, 0.75  -- grey / sem cargo
    end
    if RSE and RSE.isUserRoleName and RSE.isUserRoleName(roleName) then
        return 0.3, 1.0, 0.3   -- verde para user
    end
    if RSE and RSE.isSupporterRoleName and RSE.isSupporterRoleName(roleName) then
        return 1.0, 0.85, 0.0  -- amarelo para apoiador
    end
    return 0.9, 0.9, 0.9       -- branco para outros
end

local function BS_getServerInteger(optionName, defaultValue)
    if not getServerOptions then return defaultValue end
    local opts = getServerOptions()
    if not opts then return defaultValue end
    if opts.getInteger then
        local ok, value = pcall(function() return opts:getInteger(optionName) end)
        if ok and type(value) == "number" then return value end
    end
    if opts.getOption then
        local ok, value = pcall(function() return tonumber(opts:getOption(optionName)) end)
        if ok and type(value) == "number" then return value end
    end
    return defaultValue
end

local function BS_removalText(sh)
    local hours = BS_getServerInteger("SafeHouseRemovalTime", 0)
    if not hours or hours <= 0 then
        return BS_text("IGUI_BetterSafehouse_SidePanel_RemovalDisabled", "Auto removal: disabled")
    end
    if not sh or not sh.getLastVisited then
        return BS_text("IGUI_BetterSafehouse_SidePanel_RemovalUnknown", "Auto removal: unknown")
    end

    local ok, lastVisited = pcall(function() return sh:getLastVisited() end)
    lastVisited = ok and tonumber(lastVisited) or nil
    if not lastVisited or lastVisited <= 0 then
        return BS_text("IGUI_BetterSafehouse_SidePanel_RemovalUnknown", "Auto removal: unknown")
    end

    local expirySeconds = nil
    if lastVisited > 100000000000 then
        expirySeconds = math.floor(lastVisited / 1000) + hours * 3600
    elseif lastVisited > 1000000000 then
        expirySeconds = math.floor(lastVisited) + hours * 3600
    end

    if not expirySeconds then
        return BS_text("IGUI_BetterSafehouse_SidePanel_RemovalUnknown", "Auto removal: unknown")
    end

    local dateText = os and os.date and os.date("%Y-%m-%d %H:%M", expirySeconds) or tostring(expirySeconds)
    return BS_text("IGUI_BetterSafehouse_SidePanel_RemovalAt", "Loses ownership: %1", dateText)
end

local function BS_getUsername(playerObj)
    if not playerObj or not playerObj.getUsername then return nil end
    local ok, username = pcall(function() return playerObj:getUsername() end)
    if not ok or not username or username == "" then return nil end
    return tostring(username)
end

local function BS_userCanUseSafehouse(playerObj, sh)
    local username = BS_getUsername(playerObj)
    if not username then return false end
    if BS_isAdminClient(playerObj) then return true end
    if BetterSafehouse.safehouseHasUser then
        return BetterSafehouse.safehouseHasUser(sh, username) == true
    end
    return false
end

local function BS_userCanRespawnInSafehouse(playerObj, sh)
    local username = BS_getUsername(playerObj)
    if not username then return false end
    if BetterSafehouse.safehouseHasUser then
        return BetterSafehouse.safehouseHasUser(sh, username) == true
    end
    return false
end

local function BS_safehouseRespawnEnabled(sh, username)
    if not sh or not username or not sh.isRespawnInSafehouse then return false end
    local ok, enabled = pcall(function() return sh:isRespawnInSafehouse(username) end)
    return ok and enabled == true
end

local function BS_sendPrimaryRespawnCommand(playerObj, sh, enabled)
    if not playerObj or not sh or not sendClientCommand then return end
    local rect = BS_safehouseRect(sh)
    if not rect then return end
    sendClientCommand(playerObj, "BetterSafehouse", "SetPrimaryRespawnSafehouse", {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
        z = rect.z or 0,
        enabled = enabled == true,
    })
end

local function BS_walkChildren(root, fn)
    if not root or not root.children then return nil end
    for _, child in pairs(root.children) do
        if child then
            local result = fn(child)
            if result ~= nil then return result end
            local sub = BS_walkChildren(child, fn)
            if sub ~= nil then return sub end
        end
    end
    return nil
end

local function BS_findRespawnTickBox(ui)
    if not ui then return nil end
    if ui.respawn then return ui.respawn end
    return BS_walkChildren(ui, function(child)
        if child and child.Type == "ISTickBox" and child.options and child.options[1] then
            local text = child.options[1]
            if type(text) == "table" then text = text.text end
            text = tostring(text or ""):lower()
            if text:find("respawn", 1, true) or text:find("renascer", 1, true) then
                return child
            end
        end
        return nil
    end)
end

local function BS_syncVanillaRespawnTick(ui)
    if not ui or not ui.safehouse then return end
    local playerObj = ui.player or (getPlayer and getPlayer() or nil)
    local username = BS_getUsername(playerObj)
    if not username then return end
    local tick = BS_findRespawnTickBox(ui)
    if tick and tick.setSelected then
        local enabled = BS_safehouseRespawnEnabled(ui.safehouse, username)
        pcall(function() tick:setSelected(1, enabled == true) end)
    end
end

local function BS_openResizeWindow(parentUI)
    if not parentUI or not parentUI.safehouse then return end
    local RSE = BetterSafehouse and BetterSafehouse.Expansion or nil
    if BSExpansionSafehouseWindow and BSExpansionSafehouseWindow.instance then
        pcall(function() BSExpansionSafehouseWindow.instance:close() end)
    end
    if RSE and RSE.openExpandWindow then
        RSE.openExpandWindow(parentUI.safehouse, parentUI)
    end
end

local function BS_resizeButtonState(parentUI)
    local RSE = BetterSafehouse and BetterSafehouse.Expansion or nil
    local playerObj = getPlayer and getPlayer() or nil
    if not RSE or not RSE.openExpandWindow then
        return false, "Resize module unavailable."
    end
    if RSE.isEnabled and not RSE.isEnabled() then
        return false, BS_text("IGUI_BetterSafehouse_Expansion_Expand_DisabledBySandbox", "Safehouse resize is disabled in sandbox.")
    end
    if not parentUI or not parentUI.safehouse or not playerObj then
        return false, BS_text("IGUI_BetterSafehouse_Expansion_Expand_InvalidSafehouse", "Invalid safehouse.")
    end
    if RSE.canResizeSafehouse and not RSE.canResizeSafehouse(playerObj, parentUI.safehouse) then
        return false, BS_text("IGUI_BetterSafehouse_Expansion_Expand_OwnerOnly", "Only the safehouse owner can resize it.")
    end
    if RSE.getPlayerResizeFlowForSafehouse and not RSE.getPlayerResizeFlowForSafehouse(playerObj, parentUI.safehouse) then
        return false, BS_text("IGUI_BetterSafehouse_Expansion_Expand_RoleDenied", "Your role cannot resize safehouses.")
    end
    if RSE.isPlayerUserBorderExpansionActiveForSafehouse and RSE.isPlayerUserBorderExpansionActiveForSafehouse(playerObj, parentUI.safehouse)
        and not (RSE.isUserFlowUsingAdvancedMode and RSE.isUserFlowUsingAdvancedMode())
        and RSE.getUserMaxBorderTilesFromOriginal and RSE.getUserMaxBorderTilesFromOriginal() < 1 then
        return false, BS_text("IGUI_BetterSafehouse_Expansion_UserBorder_NoActionsConfigured", "The user system has no valid sandbox limit.")
    end
    return true, BS_text("IGUI_BetterSafehouse_Expansion_ExpandSafehouse_Button_tooltip", "Only the owner with role or user-system access can resize.")
end

BSBetterSafehousePanel = ISPanel:derive("BSBetterSafehousePanel")
BSBetterSafehousePanel.instance = nil

function BSBetterSafehousePanel:new(x, y, width, height, parentUI)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.parentUI = parentUI
    o.safehouse = parentUI and parentUI.safehouse or nil
    o.player = parentUI and parentUI.player or nil
    o.moveWithMouse = false
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.width = width
    o.height = height
    -- Tracked so BetterSafehouse_Viewer.lua can check getIsVisible() on the
    -- live object each tick instead of relying on this window remembering
    -- to push an "I'm open/closed" flag on every possible close path.
    BSBetterSafehousePanel.instance = o
    return o
end

function BSBetterSafehousePanel:initialise()
    ISPanel.initialise(self)

    local fontSmall = getTextManager():getFontHeight(UIFont.Small)
    local fontMedium = getTextManager():getFontHeight(UIFont.Medium)
    local buttonH = math.max(24, fontSmall + 8)
    local y = PAD

    -- Panel title
    self.title = ISLabel:new(PAD, y, fontMedium, BS_text("IGUI_BetterSafehouse_SidePanel_Title", "Better Safehouse"), 1, 1, 1, 1, UIFont.Medium, true)
    self.title:initialise()
    self:addChild(self.title)
    y = y + fontMedium + 10

    -- Tiles originais (base)
    self.baseTileLabel = ISLabel:new(PAD, y, fontSmall, "", 0.85, 0.85, 0.85, 1, UIFont.Small, true)
    self.baseTileLabel:initialise()
    self:addChild(self.baseTileLabel)
    y = y + fontSmall + 4

    -- Tiles expandidos (current total)
    self.expandedTileLabel = ISLabel:new(PAD, y, fontSmall, "", 0.85, 0.85, 0.85, 1, UIFont.Small, true)
    self.expandedTileLabel:initialise()
    self:addChild(self.expandedTileLabel)
    y = y + fontSmall + 6

    -- Cargo do dono (colored)
    self.ownerRoleLabel = ISLabel:new(PAD, y, fontSmall, "", 0.75, 0.75, 0.75, 1, UIFont.Small, true)
    self.ownerRoleLabel:initialise()
    self:addChild(self.ownerRoleLabel)
    y = y + fontSmall + 8

    -- Safehouses count
    self.membershipLabel = ISLabel:new(PAD, y, fontSmall, "", 1, 1, 1, 1, UIFont.Small, true)
    self.membershipLabel:initialise()
    self:addChild(self.membershipLabel)
    y = y + fontSmall + 8

    -- Auto-removal date
    self.removalLabel = ISLabel:new(PAD, y, fontSmall, "", 1, 1, 1, 1, UIFont.Small, true)
    self.removalLabel:initialise()
    self.removalLabel:setTooltip("SafeHouseRemovalTime")
    self:addChild(self.removalLabel)
    y = y + fontSmall + 14

    local buttonW = self.width - PAD * 2

    -- Resize button
    local resizeTitle = BS_text("IGUI_BetterSafehouse_Expansion_ExpandSafehouse_Button", "Resize Safehouse")
    self.resizeButton = ISButton:new(PAD, y, buttonW, buttonH, resizeTitle, self, BSBetterSafehousePanel.onResizeClicked)
    self.resizeButton:initialise()
    self.resizeButton.internal = "BS_RESIZE_SAFEHOUSE"
    self:addChild(self.resizeButton)
    y = y + buttonH + 6

    -- Admin reset button (hidden for non-admins in refresh)
    self.adminResetButton = ISButton:new(PAD, y, buttonW, buttonH,
        BS_text("IGUI_BetterSafehouse_AdminReset_Button", "[Admin] Resetar para tamanho vanilla"),
        self, BSBetterSafehousePanel.onAdminResetClicked)
    self.adminResetButton:initialise()
    self.adminResetButton.internal = "BS_ADMIN_RESET_SAFEHOUSE"
    self.adminResetButton.backgroundColor      = { r = 0.45, g = 0.10, b = 0.10, a = 1.0 }
    self.adminResetButton.backgroundColorMouseOver = { r = 0.65, g = 0.15, b = 0.15, a = 1.0 }
    self.adminResetButton:setTooltip(BS_text("IGUI_BetterSafehouse_AdminReset_Tooltip",
        "Reseta a safehouse para o tamanho vanilla original, limpando a expansao do user."))
    self:addChild(self.adminResetButton)
    y = y + buttonH + 10

    -- Viewer tick
    self.viewerTick = ISTickBox:new(PAD, y, buttonW, buttonH, "", self, BSBetterSafehousePanel.onViewerToggle)
    self.viewerTick:initialise()
    self.viewerTick:addOption(BS_text("IGUI_BetterSafehouse_ViewThisSafehouse", "View this safehouse"))
    self.viewerTick.tooltip = BS_text("IGUI_BetterSafehouse_ViewThisSafehouse_tooltip", "Highlights the entire area of this safehouse in blue. (Visual only)")
    self:addChild(self.viewerTick)
    y = y + buttonH + 10

    -- Respawn status
    self.respawnStatusLabel = ISLabel:new(PAD, y, fontSmall, "", 1, 1, 1, 1, UIFont.Small, true)
    self.respawnStatusLabel:initialise()
    self:addChild(self.respawnStatusLabel)
    y = y + fontSmall + 6

    self.respawnButton = ISButton:new(PAD, y, buttonW, buttonH, BS_text("IGUI_BetterSafehouse_SidePanel_SetPrimaryRespawn", "Set respawn here"), self, BSBetterSafehousePanel.onRespawnClicked)
    self.respawnButton:initialise()
    self.respawnButton.internal = "BS_SET_PRIMARY_RESPAWN"
    self:addChild(self.respawnButton)
    y = y + buttonH + PAD

    -- Cache for server display info (base rect + owner role)
    self.displayInfo = nil
    self.displayInfoKey = nil
    self.displayInfoRequestKey = nil

    self:setHeight(math.max(y, 215))
    self:refresh()
    self:syncPosition()
end

function BSBetterSafehousePanel:syncPosition()
    local parent = self.parentUI
    if not parent or not parent.getX or not parent.getY then return end

    local px = parent:getX()
    local py = parent:getY()
    local pw = parent.getWidth and parent:getWidth() or parent.width or 0
    local ph = parent.getHeight and parent:getHeight() or parent.height or self.height
    local sw = getCore and getCore():getScreenWidth() or 1280
    local sh = getCore and getCore():getScreenHeight() or 720

    local x = px + pw + PANEL_GAP
    local y = py

    if x + self.width > sw - 5 then
        x = px - self.width - PANEL_GAP
    end
    if x < 5 then
        x = math.max(5, sw - self.width - 5)
    end
    if y + self.height > sh - 5 then
        y = math.max(5, sh - self.height - 5)
    end
    if y < 5 then y = 5 end

    if self.setX then self:setX(x) else self.x = x end
    if self.setY then self:setY(y) else self.y = y end
    if ph > 0 and self.height > ph then
        self:setHeight(math.min(self.height, sh - y - 5))
    end
    if self.bringToTop then
        pcall(function() self:bringToTop() end)
    end
end

function BSBetterSafehousePanel:requestDisplayInfo(sh)
    if not sh or not sendClientCommand then return end
    local RSE = BetterSafehouse and BetterSafehouse.Expansion or nil
    if not RSE or not RSE.rectFromSafehouse then return end
    local rect = RSE.rectFromSafehouse(sh)
    if not rect then return end
    local key = tostring(rect.x)..":"..tostring(rect.y)..":"..tostring(rect.w)..":"..tostring(rect.h)
    if self.displayInfoKey == key and self.displayInfo then return end
    if self.displayInfoRequestKey == key then return end
    self.displayInfoKey = key
    self.displayInfo = nil
    local playerObj = self.player or (getPlayer and getPlayer() or nil)
    if not playerObj then return end
    self.displayInfoRequestKey = key
    pcall(function()
        sendClientCommand(playerObj, "BetterSafehouse", "RequestSafehouseDisplayInfo", {
            x = rect.x, y = rect.y, w = rect.w, h = rect.h
        })
    end)
end

function BSBetterSafehousePanel:refresh()
    local parentUI = self.parentUI
    local sh = parentUI and parentUI.safehouse or self.safehouse
    local playerObj = (parentUI and parentUI.player) or (getPlayer and getPlayer() or nil)
    local username = BS_getUsername(playerObj)

    self.safehouse = sh
    self.player = playerObj

    -- Request display info from server (base rect + owner role)
    self:requestDisplayInfo(sh)

    -- Base / expanded tile labels
    local info = self.displayInfo
    local baseRect = info and info.baseRect or nil
    BS_setLabel(self.baseTileLabel,     BS_baseTileText(baseRect))
    BS_setLabel(self.expandedTileLabel, BS_expandedTileText(sh, baseRect))

    -- Owner role label with colour
    local ownerRoleName = info and info.ownerRoleName or ""
    local ownerUsername = info and info.ownerUsername or ""
    local roleDisplay = ""
    if ownerUsername ~= "" then
        if ownerRoleName ~= "" then
            roleDisplay = BS_text("IGUI_BetterSafehouse_OwnerRole",
                "Cargo do dono: %1", ownerRoleName)
        else
            roleDisplay = BS_text("IGUI_BetterSafehouse_OwnerRoleNone",
                "Cargo do dono: user")
        end
    else
        roleDisplay = BS_text("IGUI_BetterSafehouse_OwnerRoleUnknown",
            "Cargo do dono: -")
    end
    local rr, rg, rb = BS_getRoleColor(ownerRoleName ~= "" and ownerRoleName or (ownerUsername ~= "" and "user" or nil))
    if self.ownerRoleLabel then
        BS_setLabel(self.ownerRoleLabel, roleDisplay)
        self.ownerRoleLabel.r = rr
        self.ownerRoleLabel.g = rg
        self.ownerRoleLabel.b = rb
    end

    -- Admin reset button visibility
    local isAdmin = BS_isAdminClient(playerObj)
    BS_setVisible(self.adminResetButton, isAdmin)
    BS_setEnabled(self.adminResetButton, isAdmin and sh ~= nil)

    -- Two different limits share this one line: MaxJoinedSafehouses caps how
    -- many safehouses a player can be a member/owner of at all (the
    -- EnhancedInvites system), while MaxSafehousesPerPlayer caps how many
    -- they can OWN (only meaningful when MultipleSafehousesEnabled is on).
    -- Servers using the multi-ownership feature care about the ownership
    -- count against ITS limit, not the membership one, so prefer that
    -- combo whenever it's the active system.
    local multiOwnerActive = BetterSafehouse.isMultipleSafehousesEnabled and BetterSafehouse.isMultipleSafehousesEnabled()
    local count, maxAllowed
    if multiOwnerActive then
        count = username and BetterSafehouse.countOwnedSafehouses and BetterSafehouse.countOwnedSafehouses(username) or 0
        maxAllowed = BetterSafehouse.getMaxSafehousesPerPlayer and BetterSafehouse.getMaxSafehousesPerPlayer() or 0
    else
        count = username and BetterSafehouse.countSafehousesForUsername and BetterSafehouse.countSafehousesForUsername(username) or 0
        maxAllowed = BetterSafehouse.getMaxJoinedSafehouses and BetterSafehouse.getMaxJoinedSafehouses() or 0
    end
    local maxText = (maxAllowed and maxAllowed > 0) and tostring(maxAllowed) or BS_text("IGUI_BetterSafehouse_SidePanel_Unlimited", "unlimited")
    BS_setLabel(self.membershipLabel, BS_text("IGUI_BetterSafehouse_SidePanel_Safehouses", "Safehouses: %1 / %2", count, maxText))

    -- Spells out both underlying sandbox limits (not just whichever one is
    -- currently shown) so a player looking at "2/1" doesn't have to ask an
    -- admin which setting controls it or why it's not the number they
    -- expected — this is exactly the confusion that prompted this tooltip.
    do
        local joinedMax = BetterSafehouse.getMaxJoinedSafehouses and BetterSafehouse.getMaxJoinedSafehouses() or 0
        local joinedMaxText = (joinedMax and joinedMax > 0) and tostring(joinedMax) or BS_text("IGUI_BetterSafehouse_SidePanel_Unlimited", "unlimited")
        local ownedMaxText
        if multiOwnerActive then
            local ownedMax = BetterSafehouse.getMaxSafehousesPerPlayer and BetterSafehouse.getMaxSafehousesPerPlayer() or 0
            ownedMaxText = (ownedMax and ownedMax > 0) and tostring(ownedMax) or BS_text("IGUI_BetterSafehouse_SidePanel_Unlimited", "unlimited")
        else
            ownedMaxText = BS_text("IGUI_BetterSafehouse_SidePanel_MultiOwnerDisabled", "disabled")
        end
        BS_setTooltip(self.membershipLabel, BS_text(
            "IGUI_BetterSafehouse_SidePanel_Safehouses_tooltip",
            "Membership limit (MaxJoinedSafehouses): %1 - how many safehouses you can be part of in total, as owner or invited member.\nOwnership limit (MaxSafehousesPerPlayer): %2 - how many you can own, only enforced while multiple-safehouse ownership is enabled.\nThis line currently shows whichever limit is active on this server.",
            joinedMaxText, ownedMaxText
        ))
    end

    BS_setLabel(self.removalLabel, BS_removalText(sh))

    local resizeEnabled, resizeTooltip = BS_resizeButtonState(parentUI)
    BS_setEnabled(self.resizeButton, resizeEnabled)
    BS_setTooltip(self.resizeButton, resizeTooltip)

    local canUse = BS_userCanUseSafehouse(playerObj, sh)
    local viewerAllowed = canUse and BetterSafehouse.isViewerEnabledBySandbox and BetterSafehouse.isViewerEnabledBySandbox()
    BS_setEnabled(self.viewerTick, viewerAllowed == true)
    if self.viewerTick and self.viewerTick.setSelected then
        local selected = false
        if viewerAllowed and BetterSafehouse.getClientViewerPref and BetterSafehouse.viewerTargetMatchesSafehouse then
            selected = BetterSafehouse.getClientViewerPref(playerObj) and BetterSafehouse.viewerTargetMatchesSafehouse(playerObj, sh)
        end
        pcall(function() self.viewerTick:setSelected(1, selected == true) end)
    end

    -- Note: this feature is our own self-contained teleport-on-respawn system,
    -- not vanilla's safehouse-respawn mechanic, so it no longer depends on the
    -- native "SafehouseAllowRespawn" server option — that's a native setting
    -- most admins never touch (off by default on new servers), and gating our
    -- unrelated feature behind it just left this button disabled with no
    -- obvious reason. Enabled by default in the mod now.
    local respawnEnabled = username and BS_safehouseRespawnEnabled(sh, username) == true
    local singleEnabled = BetterSafehouse.isSingleRespawnSafehouseEnabled and BetterSafehouse.isSingleRespawnSafehouseEnabled()
    local canRespawnHere = BS_userCanRespawnInSafehouse(playerObj, sh)
    local respawnButtonEnabled = singleEnabled == true and canRespawnHere == true

    if respawnEnabled then
        BS_setLabel(self.respawnStatusLabel, BS_text("IGUI_BetterSafehouse_SidePanel_PrimaryRespawnActive", "Respawn active here"))
        self.respawnButton:setTitle(BS_text("IGUI_BetterSafehouse_SidePanel_ClearPrimaryRespawn", "Clear respawn here"))
    else
        BS_setLabel(self.respawnStatusLabel, BS_text("IGUI_BetterSafehouse_SidePanel_SetPrimaryRespawn", "Set respawn here"))
        self.respawnButton:setTitle(BS_text("IGUI_BetterSafehouse_SidePanel_SetPrimaryRespawn", "Set respawn here"))
    end

    local respawnTooltip = nil
    if singleEnabled ~= true then
        respawnTooltip = BS_text("IGUI_BetterSafehouse_SidePanel_PrimaryRespawnDisabled", "Unique respawn is disabled in sandbox.")
    elseif canRespawnHere ~= true then
        respawnTooltip = BS_text("IGUI_BetterSafehouse_PrimaryRespawn_NotMember", "You are not a member of this safehouse.")
    end
    BS_setEnabled(self.respawnButton, respawnButtonEnabled)
    BS_setTooltip(self.respawnButton, respawnTooltip)
end

function BSBetterSafehousePanel:prerender()
    if not self.parentUI or (self.parentUI.getIsVisible and not self.parentUI:getIsVisible()) then
        self:close()
        return
    end
    self:syncPosition()
    self:refresh()
    ISPanel.prerender(self)
end

function BSBetterSafehousePanel:onResizeClicked()
    BS_openResizeWindow(self.parentUI)
end

function BSBetterSafehousePanel:onViewerToggle(option, enabled)
    local parentUI = self.parentUI
    local playerObj = (parentUI and parentUI.player) or (getPlayer and getPlayer() or nil)
    local sh = parentUI and parentUI.safehouse or self.safehouse
    if not playerObj or not sh then return end
    if not BS_userCanUseSafehouse(playerObj, sh) then
        pcall(function() self.viewerTick:setSelected(1, false) end)
        return
    end

    local sandboxAllows = BetterSafehouse.isViewerEnabledBySandbox and BetterSafehouse.isViewerEnabledBySandbox() or true
    if enabled == true and sandboxAllows then
        if BetterSafehouse.activateViewerForSafehouse then
            BetterSafehouse.activateViewerForSafehouse(sh, playerObj)
        end
    else
        if BetterSafehouse.setClientViewerTarget then BetterSafehouse.setClientViewerTarget(playerObj, nil) end
        if BetterSafehouse.setClientViewerPref then BetterSafehouse.setClientViewerPref(playerObj, false) end
        if BetterSafehouse.Viewer and BetterSafehouse.Viewer.clear then
            BetterSafehouse.Viewer.clear()
        end
    end
end

function BSBetterSafehousePanel:onRespawnClicked()
    local parentUI = self.parentUI
    local playerObj = (parentUI and parentUI.player) or (getPlayer and getPlayer() or nil)
    local sh = parentUI and parentUI.safehouse or self.safehouse
    local username = BS_getUsername(playerObj)
    local enabled = not BS_safehouseRespawnEnabled(sh, username)
    BS_sendPrimaryRespawnCommand(playerObj, sh, enabled)
end

function BSBetterSafehousePanel:onAdminResetClicked()
    local parentUI = self.parentUI
    local playerObj = (parentUI and parentUI.player) or (getPlayer and getPlayer() or nil)
    local sh = parentUI and parentUI.safehouse or self.safehouse
    if not playerObj or not sh then return end
    if not BS_isAdminClient(playerObj) then return end

    local RSE = BetterSafehouse and BetterSafehouse.Expansion or nil
    local rect = RSE and RSE.rectFromSafehouse and RSE.rectFromSafehouse(sh) or BS_safehouseRect(sh)
    if not rect then return end

    if not sendClientCommand then return end
    pcall(function()
        sendClientCommand(playerObj, "BetterSafehouse", "AdminResetSafehouse", {
            x = rect.x, y = rect.y, w = rect.w, h = rect.h
        })
    end)
    -- Invalidate cache so tile counts refresh when server responds
    self.displayInfo = nil
    self.displayInfoKey = nil
    self.displayInfoRequestKey = nil
end

function BSBetterSafehousePanel:close()
    if self.parentUI and self.parentUI.BS_sidePanel == self then
        self.parentUI.BS_sidePanel = nil
    end
    if BSBetterSafehousePanel.instance == self then
        BSBetterSafehousePanel.instance = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

local function BS_hideLegacySafehouseControls(ui)
    if not ui then return end
    local controls = {
        ui.BS_tileCountLabel,
        ui.BS_viewerTick,
        ui.BS_expansionButton,
    }
    for i = 1, #controls do
        local control = controls[i]
        if control then
            BS_setVisible(control, false)
            BS_setEnabled(control, false)
        end
    end
end

local function BS_installSidePanel(ui)
    if not ui or not ui.safehouse then return end
    BS_hideLegacySafehouseControls(ui)

    if ui.BS_sidePanel and ui.BS_sidePanel.safehouse == ui.safehouse then
        ui.BS_sidePanel:refresh()
        ui.BS_sidePanel:syncPosition()
        return
    end

    if ui.BS_sidePanel then
        pcall(function() ui.BS_sidePanel:close() end)
    end

    local panel = BSBetterSafehousePanel:new(0, 0, PANEL_WIDTH, 230, ui)
    panel:initialise()
    panel:addToUIManager()
    if panel.bringToTop then
        pcall(function() panel:bringToTop() end)
    end
    ui.BS_sidePanel = panel
end

local function BS_refreshSidePanel(ui)
    if not ui then return end
    BS_hideLegacySafehouseControls(ui)
    BS_syncVanillaRespawnTick(ui)
    if ui.BS_sidePanel then
        ui.BS_sidePanel:refresh()
        ui.BS_sidePanel:syncPosition()
    else
        BS_installSidePanel(ui)
    end
end

-- Lighter per-frame sync used by the render hook: the panel's own prerender()
-- already calls :refresh() every frame it's visible, so calling it again here
-- would double the RequestSafehouseDisplayInfo traffic for no benefit.
local function BS_syncSidePanelOnRender(ui)
    if not ui then return end
    BS_hideLegacySafehouseControls(ui)
    BS_syncVanillaRespawnTick(ui)
    if ui.BS_sidePanel then
        ui.BS_sidePanel:syncPosition()
    else
        BS_installSidePanel(ui)
    end
end

local function BS_patchSafehouseUI()
    if not ISSafehouseUI then return end
    if ISSafehouseUI._BetterSafehouseSidePanelPatched then return end
    ISSafehouseUI._BetterSafehouseSidePanelPatched = true

    local oldCreateChildren = ISSafehouseUI.createChildren
    if oldCreateChildren then
        ISSafehouseUI.createChildren = function(self, ...)
            local result = oldCreateChildren(self, ...)
            pcall(function() BS_installSidePanel(self) end)
            return result
        end
    end

    local oldPopulateList = ISSafehouseUI.populateList
    if oldPopulateList then
        ISSafehouseUI.populateList = function(self, ...)
            local result = oldPopulateList(self, ...)
            pcall(function() BS_refreshSidePanel(self) end)
            return result
        end
    end

    local oldRender = ISSafehouseUI.render
    if oldRender then
        ISSafehouseUI.render = function(self, ...)
            local result = oldRender(self, ...)
            pcall(function() BS_syncSidePanelOnRender(self) end)
            return result
        end
    end

    local oldClose = ISSafehouseUI.close
    if oldClose then
        ISSafehouseUI.close = function(self, ...)
            if self and self.BS_sidePanel then
                pcall(function() self.BS_sidePanel:close() end)
            end
            return oldClose(self, ...)
        end
    end

    local oldOnClickRespawn = ISSafehouseUI.onClickRespawn
    if oldOnClickRespawn then
        ISSafehouseUI.onClickRespawn = function(self, clickedOption, enabled, ...)
            if BetterSafehouse.isSingleRespawnSafehouseEnabled and BetterSafehouse.isSingleRespawnSafehouseEnabled() then
                local playerObj = self and self.player or (getPlayer and getPlayer() or nil)
                if playerObj and self and self.safehouse then
                    BS_sendPrimaryRespawnCommand(playerObj, self.safehouse, enabled == true)
                    return
                end
            end
            return oldOnClickRespawn(self, clickedOption, enabled, ...)
        end
    end

    -- Patch release: when the safehouse owner releases, clear their user expansion
    -- claim BEFORE the vanilla packet fires, so they can expand again elsewhere.
    local oldOnClickRelease = ISSafehouseUI.onClickRelease
    if oldOnClickRelease then
        ISSafehouseUI.onClickRelease = function(self, ...)
            pcall(function()
                local playerObj = self and self.player or (getPlayer and getPlayer() or nil)
                local sh = self and self.safehouse or nil
                if playerObj and sh and sendClientCommand then
                    -- Only send if local player is the owner
                    local username = BS_getUsername(playerObj)
                    local ownerOk, owner = pcall(function() return sh:getOwner() end)
                    if ownerOk and username and tostring(owner) == username then
                        local RSE = BetterSafehouse and BetterSafehouse.Expansion or nil
                        local rect = RSE and RSE.rectFromSafehouse and RSE.rectFromSafehouse(sh) or BS_safehouseRect(sh)
                        if rect then
                            sendClientCommand(playerObj, "BetterSafehouse", "UserReleaseClearClaim", {
                                x = rect.x, y = rect.y, w = rect.w, h = rect.h
                            })
                        end
                    end
                end
            end)
            return oldOnClickRelease(self, ...)
        end
    end
end

local function BS_eachSafehouse()
    local list = BetterSafehouse.getSafehouseList and BetterSafehouse.getSafehouseList() or nil
    if not list then return function() return nil end end
    if list.size and list.get then
        local i = 0
        local n = list:size()
        return function()
            if i < n then
                local sh = list:get(i)
                i = i + 1
                return i, sh
            end
            return nil
        end
    end
    if type(list) == "table" then
        return ipairs(list)
    end
    return function() return nil end
end

local function BS_applyPrimaryRespawnChanged(args)
    if not args or not args.username then return end
    local username = tostring(args.username)
    local targetRect = {
        x = tonumber(args.x),
        y = tonumber(args.y),
        w = tonumber(args.w),
        h = tonumber(args.h),
        z = tonumber(args.z) or 0,
    }
    if not targetRect.x or not targetRect.y or not targetRect.w or not targetRect.h then return end

    for _, sh in BS_eachSafehouse() do
        if sh and sh.setRespawnInSafehouse then
            local isTarget = BS_rectMatches(sh, targetRect)
            if isTarget then
                pcall(function() sh:setRespawnInSafehouse(args.enabled == true, username) end)
            elseif args.enabled == true and BS_safehouseRespawnEnabled(sh, username) then
                pcall(function() sh:setRespawnInSafehouse(false, username) end)
            end
        end
    end

    if triggerEvent then
        pcall(function() triggerEvent("OnSafehousesChanged") end)
    end
    if ISSafehouseUI and ISSafehouseUI.instance then
        BS_refreshSidePanel(ISSafehouseUI.instance)
    end
end

local function BS_sayResult(args)
    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj or not playerObj.Say then return end
    local msg = nil
    if args and args.key then
        local values = args.args or {}
        local ok, text = pcall(function()
            return getText(args.key, (table.unpack or unpack)(values))
        end)
        msg = ok and text or nil
    end
    if not msg then
        msg = tostring(args and args.msg or (args and args.ok and BS_text("IGUI_BetterSafehouse_GenericOK", "OK") or BS_text("IGUI_BetterSafehouse_GenericFailed", "Failed")))
    end
    playerObj:Say(msg)
end

local function BS_doPrimaryRespawn(args)
    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj or not playerObj.teleportTo or type(args) ~= "table" then return end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z) or 0
    if not x or not y then return end

    pcall(function() playerObj:teleportTo(x, y, z) end)
end

local function BS_flagPrimaryRespawnDeath(playerObj)
    if not playerObj or not playerObj.isLocalPlayer or not playerObj:isLocalPlayer() then return end
    if not sendClientCommand then return end
    sendClientCommand(playerObj, "BetterSafehouse", "FlagPrimaryRespawnDeath", {})
end

local BS_primaryRespawnRetry = nil

local function BS_sendPrimaryRespawnCheck(player)
    if not player or not player.isLocalPlayer or not player:isLocalPlayer() then return end
    if not sendClientCommand then return end
    sendClientCommand(player, "BetterSafehouse", "CheckPrimaryRespawn", {})
end

local function BS_onPrimaryRespawnRetryTick()
    if type(BS_primaryRespawnRetry) ~= "table" then
        Events.OnTick.Remove(BS_onPrimaryRespawnRetryTick)
        return
    end

    BS_primaryRespawnRetry.ticks = (BS_primaryRespawnRetry.ticks or 0) - 1
    if BS_primaryRespawnRetry.ticks > 0 then return end

    local player = getPlayer and getPlayer() or nil
    BS_sendPrimaryRespawnCheck(player)

    BS_primaryRespawnRetry.remaining = (BS_primaryRespawnRetry.remaining or 0) - 1
    if BS_primaryRespawnRetry.remaining <= 0 then
        BS_primaryRespawnRetry = nil
        Events.OnTick.Remove(BS_onPrimaryRespawnRetryTick)
        return
    end

    BS_primaryRespawnRetry.ticks = 60
end

local function BS_checkPrimaryRespawn(playerNum, playerObj)
    local player = playerObj or (getPlayer and getPlayer() or nil)
    BS_sendPrimaryRespawnCheck(player)

    BS_primaryRespawnRetry = { ticks = 60, remaining = 3 }
    Events.OnTick.Remove(BS_onPrimaryRespawnRetryTick)
    Events.OnTick.Add(BS_onPrimaryRespawnRetryTick)
end

local function BS_onServerCommand(module, command, args)
    if module ~= "BetterSafehouse" then return end
    if command == "PrimaryRespawnChanged" then
        BS_applyPrimaryRespawnChanged(args)
        return
    end
    if command == "PrimaryRespawnResult" then
        BS_sayResult(args or {})
        if ISSafehouseUI and ISSafehouseUI.instance then
            BS_refreshSidePanel(ISSafehouseUI.instance)
        end
        return
    end
    if command == "DoPrimaryRespawn" then
        BS_doPrimaryRespawn(args)
        return
    end
    -- Display info response: update cached base rect + owner role in the side panel
    if command == "SafehouseDisplayInfo" then
        if not args then return end
        local panel = ISSafehouseUI and ISSafehouseUI.instance and ISSafehouseUI.instance.BS_sidePanel or nil
        if not panel then return end
        local RSE = BetterSafehouse and BetterSafehouse.Expansion or nil
        local baseRect = nil
        if args.baseW and args.baseH and tonumber(args.baseW) and tonumber(args.baseH) then
            if RSE and RSE.makeRect then
                baseRect = RSE.makeRect(args.baseX, args.baseY, args.baseW, args.baseH)
            else
                baseRect = {
                    x = tonumber(args.baseX) or 0, y = tonumber(args.baseY) or 0,
                    w = tonumber(args.baseW) or 0, h = tonumber(args.baseH) or 0
                }
            end
        end
        panel.displayInfo = {
            baseRect     = baseRect,
            ownerUsername = tostring(args.ownerUsername or ""),
            ownerRoleName = tostring(args.ownerRoleName or ""),
        }
        panel.displayInfoRequestKey = nil
        return
    end
end

local function BS_onSafehousesChanged()
    if ISSafehouseUI and ISSafehouseUI.instance then
        BS_refreshSidePanel(ISSafehouseUI.instance)
    end
end

Events.OnGameBoot.Add(BS_patchSafehouseUI)
Events.OnGameStart.Add(BS_patchSafehouseUI)
Events.OnServerCommand.Add(BS_onServerCommand)
Events.OnSafehousesChanged.Add(BS_onSafehousesChanged)
Events.OnPlayerDeath.Add(BS_flagPrimaryRespawnDeath)
Events.OnCreatePlayer.Add(BS_checkPrimaryRespawn)
pcall(BS_patchSafehouseUI)
