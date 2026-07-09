-- ===========================================================================
-- SWAG - Set Wear And Go
-- A simple equipment set manager for World of Warcraft
-- Save your gear, switch sets, bank your stuff.
--
-- Author: goosefraba (Bernhard Keprt)
-- License: GPL-3.0
-- ===========================================================================

local ADDON_NAME = "SWAG"
local ADDON_VERSION = "0.3.0"
local ADDON_FULL = "SWAG - Set Wear And Go"

-- Colors
local ACCENT = "FFAA33"
local C_SUCCESS = "44FF44"
local C_ERROR = "FF4444"
local C_WARN = "FF8800"
local C_GOLD = "FFD100"
local C_MUTED = "AAAAAA"
local PREFIX = "|cFF" .. ACCENT .. "[SWAG]|r "

-- State
local db
local DEBUG = false
local isBankOpen = false

-- Default icon for sets (generic chest armor)
local DEFAULT_ICON = "Interface\\Icons\\INV_Chest_Chain"

-- C_Container compatibility shims (Anniversary Edition uses modern client)
local _PickupContainerItem = C_Container and C_Container.PickupContainerItem or PickupContainerItem
local _GetContainerNumSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
local _GetContainerItemLink = C_Container and C_Container.GetContainerItemLink or GetContainerItemLink
local _GetContainerItemID = C_Container and C_Container.GetContainerItemID or GetContainerItemID
local _GetContainerNumFreeSlots = C_Container and C_Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots
local _UseContainerItem = C_Container and C_Container.UseContainerItem or UseContainerItem

-- Equipment slots to track (1-19, skip 0=ammo)
local EQUIPMENT_SLOTS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }
local SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt",
    [5] = "Chest", [6] = "Waist", [7] = "Legs", [8] = "Feet",
    [9] = "Wrist", [10] = "Hands", [11] = "Ring 1", [12] = "Ring 2",
    [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back",
    [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged", [19] = "Tabard",
}

-- Settings defaults
local SETTINGS_DEFAULTS = {
    debug = false,
    chatMessages = true,
    minimapHidden = false,
}

-- Forward declarations
local RefreshSetList
local f -- main frame
local settingsPanel = {}
local helpPanel = {}

-- Per-character storage. `cdb` points at the currently-VIEWED character's
-- bucket (SWAGDB.chars[key] = { name, realm, class, sets, setOrder }). All set
-- operations act on `cdb` ("follow the view"). `ownCharKey` is this character;
-- `viewedCharKey` is whose sets are currently displayed (own by default).
local cdb
local ownCharKey
local viewedCharKey
local SetViewedChar
local RefreshCharSelector

-- ===========================================================================
-- UTILITY FUNCTIONS
-- ===========================================================================

local function P(msg)
    print(PREFIX .. msg)
end

local function D(msg)
    if DEBUG then
        print("|cFF999999[SWAG-DBG]|r " .. tostring(msg))
    end
end

local function Timestamp()
    return date("%Y-%m-%d %H:%M")
end

-- ===========================================================================
-- DATABASE INITIALIZATION
-- ===========================================================================

-- Stable key for the current character: "Name-Realm". Realm can momentarily be
-- empty very early in login, but InitDB runs on ADDON_LOADED where it is reliable.
local function CurrentCharKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or ""
    realm = realm:gsub("%s+", "")  -- normalise "Some Realm" -> "SomeRealm"
    return name .. "-" .. realm, name, realm
end

-- Reconcile a bucket's setOrder with its sets: drop order entries with no
-- backing set, and append any set that has no order entry (so nothing becomes
-- invisible). Order of existing entries is preserved.
local function CleanOrder(bucket)
    local clean = {}
    local seen = {}
    for _, name in ipairs(bucket.setOrder) do
        if bucket.sets[name] and not seen[name] then
            table.insert(clean, name)
            seen[name] = true
        end
    end
    -- Append orphaned sets (present in sets, missing from order).
    local missing = {}
    for name in pairs(bucket.sets) do
        if not seen[name] then table.insert(missing, name) end
    end
    table.sort(missing)
    for _, name in ipairs(missing) do
        table.insert(clean, name)
    end
    bucket.setOrder = clean
end

local function InitDB()
    if not SWAGDB then SWAGDB = {} end
    db = SWAGDB
    if not db.settings then db.settings = {} end
    if not db.frame then db.frame = {} end
    if not db.minimapAngle then db.minimapAngle = 220 end
    if not db.chars then db.chars = {} end

    for k, v in pairs(SETTINGS_DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end

    DEBUG = db.settings.debug

    -- Identify this character and ensure its bucket exists.
    local key, name, realm = CurrentCharKey()
    ownCharKey = key
    local _, class = UnitClass("player")
    if not db.chars[key] then
        db.chars[key] = { name = name, realm = realm, class = class, sets = {}, setOrder = {} }
    else
        -- Keep metadata fresh (class can't change, but realm display might).
        db.chars[key].name = name
        db.chars[key].realm = realm
        db.chars[key].class = class or db.chars[key].class
    end

    -- One-time migration: older versions stored a single account-wide set table
    -- under SWAGDB.sets / SWAGDB.setOrder. Fold those into THIS character's
    -- bucket so existing users don't lose their sets, then drop the legacy tables.
    local legacySets = rawget(db, "sets")
    local legacyOrder = rawget(db, "setOrder")
    if legacySets or legacyOrder then
        local bucket = db.chars[key]
        if legacySets then
            for setName, set in pairs(legacySets) do
                if bucket.sets[setName] == nil then
                    bucket.sets[setName] = set
                end
            end
        end
        if legacyOrder then
            for _, setName in ipairs(legacyOrder) do
                local already = false
                for _, n in ipairs(bucket.setOrder) do
                    if n == setName then already = true; break end
                end
                if not already and bucket.sets[setName] then
                    table.insert(bucket.setOrder, setName)
                end
            end
        end
        rawset(db, "sets", nil)
        rawset(db, "setOrder", nil)
        D("Migrated legacy account-wide sets into " .. key)
    end

    -- View our own sets by default.
    viewedCharKey = key
    cdb = db.chars[key]

    -- Integrity pass on every stored character bucket.
    for _, bucket in pairs(db.chars) do
        if not bucket.sets then bucket.sets = {} end
        if not bucket.setOrder then bucket.setOrder = {} end
        CleanOrder(bucket)
    end
end

-- ===========================================================================
-- ITEM FINDING
-- ===========================================================================

local function FindItemInBags(itemId, itemLink)
    -- Exact link match first (preserves enchant/gem identity)
    for bag = 0, 4 do
        local numSlots = _GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = _GetContainerItemLink(bag, slot)
            if link and link == itemLink then
                return bag, slot
            end
        end
    end
    -- Fallback: item ID match
    if itemId then
        for bag = 0, 4 do
            local numSlots = _GetContainerNumSlots(bag)
            for slot = 1, numSlots do
                local id = _GetContainerItemID(bag, slot)
                if id and id == itemId then
                    return bag, slot
                end
            end
        end
    end
    return nil, nil
end

local function FindItemInBank(itemId, itemLink)
    local bankBags = { -1, 5, 6, 7, 8, 9, 10, 11 }
    -- Exact link match first
    for _, bag in ipairs(bankBags) do
        local numSlots = _GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = _GetContainerItemLink(bag, slot)
            if link and link == itemLink then
                return bag, slot
            end
        end
    end
    -- Fallback: item ID
    if itemId then
        for _, bag in ipairs(bankBags) do
            local numSlots = _GetContainerNumSlots(bag)
            for slot = 1, numSlots do
                local id = _GetContainerItemID(bag, slot)
                if id and id == itemId then
                    return bag, slot
                end
            end
        end
    end
    return nil, nil
end

local function FindEmptyBagSlot()
    for bag = 0, 4 do
        local free, bagType = _GetContainerNumFreeSlots(bag)
        -- Only use normal bags (bagType 0), skip specialty bags (quiver, ammo, etc.)
        if bagType == 0 and free > 0 then
            local numSlots = _GetContainerNumSlots(bag)
            for slot = 1, numSlots do
                if not _GetContainerItemLink(bag, slot) then
                    return bag, slot
                end
            end
        end
    end
    return nil, nil
end

local function GetTotalFreeBagSlots()
    local total = 0
    for bag = 0, 4 do
        local free, bagType = _GetContainerNumFreeSlots(bag)
        if bagType == 0 then
            total = total + free
        end
    end
    return total
end

local BANK_BAGS = { -1, 5, 6, 7, 8, 9, 10, 11 }

local function GetTotalFreeBankSlots()
    local total = 0
    for _, bag in ipairs(BANK_BAGS) do
        local free = _GetContainerNumFreeSlots(bag)
        if free then total = total + free end
    end
    return total
end

-- Find an item currently equipped in a slot OTHER than excludeSlot.
-- Lets EquipSet recognise items already worn in a sibling slot (rings,
-- trinkets, weapons) instead of falsely reporting them missing.
local function FindItemEquipped(itemLink, excludeSlot)
    if not itemLink then return nil end
    for _, slotId in ipairs(EQUIPMENT_SLOTS) do
        if slotId ~= excludeSlot then
            local link = GetInventoryItemLink("player", slotId)
            if link == itemLink then
                return slotId
            end
        end
    end
    return nil
end

-- ===========================================================================
-- CORE: SAVE SET
-- ===========================================================================

local function SaveSet(name)
    if not name or name:trim() == "" then
        P("Please provide a set name.")
        return
    end
    name = name:trim()

    local items = {}
    local count = 0
    local setIcon = nil

    for _, slotId in ipairs(EQUIPMENT_SLOTS) do
        local link = GetInventoryItemLink("player", slotId)
        if link then
            local id = GetInventoryItemID("player", slotId)
            local icon = GetInventoryItemTexture("player", slotId)
            items[slotId] = { id = id, link = link, icon = icon }
            count = count + 1
            if slotId == 5 then
                setIcon = icon
            elseif slotId == 16 and not setIcon then
                setIcon = icon
            elseif slotId == 1 and not setIcon then
                setIcon = icon
            end
        end
    end

    if count == 0 then
        P("You have no items equipped!")
        return
    end

    local existing = cdb.sets[name]
    local isNew = (existing == nil)

    cdb.sets[name] = {
        name = name,
        icon = (existing and existing.icon) or setIcon or DEFAULT_ICON,
        created = (existing and existing.created) or Timestamp(),
        updated = Timestamp(),
        items = items,
        count = count,
    }

    if isNew then
        table.insert(cdb.setOrder, name)
    end

    P((isNew and "Saved" or "Updated") .. " set: |cFF" .. C_GOLD .. name .. "|r (" .. count .. " items)")
    D("SaveSet: " .. name .. " with " .. count .. " items, icon=" .. (cdb.sets[name].icon or "nil"))
    if RefreshSetList then RefreshSetList() end
end

-- ===========================================================================
-- CORE: DELETE SET
-- ===========================================================================

local function DeleteSet(name)
    if not name or name:trim() == "" then
        P("Please provide a set name.")
        return
    end
    name = name:trim()
    if not cdb.sets[name] then
        P("Set not found: |cFF" .. C_GOLD .. name .. "|r")
        return
    end

    cdb.sets[name] = nil
    for i, n in ipairs(cdb.setOrder) do
        if n == name then
            table.remove(cdb.setOrder, i)
            break
        end
    end

    P("Deleted set: |cFF" .. C_GOLD .. name .. "|r")
    if RefreshSetList then RefreshSetList() end
end

-- ===========================================================================
-- CORE: RENAME SET
-- ===========================================================================

local function RenameSet(oldName, newName)
    if not oldName or oldName:trim() == "" or not newName or newName:trim() == "" then
        P("Usage: |cFF" .. C_GOLD .. "/swag rename <old> | <new>|r")
        return
    end
    oldName = oldName:trim()
    newName = newName:trim()

    if not cdb.sets[oldName] then
        P("Set not found: |cFF" .. C_GOLD .. oldName .. "|r")
        return
    end
    if cdb.sets[newName] then
        P("A set named |cFF" .. C_GOLD .. newName .. "|r already exists.")
        return
    end

    cdb.sets[newName] = cdb.sets[oldName]
    cdb.sets[newName].name = newName
    cdb.sets[oldName] = nil

    for i, n in ipairs(cdb.setOrder) do
        if n == oldName then
            cdb.setOrder[i] = newName
            break
        end
    end

    P("Renamed |cFF" .. C_GOLD .. oldName .. "|r to |cFF" .. C_GOLD .. newName .. "|r")
    if RefreshSetList then RefreshSetList() end
end

-- ===========================================================================
-- CORE: LIST SETS
-- ===========================================================================

local function ListSets()
    if #cdb.setOrder == 0 then
        P("No sets saved. Use |cFF" .. C_GOLD .. "/swag save <name>|r to save your current gear.")
        return
    end
    P("Saved sets:")
    for i, name in ipairs(cdb.setOrder) do
        local set = cdb.sets[name]
        if set then
            P("  " .. i .. ". |cFF" .. C_GOLD .. name .. "|r (" .. (set.count or 0) .. " items)")
        end
    end
end

-- ===========================================================================
-- CORE: EQUIP SET
-- ===========================================================================

local function EquipSet(name)
    if not name or name:trim() == "" then
        P("Please provide a set name.")
        return
    end
    name = name:trim()
    local set = cdb.sets[name]
    if not set then
        P("Set not found: |cFF" .. C_GOLD .. name .. "|r")
        return
    end
    if InCombatLockdown() then
        P("|cFF" .. C_ERROR .. "Cannot switch gear in combat!|r")
        return
    end

    local queue = {}
    local notFound = {}

    for slotId, itemData in pairs(set.items) do
        local currentLink = GetInventoryItemLink("player", slotId)
        if currentLink ~= itemData.link then
            local bag = FindItemInBags(itemData.id, itemData.link)
            if bag then
                table.insert(queue, { slotId = slotId, link = itemData.link, id = itemData.id })
            elseif FindItemEquipped(itemData.link, slotId) then
                -- Item is worn in a sibling slot (e.g. ring on the other finger);
                -- queue it for an inventory-to-inventory swap rather than missing.
                table.insert(queue, { slotId = slotId, link = itemData.link, id = itemData.id })
            else
                table.insert(notFound, SLOT_NAMES[slotId] or ("Slot " .. slotId))
            end
        end
    end

    if #queue == 0 and #notFound == 0 then
        P("Already wearing set: |cFF" .. C_GOLD .. name .. "|r")
        return
    end

    if #notFound > 0 then
        P("|cFF" .. C_WARN .. "Missing:|r " .. table.concat(notFound, ", "))
    end

    if #queue == 0 then return end

    D("Equipping " .. #queue .. " items for set: " .. name)

    ClearCursor()  -- drop anything the player was holding before we start

    -- Direct loop — must stay in hardware event context (no timers)
    local equipped = 0
    for _, swap in ipairs(queue) do
        if InCombatLockdown() then
            P("|cFF" .. C_ERROR .. "Entered combat! Equip aborted.|r")
            break
        end

        -- Re-locate each item at equip time: bag/slot positions and equipped
        -- slots shift as earlier swaps in this loop complete.
        local bag, slot = FindItemInBags(swap.id, swap.link)
        if bag then
            D("Equipping slot " .. swap.slotId .. " from bags: " .. (swap.link or "?"))
            pcall(_PickupContainerItem, bag, slot)
            pcall(PickupInventoryItem, swap.slotId)
            ClearCursor()  -- always clean up
            if GetInventoryItemLink("player", swap.slotId) then
                equipped = equipped + 1
                D("  -> OK")
            else
                D("  -> equip failed")
            end
        else
            local fromSlot = FindItemEquipped(swap.link, swap.slotId)
            if fromSlot then
                D("Swapping slot " .. swap.slotId .. " from worn slot " .. fromSlot .. ": " .. (swap.link or "?"))
                pcall(PickupInventoryItem, fromSlot)
                pcall(PickupInventoryItem, swap.slotId)
                ClearCursor()  -- always clean up
                if GetInventoryItemLink("player", swap.slotId) == swap.link then
                    equipped = equipped + 1
                    D("  -> OK")
                else
                    D("  -> swap failed")
                end
            else
                D("Skip slot " .. swap.slotId .. ": item not found in bags or worn")
            end
        end
    end

    ClearCursor()
    if db.settings.chatMessages then
        P("Equipped set: |cFF" .. C_GOLD .. name .. "|r (" .. equipped .. "/" .. #queue .. " items)")
    end
    if RefreshSetList then RefreshSetList() end
end

-- ===========================================================================
-- CORE: UNDRESS (unequip all to bags)
-- ===========================================================================

local function Undress()
    if InCombatLockdown() then
        P("|cFF" .. C_ERROR .. "Cannot undress in combat!|r")
        return
    end

    ClearCursor()

    local count = 0

    for _, slotId in ipairs(EQUIPMENT_SLOTS) do
        if GetInventoryItemLink("player", slotId) then
            local emptyBag, emptySlot = FindEmptyBagSlot()
            if not emptyBag then
                P("|cFF" .. C_WARN .. "Bags full!|r Removed " .. count .. " items.")
                ClearCursor()
                return
            end
            D("Undress " .. slotId .. " (" .. (SLOT_NAMES[slotId] or "?") .. ") -> bag " .. emptyBag .. " slot " .. emptySlot)
            -- pcall prevents a taint error from killing the function before ClearCursor runs
            pcall(PickupInventoryItem, slotId)
            pcall(_PickupContainerItem, emptyBag, emptySlot)
            ClearCursor()  -- always runs, even if above calls threw errors
            if not GetInventoryItemLink("player", slotId) then
                count = count + 1
                D("  -> OK")
            else
                D("  -> still equipped")
            end
        end
    end

    ClearCursor()

    local remaining = 0
    for _, slotId in ipairs(EQUIPMENT_SLOTS) do
        if GetInventoryItemLink("player", slotId) then
            remaining = remaining + 1
        end
    end

    if count == 0 and remaining == 0 then
        P("Nothing equipped to remove.")
    elseif remaining > 0 then
        P("Removed " .. count .. " items. |cFF" .. C_WARN .. remaining .. " still equipped|r — click again.")
    elseif db.settings.chatMessages then
        P("Removed " .. count .. " items to bags.")
    end
end

-- ===========================================================================
-- CORE: BANK STORE (move set items from bags to bank)
-- ===========================================================================

local function StoreInBank(name)
    if not isBankOpen then
        P("|cFF" .. C_ERROR .. "Bank is not open!|r Visit a banker first.")
        return
    end
    if not name or name:trim() == "" then
        P("Please provide a set name.")
        return
    end
    name = name:trim()
    local set = cdb.sets[name]
    if not set then
        P("Set not found: |cFF" .. C_GOLD .. name .. "|r")
        return
    end

    local stored = 0
    local notFound = 0
    local equipped = 0

    local bankFull = false

    for slotId, itemData in pairs(set.items) do
        local bag, slot = FindItemInBags(itemData.id, itemData.link)
        if bag then
            if GetTotalFreeBankSlots() <= 0 then
                bankFull = true
                break
            end
            _UseContainerItem(bag, slot)
            stored = stored + 1
        else
            local equippedLink = GetInventoryItemLink("player", slotId)
            if equippedLink == itemData.link then
                equipped = equipped + 1
            else
                notFound = notFound + 1
            end
        end
    end

    if bankFull then
        P("|cFF" .. C_WARN .. "Bank is full!|r Stored " .. stored .. " items before running out of space.")
    end

    if db.settings.chatMessages then
        P("Stored " .. stored .. " items in bank for set: |cFF" .. C_GOLD .. name .. "|r")
        if equipped > 0 then
            P("|cFF" .. C_WARN .. equipped .. " items still equipped|r (undress first)")
        end
        if notFound > 0 then
            P("|cFF" .. C_MUTED .. notFound .. " items not found|r")
        end
    end
end

-- ===========================================================================
-- CORE: BANK LOAD (move set items from bank to bags)
-- ===========================================================================

local function LoadFromBank(name)
    if not isBankOpen then
        P("|cFF" .. C_ERROR .. "Bank is not open!|r Visit a banker first.")
        return
    end
    if not name or name:trim() == "" then
        P("Please provide a set name.")
        return
    end
    name = name:trim()
    local set = cdb.sets[name]
    if not set then
        P("Set not found: |cFF" .. C_GOLD .. name .. "|r")
        return
    end

    local loaded = 0
    local notFound = 0
    local bagsFull = false

    for slotId, itemData in pairs(set.items) do
        local bag, slot = FindItemInBank(itemData.id, itemData.link)
        if bag then
            if GetTotalFreeBagSlots() <= 0 then
                bagsFull = true
                break
            end
            _UseContainerItem(bag, slot)
            loaded = loaded + 1
        else
            -- Item might already be in bags or equipped, not an error
            local inBags = FindItemInBags(itemData.id, itemData.link)
            local equippedLink = GetInventoryItemLink("player", slotId)
            if not inBags and equippedLink ~= itemData.link then
                notFound = notFound + 1
            end
        end
    end

    if bagsFull then
        P("|cFF" .. C_WARN .. "Bags are full!|r Loaded " .. loaded .. " items before running out of space.")
    end

    if db.settings.chatMessages then
        P("Loaded " .. loaded .. " items from bank for set: |cFF" .. C_GOLD .. name .. "|r")
        if notFound > 0 then
            P("|cFF" .. C_MUTED .. notFound .. " items not found in bank|r")
        end
    end
end

-- ===========================================================================
-- STATIC POPUP DIALOGS
-- ===========================================================================

StaticPopupDialogs["SWAG_CONFIRM_DELETE"] = {
    text = "Delete equipment set \"%s\"?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data)
        DeleteSet(data)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
}

StaticPopupDialogs["SWAG_CONFIRM_UPDATE"] = {
    text = "Update set \"%s\" with your current gear?\nThis will overwrite the existing items.",
    button1 = "Update",
    button2 = "Cancel",
    OnAccept = function(self, data)
        SaveSet(data)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
}

StaticPopupDialogs["SWAG_RENAME_SET"] = {
    text = "Enter new name for set \"%s\":",
    button1 = "Rename",
    button2 = "Cancel",
    hasEditBox = true,
    editBoxWidth = 220,
    OnAccept = function(self)
        local eb = self.editBox or _G[self:GetName() .. "EditBox"]
        local newName = eb and eb:GetText() or ""
        if newName:trim() ~= "" then
            RenameSet(self.data, newName:trim())
        end
    end,
    OnShow = function(self)
        local eb = self.editBox or _G[self:GetName() .. "EditBox"]
        if eb then
            eb:SetText(self.data or "")
            eb:SetFocus()
            eb:HighlightText()
            eb:SetScript("OnEnterPressed", function() self.button1:Click() end)
            eb:SetScript("OnEscapePressed", function() self:Hide() end)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
}

-- ===========================================================================
-- MINIMAP BUTTON
-- ===========================================================================

local minimapBtn = CreateFrame("Button", "SWAGMinimapButton", Minimap)
minimapBtn:SetSize(33, 33)
minimapBtn:SetFrameStrata("MEDIUM")
minimapBtn:SetFrameLevel(8)
minimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapBtn:SetMovable(true)
minimapBtn:EnableMouse(true)
minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapBtn:RegisterForDrag("LeftButton")

local mmIcon = minimapBtn:CreateTexture(nil, "OVERLAY")
mmIcon:SetSize(20, 20)
mmIcon:SetPoint("CENTER", minimapBtn, "CENTER", 0, 1)
mmIcon:SetTexture("Interface\\Icons\\INV_Chest_Chain")

local mmBorder = minimapBtn:CreateTexture(nil, "BACKGROUND")
mmBorder:SetSize(33, 33)
mmBorder:SetPoint("CENTER", minimapBtn, "CENTER", 0, 1)
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local minimapAngle = 220
local function MinimapBtn_SetAngle(angle)
    local rad = math.rad(angle)
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * 80, math.sin(rad) * 80)
end

minimapBtn:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
        MinimapBtn_SetAngle(minimapAngle)
    end)
end)

minimapBtn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    if db then db.minimapAngle = minimapAngle end
end)

local minimapDropdown = CreateFrame("Frame", "SWAGMinimapDropdown", UIParent, "UIDropDownMenuTemplate")

UIDropDownMenu_Initialize(minimapDropdown, function(self, level)
    if level ~= 1 then return end

    local info = UIDropDownMenu_CreateInfo()

    -- List all sets sorted alphabetically (for the currently-viewed character)
    local names = {}
    if cdb and cdb.sets then
        for name in pairs(cdb.sets) do
            table.insert(names, name)
        end
        table.sort(names)
    end

    if #names == 0 then
        info.text = "|cFF" .. C_MUTED .. "No sets saved|r"
        info.isTitle = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info)
    else
        for _, setName in ipairs(names) do
            info = UIDropDownMenu_CreateInfo()
            info.text = setName
            info.icon = cdb.sets[setName] and cdb.sets[setName].icon or DEFAULT_ICON
            info.notCheckable = true
            info.func = function() EquipSet(setName) end
            UIDropDownMenu_AddButton(info)
        end
    end

    -- Divider
    info = UIDropDownMenu_CreateInfo()
    info.text = ""
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info)

    -- Open SWAG
    info = UIDropDownMenu_CreateInfo()
    info.text = "Open SWAG"
    info.notCheckable = true
    info.func = function() if f:IsShown() then f:Hide() else f:Show() end end
    UIDropDownMenu_AddButton(info)

    -- Settings
    info = UIDropDownMenu_CreateInfo()
    info.text = "Settings"
    info.notCheckable = true
    info.func = function() settingsPanel.OpenBliz() end
    UIDropDownMenu_AddButton(info)
end, "MENU")

minimapBtn:SetScript("OnClick", function(self, button)
    ToggleDropDownMenu(1, nil, minimapDropdown, self, 0, 0)
end)

minimapBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cFF" .. ACCENT .. "SWAG|r")
    GameTooltip:AddLine("Click to open menu", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag to reposition", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end)

minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
minimapBtn:Hide()

local function ToggleMinimapButton()
    if db.settings.minimapHidden then
        db.settings.minimapHidden = false
        minimapBtn:Show()
        P("Minimap button: |cFF" .. C_SUCCESS .. "shown|r")
    else
        db.settings.minimapHidden = true
        minimapBtn:Hide()
        P("Minimap button: |cFF" .. C_ERROR .. "hidden|r")
    end
end

-- ===========================================================================
-- MAIN UI FRAME
-- ===========================================================================

local PANEL_W, PANEL_H = 320, 450
local ROW_HEIGHT = 36
local MAX_VISIBLE_ROWS = 8

f = CreateFrame("Frame", "SWAGFrame", UIParent)
f:SetSize(PANEL_W, PANEL_H)
f:SetPoint("CENTER")
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetFrameStrata("DIALOG")
f:SetClampedToScreen(true)

if BackdropTemplateMixin then
    Mixin(f, BackdropTemplateMixin)
    f:OnBackdropLoaded()
end
if f.SetBackdrop then
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
end

tinsert(UISpecialFrames, "SWAGFrame")

-- Drag to move
f:SetScript("OnDragStart", function(self) self:StartMoving() end)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if db and db.frame then
        db.frame.point = point
        db.frame.relPoint = relPoint
        db.frame.x = x
        db.frame.y = y
    end
end)

-- Title
local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", f, "TOP", 0, -14)
title:SetText("|cFF" .. ACCENT .. "SWAG|r")

local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
subtitle:SetText("|cFF" .. C_MUTED .. "Set Wear And Go|r")

-- Close button
local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

-- Help button
local helpBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
helpBtn:SetSize(22, 22)
helpBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, -4)
helpBtn:SetText("?")
helpBtn:SetScript("OnClick", function() helpPanel.Toggle() end)

-- =======================================================
-- Character selector
-- =======================================================
local charArea = CreateFrame("Frame", nil, f)
charArea:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -50)
charArea:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -50)
charArea:SetHeight(28)

local charLabel = charArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
charLabel:SetPoint("LEFT", charArea, "LEFT", 0, 0)
charLabel:SetText("Char:")

local charDropdown = CreateFrame("Frame", "SWAGCharDropdown", charArea, "UIDropDownMenuTemplate")
charDropdown:SetPoint("LEFT", charLabel, "RIGHT", -8, -2)
UIDropDownMenu_SetWidth(charDropdown, 150)

-- Class colour for a character bucket's display name.
local function CharDisplay(bucket, key)
    local label = (bucket and bucket.name) or key or "?"
    if bucket and bucket.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[bucket.class] then
        local c = RAID_CLASS_COLORS[bucket.class]
        label = string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, label)
    end
    if key == ownCharKey then
        label = label .. " |cFF" .. C_MUTED .. "(you)|r"
    end
    return label
end

-- Sorted list of character keys: own char first, then others alphabetically.
local function SortedCharKeys()
    local keys = {}
    for k in pairs(db.chars) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
        if a == ownCharKey then return true end
        if b == ownCharKey then return false end
        local na = (db.chars[a].name or a):lower()
        local nb = (db.chars[b].name or b):lower()
        return na < nb
    end)
    return keys
end

UIDropDownMenu_Initialize(charDropdown, function(self, level)
    if level ~= 1 then return end
    for _, key in ipairs(SortedCharKeys()) do
        local bucket = db.chars[key]
        local info = UIDropDownMenu_CreateInfo()
        info.text = CharDisplay(bucket, key)
        info.value = key
        info.checked = (key == viewedCharKey)
        info.func = function() SetViewedChar(key) CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end
end)

RefreshCharSelector = function()
    if not db or not db.chars then return end
    UIDropDownMenu_SetText(charDropdown, CharDisplay(db.chars[viewedCharKey], viewedCharKey))
end

SetViewedChar = function(key)
    if not db.chars[key] then return end
    viewedCharKey = key
    cdb = db.chars[key]
    RefreshCharSelector()
    if RefreshSetList then RefreshSetList() end
    D("Viewing sets for " .. key)
end

-- =======================================================
-- Save controls area
-- =======================================================
local saveArea = CreateFrame("Frame", nil, f)
saveArea:SetPoint("TOPLEFT", charArea, "BOTTOMLEFT", 0, -6)
saveArea:SetPoint("TOPRIGHT", charArea, "BOTTOMRIGHT", 0, -6)
saveArea:SetHeight(30)

local nameLabel = saveArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
nameLabel:SetPoint("LEFT", saveArea, "LEFT", 0, 0)
nameLabel:SetText("Name:")

local nameBox = CreateFrame("EditBox", "SWAGNameBox", saveArea, "InputBoxTemplate")
nameBox:SetSize(170, 24)
nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 6, 0)
nameBox:SetAutoFocus(false)
nameBox:SetMaxLetters(40)

local saveBtn = CreateFrame("Button", nil, saveArea, "UIPanelButtonTemplate")
saveBtn:SetSize(60, 24)
saveBtn:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)
saveBtn:SetText("Save")
saveBtn:SetScript("OnClick", function()
    local name = nameBox:GetText()
    SaveSet(name)
    nameBox:SetText("")
    nameBox:ClearFocus()
end)

nameBox:SetScript("OnEnterPressed", function(self)
    SaveSet(self:GetText())
    self:SetText("")
    self:ClearFocus()
end)
nameBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

-- =======================================================
-- Set list (FauxScrollFrame)
-- =======================================================
local listArea = CreateFrame("Frame", nil, f)
listArea:SetPoint("TOPLEFT", saveArea, "BOTTOMLEFT", 0, -8)
listArea:SetPoint("RIGHT", f, "RIGHT", -12, 0)
listArea:SetHeight(ROW_HEIGHT * MAX_VISIBLE_ROWS)

local scrollFrame = CreateFrame("ScrollFrame", "SWAGScrollFrame", listArea, "FauxScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", listArea, "TOPLEFT", 0, 0)
scrollFrame:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT", -22, 0)

-- Create row frames
local rows = {}
-- Drag-and-drop reorder state (handlers assigned after the row loop; declared
-- here so the per-row closures capture the same upvalues).
local draggingName
local BeginRowDrag, EndRowDrag
for i = 1, MAX_VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, listArea)
    row:SetSize(listArea:GetWidth() - 22, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", listArea, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

    if BackdropTemplateMixin then
        Mixin(row, BackdropTemplateMixin)
        row:OnBackdropLoaded()
    end
    if row.SetBackdrop then
        row:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = nil,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
    end

    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    icon:SetTexture(DEFAULT_ICON)
    row.icon = icon

    -- Set name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", icon, "RIGHT", 8, 4)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    -- Item count
    local countText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", icon, "RIGHT", 8, -8)
    countText:SetJustifyH("LEFT")
    row.countText = countText

    -- Equip button
    local equipBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    equipBtn:SetSize(44, 22)
    equipBtn:SetPoint("RIGHT", row, "RIGHT", -58, 0)
    equipBtn:SetText("Wear")
    equipBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    row.equipBtn = equipBtn

    -- Update button
    local updateBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    updateBtn:SetSize(22, 22)
    updateBtn:SetPoint("LEFT", equipBtn, "RIGHT", 2, 0)
    updateBtn:SetText("|cFF44FF44S|r")
    updateBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    updateBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Update set with current gear")
        GameTooltip:Show()
    end)
    updateBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.updateBtn = updateBtn

    -- Delete button
    local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    delBtn:SetSize(22, 22)
    delBtn:SetPoint("LEFT", updateBtn, "RIGHT", 2, 0)
    delBtn:SetText("X")
    delBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    row.delBtn = delBtn

    row.setName = nil
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Drag to reorder
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function(self) if BeginRowDrag then BeginRowDrag(self) end end)
    row:SetScript("OnDragStop", function(self) if EndRowDrag then EndRowDrag(self) end end)

    -- Hover effects
    row:SetScript("OnEnter", function(self)
        if draggingName then return end  -- suppress tooltips mid-drag
        if self.setName and row.SetBackdropColor then
            row:SetBackdropColor(0.2, 0.2, 0.25, 0.8)
        end
        -- Tooltip with set items
        if self.setName and cdb.sets[self.setName] then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local set = cdb.sets[self.setName]
            GameTooltip:AddLine("|cFF" .. ACCENT .. set.name .. "|r")
            GameTooltip:AddLine("Created: " .. (set.created or "unknown"), 0.5, 0.5, 0.5)
            if set.updated and set.updated ~= set.created then
                GameTooltip:AddLine("Updated: " .. set.updated, 0.5, 0.5, 0.5)
            end
            GameTooltip:AddLine(" ")
            for _, slotId in ipairs(EQUIPMENT_SLOTS) do
                if set.items[slotId] then
                    local slotName = SLOT_NAMES[slotId] or ("Slot " .. slotId)
                    GameTooltip:AddDoubleLine(
                        "|cFF" .. C_MUTED .. slotName .. "|r",
                        set.items[slotId].link
                    )
                end
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        if row.SetBackdropColor then
            local idx = self:GetID()
            if idx % 2 == 0 then
                row:SetBackdropColor(0.12, 0.12, 0.15, 0.6)
            else
                row:SetBackdropColor(0.08, 0.08, 0.10, 0.6)
            end
        end
        GameTooltip:Hide()
    end)

    -- Right-click for rename
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" and self.setName then
            local popup = StaticPopup_Show("SWAG_RENAME_SET", self.setName)
            if popup then popup.data = self.setName end
        end
    end)

    row:Hide()
    rows[i] = row
end

-- Empty state text
local emptyText = listArea:CreateFontString(nil, "OVERLAY", "GameFontNormal")
emptyText:SetPoint("CENTER", listArea, "CENTER", 0, 0)
emptyText:SetText("|cFF" .. C_MUTED .. "No sets saved yet.\nEquip your gear, enter a name above,\nand click Save.|r")
emptyText:SetJustifyH("CENTER")

RefreshSetList = function()
    local total = #cdb.setOrder
    FauxScrollFrame_Update(scrollFrame, total, MAX_VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scrollFrame)

    emptyText:SetShown(total == 0)
    if total == 0 then
        if viewedCharKey == ownCharKey then
            emptyText:SetText("|cFF" .. C_MUTED .. "No sets saved yet.\nEquip your gear, enter a name above,\nand click Save.|r")
        else
            local bucket = db.chars[viewedCharKey]
            emptyText:SetText("|cFF" .. C_MUTED .. "No sets saved for\n" .. ((bucket and bucket.name) or "this character") .. ".|r")
        end
    end

    for i = 1, MAX_VISIBLE_ROWS do
        local row = rows[i]
        local dataIdx = offset + i
        if dataIdx <= total then
            local setName = cdb.setOrder[dataIdx]
            local set = cdb.sets[setName]
            if set then
                row:SetID(i)
                row.setName = setName
                row.icon:SetTexture(set.icon or DEFAULT_ICON)
                row.nameText:SetText("|cFF" .. C_GOLD .. set.name .. "|r")
                row.countText:SetText("|cFF" .. C_MUTED .. (set.count or 0) .. " items|r")

                row.equipBtn:SetScript("OnClick", function()
                    EquipSet(setName)
                end)
                row.updateBtn:SetScript("OnClick", function()
                    local popup = StaticPopup_Show("SWAG_CONFIRM_UPDATE", setName)
                    if popup then popup.data = setName end
                end)
                row.delBtn:SetScript("OnClick", function()
                    local popup = StaticPopup_Show("SWAG_CONFIRM_DELETE", setName)
                    if popup then popup.data = setName end
                end)

                if row.SetBackdropColor then
                    if i % 2 == 0 then
                        row:SetBackdropColor(0.12, 0.12, 0.15, 0.6)
                    else
                        row:SetBackdropColor(0.08, 0.08, 0.10, 0.6)
                    end
                end

                row:Show()
            else
                row:Hide()
            end
        else
            row:Hide()
            row.setName = nil
        end
    end
end

scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshSetList)
end)

-- Mouse-wheel scrolling. The FauxScrollFrame only exposes a draggable scrollbar
-- by default; wire the wheel so hovering the list (or any row on top of it)
-- scrolls one entry per notch, clamped to the valid offset range.
local function ScrollByDelta(delta)
    local total = #cdb.setOrder
    local maxOffset = math.max(0, total - MAX_VISIBLE_ROWS)
    if maxOffset == 0 then return end
    local offset = FauxScrollFrame_GetOffset(scrollFrame)
    local newOffset = offset - delta  -- wheel up (delta>0) scrolls toward the top
    if newOffset < 0 then newOffset = 0 end
    if newOffset > maxOffset then newOffset = maxOffset end
    if newOffset ~= offset then
        scrollFrame:SetVerticalScroll(newOffset * ROW_HEIGHT)
    end
end

scrollFrame:EnableMouseWheel(true)
scrollFrame:SetScript("OnMouseWheel", function(_, delta) ScrollByDelta(delta) end)
-- Rows cover the scroll frame, so they need to forward wheel events too.
for i = 1, MAX_VISIBLE_ROWS do
    rows[i]:EnableMouseWheel(true)
    rows[i]:SetScript("OnMouseWheel", function(_, delta) ScrollByDelta(delta) end)
end

-- =======================================================
-- Drag-and-drop reordering
-- =======================================================

-- Ghost row that follows the cursor while dragging.
local dragGhost = CreateFrame("Frame", nil, f)
dragGhost:SetSize(listArea:GetWidth() - 22, ROW_HEIGHT)
dragGhost:SetFrameStrata("TOOLTIP")
dragGhost:Hide()
do
    local g = dragGhost:CreateTexture(nil, "BACKGROUND")
    g:SetAllPoints(dragGhost)
    g:SetTexture("Interface\\Buttons\\WHITE8x8")
    g:SetVertexColor(0.3, 0.25, 0.1, 0.9)
    local gi = dragGhost:CreateTexture(nil, "ARTWORK")
    gi:SetSize(28, 28)
    gi:SetPoint("LEFT", dragGhost, "LEFT", 4, 0)
    dragGhost.icon = gi
    local gt = dragGhost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gt:SetPoint("LEFT", gi, "RIGHT", 8, 0)
    dragGhost.text = gt
end

-- Horizontal line showing where the dragged set will be dropped.
local dropIndicator = listArea:CreateTexture(nil, "OVERLAY")
dropIndicator:SetHeight(3)
dropIndicator:SetTexture("Interface\\Buttons\\WHITE8x8")
dropIndicator:SetVertexColor(1, 0.7, 0.2, 1)
dropIndicator:Hide()

-- Map the cursor's Y position to an insertion index in cdb.setOrder (1..total+1).
local function DragTargetIndex()
    local total = #cdb.setOrder
    local offset = FauxScrollFrame_GetOffset(scrollFrame)
    local listTop = listArea:GetTop()
    local _, cy = GetCursorPosition()
    cy = cy / UIParent:GetEffectiveScale()
    if not listTop then return total + 1 end
    -- Distance from the top of the visible list, in rows.
    local rel = (listTop - cy) / ROW_HEIGHT
    local visibleIndex = math.floor(rel + 0.5)  -- round to nearest gap
    if visibleIndex < 0 then visibleIndex = 0 end
    local idx = offset + visibleIndex + 1
    if idx < 1 then idx = 1 end
    if idx > total + 1 then idx = total + 1 end
    return idx
end

-- Position the drop indicator at the gap for the given insertion index.
local function PositionDropIndicator(insertIdx)
    local offset = FauxScrollFrame_GetOffset(scrollFrame)
    local visible = insertIdx - 1 - offset
    if visible < 0 then visible = 0 end
    if visible > MAX_VISIBLE_ROWS then visible = MAX_VISIBLE_ROWS end
    dropIndicator:ClearAllPoints()
    dropIndicator:SetPoint("TOPLEFT", listArea, "TOPLEFT", 0, -visible * ROW_HEIGHT + 1)
    dropIndicator:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", -22, -visible * ROW_HEIGHT + 1)
    dropIndicator:Show()
end

-- Auto-scroll when the cursor is held near the top/bottom edge of the list.
local SCROLL_EDGE = ROW_HEIGHT      -- px from edge that triggers scrolling
local scrollAccum = 0
local function DragOnUpdate(_, elapsed)
    -- Follow cursor with the ghost.
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    dragGhost:ClearAllPoints()
    dragGhost:SetPoint("LEFT", UIParent, "BOTTOMLEFT", cx / scale + 12, cy / scale)

    local total = #cdb.setOrder

    -- Edge auto-scroll (only meaningful when the list overflows). Driving
    -- SetVerticalScroll triggers the OnVerticalScroll handler, which updates the
    -- faux-scroll offset and calls RefreshSetList for us.
    if total > MAX_VISIBLE_ROWS then
        local top, bottom = listArea:GetTop(), listArea:GetBottom()
        local y = cy / scale
        scrollAccum = scrollAccum + elapsed
        if scrollAccum >= 0.08 then
            scrollAccum = 0
            local offset = FauxScrollFrame_GetOffset(scrollFrame)
            local maxOffset = total - MAX_VISIBLE_ROWS
            if top and y > top - SCROLL_EDGE and offset > 0 then
                scrollFrame:SetVerticalScroll((offset - 1) * ROW_HEIGHT)
            elseif bottom and y < bottom + SCROLL_EDGE and offset < maxOffset then
                scrollFrame:SetVerticalScroll((offset + 1) * ROW_HEIGHT)
            end
        end
    end

    PositionDropIndicator(DragTargetIndex())
end

BeginRowDrag = function(row)
    if not row.setName then return end
    if #cdb.setOrder < 2 then return end  -- nothing to reorder
    draggingName = row.setName
    scrollAccum = 0

    dragGhost.icon:SetTexture(row.icon:GetTexture() or DEFAULT_ICON)
    dragGhost.text:SetText("|cFF" .. C_GOLD .. row.setName .. "|r")
    dragGhost:Show()
    GameTooltip:Hide()

    row:SetAlpha(0.35)
    f:SetScript("OnUpdate", DragOnUpdate)
end

EndRowDrag = function(row)
    f:SetScript("OnUpdate", nil)
    dragGhost:Hide()
    dropIndicator:Hide()
    row:SetAlpha(1)

    local name = draggingName
    draggingName = nil
    if not name then return end

    -- Current position of the dragged set.
    local from
    for i, n in ipairs(cdb.setOrder) do
        if n == name then from = i; break end
    end
    if not from then RefreshSetList(); return end

    local insertIdx = DragTargetIndex()
    -- Removing the element first shifts everything after it down by one.
    if insertIdx > from then insertIdx = insertIdx - 1 end
    if insertIdx < 1 then insertIdx = 1 end
    if insertIdx > #cdb.setOrder then insertIdx = #cdb.setOrder end

    if insertIdx ~= from then
        table.remove(cdb.setOrder, from)
        table.insert(cdb.setOrder, insertIdx, name)
        D("Reordered '" .. name .. "' from " .. from .. " to " .. insertIdx)
    end
    RefreshSetList()
end

-- =======================================================
-- Bottom action buttons
-- =======================================================
local bottomArea = CreateFrame("Frame", nil, f)
bottomArea:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
bottomArea:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
bottomArea:SetHeight(30)

-- Bank buttons (with set name input)
local bankLabel = bottomArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
bankLabel:SetPoint("LEFT", bottomArea, "LEFT", 0, 0)
bankLabel:SetText("|cFF" .. C_MUTED .. "Bank:|r")

local toBankBtn = CreateFrame("Button", nil, bottomArea, "UIPanelButtonTemplate")
toBankBtn:SetSize(54, 24)
toBankBtn:SetPoint("LEFT", bankLabel, "RIGHT", 4, 0)
toBankBtn:SetText("Store")
toBankBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
toBankBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Store selected set's items in bank")
    GameTooltip:AddLine("Right-click a set first, then use this", 0.7, 0.7, 0.7)
    if not isBankOpen then
        GameTooltip:AddLine("|cFF" .. C_ERROR .. "Bank must be open|r")
    end
    GameTooltip:Show()
end)
toBankBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local fromBankBtn = CreateFrame("Button", nil, bottomArea, "UIPanelButtonTemplate")
fromBankBtn:SetSize(54, 24)
fromBankBtn:SetPoint("LEFT", toBankBtn, "RIGHT", 4, 0)
fromBankBtn:SetText("Load")
fromBankBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
fromBankBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Load selected set's items from bank")
    GameTooltip:AddLine("Right-click a set first, then use this", 0.7, 0.7, 0.7)
    if not isBankOpen then
        GameTooltip:AddLine("|cFF" .. C_ERROR .. "Bank must be open|r")
    end
    GameTooltip:Show()
end)
fromBankBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Selected set tracking for bank operations
local selectedSetName = nil

local function SetSelectedSet(name)
    selectedSetName = name
    D("Selected set for bank ops: " .. (name or "none"))
end

-- Update row click to also select for bank ops
for i = 1, MAX_VISIBLE_ROWS do
    rows[i]:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and self.setName then
            SetSelectedSet(self.setName)
            -- Visual feedback: brief highlight
            if self.SetBackdropColor then
                self:SetBackdropColor(0.3, 0.25, 0.1, 0.8)
                C_Timer.After(0.3, function()
                    if RefreshSetList then RefreshSetList() end
                end)
            end
        elseif button == "RightButton" and self.setName then
            SetSelectedSet(self.setName)
            local popup = StaticPopup_Show("SWAG_RENAME_SET", self.setName)
            if popup then popup.data = self.setName end
        end
    end)
end

toBankBtn:SetScript("OnClick", function()
    if selectedSetName then
        StoreInBank(selectedSetName)
    else
        P("Click a set first to select it for bank operations.")
    end
end)

fromBankBtn:SetScript("OnClick", function()
    if selectedSetName then
        LoadFromBank(selectedSetName)
    else
        P("Click a set first to select it for bank operations.")
    end
end)

-- Keep the character selector and list in sync every time the panel opens.
f:SetScript("OnShow", function()
    if RefreshCharSelector then RefreshCharSelector() end
    if RefreshSetList then RefreshSetList() end
end)

f:Hide()

-- ===========================================================================
-- SETTINGS PANEL (Blizzard Interface Options)
-- ===========================================================================

local optPanel = CreateFrame("Frame", "SWAGSettingsPanel")
optPanel.name = ADDON_NAME

local optTitle = optPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
optTitle:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 16, -16)
optTitle:SetText("|cFF" .. ACCENT .. ADDON_FULL .. "|r")

local optVersion = optPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
optVersion:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -4)
optVersion:SetText("|cFF" .. C_MUTED .. "v" .. ADDON_VERSION .. " by goosefraba|r")

local optDesc = optPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
optDesc:SetPoint("TOPLEFT", optVersion, "BOTTOMLEFT", 0, -12)
optDesc:SetText("A simple equipment set manager.\nSave your gear, switch sets, bank your stuff.")

-- Toggle: Chat messages
local function CreateCheckbox(parent, yOffset, label, desc, getFunc, setFunc)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    lbl:SetText(label)

    local d = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    d:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    d:SetText("|cFF888888" .. desc .. "|r")

    cb:SetScript("OnClick", function(self)
        setFunc(self:GetChecked() and true or false)
    end)

    cb.Refresh = function()
        cb:SetChecked(getFunc())
    end

    return cb
end

local cbChat = CreateCheckbox(optPanel, -110, "Chat Messages",
    "Show messages when switching sets, banking items, etc.",
    function() return db and db.settings.chatMessages end,
    function(v) if db then db.settings.chatMessages = v end end
)

local cbMinimap = CreateCheckbox(optPanel, -160, "Minimap Button",
    "Show the SWAG button on the minimap.",
    function() return db and not db.settings.minimapHidden end,
    function(v)
        if db then
            db.settings.minimapHidden = not v
            if v then minimapBtn:Show() else minimapBtn:Hide() end
        end
    end
)

local cbDebug = CreateCheckbox(optPanel, -210, "Debug Mode",
    "Print debug messages to chat (for troubleshooting).",
    function() return DEBUG end,
    function(v) DEBUG = v; if db then db.settings.debug = v end end
)

-- About section at bottom
local aboutLabel = optPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
aboutLabel:SetPoint("BOTTOMLEFT", optPanel, "BOTTOMLEFT", 16, 16)
aboutLabel:SetText("|cFF" .. C_MUTED .. ADDON_FULL .. " v" .. ADDON_VERSION .. "\nby goosefraba (Bernhard Keprt)\nLicense: GPL-3.0|r")

settingsPanel.RegisterBliz = function()
    pcall(function()
        if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
            -- Modern (retail / future Anniversary) options API
            local category = Settings.RegisterCanvasLayoutCategory(optPanel, optPanel.name)
            category.ID = optPanel.name
            Settings.RegisterAddOnCategory(category)
            settingsPanel.category = category
        elseif InterfaceOptions_AddCategory then
            -- Legacy API (TBC Anniversary 2.5.x)
            InterfaceOptions_AddCategory(optPanel)
        end
    end)
end

settingsPanel.OpenBliz = function()
    pcall(function()
        if settingsPanel.category and Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(settingsPanel.category.ID)
        elseif InterfaceOptionsFrame_OpenToCategory then
            InterfaceOptionsFrame_OpenToCategory(optPanel)
            InterfaceOptionsFrame_OpenToCategory(optPanel) -- called twice intentionally (Blizzard bug)
        end
    end)
end

settingsPanel.Refresh = function()
    if cbChat and cbChat.Refresh then cbChat.Refresh() end
    if cbMinimap and cbMinimap.Refresh then cbMinimap.Refresh() end
    if cbDebug and cbDebug.Refresh then cbDebug.Refresh() end
end

-- ===========================================================================
-- HELP / ABOUT PANEL
-- ===========================================================================

local hp = CreateFrame("Frame", "SWAGHelpPanel", UIParent)
hp:SetSize(420, 380)
hp:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
hp:SetFrameStrata("FULLSCREEN_DIALOG")
hp:SetMovable(true)
hp:EnableMouse(true)
hp:RegisterForDrag("LeftButton")

if BackdropTemplateMixin then
    Mixin(hp, BackdropTemplateMixin)
    hp:OnBackdropLoaded()
end
if hp.SetBackdrop then
    hp:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    hp:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
end

tinsert(UISpecialFrames, "SWAGHelpPanel")

hp:SetScript("OnDragStart", function(self) self:StartMoving() end)
hp:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

local hpClose = CreateFrame("Button", nil, hp, "UIPanelCloseButton")
hpClose:SetPoint("TOPRIGHT", hp, "TOPRIGHT", -4, -4)

local hpTitle = hp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
hpTitle:SetPoint("TOP", hp, "TOP", 0, -14)
hpTitle:SetText("|cFF" .. ACCENT .. ADDON_FULL .. "|r")

local HELP_LINES = {
    "|cFF" .. C_GOLD .. "Slash Commands:|r",
    "/swag — Toggle main panel",
    "/swag save <name> — Save current gear as a set",
    "/swag wear <name> — Equip a saved set",
    "/swag delete <name> — Delete a set",
    "/swag rename <old> | <new> — Rename a set",
    "/swag list — List all saved sets",
    "/swag undress — Unequip all items to bags",
    "/swag bank <name> — Store set items in bank",
    "/swag load <name> — Load set items from bank",
    "/swag minimap — Toggle minimap button",
    "/swag settings — Open settings",
    "/swag help — Show this help",
    "/swag debug — Toggle debug mode",
    " ",
    "|cFF" .. C_GOLD .. "Panel Usage:|r",
    "Enter a name and click Save to save current gear.",
    "Click Wear to equip a set.",
    "Click X to delete a set.",
    "Right-click a set to rename it.",
    "Left-click a set to select it for bank operations.",
    "Drag a set up or down to reorder the list.",
    " ",
    "|cFF" .. C_GOLD .. "Characters:|r",
    "Sets are saved per character. By default you see",
    "only this character's sets.",
    "Use the Char dropdown (top of panel) to view",
    "another character's sets.",
    " ",
    "|cFF" .. C_GOLD .. "Macros:|r",
    "/swag wear PvP — Quick-switch to a set named PvP",
    "/swag save Farming — Save current gear as Farming",
    " ",
    "|cFF" .. C_MUTED .. "v" .. ADDON_VERSION .. " by goosefraba (Bernhard Keprt)|r",
    "|cFF" .. C_MUTED .. "License: GPL-3.0|r",
}

local hpText = hp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
hpText:SetPoint("TOPLEFT", hp, "TOPLEFT", 20, -40)
hpText:SetPoint("RIGHT", hp, "RIGHT", -20, 0)
hpText:SetJustifyH("LEFT")
hpText:SetSpacing(3)
hpText:SetText(table.concat(HELP_LINES, "\n"))

hp:Hide()

helpPanel.Toggle = function()
    if hp:IsShown() then hp:Hide() else hp:Show() end
end

-- ===========================================================================
-- ITEM TOOLTIPS — show which sets an item belongs to
-- ===========================================================================

local function SWAG_ItemTooltip(tooltip, data)
    if tooltip ~= GameTooltip then return end
    if not db or not db.chars then return end

    -- Modern API (TooltipDataProcessor) passes the link in data.hyperlink;
    -- the legacy OnTooltipSetItem hook passes no data, so fall back to GetItem.
    local link
    if data and data.hyperlink then
        link = data.hyperlink
    elseif tooltip.GetItem then
        local _, l = tooltip:GetItem()
        link = l
    end
    if not link then return end
    local itemId = tonumber(link:match("item:(%d+)"))
    if not itemId then return end

    -- Search every character's sets so the tooltip is useful regardless of who
    -- you're viewing. Matches on this character are listed plainly; matches on
    -- other characters are tagged with that character's name.
    local ownMatches, otherMatches = {}, {}
    for charKey, bucket in pairs(db.chars) do
        if bucket.sets then
            for setName, set in pairs(bucket.sets) do
                for _, itemData in pairs(set.items) do
                    if itemData.id == itemId then
                        if charKey == ownCharKey then
                            table.insert(ownMatches, setName)
                        else
                            table.insert(otherMatches, (bucket.name or charKey) .. ": " .. setName)
                        end
                        break
                    end
                end
            end
        end
    end

    if #ownMatches > 0 or #otherMatches > 0 then
        table.sort(ownMatches)
        table.sort(otherMatches)
        local all = {}
        for _, v in ipairs(ownMatches) do table.insert(all, v) end
        for _, v in ipairs(otherMatches) do table.insert(all, "|cFF" .. C_MUTED .. v .. "|r") end
        tooltip:AddLine("|cFF" .. ACCENT .. "[SWAG]|r " .. table.concat(all, ", "))
        tooltip:Show()
    end
end

-- Modern clients (retail / future Anniversary builds) deprecate the
-- OnTooltipSetItem script hook in favour of TooltipDataProcessor. Use it when
-- present, otherwise fall back to the legacy hook used on TBC 2.5.x.
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, SWAG_ItemTooltip)
else
    GameTooltip:HookScript("OnTooltipSetItem", SWAG_ItemTooltip)
end

-- ===========================================================================
-- SLASH COMMANDS
-- ===========================================================================

SLASH_SWAG1 = "/swag"

SlashCmdList["SWAG"] = function(msg)
    msg = (msg or ""):trim()

    if msg == "" then
        if f:IsShown() then f:Hide() else f:Show(); RefreshSetList() end
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or ""):lower()
    rest = (rest or ""):trim()

    if cmd == "save" then
        SaveSet(rest)

    elseif cmd == "wear" or cmd == "equip" or cmd == "switch" then
        EquipSet(rest)

    elseif cmd == "delete" or cmd == "rm" or cmd == "del" then
        if rest ~= "" then
            local popup = StaticPopup_Show("SWAG_CONFIRM_DELETE", rest)
            if popup then popup.data = rest end
        else
            P("Usage: |cFF" .. C_GOLD .. "/swag delete <set name>|r")
        end

    elseif cmd == "rename" then
        local old, new = rest:match("^(.-)%s*|%s*(.+)")
        if old and new then
            RenameSet(old, new)
        else
            P("Usage: |cFF" .. C_GOLD .. "/swag rename <old name> | <new name>|r")
        end

    elseif cmd == "list" or cmd == "ls" then
        ListSets()

    elseif cmd == "undress" or cmd == "strip" then
        Undress()

    elseif cmd == "bank" or cmd == "store" then
        StoreInBank(rest)

    elseif cmd == "load" or cmd == "withdraw" then
        LoadFromBank(rest)

    elseif cmd == "minimap" then
        ToggleMinimapButton()

    elseif cmd == "settings" or cmd == "options" or cmd == "config" then
        settingsPanel.Refresh()
        settingsPanel.OpenBliz()

    elseif cmd == "help" then
        helpPanel.Toggle()

    elseif cmd == "debug" then
        DEBUG = not DEBUG
        if db then db.settings.debug = DEBUG end
        P("Debug mode: " .. (DEBUG and "|cFF" .. C_SUCCESS .. "ON|r" or "|cFF" .. C_ERROR .. "OFF|r"))

    else
        P("Unknown command: |cFF" .. C_GOLD .. cmd .. "|r. Type |cFF" .. C_GOLD .. "/swag help|r")
    end
end

-- ===========================================================================
-- EVENT HANDLER / LOADER
-- ===========================================================================

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("BANKFRAME_OPENED")
loader:RegisterEvent("BANKFRAME_CLOSED")

loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1:upper() == ADDON_NAME:upper() then
        InitDB()

        -- Restore frame position
        if db.frame and db.frame.point then
            f:ClearAllPoints()
            f:SetPoint(db.frame.point, UIParent, db.frame.relPoint, db.frame.x, db.frame.y)
        end

        -- Minimap button
        minimapAngle = db.minimapAngle or 220
        MinimapBtn_SetAngle(minimapAngle)
        if not db.settings.minimapHidden then
            minimapBtn:Show()
        end

        -- Initialise the character selector text now that cdb is ready.
        if RefreshCharSelector then RefreshCharSelector() end

    elseif event == "PLAYER_LOGIN" then
        settingsPanel.RegisterBliz()
        settingsPanel.Refresh()
        P("v" .. ADDON_VERSION .. " loaded. Type |cFF" .. C_GOLD .. "/swag|r or |cFF" .. C_GOLD .. "/swag help|r")
        self:UnregisterEvent("ADDON_LOADED")
        self:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "BANKFRAME_OPENED" then
        isBankOpen = true
        D("Bank opened")

    elseif event == "BANKFRAME_CLOSED" then
        isBankOpen = false
        D("Bank closed")
    end
end)
