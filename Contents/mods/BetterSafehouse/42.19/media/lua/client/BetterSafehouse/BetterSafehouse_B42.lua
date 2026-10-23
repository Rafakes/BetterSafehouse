--[[
    Better Safehouse (B42 MP) - UI patches
--]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse._cooldownCache = type(BetterSafehouse._cooldownCache) == "table" and BetterSafehouse._cooldownCache or {}
local BS_cooldownCache = BetterSafehouse._cooldownCache

local function isAdminClient(playerObj)
    -- Only true "Admin" can use offline invite / free-add features.
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
        -- Fallback: some builds expose isAdmin() only for true admins.
        local ok, v = pcall(function() return playerObj:isAdmin() end)
        if ok and v == true then return true end
    end

    return false
end


local function patchISSafehouseAddPlayerUI_EnhancedInvites()
    -- Respect sandbox option to keep vanilla behavior.
    if BetterSafehouse.getSandboxBool and (not BetterSafehouse.getSandboxBool("EnhancedInvites", true)) then return end
    if not ISSafehouseAddPlayerUI or not ISSafehouseAddPlayerUI.populateList then return end
    if ISSafehouseAddPlayerUI._BetterSafehousePatched then return end
    ISSafehouseAddPlayerUI._BetterSafehousePatched = true

    local oldPopulateList = ISSafehouseAddPlayerUI.populateList

    ISSafehouseAddPlayerUI.populateList = function(self, ...)
        if oldPopulateList then oldPopulateList(self, ...) end
        if not self or not self.safehouse or not self.playerList or not self.playerList.items then return end

        -- If a player already belongs to another safehouse, vanilla often blocks selection by tooltip.
        -- We clear that tooltip so the UI can still select them (server-side behavior decides what happens next).
        for _, listItem in ipairs(self.playerList.items) do
            local username = listItem and listItem.item and listItem.item.username
            if username then
                local other = self.safehouse:alreadyHaveSafehouse(username)
                if other and not BetterSafehouse.sameSafehouse(other, self.safehouse) then
                    listItem.tooltip = nil
                    if listItem.item then listItem.item.tooltip = nil end
                end
            end
        end
    end
end

local function patchISSafehouseAddPlayerUI_AdminFreeAdd()
    if not ISSafehouseAddPlayerUI then return end
    if ISSafehouseAddPlayerUI._BetterSafehouseAdminFreeAddPatched then return end
    ISSafehouseAddPlayerUI._BetterSafehouseAdminFreeAddPatched = true

-- ---------------------------------------------------------
-- Offline add UI (admin only): adds a username entry field.
-- We anchor it above the player list and shrink the listbox
-- so it never overlaps the bottom buttons.
-- ---------------------------------------------------------
local function BS_trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function BS_T(key, fallback)
    if getText then
        local ok, v = pcall(function() return getText(key) end)
        if ok and v and v ~= key then return v end
    end
    return fallback
end

local function BS_findPlayerList(self)
    if not self then return nil end
    local candidates = {
        self.playerList, self.players, self.listbox, self.list, self.playerListBox,
    }
    for _, c in ipairs(candidates) do
        if c and (c.doDrawItem or c.drawItem or c.items) and (c.setHeight or c.height) then
            return c
        end
    end
    if self.children then
        for i = 1, #self.children do
            local c = self.children[i]
            if c and instanceof and instanceof(c, "ISScrollingListBox") then
                return c
            end
        end
    end
    return nil
end

local function BS_findAddButton(self)
    if not self then return nil end
    if self.addPlayer and self.addPlayer.internal == "ADDPLAYER" then return self.addPlayer end
    if self.add and self.add.internal == "ADDPLAYER" then return self.add end
    if self.addPlayerBtn and self.addPlayerBtn.internal == "ADDPLAYER" then return self.addPlayerBtn end
    if self.children then
        for i = 1, #self.children do
            local c = self.children[i]
            if c and c.internal == "ADDPLAYER" and c.setEnable then
                return c
            end
        end
    end
    return nil
end

local function BS_updateAddButtonEnable(self)
    local btn = BS_findAddButton(self)
    if not btn or not btn.setEnable then return end
    local typed = ""
    if self and self.BS_offlineNameEntry and self.BS_offlineNameEntry.getText then
        typed = BS_trim(self.BS_offlineNameEntry:getText())
    end
    local sel = BS_trim(self and self.selectedPlayer or "")
    btn:setEnable(typed ~= "" or sel ~= "")
    if btn.tooltip then btn.tooltip = nil end
end


local function BS_clearOnlineSelection(self)
    -- When typing/clicking an offline username, we must NOT keep any online selection highlighted.
    local list = BS_findPlayerList(self)
    if list then
        -- Some listboxes expose helper APIs; call them if present, but DO NOT rely on their semantics.
        if list.clearSelection then pcall(function() list:clearSelection() end) end

        -- B42 listboxes are safest cleared by forcing selected=0 (no selection).
        -- (Using -1 can get clamped back to 1 in some UI code paths.)
        list.selected = 0
        if list.selectedIndex ~= nil then list.selectedIndex = 0 end
        if list.selectedRow ~= nil then list.selectedRow = 0 end
        if list.selectedItem ~= nil then list.selectedItem = nil end
        if list.joypadIndex ~= nil then list.joypadIndex = 0 end
    end

    -- Also clear any cached selection on the parent UI.
    self.selectedPlayer = nil
    self.selectedPlayerName = nil
    self.selected = nil
end


local function BS_installOfflineEntry(self)
    if not self or self.BS_offlineNameEntry then return end
    if not ISLabel or not ISTextEntryBox then return end

    local list = BS_findPlayerList(self)
    if not list then return end

    local pad = 6
    local font = UIFont.Small
    local tm = getTextManager and getTextManager() or nil
    local fontH = 14
    if tm and tm.getFontHeight then
        local ok, h = pcall(function() return tm:getFontHeight(font) end)
        if ok and type(h) == "number" and h > 0 then fontH = h end
    end

    local entryH = math.max(18, fontH + 6)

    -- Compact line: [Offline:] [__________]
    local labelText = BS_T("UI_BetterSafehouse_OfflineShort", "Offline:")
    local labelW = 60
    if tm and tm.MeasureStringX then
        local ok, w = pcall(function() return tm:MeasureStringX(font, labelText) end)
        if ok and type(w) == "number" and w > 0 then labelW = w + 10 end
    end

    local baseX = list.x
    local baseY = list.y
    local totalW = list.width

    local label = ISLabel:new(baseX, baseY + 2, fontH, labelText, 1, 1, 1, 1, font, true)
    label:initialise()
    self:addChild(label)
    self.BS_offlineLabel = label

    local entryX = baseX + labelW
    local entryW = math.max(80, totalW - labelW)

    local entry = ISTextEntryBox:new("", entryX, baseY, entryW, entryH)
    entry:initialise()
    entry:instantiate()
    if entry.setTooltip then
        entry:setTooltip(BS_T("UI_BetterSafehouse_OfflineTooltip", "Digite o username exato para adicionar mesmo offline (somente ADMIN)."))
    end
    self:addChild(entry)
    self.BS_offlineNameEntry = entry


-- Clicking/focusing the offline entry must clear any online selection in the list,
-- otherwise a highlighted player can be accidentally added instead of the typed name.
do
    local _oldMouseDown = entry.onMouseDown
    entry.onMouseDown = function(box, ...)
        -- Consume the click and force-clear any online selection.
        BS_clearOnlineSelection(self)
        BS_updateAddButtonEnable(self)
        if _oldMouseDown then _oldMouseDown(box, ...) end
        return true
    end

    local _oldGain = entry.onGainFocus
    entry.onGainFocus = function(box, ...)
        BS_clearOnlineSelection(self)
        BS_updateAddButtonEnable(self)
        if _oldGain then _oldGain(box, ...) end
    end

    local _oldTextChange = entry.onTextChange
    entry.onTextChange = function(box, ...)
        -- While the user types an offline name, keep the online list unselected.
        BS_clearOnlineSelection(self)
        BS_updateAddButtonEnable(self)
        if _oldTextChange then return _oldTextChange(box, ...) end
    end

    local _oldOther = entry.onOtherMouseDown
    entry.onOtherMouseDown = function(box, ...)
        BS_clearOnlineSelection(self)
        BS_updateAddButtonEnable(self)
        if _oldOther then _oldOther(box, ...) end
        return true
    end
end

-- Keep the online list from auto-selecting the first row while the offline entry is focused/typed.
-- Some UI code paths will clamp selected < 1 back to 1 every frame; we override after list.prerender.
if list and not list.BS_offlineNoAutoSelect then
    list.BS_offlineNoAutoSelect = true
    local _oldPre = list.prerender
    list.prerender = function(lb, ...)
        local r
        if _oldPre then r = _oldPre(lb, ...) end

        local typed = ""
        local focused = false
        if self and self.BS_offlineNameEntry then
            if self.BS_offlineNameEntry.getText then
                typed = BS_trim(self.BS_offlineNameEntry:getText())
            end
            if self.BS_offlineNameEntry.isFocused then
                local ok, v = pcall(function() return self.BS_offlineNameEntry:isFocused() end)
                if ok and v then focused = true end
            elseif self.BS_offlineNameEntry.focus ~= nil then
                focused = self.BS_offlineNameEntry.focus and true or false
            end
        end

        if focused or typed ~= "" then
            lb.selected = 0
            if lb.selectedIndex ~= nil then lb.selectedIndex = 0 end
            if lb.selectedRow ~= nil then lb.selectedRow = 0 end
            if lb.selectedItem ~= nil then lb.selectedItem = nil end
            if self then
                self.selectedPlayer = nil
                self.selectedPlayerName = nil
            end
        end

        return r
    end
end

    -- Move the list down and shrink it so it never overlaps the field/buttons
    local deltaY = entryH + pad
    local newY = baseY + deltaY
    if list.setY then list:setY(newY) else list.y = newY end

    local newH = (list.height or 0) - deltaY
    if newH < 60 then newH = 60 end
    if list.setHeight then list:setHeight(newH) else list.height = newH end

    -- Enable/disable ADDPLAYER button based on selection OR typed name
    entry.onTextChange = function() BS_updateAddButtonEnable(self) end
    BS_updateAddButtonEnable(self)
end

-- Hook createChildren to inject the offline entry field after vanilla creates widgets.
local oldCreateChildren = ISSafehouseAddPlayerUI.createChildren
if oldCreateChildren then
    ISSafehouseAddPlayerUI.createChildren = function(self, ...)
        oldCreateChildren(self, ...)
        local me = getPlayer()
        if BetterSafehouse.getSandboxBool
            and BetterSafehouse.getSandboxBool("AdminsFreeAddToSafehouse", true)
            and isAdminClient(me) then
            BS_installOfflineEntry(self)
        end
        BS_updateAddButtonEnable(self)
    end
end


    local oldDrawPlayers = ISSafehouseAddPlayerUI.drawPlayers
    if oldDrawPlayers then
        -- Wrap the original drawPlayers. We DON'T redraw the list ourselves;
        -- we simply prevent tooltip-gating when the local player is an admin.
        ISSafehouseAddPlayerUI.drawPlayers = function(self, y, item, alt)
            local me = getPlayer()
            if BetterSafehouse.getSandboxBool
                and BetterSafehouse.getSandboxBool("AdminsFreeAddToSafehouse", true)
                and isAdminClient(me) then

                local savedTooltip = item and item.tooltip
                if item then item.tooltip = nil end
                local ny = oldDrawPlayers(self, y, item, alt)
                if item then item.tooltip = savedTooltip end

                -- If selected, force-enable the add button (vanilla may disable due to tooltip)
                if self and item and self.selected == item.index and self.parent and self.parent.addPlayer then
                    self.parent.addPlayer.enable = true
                    self.parent.addPlayer.tooltip = nil
                    if item.item and item.item.username then
                        self.parent.selectedPlayer = item.item.username
                    end
                end
                return ny
            end

            return oldDrawPlayers(self, y, item, alt)
        end
    end

    local oldOnClick = ISSafehouseAddPlayerUI.onClick
    if oldOnClick then
        ISSafehouseAddPlayerUI.onClick = function(self, button, ...)
            -- Admin "free add" uses server-side command, only for ADDPLAYER.
            if button and button.internal == "ADDPLAYER" then
                local me = getPlayer()
                if BetterSafehouse.getSandboxBool
                    and BetterSafehouse.getSandboxBool("AdminsFreeAddToSafehouse", true)
                    and isAdminClient(me) then

                    local typed = ""
if self and self.BS_offlineNameEntry and self.BS_offlineNameEntry.getText then
    typed = BS_trim(self.BS_offlineNameEntry:getText())
end

-- Offline typed name ALWAYS takes precedence (prevents adding the auto-selected first online player).
local target = (typed ~= "" and typed) or (self and self.selectedPlayer)

                    local sh = self and self.safehouse
                    if target and sh and sh.getX and sh.getY and sh.getW and sh.getH then
                        local z = 0
                        if sh.getZ then
                            local ok, zz = pcall(function() return sh:getZ() end)
                            if ok and type(zz) == "number" then z = zz end
                        end

                        sendClientCommand(me, "BetterSafehouse", "AdminAddToSafehouse", {
                            username = target,
                            x = sh:getX(), y = sh:getY(), w = sh:getW(), h = sh:getH(), z = z,
                            changeOwnership = self.changeOwnership == true,
                        })

                        if self and self.BS_offlineNameEntry and self.BS_offlineNameEntry.setText then
                            self.BS_offlineNameEntry:setText("")
                        end
                        if BS_updateAddButtonEnable then BS_updateAddButtonEnable(self) end

                        return -- don't run vanilla restrictions
                    end
                end
            -- EnhancedInvites: when target already has another safehouse, vanilla MP invite packet is blocked by the server.
            -- We use a custom (server-validated) invite flow so owners/members can still be invited.
            if BetterSafehouse.getSandboxBool and BetterSafehouse.getSandboxBool("EnhancedInvites", true) then
                local me2 = getPlayer()
                local sh2 = self and self.safehouse
                local target2 = self and self.selectedPlayer
                if target2 and target2 ~= "" and sh2 and sh2.alreadyHaveSafehouse and sh2.getX and sh2.getY and sh2.getW and sh2.getH then
                    local other2 = sh2:alreadyHaveSafehouse(target2)
                    if other2 and BetterSafehouse.sameSafehouse and (not BetterSafehouse.sameSafehouse(other2, sh2)) then
                        local z2 = 0
                        if sh2.getZ then
                            local okZ, zz2 = pcall(function() return sh2:getZ() end)
                            if okZ and type(zz2) == "number" then z2 = zz2 end
                        end

                        local rid = tostring((getTimestampMs and getTimestampMs()) or (os.time() * 1000)) .. "_" .. tostring((ZombRand and ZombRand(1000000)) or math.random(1000000))
                        sendClientCommand(me2, "BetterSafehouse", "RequestInvite", {
                            target = target2,
                            x = sh2:getX(), y = sh2:getY(), w = sh2:getW(), h = sh2:getH(), z = z2,
                            requestId = rid,
                        })
                        return
                    end
                end
            end

            end

            return oldOnClick(self, button, ...)
        end
    end
end


local function refreshOpenSafehouseUIs()
    if not UIManager or not UIManager.getUI then return end
    local uiList = UIManager.getUI()
    if not uiList then return end

    for i = 0, uiList:size() - 1 do
        local ui = uiList:get(i)

        if ui and instanceof(ui, "ISSafehouseAddPlayerUI") and ui.populateList then
            pcall(function() ui:populateList() end)
        end

        if ui and instanceof(ui, "ISSafehouseUI") and ui.populateList then
            pcall(function() ui:populateList() end)
        end
    end
end

local function BS_getSafehouseListForSync()
    if not SafeHouse or not SafeHouse.getSafehouseList then return nil end
    local ok, list = pcall(function() return SafeHouse.getSafehouseList() end)
    if ok then return list end
    return nil
end

local function BS_eachSafehouseForSync(list)
    if not list then
        return function() return nil end
    end

    if type(list) == "table" then
        return ipairs(list)
    end

    local okSize, n = pcall(function() return list:size() end)
    if okSize and type(n) == "number" and n > 0 then
        local i = 0
        return function()
            if i < n then
                local value = nil
                local okGet = pcall(function() value = list:get(i) end)
                i = i + 1
                if okGet then
                    return i, value
                end
            end
            return nil
        end
    end

    return function() return nil end
end

local function BS_safehouseMatchesReleaseRect(sh, x, y, w, h, z)
    if not sh or not sh.getX or not sh.getY or not sh.getW or not sh.getH then
        return false
    end

    local okx, sx = pcall(function() return sh:getX() end)
    local oky, sy = pcall(function() return sh:getY() end)
    local okw, sw = pcall(function() return sh:getW() end)
    local okh, shh = pcall(function() return sh:getH() end)
    if not okx or not oky or not okw or not okh then
        return false
    end

    local sz = 0
    if sh.getZ then
        local okz, zv = pcall(function() return sh:getZ() end)
        if okz and type(zv) == "number" then
            sz = zv
        end
    end

    if sx == x and sy == y and sw == w and shh == h and sz == z then
        return true
    end

    local okx2, shx2 = pcall(function()
        if sh.getX2 then return sh:getX2() end
        return sx + sw - 1
    end)
    local oky2, shy2 = pcall(function()
        if sh.getY2 then return sh:getY2() end
        return sy + shh - 1
    end)

    if okx2 and oky2 then
        local wantedX2 = x + w - 1
        local wantedY2 = y + h - 1
        return sx == x and sy == y and shx2 == wantedX2 and shy2 == wantedY2 and sz == z
    end

    return false
end

local function BS_findSafehouseForReleaseSync(x, y, w, h, z)
    if not SafeHouse then return nil end

    if SafeHouse.getSafeHouse then
        local ok, sh = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
        if ok and sh then return sh end
    end

    local cell = getCell and getCell() or nil
    if cell and cell.getGridSquare and SafeHouse.getSafeHouse then
        local centerX = x + math.floor(math.max(w - 1, 0) / 2)
        local centerY = y + math.floor(math.max(h - 1, 0) / 2)
        local okSq, square = pcall(function() return cell:getGridSquare(centerX, centerY, z) end)
        if okSq and square then
            local okBySquare, sh = pcall(function() return SafeHouse.getSafeHouse(square) end)
            if okBySquare and sh then return sh end
        end
    end

    local ui = ISSafehouseUI and ISSafehouseUI.instance or nil
    if ui and BS_safehouseMatchesReleaseRect(ui.safehouse, x, y, w, h, z) then
        return ui.safehouse
    end

    local listUI = ISSafehousesList and ISSafehousesList.instance or nil
    if listUI and listUI.selectedSafehouse and BS_safehouseMatchesReleaseRect(listUI.selectedSafehouse, x, y, w, h, z) then
        return listUI.selectedSafehouse
    end

    local editor = ISMultiplayerZoneEditor_instance
    if editor and editor.mode and editor.mode.Safehouse and editor.mode.Safehouse.detailsPanel then
        local panel = editor.mode.Safehouse.detailsPanel
        if BS_safehouseMatchesReleaseRect(panel.safehouse, x, y, w, h, z) then
            return panel.safehouse
        end
    end

    local list = BS_getSafehouseListForSync()
    if not list then return nil end

    for _, sh in BS_eachSafehouseForSync(list) do
        if BS_safehouseMatchesReleaseRect(sh, x, y, w, h, z) then
            return sh
        end
    end

    return nil
end

local function BS_clearViewerForReleaseRect(playerObj, sh, x, y, w, h, z)
    if not playerObj then return end

    local matches = false
    if sh and BetterSafehouse.viewerTargetMatchesSafehouse then
        matches = BetterSafehouse.viewerTargetMatchesSafehouse(playerObj, sh) == true
    end

    if not matches and BetterSafehouse.getClientViewerTarget then
        local target = BetterSafehouse.getClientViewerTarget(playerObj)
        if target then
            matches = target.x == x and target.y == y and target.w == w and target.h == h and (target.z or 0) == z
        end
    end

    if not matches then return end

    if BetterSafehouse.setClientViewerTarget then
        pcall(function() BetterSafehouse.setClientViewerTarget(playerObj, nil) end)
    end
    if BetterSafehouse.setClientViewerPref then
        pcall(function() BetterSafehouse.setClientViewerPref(playerObj, false) end)
    end
    if BetterSafehouse.Viewer and BetterSafehouse.Viewer.clear then
        pcall(function() BetterSafehouse.Viewer.clear() end)
    end
end

local function BS_removeSafehouseForReleaseSync(sh)
    if not sh then return false end

    local removed = false

    if SafeHouse and SafeHouse.removeSafeHouse then
        local ok = pcall(function() SafeHouse.removeSafeHouse(sh) end)
        if ok then removed = true end
    elseif sh.removeSafeHouse then
        local ok = pcall(function() sh.removeSafeHouse(sh) end)
        if ok then removed = true end
    end

    local list = BS_getSafehouseListForSync()
    if list then
        if list.remove then
            pcall(function() list:remove(sh) end)
            removed = true
        elseif type(list) == "table" then
            for i = #list, 1, -1 do
                if list[i] == sh then
                    table.remove(list, i)
                    removed = true
                    break
                end
            end
        end
    end

    return removed
end

local function BS_closeReleasedSafehouseUIs(x, y, w, h, z)
    local ui = ISSafehouseUI and ISSafehouseUI.instance or nil
    if ui and BS_safehouseMatchesReleaseRect(ui.safehouse, x, y, w, h, z) then
        pcall(function() ui:close() end)
    end

    local listUI = ISSafehousesList and ISSafehousesList.instance or nil
    if listUI and listUI.selectedSafehouse and BS_safehouseMatchesReleaseRect(listUI.selectedSafehouse, x, y, w, h, z) then
        listUI.selectedSafehouse = nil
        if listUI.listbox then
            listUI.listbox.selected = 0
        end
    end

    local editor = ISMultiplayerZoneEditor_instance
    if editor and editor.mode and editor.mode.Safehouse and editor.mode.Safehouse.detailsPanel then
        local panel = editor.mode.Safehouse.detailsPanel
        if BS_safehouseMatchesReleaseRect(panel.safehouse, x, y, w, h, z) then
            pcall(function() panel:setSafehouse(nil) end)
            pcall(function() panel:setVisible(false) end)
        end
    end
end

local function BS_applySafehouseReleased(args)
    if not args then return end

    local x = math.floor(tonumber(args.x) or 0)
    local y = math.floor(tonumber(args.y) or 0)
    local w = math.floor(tonumber(args.w) or 0)
    local h = math.floor(tonumber(args.h) or 0)
    local z = math.floor(tonumber(args.z) or 0)

    local sh = BS_findSafehouseForReleaseSync(x, y, w, h, z)
    local playerObj = getPlayer and getPlayer() or nil

    BS_clearViewerForReleaseRect(playerObj, sh, x, y, w, h, z)
    BS_removeSafehouseForReleaseSync(sh)
    BS_closeReleasedSafehouseUIs(x, y, w, h, z)

    if triggerEvent then
        pcall(function() triggerEvent("OnSafehousesChanged") end)
    end

    refreshOpenSafehouseUIs()
end


-- =========================================================
-- Custom safehouse invites (MP): allows inviting players who already own/belong to another safehouse.
-- Vanilla B42 server blocks the standard SafehouseInvitePacket in this case.
-- =========================================================

BetterSafehouse._inviteQueue = BetterSafehouse._inviteQueue or {}
BetterSafehouse._inviteModalOpen = BetterSafehouse._inviteModalOpen or false

local function BS_showNextInvite()
    if BetterSafehouse._inviteModalOpen then return end
    if not ISModalDialog then return end

    local inv = table.remove(BetterSafehouse._inviteQueue, 1)
    if not inv then return end

    BetterSafehouse._inviteModalOpen = true

    local title = tostring(inv.title or getText("IGUI_BetterSafehouse_DefaultSafehouseTitle"))
    local from = tostring(inv.from or inv.inviter or "???")
    local txt = getText("IGUI_BetterSafehouse_InviteModal_Text", title, from)

    local modal
    modal = ISModalDialog:new(0, 0, 440, 170, txt, true, nil, function(_, button)
        BetterSafehouse._inviteModalOpen = false

        local me = getPlayer()
        if me and sendClientCommand then
            if button and button.internal == "YES" then
                sendClientCommand(me, "BetterSafehouse", "AcceptInvite", {
                    requestId = inv.requestId,
                    x = inv.x, y = inv.y, w = inv.w, h = inv.h, z = inv.z,
                })
            else
                sendClientCommand(me, "BetterSafehouse", "DeclineInvite", {
                    requestId = inv.requestId,
                })
            end
        end

        BS_showNextInvite()
    end)

    modal:initialise()
    modal:addToUIManager()
end

local function BS_enqueueInvite(inv)
    table.insert(BetterSafehouse._inviteQueue, inv)
    BS_showNextInvite()
end

local function BS_sayServerResult(args)
    local me = getPlayer()
    if not me or not me.Say then return end

    local msg = ""
    if args and args.key then
        msg = getText(args.key, (table.unpack or unpack)(args.args or {}))
    else
        msg = tostring(args and args.msg or (args and args.ok and getText("IGUI_BetterSafehouse_GenericOK") or getText("IGUI_BetterSafehouse_GenericFailed")))
    end

    me:Say(msg)
end

local function onServerCommand(module, command, args)
    if module ~= "BetterSafehouse" then return end
    if not args then args = {} end

    if command == "AdminAddResult" then
        BS_sayServerResult(args)
        return
    end

    if command == "AdminReleaseResult" then
        BS_sayServerResult(args)
        return
    end

    if command == "InviteReceived" then
        -- args: { x,y,w,h,z, from, title, requestId }
        BS_enqueueInvite(args)
        return
    end

    if command == "InviteResult" then
        BS_sayServerResult(args)
        return
    end

    if command == "SafehouseMemberAdded" then
        -- Update local mirror (UI only). Server remains authoritative.
        if SafeHouse and SafeHouse.getSafeHouse and args.x and args.y and args.w and args.h then
            local ok, sh = pcall(function() return SafeHouse.getSafeHouse(args.x, args.y, args.w, args.h) end)
            if ok and sh then
                if args.changeOwnership and args.owner and sh.setOwner then
                    pcall(function() sh:setOwner(tostring(args.owner)) end)
                end
                if args.prevOwner and sh.addPlayer then
                    pcall(function() sh:addPlayer(tostring(args.prevOwner)) end)
                end
                if args.username and sh.addPlayer then
                    pcall(function() sh:addPlayer(tostring(args.username)) end)
                end
            end
        end

        refreshOpenSafehouseUIs()
        return
    end

    if command == "SafehouseReleased" then
        BS_applySafehouseReleased(args)
        return
    end

    if command == "ClaimVanillaBypassResult" then
        -- Only sent on failure; success arrives as "ClaimVanillaBypassAdded" instead.
        BS_sayServerResult(args)
        return
    end

    if command == "ClaimVanillaBypassAdded" then
        local x = math.floor(tonumber(args.x) or 0)
        local y = math.floor(tonumber(args.y) or 0)
        local w = math.floor(tonumber(args.w) or 0)
        local h = math.floor(tonumber(args.h) or 0)
        local owner = args.owner

        if SafeHouse and w > 0 and h > 0 then
            local okFind, sh = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
            if not (okFind and sh) then
                local fn = SafeHouse.addSafeHouse or SafeHouse.addSafehouse
                if fn then
                    pcall(function() return fn(x, y, w, h, owner) end)
                end
                okFind, sh = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
            end

            if okFind and sh then
                -- Same belt-and-suspenders as the server's createSafehouseAt:
                -- force owner/membership explicitly rather than trusting
                -- addSafeHouse's 5th arg alone, so this client's local mirror
                -- always matches what the server actually created.
                if owner then
                    pcall(function() sh:setOwner(owner) end)
                    if sh.addPlayer then
                        pcall(function() sh:addPlayer(owner) end)
                    end
                end

                local playerObj = getPlayer and getPlayer() or nil
                local username = playerObj and playerObj.getUsername and playerObj:getUsername() or nil
                if playerObj and username and owner and tostring(owner) == tostring(username) then
                    if playerObj.Say then
                        pcall(function() playerObj:Say(getText("IGUI_BetterSafehouse_Claim_GenericSuccess")) end)
                    end
                    if BetterSafehouse.activateViewerForSafehouse then
                        pcall(function() BetterSafehouse.activateViewerForSafehouse(sh, playerObj) end)
                    end
                end
            end
        end

        refreshOpenSafehouseUIs()
        return
    end

    if command == "CooldownSync" then
        -- Servidor enviou timestamp do último claim: armazenar no cache local.
        -- NÃO usa ModData — sem risco de sobrescrever dados de outros mods.
        local me = getPlayer()
        if me and args and type(args.ts) == "number" then
            local username = me.getUsername and me:getUsername() or nil
            if username and username ~= "" then
                BS_cooldownCache[username] = args.ts
                print(string.format("[BetterSafehouse] CooldownSync recebido: ts=%d", args.ts))
            end
        end
        return
    end
end

local function boot()
    patchISSafehouseAddPlayerUI_EnhancedInvites()
    patchISSafehouseAddPlayerUI_AdminFreeAdd()
end

Events.OnGameBoot.Add(boot)
Events.OnGameStart.Add(boot)
Events.OnServerCommand.Add(onServerCommand)


-- =========================================================
-- Enforce MaxJoinedSafehouses at invite-accept time (client)
-- NOTE: Vanilla safehouse invites are accepted via acceptSafehouseInvite().
-- We wrap it to prevent accepting when at/over the sandbox limit.
-- =========================================================

local function patchAcceptSafehouseInvite_MaxJoined()
    if BetterSafehouse._patchedAcceptSafehouseInvite_MaxJoined then return end
    if type(acceptSafehouseInvite) ~= "function" then return end

    BetterSafehouse._patchedAcceptSafehouseInvite_MaxJoined = true
    local oldAccept = acceptSafehouseInvite

    acceptSafehouseInvite = function(...)
        local safehouse = select(1, ...)
        local hostUsername = select(2, ...)
        local max = BetterSafehouse.getMaxJoinedSafehouses and BetterSafehouse.getMaxJoinedSafehouses() or 0
        if max and max > 0 then
            local me = getPlayer()
            local username = me and me.getUsername and me:getUsername() or nil

            if username and safehouse and BetterSafehouse.safehouseHasUser and BetterSafehouse.countSafehousesForUsername
                and not BetterSafehouse.safehouseHasUser(safehouse, username) then
                local cur = BetterSafehouse.countSafehousesForUsername(username) or 0
                if cur >= max then
                    if me and me.Say then
                        me:Say(getText("IGUI_BetterSafehouse_Invite_MaxJoinedReached_Local", tostring(cur), tostring(max)))
                    end
                    return
                end
            end
        end

        -- IMPORTANT: forward ALL args (B42 acceptSafehouseInvite expects 4 args)
        return oldAccept(...)
    end
end

Events.OnGameStart.Add(patchAcceptSafehouseInvite_MaxJoined)


-- =========================================================
-- Safehouse UI tab: per-safehouse viewer toggle (player + admin)
-- Adds a checkbox inside ISSafehouseUI to highlight THIS safehouse.
-- MP-safe: client-side only (stores target in player modData).
-- =========================================================

local function BS_getTextOrFallback(key, fallback)
    local t = getTextOrNull and getTextOrNull(key) or nil
    if t and t ~= "" and t ~= key then return t end
    return fallback
end
-- =========================================================
-- Safehouse tile counter label (ISSafehouseUI)
-- Shows safehouse footprint tiles (W*H) for the currently selected safehouse.
-- Client-side only (safehouse bounds are already synced in MP).
-- =========================================================

local function BS_safehouseFootprintTiles(sh)
    if not sh then return 0, 0, 0 end

    -- Bounds reconciliation (same idea as BetterSafehouse.Viewer.safehouseBounds()).
    local x1 = sh.getX and sh:getX() or 0
    local y1 = sh.getY and sh:getY() or 0

    local w = nil
    local h = nil
    if sh.getW then
        local ok, v = pcall(function() return sh:getW() end)
        if ok and type(v) == "number" then w = v end
    end
    if sh.getH then
        local ok, v = pcall(function() return sh:getH() end)
        if ok and type(v) == "number" then h = v end
    end

    local x2 = nil
    local y2 = nil
    if sh.getX2 then
        local ok, v = pcall(function() return sh:getX2() end)
        if ok and type(v) == "number" then x2 = v end
    end
    if sh.getY2 then
        local ok, v = pcall(function() return sh:getY2() end)
        if ok and type(v) == "number" then y2 = v end
    end

    if w then
        local expected = x1 + w - 1
        if x2 == nil then
            x2 = expected
        else
            -- Some builds expose getX2 as EXCLUSIVE (x1+w). Convert to inclusive.
            if x2 == expected + 1 then x2 = expected end
        end
    end
    if h then
        local expected = y1 + h - 1
        if y2 == nil then
            y2 = expected
        else
            if y2 == expected + 1 then y2 = expected end
        end
    end

    if x2 == nil then x2 = x1 end
    if y2 == nil then y2 = y1 end

    local ww = math.max(0, (x2 - x1 + 1))
    local hh = math.max(0, (y2 - y1 + 1))
    return ww * hh, ww, hh
end

local function BS_tileCountText(count, w, h)
    -- Optional translation key (if present): IGUI_BetterSafehouse_TileCount = "Tiles: %1 (%2x%3)"
    -- The key carries %1/%2/%3: look it up together with its arguments, never
    -- alone, otherwise Translator logs MissingFormatArgumentException.
    if getText then
        local ok, v = pcall(getText, "IGUI_BetterSafehouse_TileCount", count, w, h)
        if ok and type(v) == "string" and v ~= "" and v ~= "IGUI_BetterSafehouse_TileCount"
            and v:sub(1, 6) ~= "ERROR:" then
            return v
        end
    end
    return tostring("Tiles: " .. tostring(count) .. " (" .. tostring(w) .. "x" .. tostring(h) .. ")")
end

local function BS_updateSafehouseTileCountLabel(self)
    if not self then return end
    local lbl = self.BS_tileCountLabel
    if not lbl then return end

    local sh = self.safehouse
    if not sh then
        if lbl.setVisible then lbl:setVisible(false) else lbl.visible = false end
        return
    end

    local count, w, h = BS_safehouseFootprintTiles(sh)
    local txt = BS_tileCountText(count, w, h)

    if lbl.setName then lbl:setName(txt) else lbl.name = txt end
    if lbl.setVisible then lbl:setVisible(true) else lbl.visible = true end
end

local function BS_findRefreshButtonDeep(root)
    if not root or not root.children then return nil, nil end
    for _, child in pairs(root.children) do
        if child then
            if child.Type == "ISButton" then
                local internal = tostring(child.internal or ""):lower()
                local title = tostring(child.title or ""):lower()
                if internal == "refresh" or internal == "refreshlist" or title:find("refresh", 1, true) or title:find("atualizar", 1, true) then
                    return child, (child.parent or root)
                end
            end
            local b, p = BS_findRefreshButtonDeep(child)
            if b then return b, p end
        end
    end
    return nil, nil
end

local function BS_repositionTileCountLabel(self)
    if not self then return end
    local lbl = self.BS_tileCountLabel
    if not lbl then return end

    -- Prefer placing next to the Refresh button (layout-safe across resolutions).
    local refreshBtn, refreshContainer = BS_findRefreshButtonDeep(self)
    if refreshBtn and refreshBtn.getX and refreshBtn.getY and refreshBtn.getWidth then
        local container = refreshContainer or refreshBtn.parent or self

        -- Ensure coordinates match (label as sibling of refresh button).
        if lbl.parent ~= container then
            pcall(function()
                if lbl.parent and lbl.parent.removeChild then lbl.parent:removeChild(lbl) end
            end)
            pcall(function()
                if container and container.addChild then container:addChild(lbl) end
            end)
        end

        local lblW = (lbl.getWidth and lbl:getWidth()) or lbl.width or 80
        local lblH = (lbl.getHeight and lbl:getHeight()) or lbl.height or 14
        local btnX = refreshBtn:getX()
        local btnY = refreshBtn:getY()
        local btnW = refreshBtn:getWidth()
        local btnH = (refreshBtn.getHeight and refreshBtn:getHeight()) or 20

        -- Default: to the right of Refresh
        local x = math.floor(btnX + btnW + 10)
        local y = math.floor(btnY + (btnH - lblH) / 2)

        -- Keep inside the container bounds
        local panelW = (container.getWidth and container:getWidth()) or (self.getWidth and self:getWidth()) or 520
        local rightLimit = panelW - 10

        if x + lblW > rightLimit then
            -- Try left of Refresh
            x = math.floor(btnX - lblW - 10)
            if x < 10 then
                -- Fallback: below Refresh
                x = math.floor(btnX)
                y = math.floor(btnY + btnH + 2)
            end
        end

        if lbl.setX then lbl:setX(x) else lbl.x = x end
        if lbl.setY then lbl:setY(y) else lbl.y = y end
        if lbl.bringToTop then pcall(function() lbl:bringToTop() end) end
        return
    end

    -- Fallback: keep near the viewer tick (older layouts).
    local x = 20
    local y = 10

    local tick = self.BS_viewerTick
    local h = (lbl.getHeight and lbl:getHeight()) or lbl.height or 14

    if tick and tick.getX and tick.getY then
        x = tick:getX()
        y = tick:getY() - (h + 2)
        -- If we would go out of the panel, place it below the tick.
        if y < 10 and tick.getHeight then
            y = tick:getY() + tick:getHeight() + 2
        end
    end

    if lbl.setX then lbl:setX(x) else lbl.x = x end
    if lbl.setY then lbl:setY(y) else lbl.y = y end
    if lbl.bringToTop then pcall(function() lbl:bringToTop() end) end
end


local function BS_installSafehouseTileCountLabel(self)
    if not self or self.BS_tileCountLabel then return end
    if not ISLabel then return end
    if not self.safehouse then return end

    local count, w, h = BS_safehouseFootprintTiles(self.safehouse)
    local txt = BS_tileCountText(count, w, h)

    local fontH = 14
    if getTextManager and getTextManager() and getTextManager().getFontHeight then
        local ok, v = pcall(function() return getTextManager():getFontHeight(UIFont.Small) end)
        if ok and type(v) == "number" and v > 0 then fontH = v end
    end

    -- Prefer adding as a sibling of the Refresh button so coords match on any resolution/layout.
    local parent = self
    local refreshBtn, refreshContainer = BS_findRefreshButtonDeep(self)
    if refreshBtn then
        parent = refreshContainer or refreshBtn.parent or self
    end

    local lbl = ISLabel:new(20, 10, fontH, txt, 1, 1, 1, 1, UIFont.Small, true)
    lbl:initialise()
    if parent and parent.addChild then
        parent:addChild(lbl)
    elseif self.addChild then
        self:addChild(lbl)
    end
    self.BS_tileCountLabel = lbl

    pcall(function() BS_updateSafehouseTileCountLabel(self) end)
    pcall(function() BS_repositionTileCountLabel(self) end)
end



local function BS_findOkButton(self)
    if not self or not self.children then return nil end
    for _,child in pairs(self.children) do
        if child and child.Type == "ISButton" and child.title and child.getY then
            local t = tostring(child.title):lower()
            if t == "ok" or t:find("fechar") or t:find("close") then
                return child
            end
        end
    end
    return nil
end

-- Walk UI children recursively (ISSafehouseUI uses nested panels in some layouts).
local function BS_walkChildren(root, fn)
    if not root or not root.children then return nil end
    for _, child in pairs(root.children) do
        if child then
            local res = fn(child, root)
            if res ~= nil then return res end
            local sub = BS_walkChildren(child, fn)
            if sub ~= nil then return sub end
        end
    end
    return nil
end

local function BS_findButton(self, internal, keywords)
    local res = BS_walkChildren(self, function(child, parent)
        if child and child.Type == "ISButton" then
            if internal and child.internal == internal then
                return { btn = child, parent = (child.parent or parent or self) }
            end
            local title = tostring(child.title or ""):lower()
            for i=1, #keywords do
                local kw = keywords[i]
                if kw and kw ~= "" and title:find(kw, 1, true) then
                    return { btn = child, parent = (child.parent or parent or self) }
                end
            end
        end
        return nil
    end)
    if res then return res.btn, res.parent end
    return nil, nil
end

local function BS_findSafehouseAddButton(self)
    return BS_findButton(self, "ADDPLAYER", {"adicionar", "add player", "add"})
end

local function BS_findSafehouseRemoveButton(self)
    return BS_findButton(self, "REMOVE", {"remover", "remove"})
end



local function BS_repositionViewerTick(self)
    if not self then return end
    local tick = self.BS_viewerTick
    if not tick then return end

    -- Always prefer positioning next to the "Adicionar Jogador" button.
    local addBtn, addContainer = BS_findSafehouseAddButton(self)
    if addBtn and addBtn.getX and addBtn.getY and addBtn.getWidth then
        local container = addContainer or addBtn.parent or self

        local x = math.floor(addBtn:getX() + addBtn:getWidth() + 14)
        local y = math.floor(addBtn:getY() + 2)

        local panelW = (container.getWidth and container:getWidth()) or (self.getWidth and self:getWidth()) or 520
        local rightLimit = panelW - 20

        local rmBtn, rmContainer = BS_findSafehouseRemoveButton(self)
        if rmBtn and rmBtn.getX then
            local rCont = rmContainer or rmBtn.parent
            if rCont == container then
                rightLimit = math.floor(rmBtn:getX() - 12)
            end
        end

        local w = math.max(140, math.min(320, rightLimit - x))
        if w < 120 then w = 120 end

        -- If parent differs (some layouts rebuild children), try to move it to the right container.
        if tick.parent ~= container and container and container.addChild then
            if tick.parent and tick.parent.removeChild then pcall(function() tick.parent:removeChild(tick) end) end
            pcall(function() container:addChild(tick) end)
        end

        if tick.setX then tick:setX(x) else tick.x = x end
        if tick.setY then tick:setY(y) else tick.y = y end
        if tick.setWidth then tick:setWidth(w) else tick.width = w end

        if tick.bringToTop then pcall(function() tick:bringToTop() end) end
    end
    if BS_repositionTileCountLabel then pcall(function() BS_repositionTileCountLabel(self) end) end
end



local function BS_findRespawnTickBox(self)
    if not self or not self.children then return nil end

    -- Common field names (varies by build)
    if self.respawn then return self.respawn end
    if self.respawnTickBox then return self.respawnTickBox end
    if self.respawnInSafehouseTickBox then return self.respawnInSafehouseTickBox end
    if self.respawnInSafehouse then return self.respawnInSafehouse end

    for _,child in pairs(self.children) do
        if child and child.Type == "ISTickBox" and child.options and child.options[1] then
            local txt = child.options[1]
            if type(txt) == "table" then
                txt = txt.text
            end
            if txt then
                local s = tostring(txt):lower()
                if s:find("renascer") or s:find("respawn") then
                    return child
                end
            end
        end
    end

    return nil
end


local function BS_safehouseToTarget(sh)
    if not sh or not sh.getX or not sh.getY then return nil end

    local okx, x = pcall(function() return sh:getX() end); if not okx then return nil end
    local oky, y = pcall(function() return sh:getY() end); if not oky then return nil end

    -- Prefer inclusive x2/y2 when available (matches viewer safehouseBounds and avoids missing border tiles).
    local x2, y2 = nil, nil
    if sh.getX2 then
        local ok, v = pcall(function() return sh:getX2() end)
        if ok and type(v) == "number" then x2 = v end
    end
    if sh.getY2 then
        local ok, v = pcall(function() return sh:getY2() end)
        if ok and type(v) == "number" then y2 = v end
    end

    local w, h = nil, nil
    if sh.getW then
        local ok, v = pcall(function() return sh:getW() end)
        if ok and type(v) == "number" then w = v end
    end
    if sh.getH then
        local ok, v = pcall(function() return sh:getH() end)
        if ok and type(v) == "number" then h = v end
    end

    if not x2 and w then x2 = x + w - 1 end
    if not y2 and h then y2 = y + h - 1 end
    if not x2 then x2 = x end
    if not y2 then y2 = y end

    -- Ensure w/h are consistent even if only x2/y2 existed.
    if not w then w = (x2 - x + 1) end
    if not h then h = (y2 - y + 1) end

    local z = 0
    if sh.getZ then
        local okz, zz = pcall(function() return sh:getZ() end)
        if okz and type(zz) == "number" then z = zz end
    end

    return { x=x, y=y, x2=x2, y2=y2, w=w, h=h, z=z }
end

local function BS_sameSafehouseRect(a, b)
    if not a or not b then return false end

    local ta = (type(a) == "table" and type(a.x) == "number") and a or BS_safehouseToTarget(a)
    local tb = (type(b) == "table" and type(b.x) == "number") and b or BS_safehouseToTarget(b)
    if not ta or not tb then return false end

    return ta.x == tb.x and ta.y == tb.y and ta.w == tb.w and ta.h == tb.h and (ta.z or 0) == (tb.z or 0)
end

local function BS_findOwnedSafehouse(playerObj)
    if not playerObj or not BetterSafehouse.getSafehouseList then return nil end

    local username = playerObj.getUsername and playerObj:getUsername() or nil
    if not username or username == "" then return nil end
    username = tostring(username)

    local list = BetterSafehouse.getSafehouseList()
    if not list then return nil end

    if list.size and list.get then
        for i = 0, list:size() - 1 do
            local sh = list:get(i)
            if sh and sh.getOwner then
                local ok, owner = pcall(function() return sh:getOwner() end)
                if ok and owner and tostring(owner) == username then
                    return sh
                end
            end
        end
        return nil
    end

    if type(list) == "table" then
        for _, sh in ipairs(list) do
            if sh and sh.getOwner then
                local ok, owner = pcall(function() return sh:getOwner() end)
                if ok and owner and tostring(owner) == username then
                    return sh
                end
            end
        end
    end

    return nil
end

local function BS_nowMs()
    if getTimestampMs then
        local ok, now = pcall(getTimestampMs)
        if ok and type(now) == "number" then
            return now
        end
    end

    if os and os.time then
        return os.time() * 1000
    end

    return 0
end

function BetterSafehouse.activateViewerForSafehouse(sh, playerObj)
    playerObj = playerObj or (getPlayer and getPlayer() or nil)
    if not sh or not playerObj then return false end
    if not BetterSafehouse.setClientViewerPref or not BetterSafehouse.setClientViewerTarget then return false end

    local sandboxAllows = BetterSafehouse.isViewerEnabledBySandbox and BetterSafehouse.isViewerEnabledBySandbox() or true
    if not sandboxAllows then return false end

    local target = BS_safehouseToTarget(sh)
    if not target then return false end

    BetterSafehouse.setClientViewerPref(playerObj, true)
    BetterSafehouse.setClientViewerTarget(playerObj, target)

    if BetterSafehouse.Viewer then
        BetterSafehouse.Viewer.lastSafehouseId = nil
        BetterSafehouse.Viewer.lastZ = nil
        BetterSafehouse.Viewer.lastApplyMs = 0
    end

    return true
end

local BS_pendingViewerAutoEnable = nil

local function BS_queueViewerAutoEnable(playerObj, previousSafehouse)
    if not playerObj then return end

    local username = playerObj.getUsername and playerObj:getUsername() or nil
    if not username or username == "" then return end

    BS_pendingViewerAutoEnable = {
        playerNum = playerObj.getPlayerNum and playerObj:getPlayerNum() or 0,
        username = tostring(username),
        startedAt = BS_nowMs(),
        previous = BS_safehouseToTarget(previousSafehouse),
    }
end

local function BS_tryResolvePendingViewerAutoEnable()
    local pending = BS_pendingViewerAutoEnable
    if not pending then return end

    local playerObj = nil
    if getSpecificPlayer and pending.playerNum ~= nil then
        playerObj = getSpecificPlayer(pending.playerNum)
    end
    if not playerObj and getPlayer then
        playerObj = getPlayer()
    end
    if not playerObj then return end

    local username = playerObj.getUsername and playerObj:getUsername() or nil
    if not username or tostring(username) ~= pending.username then
        BS_pendingViewerAutoEnable = nil
        return
    end

    if BetterSafehouse.isViewerEnabledBySandbox and not BetterSafehouse.isViewerEnabledBySandbox() then
        BS_pendingViewerAutoEnable = nil
        return
    end

    local sh = BS_findOwnedSafehouse(playerObj)
    if sh and not BS_sameSafehouseRect(sh, pending.previous) then
        if BetterSafehouse.activateViewerForSafehouse(sh, playerObj) then
            BS_pendingViewerAutoEnable = nil
            return
        end
    end

    if BS_nowMs() - (pending.startedAt or 0) > 10000 then
        BS_pendingViewerAutoEnable = nil
    end
end

if Events and not BetterSafehouse._viewerAutoEnableClaimHooked then
    BetterSafehouse._viewerAutoEnableClaimHooked = true
    if Events.OnTick then Events.OnTick.Add(BS_tryResolvePendingViewerAutoEnable) end
    if Events.OnSafehousesChanged then Events.OnSafehousesChanged.Add(BS_tryResolvePendingViewerAutoEnable) end
end

-- ISTickBox callback: (targetUI, optionIndex, enabled)
function BetterSafehouse:onSafehouseTabViewerToggle(option, enabled)
    local ui = self
    local playerObj = getPlayer()
    if not ui or not playerObj then return end

    -- Permission: admins can target any safehouse; players only their own/member safehouses.
    local username = playerObj.getUsername and playerObj:getUsername() or nil
    local allowed = isAdminClient(playerObj)
    if (not allowed) and ui.safehouse and username and BetterSafehouse.safehouseHasUser then
        allowed = BetterSafehouse.safehouseHasUser(ui.safehouse, username) == true
    end
    if not allowed then
        -- Force UI OFF if someone somehow opens it without permission.
        if ui.BS_viewerTick and ui.BS_viewerTick.setSelected then
            ui.BS_viewerTick:setSelected(1, false)
        end
        return
    end

    -- Respect server/sandbox enable.
    local sandboxAllows = BetterSafehouse.isViewerEnabledBySandbox and BetterSafehouse.isViewerEnabledBySandbox() or true
    local ena = (enabled == true) and sandboxAllows

    if ena then
        BetterSafehouse.activateViewerForSafehouse(ui.safehouse, playerObj)
    else
        BetterSafehouse.setClientViewerTarget(playerObj, nil)
        BetterSafehouse.setClientViewerPref(playerObj, false)
        if BetterSafehouse.Viewer and BetterSafehouse.Viewer.clear then
            BetterSafehouse.Viewer.clear()
        end
    end

    -- Force immediate refresh
    if BetterSafehouse.Viewer then
        BetterSafehouse.Viewer.lastSafehouseId = nil
        BetterSafehouse.Viewer.lastZ = nil
        BetterSafehouse.Viewer.lastApplyMs = 0
    end

    -- If sandbox disabled, snap checkbox back to OFF.
    if not sandboxAllows and ui.BS_viewerTick and ui.BS_viewerTick.setSelected then
        ui.BS_viewerTick:setSelected(1, false)
        if playerObj and playerObj.Say then
            local msg = BS_getTextOrFallback("IGUI_BetterSafehouse_ViewerToggle_disabledByServer", "Desativado nas opções de sandbox do servidor.")
            playerObj:Say(msg)
        end
    end
end

local function BS_installSafehouseTabViewerTick(self)
    if not self or self.BS_viewerTick then return end
    if not ISTickBox then return end
    if not BetterSafehouse.isViewerEnabledBySandbox then return end

    local playerObj = getPlayer()
    if not playerObj then return end

    local sh = self.safehouse
    if not sh then return end

    -- Only show for members/owner OR admin.
    local username = playerObj.getUsername and playerObj:getUsername() or nil
    local allowed = isAdminClient(playerObj)
    if (not allowed) and username and BetterSafehouse.safehouseHasUser then
        allowed = BetterSafehouse.safehouseHasUser(sh, username) == true
    end
    if not allowed then return end

    local x = 20
    local y = 0
    local h = math.max(22, getTextManager():getFontHeight(UIFont.Small) + 6)
    local w = 260

    local container = self

    -- Prefer positioning next to the "Adicionar Jogador" button (same row as bottom actions).
    local addBtn, addContainer = BS_findSafehouseAddButton(self)
    if addBtn and addBtn.getX and addBtn.getY then
        container = addContainer or addBtn.parent or self

        x = math.floor(addBtn:getX() + addBtn:getWidth() + 14)
        y = math.floor(addBtn:getY() + 2)
        if addBtn.getHeight then h = math.max(h, addBtn:getHeight()) end

        local panelW = (container.getWidth and container:getWidth()) or (self.getWidth and self:getWidth()) or 520
        local rightLimit = panelW - 20

        local rmBtn, rmContainer = BS_findSafehouseRemoveButton(self)
        if rmBtn and rmBtn.getX then
            local rCont = rmContainer or rmBtn.parent
            if rCont == container then
                rightLimit = math.floor(rmBtn:getX() - 12)
            end
        end

        w = math.max(140, math.min(320, rightLimit - x))
    else
        -- Fallback: next to the vanilla "Respawn in Safehouse" tickbox (Renascer na Base)
        local anchor = BS_findRespawnTickBox(self)
        if anchor and anchor.getX then
            x = anchor:getX() + anchor:getWidth() + 12
            y = anchor:getY()
            if anchor.getHeight then h = anchor:getHeight() end

            -- If there isn't enough room to the right, place below it.
            local panelW = (self.getWidth and self:getWidth() or 520)
            if x + w > panelW - 20 then
                x = anchor:getX()
                y = anchor:getY() + h + 2
            end
        else
            -- Fallback: place just above the OK button, left aligned.
            local okBtn = BS_findOkButton(self)
            local panelW = (self.getWidth and self:getWidth() or 520)
            if w > panelW - 40 then w = panelW - 40 end

            if okBtn and okBtn.getY then
                y = okBtn:getY() - (h + 10)
                if y < 10 then y = 10 end
                x = 20
            else
                y = (self.getHeight and self:getHeight() or 420) - (h + 40)
            end
        end
    end

    local panelW = (container.getWidth and container:getWidth()) or (self.getWidth and self:getWidth()) or 520
    if w > panelW - x - 20 then w = math.max(120, panelW - x - 20) end

    local label = BS_getTextOrFallback("IGUI_BetterSafehouse_ViewThisSafehouse", "Visualizar esta safehouse")
    local tooltip = BS_getTextOrFallback("IGUI_BetterSafehouse_ViewThisSafehouse_tooltip", "Destaca no chão (azul) toda a área desta safehouse. (Somente visual)")

    local tick = ISTickBox:new(x, y, w, h, "", self, BetterSafehouse.onSafehouseTabViewerToggle)
    tick:initialise()
    tick:addOption(label)
    if tick.setTooltip then tick:setTooltip(tooltip) end

    -- initial state = viewer enabled AND target matches this safehouse
    local selected = false
    if BetterSafehouse.getClientViewerPref and BetterSafehouse.viewerTargetMatchesSafehouse then
        selected = BetterSafehouse.getClientViewerPref(playerObj) and BetterSafehouse.viewerTargetMatchesSafehouse(playerObj, sh)
    end
    tick:setSelected(1, selected)

    local parent = container or self
    if parent and parent.addChild then parent:addChild(tick) else self:addChild(tick) end
    if tick.bringToTop then pcall(function() tick:bringToTop() end) end
    self.BS_viewerTick = tick
    pcall(function() BS_repositionViewerTick(self) end)
end

local function patchISSafehouseUI_ViewerTab()
    if not ISSafehouseUI then return end
    if ISSafehouseUI._BetterSafehouseViewerTabPatched then return end
    ISSafehouseUI._BetterSafehouseViewerTabPatched = true

    local oldCreateChildren = ISSafehouseUI.createChildren
    if oldCreateChildren then
        ISSafehouseUI.createChildren = function(self, ...)
            local ret = oldCreateChildren(self, ...)
            pcall(function() BS_installSafehouseTabViewerTick(self) end)
            pcall(function() BS_installSafehouseTileCountLabel(self) end)
            pcall(function() BS_updateSafehouseTileCountLabel(self) end)
            pcall(function() BS_repositionViewerTick(self) end)
            pcall(function() BS_repositionTileCountLabel(self) end)
            return ret
        end

        -- Some layouts reposition bottom buttons during populateList; keep our tick aligned.
        if not ISSafehouseUI._BetterSafehouseViewerTabPopulatePatched then
            ISSafehouseUI._BetterSafehouseViewerTabPopulatePatched = true
            local oldPopulateList = ISSafehouseUI.populateList
            if oldPopulateList then
                ISSafehouseUI.populateList = function(self, ...)
                    local ret = oldPopulateList(self, ...)
                    pcall(function() BS_repositionViewerTick(self) end)
                    pcall(function() BS_installSafehouseTileCountLabel(self) end)
                    pcall(function() BS_updateSafehouseTileCountLabel(self) end)
                    pcall(function() BS_repositionTileCountLabel(self) end)
                    return ret
                end
            end
        end

        return
    end

    local oldCreate = ISSafehouseUI.create
    if oldCreate then
        ISSafehouseUI.create = function(self, ...)
            local ret = oldCreate(self, ...)
            pcall(function() BS_installSafehouseTabViewerTick(self) end)
            pcall(function() BS_installSafehouseTileCountLabel(self) end)
            pcall(function() BS_updateSafehouseTileCountLabel(self) end)
            pcall(function() BS_repositionViewerTick(self) end)
            pcall(function() BS_repositionTileCountLabel(self) end)
            return ret
        end
    end
end

Events.OnGameStart.Add(patchISSafehouseUI_ViewerTab)


-- =========================================================
-- Admin Safehouses List: Owner search filter (B42)
-- Robust runtime injection (no dependency on UI class names).
-- Adds a search box under the title to filter safehouses by Owner.
-- =========================================================

local function BSA_trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function BSA_lower(s)
    s = BSA_trim(s)
    return string.lower(s)
end

local function BSA_getChildrenList(panel)
    if not panel then return nil end
    if panel.children then return panel.children end
    if panel.getChildren then
        local ok, kids = pcall(function() return panel:getChildren() end)
        if ok and kids then return kids end
    end
    return nil
end

local function BSA_walk(panel, fn)
    local kids = BSA_getChildrenList(panel)
    if not kids then return nil end

    if type(kids) == "table" then
        for _, child in pairs(kids) do
            if child then
                local r = fn(child, panel)
                if r ~= nil then return r end
                local sub = BSA_walk(child, fn)
                if sub ~= nil then return sub end
            end
        end
    else
        -- Java ArrayList
        local okSize, sz = pcall(function() return kids:size() end)
        if okSize and sz and sz > 0 then
            for i = 0, sz - 1 do
                local child = kids:get(i)
                if child then
                    local r = fn(child, panel)
                    if r ~= nil then return r end
                    local sub = BSA_walk(child, fn)
                    if sub ~= nil then return sub end
                end
            end
        end
    end

    return nil
end

local function BSA_isScrollingListBox(w)
    if not w then return false end
    if w.Type == "ISScrollingListBox" then return true end
    if instanceof then
        local ok, v = pcall(function() return instanceof(w, "ISScrollingListBox") end)
        if ok and v then return true end
    end
    return (w.items ~= nil) and (w.doDrawItem or w.drawItem or w.addItem)
end

local function BSA_itemsToArray(items)
    if not items then return {} end
    if type(items) == "table" then return items end
    if items.size and items.get then
        local t = {}
        local ok, sz = pcall(function() return items:size() end)
        if ok and sz and sz > 0 then
            for i = 0, sz - 1 do t[#t+1] = items:get(i) end
        end
        return t
    end
    return {}
end

local function BSA_listItemText(li)
    if li == nil then return "" end
    if type(li) == "string" then return li end
    if type(li) == "table" then
        if li.text then return tostring(li.text) end
        if li.name then return tostring(li.name) end
        if li.item then
            if type(li.item) == "table" then
                if li.item.text then return tostring(li.item.text) end
                if li.item.name then return tostring(li.item.name) end
            else
                return tostring(li.item)
            end
        end
    end
    return tostring(li)
end

local function BSA_extractOwner(line)
    line = tostring(line or "")

    -- Capture "Owner:" and common translations up to end-of-line.
    -- Use escaped \r and \n (do NOT embed raw CR/LF characters inside quotes).
    local patterns = {
        "[Oo]wner%s*:%s*([^\r\n]+)",
        "[Pp]ropriet[aá]rio%s*:%s*([^\r\n]+)",
        "[Pp]roprietario%s*:%s*([^\r\n]+)",
        "[Dd]ono%s*:%s*([^\r\n]+)",
    }

    local owner = nil
    for _, pat in ipairs(patterns) do
        owner = line:match(pat)
        if owner then break end
    end
    if not owner then return "" end

    owner = BSA_trim(owner)

    -- Strip common trailing fields after separators (keeps just the username).
    owner = owner:gsub("%s*[|].*$", "")
    owner = owner:gsub("%s*%-%s*.*$", "")

    return BSA_trim(owner)
end


local function BSA_objectHasMember(obj, member)
    local objType = type(obj)
    if objType ~= "table" and objType ~= "userdata" then return false end

    local ok, value = pcall(function() return obj[member] end)
    return ok and value ~= nil
end

local function BSA_safehouseObjectLooksValid(obj)
    if not obj then return false end

    -- Prefer the exact vanilla Java type when available. Keep the method
    -- signature fallback for custom safehouse lists and older B42 variants.
    if type(obj) == "userdata" and instanceof then
        local ok, isSafehouse = pcall(function() return instanceof(obj, "SafeHouse") end)
        if ok and isSafehouse then return true end
    end

    -- Safehouses must expose both ownership and world geometry. Requiring both
    -- avoids mistaking unrelated mod UI entries (including functions) for rows.
    local hasOwner = BSA_objectHasMember(obj, "getOwner")
        or BSA_objectHasMember(obj, "getOwnerName")
        or BSA_objectHasMember(obj, "getOwnerUsername")
    if not hasOwner then return false end

    local hasOrigin = BSA_objectHasMember(obj, "getX") and BSA_objectHasMember(obj, "getY")
    local hasSize = (BSA_objectHasMember(obj, "getW") and BSA_objectHasMember(obj, "getH"))
        or (BSA_objectHasMember(obj, "getX2") and BSA_objectHasMember(obj, "getY2"))

    return hasOrigin and hasSize
end

local function BSA_listLooksLikeSafehouses(list, allowTextOnly)
    if not list then return false end
    local arr = BSA_itemsToArray(list.items)

    for i = 1, math.min(#arr, 8) do
        local li = arr[i]

        -- 1) Text-based detection (works when the row string includes Owner/Proprietário).
        if allowTextOnly then
            local t = BSA_listItemText(li)
            if t and t ~= "" then
                local tl = t:lower()
                if t:find("Owner:", 1, true) or tl:find("propriet") or tl:find("dono") then
                    return true
                end
            end
        end

        -- 2) Object-based detection (works when drawItem composes the row dynamically).
        local itemObj = (type(li) == "table" and li.item) or li
        if itemObj and BSA_safehouseObjectLooksValid(itemObj) then
            return true
        end
    end

    return false
end

local function BSA_getTitleLower(ui)
    if not ui then return "" end
    local t = ""
    if ui.title then t = tostring(ui.title) end
    if t == "" and ui.getTitle then
        local ok, v = pcall(function() return ui:getTitle() end)
        if ok and v then t = tostring(v) end
    end
    return BSA_lower(t)
end

local function BSA_buttonTitleLower(btn)
    if not btn then return "" end
    local t = ""
    if btn.title then t = tostring(btn.title) end
    if t == "" and btn.getTitle then
        local ok, v = pcall(function() return btn:getTitle() end)
        if ok and v then t = tostring(v) end
    end
    if t == "" and btn.name then t = tostring(btn.name) end
    if t == "" and btn.text then t = tostring(btn.text) end
    return BSA_lower(t)
end

local function BSA_windowHasTeleportButton(ui)
    if not ui then return false end
    local hit = BSA_walk(ui, function(child)
        if not child then return nil end
        -- Avoid hard dependency on instanceof being present.
        local isButton = (child.Type == "ISButton")
        if (not isButton) and instanceof then
            local ok, v = pcall(function() return instanceof(child, "ISButton") end)
            isButton = ok and v or false
        end
        if isButton then
            local tt = BSA_buttonTitleLower(child)
            if tt:find("teleport", 1, true) or tt:find("teleportar", 1, true) then
                return true
            end
        end
        return nil
    end)
    return hit == true
end

local function BSA_isProbablySafehousesWindow(ui)
    local t = BSA_getTitleLower(ui)
    if t ~= "" then
        -- English + common PT strings (title seen in your screenshot).
        if t:find("safehouse", 1, true) then return true end
        if t:find("safehouses", 1, true) then return true end
        if t:find("base", 1, true) then return true end
        if t:find("bases", 1, true) then return true end
        if t:find("lista de bases", 1, true) then return true end
    end

    -- Fallback when title isn't exposed: admin list has a Teleport button.
    if BSA_windowHasTeleportButton(ui) then return true end

    return false
end

local function BSA_findLargestScrollingListBox(ui)
    local best = nil
    local bestScore = -1
    BSA_walk(ui, function(child)
        if BSA_isScrollingListBox(child) then
            local w = (child.getWidth and child:getWidth()) or child.width or 0
            local h = (child.getHeight and child:getHeight()) or child.height or 0
            local score = (w or 0) * (h or 0)
            if score > bestScore then
                bestScore = score
                best = child
            end
        end
        return nil
    end)
    return best
end

local function BSA_findSafehouseListBox(ui)
    if not ui then return nil end

    -- 1) Preferred: find a list that already contains safehouse-like rows.
    local found = BSA_walk(ui, function(child)
        if BSA_isScrollingListBox(child) and BSA_listLooksLikeSafehouses(child, true) then
            return child
        end
        return nil
    end)
    if found then return found end

    -- 2) Fallback: if this window title looks like the safehouse list, pick the largest listbox.
    if BSA_isProbablySafehousesWindow(ui) then
        return BSA_findLargestScrollingListBox(ui)
    end

    return nil
end

local function BSA_ownerFromItemOrText(itemObj, txt)
    -- 1) Prefer object methods (more reliable than parsing row text in some UIs).
    if type(itemObj) == "table" or type(itemObj) == "userdata" then
        if BSA_objectHasMember(itemObj, "getOwner") then
            local ok, v = pcall(function() return itemObj:getOwner() end)
            if ok and v then
                local s = BSA_trim(v)
                if s ~= "" then return s end
            end
        end
        if BSA_objectHasMember(itemObj, "getOwnerName") then
            local ok, v = pcall(function() return itemObj:getOwnerName() end)
            if ok and v then
                local s = BSA_trim(v)
                if s ~= "" then return s end
            end
        end
        if BSA_objectHasMember(itemObj, "getOwnerUsername") then
            local ok, v = pcall(function() return itemObj:getOwnerUsername() end)
            if ok and v then
                local s = BSA_trim(v)
                if s ~= "" then return s end
            end
        end
    end

    -- 2) Fallback: parse from the rendered line string.
    return BSA_extractOwner(txt)
end

local function BSA_captureBaseline(ui, list)
    if not ui or not list then return end
    if ui._BS_ownerSearchIsFiltering then return end

    local entry = ui._BS_ownerSearchEntry
    if entry and entry.getText then
        local t = BSA_trim(entry:getText())
        if t ~= "" then return end -- don't overwrite baseline while filtering
    end

    local baseline = {}
    local arr = BSA_itemsToArray(list.items)
    for _, li in ipairs(arr) do
        local txt = BSA_listItemText(li)
        local itemObj = (type(li) == "table" and li.item) or li
        local owner = BSA_ownerFromItemOrText(itemObj, txt)
        baseline[#baseline+1] = { text = txt, item = itemObj, owner = BSA_lower(owner) }
    end

    ui._BS_ownerSearchAllItems = baseline
    ui._BS_ownerSearchBaselineCount = #baseline
end

local function BSA_captureBaselineForced(ui, list)
    if not ui or not list then return end
    if ui._BS_ownerSearchIsFiltering then return end

    local baseline = {}
    local arr = BSA_itemsToArray(list.items)
    for _, li in ipairs(arr) do
        local txt = BSA_listItemText(li)
        local itemObj = (type(li) == "table" and li.item) or li
        local owner = BSA_ownerFromItemOrText(itemObj, txt)
        baseline[#baseline+1] = { text = txt, item = itemObj, owner = BSA_lower(owner) }
    end

    ui._BS_ownerSearchAllItems = baseline
    ui._BS_ownerSearchBaselineCount = #baseline
end

local function BSA_textMatchesFilter(lineText, filterLower)
    filterLower = BSA_lower(filterLower or "")
    if filterLower == "" then return true end
    local t = BSA_lower(lineText or "")
    local owner = BSA_lower(BSA_extractOwner(lineText))
    if owner ~= "" then
        return owner:find(filterLower, 1, true) ~= nil
    end
    -- Fallback: if we can't parse owner, match anywhere in the line.
    return t:find(filterLower, 1, true) ~= nil
end


local function BSA_clearList(list)
    if not list then return end

    -- ISScrollingListBox implementations differ between builds (items can be Lua table or Java ArrayList).
    if list.clear then pcall(function() list:clear() end) end
    if list.clearItems then pcall(function() list:clearItems() end) end

    local items = list.items
    if items ~= nil then
        if type(items) == "table" then
            list.items = {}
        elseif items.clear then
            pcall(function() items:clear() end)
        end
    end

    if list.selected then list.selected = -1 end
    if list.selectedIndex then list.selectedIndex = -1 end
    if list.selectedItem then list.selectedItem = nil end
    if list.setSelectedRow then pcall(function() list:setSelectedRow(-1) end) end
end

local function BSA_rebuildList(list, items)
    if not list or not items then return end
    BSA_clearList(list)

    for _, it in ipairs(items) do
        local ok = false
        if list.addItem then
            ok = pcall(function() list:addItem(it.text, it.item) end)
        end
        if not ok then
            if type(list.items) ~= "table" then list.items = {} end
            table.insert(list.items, { text = it.text, item = it.item })
        end
    end

    -- Best-effort refresh (varies between builds).
    if list.setScrollHeight and list.itemheight then
        local arr = BSA_itemsToArray(list.items)
        pcall(function() list:setScrollHeight(#arr * list.itemheight) end)
    end
    if list.updateScrollbars then pcall(function() list:updateScrollbars() end) end
    if list.recalcSize then pcall(function() list:recalcSize() end) end
    if list.invalidate then pcall(function() list:invalidate() end) end
end

local function BSA_applyFilter(ui)
    if not ui then return end
    local list = ui._BS_ownerSearchListBox
    if not list then return end
    local entry = ui._BS_ownerSearchEntry
    if not entry or not entry.getText then return end

    local filter = BSA_lower(entry:getText())
    if not ui._BS_ownerSearchAllItems then
        BSA_captureBaseline(ui, list)
    end
    local all = ui._BS_ownerSearchAllItems or {}

    ui._BS_ownerSearchIsFiltering = true

    if filter == "" then
        BSA_rebuildList(list, all)
    else
        local out = {}
        for _, it in ipairs(all) do
            local owner = it.owner or ""
            if owner ~= "" then
                if owner:find(filter, 1, true) then
                    out[#out+1] = it
                end
            else
                -- Fallback: match anywhere in text if we couldn't detect owner.
                local tl = BSA_lower(it.text or "")
                if tl:find(filter, 1, true) then
                    out[#out+1] = it
                end
            end
        end
        BSA_rebuildList(list, out)
    end

    ui._BS_ownerSearchIsFiltering = false
end

local function BSA_installSearch(ui, list)
    if not ui or ui._BS_ownerSearchInstalled or ui._BS_ownerSearchInstalling then return false end
    if not ISLabel or not ISTextEntryBox or not ISButton then return false end
    if not list or not (list.getX or list.x) or not (list.getY or list.y) then return false end

    ui._BS_ownerSearchInstalling = true

    local okAll, err = pcall(function()
        ui._BS_ownerSearchListBox = list

        local container = (list.parent and list.parent.addChild and list.parent) or ui

        local tm = getTextManager and getTextManager() or nil
        local font = UIFont.Small
        local fontH = 14
        if tm and tm.getFontHeight then
            local ok, h = pcall(function() return tm:getFontHeight(font) end)
            if ok and type(h) == "number" and h > 0 then fontH = h end
        end

        local h = math.max(18, fontH + 6)
        local margin = 6

        local lx = (list.getX and list:getX()) or list.x or 20
        local ly = (list.getY and list:getY()) or list.y or 50
        local lw = (list.getWidth and list:getWidth()) or list.width or 400

        -- Place the search row exactly where the list starts, then push the list down.
        ui._BS_ownerSearchOrigY = ly
        ui._BS_ownerSearchOrigH = (list.getHeight and list:getHeight()) or list.height or 200

        local labelText = "Search owner:"
        local t = getTextOrNull and getTextOrNull("IGUI_BetterSafehouse_SearchOwner") or nil
        if t and t ~= "" then labelText = t end

        local labelW = 110
        if tm and tm.MeasureStringX then
            local ok, w = pcall(function() return tm:MeasureStringX(font, labelText) end)
            if ok and type(w) == "number" and w > 0 then labelW = math.floor(w + 6) end
        end

        local label = ISLabel:new(lx, ly + 2, h, labelText, 1, 1, 1, 1, UIFont.Small, true)
        label:initialise()
        if label.instantiate then pcall(function() label:instantiate() end) end
        container:addChild(label)
        ui._BS_ownerSearchLabel = label

        local ex = lx + labelW + margin
        local ew = lw - (labelW + margin)
        if ew < 120 then ew = 120 end

        -- Clear button (i18n; default is always English)
        local clearText = "Clear"
        local ct = getTextOrNull and getTextOrNull("IGUI_BetterSafehouse_Clear") or nil
        if ct and ct ~= "" then clearText = ct end

        local clearW = 60
        if tm and tm.MeasureStringX then
            local ok, w = pcall(function() return tm:MeasureStringX(font, clearText) end)
            if ok and type(w) == "number" and w > 0 then clearW = math.floor(w + 16) end
        end
        if clearW < 50 then clearW = 50 end
        if clearW > 120 then clearW = 120 end

        local entryW = ew - (clearW + margin)
        if entryW < 60 then
            entryW = math.max(60, ew - (50 + margin))
            clearW = ew - entryW - margin
        end

        local entry = ISTextEntryBox:new("", ex, ly, entryW, h)
        entry:initialise()
        if entry.instantiate then pcall(function() entry:instantiate() end) end
        entry.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
        entry.borderColor = { r = 1, g = 1, b = 1, a = 0.2 }
        container:addChild(entry)
        ui._BS_ownerSearchEntry = entry

        -- Clear button: resets filter and restores the full list.
        local bx = ex + entryW + margin
        local btn = ISButton:new(bx, ly, clearW, h, clearText, ui, function()
            local e = ui and ui._BS_ownerSearchEntry or nil
            if e then
                if e.setText then
                    pcall(function() e:setText("") end)
                else
                    e.text = ""
                end
                if e.setCursorPos then pcall(function() e:setCursorPos(0) end) end
            end

            BSA_applyFilter(ui)
        end)
        btn:initialise()
        if btn.instantiate then pcall(function() btn:instantiate() end) end
        container:addChild(btn)
        ui._BS_ownerSearchClearBtn = btn

        -- Ensure the entry is drawn on top, even if the list isn't moved (prevents "invisible behind list").
        if entry.bringToTop then pcall(function() entry:bringToTop() end) end

        -- Push list down and shrink it (only once, from the original Y/Height).
        local dy = h + margin
        local newY = ly + dy
        local newH = ui._BS_ownerSearchOrigH - dy
        if newH < 80 then newH = 80 end
        if list.setY then pcall(function() list:setY(newY) end) else list.y = newY end
        if list.setHeight then pcall(function() list:setHeight(newH) end) else list.height = newH end

        entry.onTextChange = function()
            BSA_applyFilter(ui)
        end

        -- baseline + apply once
        BSA_captureBaseline(ui, list)
        BSA_applyFilter(ui)
    end)

    ui._BS_ownerSearchInstalling = nil
    if not okAll then
        -- Allow retries if the UI types differ (avoid "installed=true but nothing created").
        ui._BS_ownerSearchInstalled = nil
        return false
    end

    ui._BS_ownerSearchInstalled = true
    return true
end

-- Tick-driven injector: finds the Safehouses List window instance and injects the search box.
local _BSA_lastTickMs = 0
local function BSA_nowMs()
    if getTimestampMs then
        local ok, v = pcall(getTimestampMs)
        if ok and type(v) == "number" then return v end
    end
    return os.time() * 1000
end

local function BSA_getOpenUIList()
    if UIManager and UIManager.getUI then
        local ok, l = pcall(UIManager.getUI)
        if ok and l then return l end
    end
    if getUIManager then
        local ok, mgr = pcall(getUIManager)
        if ok and mgr and mgr.getUI then
            local ok2, l = pcall(function() return mgr:getUI() end)
            if ok2 and l then return l end
        end
    end
    return nil
end

local function BSA_iterUIList(uiList, fn)
    if not uiList or not fn then return end

    if type(uiList) == "table" then
        for _, ui in ipairs(uiList) do
            if ui then fn(ui) end
        end
        return
    end

    if uiList.size and uiList.get then
        local ok, sz = pcall(function() return uiList:size() end)
        if ok and sz and sz > 0 then
            for i = 0, sz - 1 do
                local ui = uiList:get(i)
                if ui then fn(ui) end
            end
        end
    end
end


-- Track candidate UIs without relying on UIManager.getUI (some B42 builds don't expose all windows there).
local _BSA_trackedUIs = {}

local function BSA_trackUI(ui)
    if not ui then return end
    _BSA_trackedUIs[ui] = true
end

local function BSA_untrackUI(ui)
    if not ui then return end
    _BSA_trackedUIs[ui] = nil
end

local function BSA_tryInstallOnUI(ui)
    if not ui or ui._BS_ownerSearchInstalled then return end
    -- Install only on windows that look like the Admin Safehouses list.
    if not BSA_isProbablySafehousesWindow(ui) then return end
    local list = BSA_findSafehouseListBox(ui)
    if list then
        local ok = BSA_installSearch(ui, list)
        if ok and print then pcall(function() print("[BetterSafehouse] OwnerSearch installed (addToUIManager hook).") end) end
    end
end

local function BSA_patchAddToUIManagerTracker()
    if not ISUIElement or not ISUIElement.addToUIManager then return end
    if ISUIElement._BetterSafehouseOwnerSearchTrackPatched then return end
    ISUIElement._BetterSafehouseOwnerSearchTrackPatched = true

    local oldAdd = ISUIElement.addToUIManager
    ISUIElement.addToUIManager = function(self, ...)
        local ret = oldAdd(self, ...)
        pcall(function()
            -- Track only likely candidates (cheap title/button heuristic).
            if BSA_isProbablySafehousesWindow(self) then
                BSA_trackUI(self)
                BSA_tryInstallOnUI(self)
            end
        end)
        return ret
    end

    if ISUIElement.removeFromUIManager then
        local oldRemove = ISUIElement.removeFromUIManager
        ISUIElement.removeFromUIManager = function(self, ...)
            pcall(function() BSA_untrackUI(self) end)
            return oldRemove(self, ...)
        end
    end
end

Events.OnGameStart.Add(BSA_patchAddToUIManagerTracker)

local function BSA_tick()
    -- Note: we don't gate by access-level; the window itself is admin-only.
    local now = BSA_nowMs()
    if now - _BSA_lastTickMs < 250 then return end
    _BSA_lastTickMs = now

    -- 1) Tracked candidates (most reliable).
    for ui, _ in pairs(_BSA_trackedUIs) do
        if ui then
            -- Install when first seen.
            if not ui._BS_ownerSearchInstalled then
                local list = BSA_findSafehouseListBox(ui)
                if list then
                    BSA_installSearch(ui, list)
                end
            else
                -- Keep baseline fresh when no filter is active / enforce filter if repopulated.
                local entry = ui._BS_ownerSearchEntry
                local list = ui._BS_ownerSearchListBox
                if entry and entry.getText and list then
                    local filter = BSA_trim(entry:getText())
                    if filter == "" then
                        local arr = BSA_itemsToArray(list.items)
                        if ui._BS_ownerSearchBaselineCount ~= #arr then
                            BSA_captureBaseline(ui, list)
                            BSA_applyFilter(ui)
                        end
                    else
                        if not ui._BS_ownerSearchAllItems then
                            BSA_captureBaselineForced(ui, list)
                        end
                        local filterLower = BSA_lower(filter)
                        local arr = BSA_itemsToArray(list.items)
                        local shouldReapply = false
                        for _, li in ipairs(arr) do
                            local txt = BSA_listItemText(li)
                            local itemObj = (type(li) == "table" and li.item) or li
                            local owner = BSA_lower(BSA_ownerFromItemOrText(itemObj, txt))
                            if owner == "" then owner = BSA_lower(txt) end
                            if owner ~= "" and owner:find(filterLower, 1, true) == nil then
                                shouldReapply = true
                                break
                            end
                        end
                        if shouldReapply then
                            BSA_applyFilter(ui)
                        end
                    end
                end
            end
        else
            _BSA_trackedUIs[ui] = nil
        end
    end

    -- 2) Secondary scan via UIManager list (kept for compatibility).
    local uiList = BSA_getOpenUIList()
    if not uiList then return end

    BSA_iterUIList(uiList, function(ui)
        if not ui or not BSA_isProbablySafehousesWindow(ui) then return end
        if not ui._BS_ownerSearchInstalled then
            local list = BSA_findSafehouseListBox(ui)
            if list then
                BSA_installSearch(ui, list)
            end
        end
    end)
end

-- =========================================================
-- Extra injector (B42 patch-proof):
-- Some B42 versions do not expose UIManager.getUI() in the same way, so our tick-scanner
-- may never see the Safehouses window. To make the search box always appear, we also hook
-- ISScrollingListBox's render cycle and install when we detect safehouse-like rows.
-- =========================================================

local function BSA_getRootUI(elem)
    local cur = elem
    local guard = 0
    while cur and cur.parent and guard < 25 do
        cur = cur.parent
        guard = guard + 1
    end
    return cur
end

local function BSA_listHasSafehouseRows(list)
    if not list then return false end
    -- Global hooks accept object-backed safehouse rows only. Other mod lists
    -- may legitimately contain text such as "Owner:".
    return BSA_listLooksLikeSafehouses(list, false)
end

local function BSA_tryInstallFromList(list)
    if not list or not BSA_isScrollingListBox(list) then return end
    if not BSA_listHasSafehouseRows(list) then return end

    local root = BSA_getRootUI(list) or list.parent
    if not root then return end

    -- If already installed on this root, do nothing.
    if root._BS_ownerSearchInstalled or root._BS_ownerSearchInstalling then return end

    -- Attempt install; only mark tried if it succeeded.
    local ok = BSA_installSearch(root, list)
    if ok then
        -- Lightweight debug (shows once) - helps confirm it installed.
        if print then pcall(function() print("[BetterSafehouse] OwnerSearch installed via list-hook.") end) end
    end
end

local function BSA_patchScrollingListBoxInjector()
    if not ISScrollingListBox or ISScrollingListBox._BetterSafehouseOwnerSearchPatched then return end
    ISScrollingListBox._BetterSafehouseOwnerSearchPatched = true

    local oldPrerender = ISScrollingListBox.prerender
    local oldRender = ISScrollingListBox.render

    if oldPrerender then
        ISScrollingListBox.prerender = function(self, ...)
            local ret = oldPrerender(self, ...)
            pcall(function() BSA_tryInstallFromList(self) end)
            return ret
        end
    elseif oldRender then
        ISScrollingListBox.render = function(self, ...)
            local ret = oldRender(self, ...)
            pcall(function() BSA_tryInstallFromList(self) end)
            return ret
        end
    else
        -- Fallback: hook addItem (covers most list population flows)
        local oldAddItem = ISScrollingListBox.addItem
        if oldAddItem then
            ISScrollingListBox.addItem = function(self, text, item, ...)
                local ret = oldAddItem(self, text, item, ...)
                pcall(function() BSA_tryInstallFromList(self) end)
                return ret
            end
        end
    end
end

Events.OnGameStart.Add(BSA_patchScrollingListBoxInjector)

Events.OnTick.Add(BSA_tick)


-- Helpers de sandbox
local function BS_getAreaLimit()
    if not BetterSafehouse.getSandboxInt then return 0 end
    return BetterSafehouse.getSandboxInt("VanillaSafehouseAreaLimit", 0) or 0
end

local function BS_getAreaMinimum()
    if not BetterSafehouse.getSandboxInt then return 0 end
    return BetterSafehouse.getSandboxInt("VanillaSafehouseAreaMinimum", 0) or 0
end

local function BS_isVanillaEnabled()
    if not BetterSafehouse.getSandboxBool then return true end
    return BetterSafehouse.getSandboxBool("VanillaSafehouseEnabled", true)
end


-- def:getW()/getH() only covers the building's own footprint, not the couple
-- of tiles around the perimeter (porch/immediate yard) that native's real
-- safehouse claim also grabs. Confirmed against a live test: raw building def
-- was 11x15, the vanilla claim on the same house came out 15x19 — exactly
-- +2 tiles on every edge (+4 to each dimension). This also matches (and
-- replaces) the old "*1.65 area" fudge factor below, which was an
-- approximation of this same, additive, per-edge padding.
local BS_BUILDING_CLAIM_PADDING = 2

local function BS_getBuildingAreaFromSquare(square)
    if not square then return nil end
    local building = square:getBuilding()
    if not building then return nil end
    local def = building:getDef()
    if not def then return nil end
    local w = def:getW()
    local h = def:getH()
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return nil end
    local x = def.getX and def:getX() or nil
    local y = def.getY and def:getY() or nil
    if type(x) ~= "number" or type(y) ~= "number" then return nil end

    x = x - BS_BUILDING_CLAIM_PADDING
    y = y - BS_BUILDING_CLAIM_PADDING
    w = w + BS_BUILDING_CLAIM_PADDING * 2
    h = h + BS_BUILDING_CLAIM_PADDING * 2

    return w * h, w, h, x, y
end

-- Vanilla's own native claim blocks non-residential buildings unless the
-- server's own "SafehouseAllowNonResidential" option allows it. Our bypass
-- doesn't go through the native check at all, so we replicate it here (same
-- option, same API, matching the reference mod's own approach).
local function BS_isResidentialAllowed(square)
    if not square then return true end
    local ok, building = pcall(function() return square:getBuilding() end)
    if not ok or not building then return true end
    local okDef, def = pcall(function() return building:getDef() end)
    if not okDef or not def then return true end
    local okRes, isRes = pcall(function() return def:isResidential() end)
    if not okRes then return true end
    if isRes then return true end
    local okAllow, allowNonRes = pcall(function() return getServerOptions():getBoolean("SafehouseAllowNonResidential") end)
    if not okAllow then return true end
    return allowNonRes == true
end

-- Vanilla also refuses to let you claim an occupied building (zombies inside
-- count as "occupied"). Same reasoning as above: our bypass skips the native
-- check, so replicate it by scanning the cell's zombie list for anything
-- alive inside the claim rectangle.
local function BS_hasLivingZombieInArea(x1, y1, x2, y2, z)
    local okCell, cell = pcall(function() return getCell() end)
    if not okCell or not cell then return false end
    local okList, zombieList = pcall(function() return cell:getZombieList() end)
    if not okList or not zombieList then return false end
    local okSize, size = pcall(function() return zombieList:size() end)
    if not okSize then return false end
    for i = 0, size - 1 do
        local okZ, zed = pcall(function() return zombieList:get(i) end)
        if okZ and zed then
            local okAlive, dead = pcall(function() return zed:isDead() end)
            if okAlive and not dead then
                local okPos, zx, zy, zz = pcall(function()
                    return zed:getX(), zed:getY(), zed:getZ()
                end)
                if okPos and zz == z and zx >= x1 and zx <= x2 and zy >= y1 and zy <= y2 then
                    return true
                end
            end
        end
    end
    return false
end

-- =================================================================
-- COOLDOWN: Verificação client-side (tooltip apenas)
-- Cache em memória local — NÃO usa ModData nem transmitModData.
-- O timestamp é recebido via sendServerCommand "CooldownSync" do servidor.
-- =================================================================

-- Cache local: { [username] = timestampMs }
-- Volátil por design: reconexão limpa o cache visual, mas o servidor
-- continua bloqueando via validação própria (fonte de verdade).

local function BS_getCooldownMinutes()
    if SandboxVars and SandboxVars.BetterSafehouse then
        local v = SandboxVars.BetterSafehouse.VanillaSafehouseClaimCooldownMinutes
        if type(v) == "number" then return math.floor(v) end
        local legacy = SandboxVars.BetterSafehouse.VanillaSafehouseClaimCooldown
        if type(legacy) == "number" then return math.floor(legacy * 60) end
    end
    return 0
end

local function BS_checkCooldown(playerObj)
    local cooldownMinutes = BS_getCooldownMinutes()
    if cooldownMinutes <= 0 then return nil end  -- sem cooldown

    if not playerObj then return nil end

    -- Lê do cache local (populado via CooldownSync do servidor)
    local username = playerObj.getUsername and playerObj:getUsername() or ""
    local lastClaim = BS_cooldownCache[username]
    if not lastClaim or type(lastClaim) ~= "number" then return nil end

    local nowMs = getTimeInMillis and getTimeInMillis() or 0
    if nowMs <= 0 then return nil end

    local cooldownMs = cooldownMinutes * 60 * 1000
    local elapsed = nowMs - lastClaim

    if elapsed < cooldownMs then
        local remainMs = cooldownMs - elapsed
        local remainH = math.floor(remainMs / 3600000)
        local remainM = math.floor((remainMs % 3600000) / 60000)
        return string.format("Cooldown ativo: aguarde %dh %dm", remainH, remainM)
    end

    return nil
end

-- Motivo de bloqueio (string) — vazio se pode reivindicar
local function BS_getClaimBlockReason(square, playerObj)
    if not BS_isVanillaEnabled() then
        return "Reivindicação vanilla desativada no servidor."
    end
    
    -- NOVO: Verificar cooldown ANTES de verificar tamanho
    if playerObj then
        local cooldownMsg = BS_checkCooldown(playerObj)
        if cooldownMsg then return cooldownMsg end
    end

    -- Posse/participação: hoje o vanilla nativo bloqueia silenciosamente depois
    -- do clique (sem gerar aviso aqui), inclusive em casos que este mod agora
    -- permite (membro/sub-dono com Convites aprimorados, ou dono adicional com
    -- Ativar posse de multiplas safehouses). Reaproveita a mesma checagem usada
    -- pelo desvio de claim pra já avisar o jogador antes do clique.
    if playerObj and playerObj.getUsername and BetterSafehouse and BetterSafehouse.evaluateClaimEligibility then
        local username = playerObj:getUsername()
        if username and username ~= "" then
            local allowed, _, reasonKey, reasonArg = BetterSafehouse.evaluateClaimEligibility(username)
            if not allowed then
                local args = reasonArg and { tostring(reasonArg) } or {}
                local ok, t = pcall(function()
                    return getText(reasonKey, (table.unpack or unpack)(args))
                end)
                if ok and t and t ~= "" and t ~= reasonKey then
                    return t
                end
                return "Você já possui uma safehouse."
            end
        end
    end

    if not BS_isResidentialAllowed(square) then
        local ok, t = pcall(getText, "IGUI_BetterSafehouse_Claim_NotResidential")
        if ok and t and t ~= "" and t ~= "IGUI_BetterSafehouse_Claim_NotResidential" then
            return t
        end
        return "Apenas edifícios residenciais podem ser reivindicados."
    end

    local areaMinimum = BS_getAreaMinimum()
    local areaLimit = BS_getAreaLimit()

    local area, w, h, bx, by = BS_getBuildingAreaFromSquare(square)

    if area and square and square.getZ then
        if BS_hasLivingZombieInArea(bx, by, bx + w - 1, by + h - 1, square:getZ()) then
            local ok, t = pcall(getText, "IGUI_BetterSafehouse_Claim_ZombiesNearby")
            if ok and t and t ~= "" and t ~= "IGUI_BetterSafehouse_Claim_ZombiesNearby" then
                return t
            end
            return "Existem zumbis dentro do prédio. Elimine-os antes de reivindicar."
        end
    end

    if areaMinimum <= 0 and areaLimit <= 0 then return "" end

    if not area then
        -- Sem building ou sem def: não pode ser safehouse de qualquer forma
        return ""
    end

    -- BS_getBuildingAreaFromSquare já inclui o padding de perímetro (ver
    -- BS_BUILDING_CLAIM_PADDING) — não precisa de nenhum fator extra aqui.
    local estimatedArea = area

    if areaMinimum > 0 and estimatedArea < areaMinimum then
        local ok, t = pcall(getText, "IGUI_BetterSafehouse_ClaimSizeTooSmall",
            tostring(estimatedArea), tostring(areaMinimum))
        if ok and t and t ~= "" and t ~= "IGUI_BetterSafehouse_ClaimSizeTooSmall" then
            return t
        end
        return string.format("Safehouse pequena demais (%d tiles²). Mínimo do servidor: %d tiles².",
            estimatedArea, areaMinimum)
    end

    if estimatedArea > areaLimit then
        local ok, t = pcall(getText, "IGUI_BetterSafehouse_ClaimSizeTooLarge",
            tostring(estimatedArea), tostring(areaLimit))
        if ok and t and t ~= "" and t ~= "IGUI_BetterSafehouse_ClaimSizeTooLarge" then
            return t
        end
        return string.format("Safehouse grande demais (%d tiles²). Limite do servidor: %d tiles².",
            estimatedArea, areaLimit)
    end

    return ""
end

-- =================================================================
-- CONTEXT MENU: bloqueia opção visualmente (cinza + tooltip)
-- Método exato do : busca por option.onSelect
-- =================================================================
local function BS_onFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    if test then return end
    if not context or not context.options then return end
    if not ISWorldObjectContextMenu then return end

    local vanillaEnabled = BS_isVanillaEnabled()

    -- Obter square do clique (igual ao )
    local clickedSquare = nil
    if worldobjects and worldobjects[1] and worldobjects[1].getSquare then
        local ok, sq = pcall(function() return worldobjects[1]:getSquare() end)
        if ok then clickedSquare = sq end
    end

    local playerObj = getSpecificPlayer(playerIndex)

    -- Buscar a opção pelo callback — método do  (100% confiável)
    local vanillaClaimOptionName = nil
    for i = 1, #context.options do
        local option = context.options[i]
        if option and option.onSelect == ISWorldObjectContextMenu.onTakeSafeHouse then
            vanillaClaimOptionName = option.name
            if option.notAvailable then break end  -- já bloqueada por outra razão

            local reason = ""

            if not vanillaEnabled then
                reason = "Reivindicação vanilla desativada no servidor."
            elseif clickedSquare then
                reason = BS_getClaimBlockReason(clickedSquare, playerObj)
            end
            -- Se não tem square: SafeHouse.canBeSafehouse já vai bloquear por outro motivo

            if reason ~= "" then
                local toolTip = ISWorldObjectContextMenu.addToolTip()
                toolTip:setVisible(false)
                toolTip.description = reason
                option.notAvailable = true
                option.toolTip = toolTip
                print(string.format("[BetterSafehouse] ContextMenu: bloqueado — %s", reason))
            end
            break
        end
    end

    -- Opção separada pra reivindicar uma safehouse ADICIONAL. Necessária porque
    -- uma opção com notAvailable=true nunca dispara o clique (confirmado no
    -- ISContextMenu vanilla: "not option.notAvailable" e condição pro onSelect
    -- rodar) — o botão "Reivindicar Base" fica desabilitado pelo próprio jogo
    -- pra quem já é dono ou membro de outra safehouse, então mesmo permitindo
    -- esses casos no nosso desvio, o clique nele nunca chegaria a acontecer.
    -- Só aparece nos dois casos-limite (membro/sub-dono + Convites aprimorados,
    -- ou dono adicional + Ativar posse de multiplas safehouses).
    local clickedSquareIsAlreadySafehouse = false
    if clickedSquare and SafeHouse and SafeHouse.getSafeHouse then
        local okSh, sh = pcall(function() return SafeHouse.getSafeHouse(clickedSquare) end)
        clickedSquareIsAlreadySafehouse = okSh and sh ~= nil
    end

    if vanillaEnabled and clickedSquare and not clickedSquareIsAlreadySafehouse
        and playerObj and playerObj.getUsername
        and BetterSafehouse and BetterSafehouse.evaluateClaimEligibility then
        local username = playerObj:getUsername()
        if username and username ~= "" then
            local allowed, needsBypass = BetterSafehouse.evaluateClaimEligibility(username)
            if allowed and needsBypass then
                local _, bw, bh, bx, by = BS_getBuildingAreaFromSquare(clickedSquare)
                if bw and bh and bx and by then
                    local okLabel, label = pcall(getText, "IGUI_BetterSafehouse_Claim_ExtraSafehouseOption")
                    if not okLabel or not label or label == "" or label == "IGUI_BetterSafehouse_Claim_ExtraSafehouseOption" then
                        label = "Reivindicar Base (Better Safehouse)"
                    end
                    -- Sit right below the vanilla "Reivindicar Base" entry instead
                    -- of trailing at the bottom of the whole menu, so the two
                    -- claim options read as a pair.
                    local option
                    if vanillaClaimOptionName and context.insertOptionAfter then
                        option = context:insertOptionAfter(vanillaClaimOptionName, label, worldobjects, function()
                            sendClientCommand(playerObj, "BetterSafehouse", "ClaimVanillaBypass", {
                                x = bx, y = by, w = bw, h = bh, z = clickedSquare:getZ(),
                            })
                        end)
                    else
                        option = context:addOption(label, worldobjects, function()
                            sendClientCommand(playerObj, "BetterSafehouse", "ClaimVanillaBypass", {
                                x = bx, y = by, w = bw, h = bh, z = clickedSquare:getZ(),
                            })
                        end)
                    end

                    -- Same treatment as the native button above: keep the option
                    -- visible but grayed out with a tooltip when something
                    -- (cooldown, zombies, non-residential, size limits) blocks
                    -- it right now, instead of hiding the option entirely.
                    local otherReason = BS_getClaimBlockReason(clickedSquare, playerObj)
                    if otherReason ~= "" then
                        local toolTip = ISWorldObjectContextMenu.addToolTip()
                        toolTip:setVisible(false)
                        toolTip.description = otherReason
                        option.notAvailable = true
                        option.toolTip = toolTip
                    end
                end
            end
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(BS_onFillWorldObjectContextMenu)
print("[BetterSafehouse] VanillaClaimRestrict: context menu hook registrado")

-- =================================================================
-- PATCH onTakeSafeHouse — segunda camada (dentro do OnGameStart)
-- Bloqueia ANTES de abrir a ISSafehouseUI
-- =================================================================
local function BS_patchOnTakeSafeHouse()
    if not ISWorldObjectContextMenu then return end
    if ISWorldObjectContextMenu._BS_claimPatch then return end
    ISWorldObjectContextMenu._BS_claimPatch = true

    local _vanilla = ISWorldObjectContextMenu.onTakeSafeHouse
    if not _vanilla then return end

    ISWorldObjectContextMenu.onTakeSafeHouse = function(worldobjects, square, player)
        local blocked = false
        local playerObj = type(player) == "number"
            and (getSpecificPlayer and getSpecificPlayer(player))
            or (getPlayer and getPlayer())
        local ownedBefore = BS_findOwnedSafehouse(playerObj)
        local ok, err = pcall(function()
            local reason = BS_getClaimBlockReason(square, playerObj)
            if reason ~= "" then
                blocked = true
                if playerObj and playerObj.Say then
                    pcall(function() playerObj:Say(reason) end)
                end
                print("[BetterSafehouse] onTakeSafeHouse: bloqueado — " .. reason)
            end
        end)
        if not ok then
            print("[BetterSafehouse][onTakeSafeHouse] Erro: " .. tostring(err))
        end

        -- Edge cases (member/sub-dono elsewhere + Convites aprimorados, or an
        -- extra safehouse with Ativar posse de multiplas safehouses): vanilla's
        -- native claim would incorrectly reject these, so create the safehouse
        -- ourselves instead of calling through to it. Everyone else (the normal
        -- "no safehouse at all yet" case) keeps using the vanilla path untouched.
        if not blocked and playerObj and playerObj.getUsername and BetterSafehouse and BetterSafehouse.evaluateClaimEligibility then
            local username = playerObj:getUsername()
            if username and username ~= "" then
                local allowed, needsBypass = BetterSafehouse.evaluateClaimEligibility(username)
                if allowed and needsBypass then
                    blocked = true -- prevent the _vanilla call below; we're handling this ourselves
                    local _, bw, bh, bx, by = BS_getBuildingAreaFromSquare(square)
                    if bw and bh and bx and by then
                        sendClientCommand(playerObj, "BetterSafehouse", "ClaimVanillaBypass", {
                            x = bx, y = by, w = bw, h = bh, z = square:getZ(),
                        })
                    else
                        print("[BetterSafehouse] onTakeSafeHouse: nao foi possivel determinar a area do predio pro desvio de claim")
                    end
                end
            end
        end

        if not blocked and _vanilla then
            local okTake, result = pcall(_vanilla, worldobjects, square, player)
            if not okTake then
                print("[BetterSafehouse][onTakeSafeHouse] Callback anterior falhou: " .. tostring(result))
                result = nil
            end
            if playerObj then
                local ownedAfter = BS_findOwnedSafehouse(playerObj)
                if ownedAfter and not BS_sameSafehouseRect(ownedAfter, ownedBefore) then
                    if not BetterSafehouse.activateViewerForSafehouse(ownedAfter, playerObj) then
                        BS_queueViewerAutoEnable(playerObj, ownedBefore)
                    end
                else
                    BS_queueViewerAutoEnable(playerObj, ownedBefore)
                end
            end
            return result
        end
    end

    print("[BetterSafehouse] onTakeSafeHouse: patch instalado")
end

Events.OnGameStart.Add(BS_patchOnTakeSafeHouse)
