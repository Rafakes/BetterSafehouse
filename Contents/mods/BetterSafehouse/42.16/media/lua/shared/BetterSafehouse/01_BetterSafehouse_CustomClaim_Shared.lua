--[[
    Better Safehouse (Build 42) - Custom Claim system (Shared)

    Multiplayer rules:
      - Server is authoritative for claims, item consumption, and final area.
      - Client only requests; server validates.
--]]

BetterSafehouse = BetterSafehouse or {}
BetterSafehouse.CustomClaim = BetterSafehouse.CustomClaim or {}

-- Net module used by sendClientCommand / sendServerCommand
BetterSafehouse.CustomClaim.NET_MODULE = "BetterSafehouseCC"

-- Sandbox keys (SandboxVars.BetterSafehouse.<key>)
BetterSafehouse.CustomClaim.SB = {
    Enabled = "CustomClaimEnabled",                 -- boolean: item-mode enabled
    FreeAnywhere = "CustomClaimFreeAnywhere",       -- enum/int: 1=Off, 2=15x15, 3=30x30, 4=60x60, 5=Custom (sandbox)
    CustomSize = "CustomSafehouseSize",             -- integer: NxN used when FreeAnywhere=5 or ItemCustom enabled
    ItemCustom = "CustomClaimItemCustomSafehouse",  -- boolean: allow CUSTOM option in item-mode (requires BetterSafehouse.customsafehouse)
    RestrictLocations = "CustomClaimRestrictLocations", -- boolean
}

-- Item-claim sizes (requires the matching item)
BetterSafehouse.CustomClaim.SIZES = {
    -- Only expose the requested item sizes in the context menu.
    -- Note: even sizes won't be perfectly symmetric around the player's tile, but this preserves existing mechanics.
    { id="10", label="10x10", w=10, h=10, item="BetterSafehouse.Claim10x10", xOff=-1, yOff=-5 },
    { id="15", label="15x15", w=15, h=15, item="BetterSafehouse.Claim15x15", xOff=-1, yOff=-7 },
    { id="30", label="30x30", w=30, h=30, item="BetterSafehouse.Claim30x30", xOff=-1, yOff=-15 },
    { id="60", label="60x60", w=60, h=60, item="BetterSafehouse.Claim60x60", xOff=-1, yOff=-30 },
}

BetterSafehouse.CustomClaim.FREE_MODE = {
    Off = 1,
    Preset15 = 2,
    Preset30 = 3,
    Preset60 = 4,
    Custom = 5,
    All = 6,
}

local function clampCustomSize(n)
    n = tonumber(n) or 31
    n = math.floor(n)
    if n < 3 then n = 3 end
    if n > 200 then n = 200 end
    return n
end

local function copySize(s)
    local t = {}
    for k, v in pairs(s) do t[k] = v end
    return t
end

function BetterSafehouse.CustomClaim.getConfig()
    local itemEnabled = BetterSafehouse.getSandboxBool(BetterSafehouse.CustomClaim.SB.Enabled, false)

    local freeMode = BetterSafehouse.getSandboxInt(BetterSafehouse.CustomClaim.SB.FreeAnywhere, BetterSafehouse.CustomClaim.FREE_MODE.Off)
    if not freeMode or freeMode < 1 then freeMode = BetterSafehouse.CustomClaim.FREE_MODE.Off end

    local freeEnabled = freeMode > BetterSafehouse.CustomClaim.FREE_MODE.Off
    local itemCustomEnabled = BetterSafehouse.getSandboxBool(BetterSafehouse.CustomClaim.SB.ItemCustom, false)

    local conflict = itemEnabled and freeEnabled
    local enabled = (itemEnabled or freeEnabled) and (not conflict)

    local mode = "disabled"
    if conflict then
        mode = "conflict"
    elseif itemEnabled then
        mode = "item"
    elseif freeEnabled then
        mode = "free"
    end

    return {
        enabled = enabled,
        mode = mode,
        conflict = conflict,

        itemEnabled = itemEnabled,
        freeEnabled = freeEnabled,
        freeMode = freeMode,
        itemCustomEnabled = itemCustomEnabled,

        restrictLocations = BetterSafehouse.getSandboxBool(BetterSafehouse.CustomClaim.SB.RestrictLocations, false),
        cooldownSeconds = 2,
    }
end

function BetterSafehouse.CustomClaim.getSizeById(id)
    if not id then return nil end
    for _, s in ipairs(BetterSafehouse.CustomClaim.SIZES) do
        if s.id == id then return s end
    end
    return nil
end

---Custom NxN size configured in sandbox. `itemFullType` may be nil for free-mode.
function BetterSafehouse.CustomClaim.getCustomSizeFromSandbox(itemFullType)
    local n = BetterSafehouse.getSandboxInt(BetterSafehouse.CustomClaim.SB.CustomSize, 31)
    n = clampCustomSize(n)
    return {
        id = "CUSTOM",
        label = tostring(n) .. "x" .. tostring(n),
        w = n,
        h = n,
        item = itemFullType,
        xOff = -1,
        yOff = -math.floor(n / 2),
        custom = true,
    }
end

---Resolve item-mode size by id (supports CUSTOM if enabled in sandbox).
function BetterSafehouse.CustomClaim.getItemSizeById(id, cfg)
    if id == "CUSTOM" then
        if cfg and cfg.itemCustomEnabled then
            return BetterSafehouse.CustomClaim.getCustomSizeFromSandbox("BetterSafehouse.customsafehouse")
        end
        return nil
    end
    return BetterSafehouse.CustomClaim.getSizeById(id)
end

---Get the free-mode size from sandbox (server authoritative).
function BetterSafehouse.CustomClaim.getFreeSizeFromSandbox(cfg)
    local freeMode = (cfg and cfg.freeMode) or BetterSafehouse.getSandboxInt(BetterSafehouse.CustomClaim.SB.FreeAnywhere, BetterSafehouse.CustomClaim.FREE_MODE.Off)
    if not freeMode or freeMode <= BetterSafehouse.CustomClaim.FREE_MODE.Off then return nil end

    if freeMode == BetterSafehouse.CustomClaim.FREE_MODE.All then return nil end

    if freeMode == BetterSafehouse.CustomClaim.FREE_MODE.Custom then
        local s = BetterSafehouse.CustomClaim.getCustomSizeFromSandbox(nil)
        s.id = "FREE_CUSTOM"
        s.item = nil
        return s
    end

    local baseId = nil
    if freeMode == BetterSafehouse.CustomClaim.FREE_MODE.Preset15 then baseId = "15" end
    if freeMode == BetterSafehouse.CustomClaim.FREE_MODE.Preset30 then baseId = "30" end
    if freeMode == BetterSafehouse.CustomClaim.FREE_MODE.Preset60 then baseId = "60" end
    if not baseId then return nil end

    local base = BetterSafehouse.CustomClaim.getSizeById(baseId)
    if not base then return nil end
    local s = copySize(base)
    s.id = "FREE_" .. tostring(baseId)
    s.item = nil
    return s
end

-- When FreeAnywhere is set to "All", the player can pick among all allowed sizes (server validates).
function BetterSafehouse.CustomClaim.getFreeSizesForAll(cfg)
    local FM = BetterSafehouse.CustomClaim.FREE_MODE
    local list = {}
    local modes = { FM.Preset15, FM.Preset30, FM.Preset60, FM.Custom }
    for _, m in ipairs(modes) do
        local s = BetterSafehouse.CustomClaim.getFreeSizeFromSandbox({ freeMode = m })
        if s then table.insert(list, s) end
    end
    return list
end

-- Map a client-requested sizeId (FREE_15/FREE_30/FREE_60/FREE_CUSTOM) to a size (used only when FreeAnywhere="All").
function BetterSafehouse.CustomClaim.getFreeSizeByRequestId(sizeId, cfg)
    local FM = BetterSafehouse.CustomClaim.FREE_MODE
    if sizeId == "FREE_15" then return BetterSafehouse.CustomClaim.getFreeSizeFromSandbox({ freeMode = FM.Preset15 }) end
    if sizeId == "FREE_30" then return BetterSafehouse.CustomClaim.getFreeSizeFromSandbox({ freeMode = FM.Preset30 }) end
    if sizeId == "FREE_60" then return BetterSafehouse.CustomClaim.getFreeSizeFromSandbox({ freeMode = FM.Preset60 }) end
    if sizeId == "FREE_CUSTOM" then return BetterSafehouse.CustomClaim.getFreeSizeFromSandbox({ freeMode = FM.Custom }) end
    return nil
end

function BetterSafehouse.CustomClaim.rectsOverlap(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
    return not (ax2 < bx1 or bx2 < ax1 or ay2 < by1 or by2 < ay1)
end
