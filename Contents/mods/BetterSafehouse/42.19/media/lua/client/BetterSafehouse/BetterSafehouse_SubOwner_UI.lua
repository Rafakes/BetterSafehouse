--[[
    Better Safehouse (Build 42 MP) - Sub-owner (Subdono) - CLIENT UI

    Patches ISSafehouseUI so that:
      * the OWNER (or an admin) gets a "Promote / Demote sub-owner" button;
      * a SUB-OWNER gets the "Add player" and "Remove" buttons that vanilla reserves
        for the owner, and nothing else (no release, no change owner, no change title);
      * sub-owners are tagged in the member list.

    Every action a sub-owner performs is sent as a server command, never as a vanilla
    packet: SafehouseChangeMemberPacket and SafehouseInvitePacket are both refused by the
    server anti-cheat when the sender is not the owner (see the shared file for details).
    Owner/admin keep using the untouched vanilla paths.

    UI authority is cosmetic only: the server re-validates everything.
--]]

BetterSafehouse = BetterSafehouse or {}
local SO = BetterSafehouse.SubOwner

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local ROW_STEP = BUTTON_HGT + 5

local REFRESH_INTERVAL_MS = 5000

local function T(key, fallback)
    local t = getTextOrNull and getTextOrNull(key) or nil
    if t and t ~= "" and t ~= key then return t end
    return fallback
end

local function nowMs()
    if getTimestampMs then
        local ok, v = pcall(getTimestampMs)
        if ok and type(v) == "number" then return v end
    end
    return os.time() * 1000
end

local function featureUsable()
    -- MP-only: the whole flow depends on client->server commands.
    return SO.isEnabled() and isClient()
end

-- =========================================================
-- Server queries
-- =========================================================

local function requestSubOwners(sh, force)
    if not featureUsable() or not sh then return end

    local me = getPlayer()
    if not me then return end

    local key = SO.safehouseCacheKey(sh)
    if not key then return end

    SO._lastRequestMs = SO._lastRequestMs or {}
    local last = SO._lastRequestMs[key] or 0
    local now = nowMs()
    if not force and (now - last) < REFRESH_INTERVAL_MS then return end
    SO._lastRequestMs[key] = now

    local b = SO.boundsOf(sh)
    if not b then return end

    sendClientCommand(me, SO.MODULE, "SubOwnersRequest", b)
end

-- =========================================================
-- ISSafehouseUI layout
-- =========================================================

---Vanilla puts "Remove" and "Quit safehouse" on the same row and relies on them never
---being visible together (remove = owner/admin, quit = non-owner member). A sub-owner is
---both a member and a remover, so we lay the bottom rows out ourselves.
local function BS_SO_layout(ui)
    if not ui or not ui.playerList or not ui.removePlayer or not ui.addPlayer then return end

    local me = ui.player
    if not me or not me.getUsername then return end
    local username = me:getUsername()
    local sh = ui.safehouse
    if not sh then return end

    if ui.BS_SO_orig == nil then
        ui.BS_SO_orig = {
            respawn = ui.respawn and ui.respawn:getY() or nil,
            ok      = ui.no and ui.no:getY() or nil,
            release = ui.releaseSafehouse and ui.releaseSafehouse:getY() or nil,
            height  = ui:getHeight(),
        }
    end

    local isOwner  = ui:isOwner()
    -- Admins: accept both the vanilla capability check and the plain access-level check,
    -- so a GM/Admin without CanSetupSafehouses still manages ranks (server allows both too).
    local isPriv   = ui:hasPrivilegedAccessLevel() or SO.isPrivileged(me)
    local isSub    = SO.isSubOwnerCached(sh, username)
    local canManage = isOwner or isPriv or isSub
    local canRank   = (isOwner or isPriv) and featureUsable()

    -- Same predicate vanilla uses in updateButtons().
    local quitVisible = (not isOwner) and SO.isInPlayerList(sh, username)

    ui.BS_SO_isSub     = isSub
    ui.BS_SO_canManage = canManage
    ui.BS_SO_canRank   = canRank

    ui.removePlayer:setVisible(canManage)

    if ui.BS_SO_rankBtn then
        ui.BS_SO_rankBtn:setVisible(canRank)
    end

    local row1Y = ui.removePlayer:getY()
    local nextY = row1Y + ROW_STEP

    if ui.BS_SO_rankBtn and canRank then
        ui.BS_SO_rankBtn:setY(nextY)
        ui.BS_SO_rankBtn:setX(ui.playerList:getRight() - ui.BS_SO_rankBtn:getWidth())
        nextY = nextY + ROW_STEP
    end

    -- Quit only needs its own row when the remove button occupies row 1.
    if quitVisible and canManage then
        ui.BS_SO_quitY = nextY
        nextY = nextY + ROW_STEP
    else
        ui.BS_SO_quitY = nil
    end

    if ui.quitSafehouse and ui.BS_SO_quitY then
        ui.quitSafehouse:setY(ui.BS_SO_quitY)
    end

    -- Push the bottom block (respawn tickbox / OK / Release) below whatever we used.
    local lastBottom = ui.addPlayer:getBottom()
    if canManage then lastBottom = math.max(lastBottom, ui.removePlayer:getBottom()) end
    if ui.BS_SO_rankBtn and canRank then lastBottom = math.max(lastBottom, ui.BS_SO_rankBtn:getBottom()) end
    if quitVisible and ui.quitSafehouse then lastBottom = math.max(lastBottom, ui.quitSafehouse:getBottom()) end

    local orig = ui.BS_SO_orig
    local delta = 0
    if orig.respawn then
        delta = math.max(0, (lastBottom + UI_BORDER_SPACING) - orig.respawn)
    end

    if orig.respawn and ui.respawn then ui.respawn:setY(orig.respawn + delta) end
    if orig.ok and ui.no then ui.no:setY(orig.ok + delta) end
    if orig.release and ui.releaseSafehouse then ui.releaseSafehouse:setY(orig.release + delta) end
    if orig.height then ui:setHeight(orig.height + delta) end

    -- If the taller panel now runs off the bottom of the screen, slide the whole window up so
    -- the OK/Release row stays reachable (the panel is moveWithMouse, but keep it usable by default).
    if delta > 0 and getCore then
        local screenH = getCore():getScreenHeight()
        local bottom = ui:getY() + ui:getHeight()
        if bottom > screenH then
            local newY = math.max(0, ui:getY() - (bottom - screenH))
            ui:setY(newY)
        end
    end
end

---Cheap signature so we only re-run the layout when the player's role (or membership) changes.
local function BS_SO_roleSignature(ui)
    local me = ui.player
    local username = (me and me.getUsername) and me:getUsername() or ""
    local sh = ui.safehouse
    return table.concat({
        tostring(ui:isOwner()),
        tostring(ui:hasPrivilegedAccessLevel() or SO.isPrivileged(me)),
        tostring(SO.isSubOwnerCached(sh, username)),
        tostring(SO.isInPlayerList(sh, username)),
    }, "|")
end

local function BS_SO_relayoutIfNeeded(ui, force)
    local sig = BS_SO_roleSignature(ui)
    if force or ui.BS_SO_sig ~= sig then
        ui.BS_SO_sig = sig
        BS_SO_layout(ui)
    end
end

---Re-evaluate roles on the open safehouse panel (used when the server pushes a new list).
---`changedKey` (optional) is the bounds key of the safehouse whose list changed; when given,
---we skip the refresh unless the open panel is that exact safehouse, so an unrelated group's
---rank change costs nothing on the 149 other clients.
local function BS_SO_refreshOpenPanels(changedKey)
    local ui = ISSafehouseUI and ISSafehouseUI.instance or nil
    if not ui then return end
    if ui.setVisible and ui.isVisible and not ui:isVisible() then return end
    if changedKey and SO.safehouseCacheKey(ui.safehouse) ~= changedKey then return end
    BS_SO_relayoutIfNeeded(ui, true)
    if ui.populateList then pcall(function() ui:populateList() end) end
end

-- =========================================================
-- Promote / demote button
-- =========================================================

---True when `targetName` is a member we are allowed to rank up/down.
local function BS_SO_isRankableTarget(ui, targetName)
    if not targetName or targetName == "" then return false end
    local sh = ui.safehouse
    if SO.isOwner(sh, targetName) then return false end
    return SO.isPlainMemberSlot(sh, targetName)
end

---ISModalDialog always calls onclick(self.target, button, ...) -- target first, even when nil.
local function BS_SO_onConfirmRank(_target, button)
    if not button or button.internal ~= "YES" then return end

    local modal = button.parent
    if not modal or not modal.ui then return end

    local ui = modal.ui
    local target = modal.BS_SO_target
    local demote = modal.BS_SO_demote == true
    if not target or target == "" or not ui.safehouse then return end

    local me = getPlayer()
    if not me then return end

    local b = SO.boundsOf(ui.safehouse)
    if not b then return end
    b.username = target

    local cmd = demote and "SubOwnerDemote" or "SubOwnerPromote"
    print(string.format("[BetterSafehouse][SubOwner][C] sending %s for '%s'", cmd, tostring(target)))
    sendClientCommand(me, SO.MODULE, cmd, b)
end

local function BS_SO_onRankClick(ui)
    local me = getPlayer()
    local target = ui.selectedPlayer
    print("[BetterSafehouse][SubOwner][C] rank button clicked, selected=" .. tostring(target))

    if not BS_SO_isRankableTarget(ui, target) then
        -- No valid selection: say so instead of silently doing nothing.
        if me and me.Say then
            me:Say(getText("IGUI_BetterSafehouse_SubOwner_SelectMember"))
        end
        return
    end

    local demote = SO.isSubOwnerCached(ui.safehouse, target)
    local text = demote
        and getText("IGUI_BetterSafehouse_SubOwner_ConfirmDemote", target)
        or getText("IGUI_BetterSafehouse_SubOwner_ConfirmPromote", target)

    local modal = ISModalDialog:new(0, 0, 380, 150, text, true, nil, BS_SO_onConfirmRank)
    modal:initialise()
    modal:addToUIManager()
    modal.ui = ui
    modal.BS_SO_target = target
    modal.BS_SO_demote = demote
    modal.moveWithMouse = true
end

local function BS_SO_installRankButton(ui)
    if not ui or ui.BS_SO_rankBtn then return end
    if not featureUsable() then return end
    if not ui.playerList or not ui.removePlayer then return end

    -- One fixed width for both captions, so the button does not jump when the label flips.
    local promote = T("IGUI_BetterSafehouse_SubOwner_Promote", "Promover a Subdono")
    local demote  = T("IGUI_BetterSafehouse_SubOwner_Demote", "Rebaixar Subdono")
    local tm = getTextManager()
    local w = math.max(tm:MeasureStringX(UIFont.Small, promote), tm:MeasureStringX(UIFont.Small, demote)) + 20

    local btn = ISButton:new(
        ui.playerList:getRight() - w,
        ui.removePlayer:getY() + ROW_STEP,
        w, BUTTON_HGT,
        promote, ui, ISSafehouseUI.onClick)
    btn.internal = "BS_SUBOWNER"
    btn:initialise()
    btn:instantiate()
    btn.borderColor = ui.buttonBorderColor
    btn:setTooltip(T("IGUI_BetterSafehouse_SubOwner_Tooltip",
        "Subdonos podem adicionar e remover membros comuns."))
    btn.enable = false
    ui:addChild(btn)

    ui.BS_SO_rankBtn = btn
    ui.BS_SO_promoteLabel = promote
    ui.BS_SO_demoteLabel = demote
end

-- =========================================================
-- Patches
-- =========================================================

local function patchSafehouseUI()
    if not ISSafehouseUI then return end
    if ISSafehouseUI._BetterSafehouseSubOwnerPatched then return end
    ISSafehouseUI._BetterSafehouseSubOwnerPatched = true

    -- 1) initialise: add the rank button, lay the bottom rows out, ask the server for the list.
    local origInitialise = ISSafehouseUI.initialise
    ISSafehouseUI.initialise = function(self, ...)
        local r = origInitialise(self, ...)
        local ok, err = pcall(function()
            BS_SO_installRankButton(self)
            requestSubOwners(self.safehouse, true)
            BS_SO_relayoutIfNeeded(self, true)
        end)
        if not ok then
            print("[BetterSafehouse][SubOwner][C] panel setup FAILED: " .. tostring(err))
        end
        return r
    end

    -- 2) updateButtons: vanilla hard-gates add/remove on owner|admin. Re-open them for sub-owners.
    local origUpdateButtons = ISSafehouseUI.updateButtons
    ISSafehouseUI.updateButtons = function(self, ...)
        local r = origUpdateButtons(self, ...)
        if self.BS_SO_isSub and self.addPlayer then
            self.addPlayer.enable = true
        end
        return r
    end

    -- 3) render: vanilla recomputes removePlayer.enable from the selection every frame.
    local origRender = ISSafehouseUI.render
    ISSafehouseUI.render = function(self, ...)
        local r = origRender(self, ...)

        local sh = self.safehouse
        local me = self.player
        if not sh or not me then return r end

        local username = me:getUsername()
        local target = self.selectedPlayer

        -- Sub-owner: may remove plain members only (not the owner, not another sub-owner, not self).
        if self.BS_SO_isSub and self.removePlayer then
            local ok = target ~= nil and target ~= "" and target ~= username
                and not SO.isOwner(sh, target)
                and not SO.isSubOwnerCached(sh, target)
            self.removePlayer.enable = ok
        end

        -- Owner/admin: promote or demote the selected member.
        local btn = self.BS_SO_rankBtn
        if btn then
            -- Self-heal: if the layout pass never completed (flag still nil), a visible
            -- button would otherwise stay disabled forever and clicks would die silently.
            if self.BS_SO_canRank == nil then
                BS_SO_relayoutIfNeeded(self, true)
            end
            if self.BS_SO_canRank then
                -- Always clickable: a click without a valid selection answers with a hint
                -- instead of doing nothing (disabled ISButtons swallow clicks silently).
                btn.enable = true
                if target and target ~= "" and SO.isSubOwnerCached(sh, target) then
                    btn.title = self.BS_SO_demoteLabel
                else
                    btn.title = self.BS_SO_promoteLabel
                end
            end
        end

        return r
    end

    -- 4) prerender: vanilla re-places the quit button every frame; keep our row assignment,
    --    and keep the panel fresh while it stays open.
    local origPrerender = ISSafehouseUI.prerender
    ISSafehouseUI.prerender = function(self, ...)
        local r = origPrerender(self, ...)
        local ok, err = pcall(function()
            BS_SO_relayoutIfNeeded(self, false)
            if self.quitSafehouse and self.BS_SO_quitY then
                self.quitSafehouse:setY(self.BS_SO_quitY)
            end
            -- No polling here: the list is requested when the panel opens and the server
            -- broadcasts SubOwnersChanged on every rank change (polling flooded cmd.txt).
        end)
        if not ok and self.BS_SO_lastErr ~= tostring(err) then
            self.BS_SO_lastErr = tostring(err)   -- log each distinct error once, not per frame
            print("[BetterSafehouse][SubOwner][C] prerender patch FAILED: " .. tostring(err))
        end
        return r
    end

    -- 5) member list: tag the sub-owners.
    local origDrawPlayers = ISSafehouseUI.drawPlayers
    ISSafehouseUI.drawPlayers = function(self, y, item, alt)
        local newY = origDrawPlayers(self, y, item, alt)

        local ui = self.parent
        local name = item and item.item and item.item.name
        if ui and ui.safehouse and name and SO.isSubOwnerCached(ui.safehouse, name) then
            -- Right after the name (vanilla draws it at x=10): always visible, never under
            -- the scrollbar like a right-edge draw would be.
            local tag = T("IGUI_BetterSafehouse_SubOwner_Tag", "[Subdono]")
            local nameW = getTextManager():MeasureStringX(self.font, tostring(name))
            self:drawText(tag, 10 + nameW + 8, y + 2, 0.45, 0.8, 1.0, 0.95, self.font)
        end

        return newY
    end

    -- 6) the rank button rides on the vanilla onClick dispatcher.
    local origOnClick = ISSafehouseUI.onClick
    ISSafehouseUI.onClick = function(self, button, ...)
        if button and button.internal == "BS_SUBOWNER" then
            BS_SO_onRankClick(self)
            return
        end
        return origOnClick(self, button, ...)
    end

    -- 7) removal: a sub-owner cannot use the vanilla packet (the anti-cheat drops it),
    --    so route their confirmation through our server command instead.
    -- Vanilla declares this with ':' and hands it to ISModalDialog with a nil target, so the
    -- engine invokes it as onclick(nil, button): the real button is the SECOND argument.
    local origOnRemove = ISSafehouseUI.onRemovePlayerFromSafehouse
    ISSafehouseUI.onRemovePlayerFromSafehouse = function(modalTarget, button, ...)
        local ui = button and button.parent and button.parent.ui
        local me = getPlayer()

        if button and button.internal == "YES" and ui and ui.safehouse and me
            and featureUsable()
            and SO.actsAsSubOwnerOnly(ui.safehouse, me) then

            local victim = ui.selectedPlayer
            if victim and victim ~= "" then
                local b = SO.boundsOf(ui.safehouse)
                if b then
                    b.username = victim
                    sendClientCommand(me, SO.MODULE, "SubOwnerRemoveMember", b)
                end
            end
            if ui.populateList then ui:populateList() end
            return
        end

        return origOnRemove(modalTarget, button, ...)
    end
end

---A sub-owner's "Add player" cannot use sendSafehouseInvite either (AntiCheatSafeHouseOwner
---requires the sender to be the owner). Route it through the mod's server-validated invite.
local function patchAddPlayerUI()
    if not ISSafehouseAddPlayerUI then return end
    if ISSafehouseAddPlayerUI._BetterSafehouseSubOwnerPatched then return end
    ISSafehouseAddPlayerUI._BetterSafehouseSubOwnerPatched = true

    local origOnClick = ISSafehouseAddPlayerUI.onClick
    ISSafehouseAddPlayerUI.onClick = function(self, button, ...)
        if button and button.internal == "ADDPLAYER" and not self.changeOwnership then
            local me = getPlayer()
            local sh = self.safehouse

            if me and sh and featureUsable() then
                if SO.actsAsSubOwnerOnly(sh, me) then
                    -- Sub-owner: route through the mod's server-validated invite.
                    local target = self.selectedPlayer
                    if target and target ~= "" then
                        local b = SO.boundsOf(sh)
                        if b then
                            b.target = target
                            b.requestId = tostring(nowMs()) .. "_" ..
                                tostring((ZombRand and ZombRand(1000000)) or math.random(1000000))
                            sendClientCommand(me, SO.MODULE, "RequestInvite", b)
                        end
                    end

                    self:setVisible(false)
                    self:removeFromUIManager()
                    ISSafehouseAddPlayerUI.instance = nil
                    return

                elseif not self.isOwner then
                    -- Not owner/admin and not (or no longer) a sub-owner: e.g. demoted while this
                    -- panel was open. The vanilla invite would be silently dropped by the anti-cheat
                    -- yet show "invite sent", so block it with a clear message instead.
                    if me.Say then
                        me:Say(getText("IGUI_BetterSafehouse_Invite_NoPermission"))
                    end
                    self:setVisible(false)
                    self:removeFromUIManager()
                    ISSafehouseAddPlayerUI.instance = nil
                    return
                end
            end
        end

        return origOnClick(self, button, ...)
    end
end

-- =========================================================
-- Server -> client
-- =========================================================

local function onServerCommand(module, command, args)
    if module ~= SO.MODULE then return end
    if not args then return end

    if command == "SubOwnersList" or command == "SubOwnersChanged" then
        local n = 0
        if type(args.subs) == "table" then
            -- Count via pairs: '#' can be unreliable on net-deserialized tables.
            for _ in pairs(args.subs) do n = n + 1 end
        end
        print(string.format("[BetterSafehouse][SubOwner][C] %s received (%d sub-owner(s))", command, n))
        SO.setCachedSubs(args.x, args.y, args.w, args.h, args.z, args.subs)
        local changedKey = SO.boundsKey(args.x, args.y, args.w, args.h, args.z or 0)
        BS_SO_refreshOpenPanels(changedKey)
        return
    end

    if command == "SubOwnerResult" then
        local me = getPlayer()
        if not me or not me.Say then return end
        local msg
        if args.key then
            msg = getText(args.key, (table.unpack or unpack)(args.args or {}))
        else
            msg = tostring(args.msg or "")
        end
        if msg and msg ~= "" then me:Say(msg) end

        -- After a successful rank action, re-pull the roster for the open panel: covers a
        -- lost/failed SubOwnersChanged broadcast so the [Subdono] tag never stays stale.
        if args.ok and ISSafehouseUI and ISSafehouseUI.instance and ISSafehouseUI.instance.safehouse then
            requestSubOwners(ISSafehouseUI.instance.safehouse, true)
        end
        return
    end
end

---Membership changed somewhere (vanilla SafehouseSync): our cached ranks may be stale.
local function onSafehousesChanged()
    local ui = ISSafehouseUI and ISSafehouseUI.instance or nil
    if not ui or not ui.safehouse then return end
    requestSubOwners(ui.safehouse, true)
end

local function boot()
    patchSafehouseUI()
    patchAddPlayerUI()
end

Events.OnGameStart.Add(boot)
Events.OnServerCommand.Add(onServerCommand)
Events.OnSafehousesChanged.Add(onSafehousesChanged)

