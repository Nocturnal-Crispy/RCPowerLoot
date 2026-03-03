--- RCPowerLoot/bis.lua
-- BIS (Best In Slot) marking for the current character's loot spec.
-- Allows a player to tag item IDs as BIS so the voting frame can
-- highlight candidates who have the item as their best-in-slot piece.

local ADDON_NAME, ns = ...
local RPL = ns.RPL

local BIS = {}
ns.BIS = BIS

--- SavedVariable key: RCPowerLootDB.bis[specID][itemID] = true
local function GetBisDB()
    if not RCPowerLootDB then RCPowerLootDB = {} end
    if not RCPowerLootDB.bis then RCPowerLootDB.bis = {} end
    return RCPowerLootDB.bis
end

--- Returns the current player's active loot spec ID (falls back to class spec).
local function GetCurrentSpecID()
    local specIndex = GetSpecialization()
    if not specIndex then return 0 end
    local specID = GetSpecializationInfo(specIndex)
    return specID or 0
end

--- Marks an item as BIS for the player's current spec.
-- @param itemLink string  A shift-clicked item link from the game chat input.
function BIS:MarkBIS(itemLink)
    if not itemLink or itemLink == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[RPL]|r Usage: /rpl bis (shift-click item link)")
        return
    end

    -- Extract itemID from the link  e.g. |Hitem:12345:0:...|h[Name]|h
    local itemID = tonumber(itemLink:match("item:(%d+)"))
    if not itemID then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[RPL]|r Invalid item link.")
        return
    end

    local specID = GetCurrentSpecID()
    local db = GetBisDB()

    if not db[specID] then db[specID] = {} end
    db[specID][itemID] = true

    local _, itemName = GetItemInfo(itemLink)
    itemName = itemName or ("item:" .. itemID)
    DEFAULT_CHAT_FRAME:AddMessage(
        string.format("|cffffcc00[RPL]|r Marked |cff00ff00%s|r as BIS for specID %d.", itemName, specID))
end

--- Returns true if the given itemID is BIS for the provided specID.
function BIS:IsBIS(specID, itemID)
    local db = GetBisDB()
    return db[specID] and db[specID][itemID] == true or false
end

--- Handles the "/rpl bis <link>" slash command.
function BIS:HandleBisCommand(args)
    self:MarkBIS(args)
end
