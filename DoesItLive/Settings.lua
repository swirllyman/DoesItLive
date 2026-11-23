-- DoesItLive settings: defaults (filled into DoesItLiveDB on load) and the choices the options window offers.
-- Read them through ns.setting(key), which falls back to the default before the saved settings are loaded.
-- Colors and icons stay apart from DoesItDie's: no red, gold or white fills, no skull, X, checkmark or sunglasses.
-- Loaded after Probe.lua.

local _, ns = ...

ns.DEFAULTS = {
    -- Where
    showPlayer = true, showPersonal = true, showTarget = true, showPlates = true,
    -- Which HoTs
    spellRejuvenation = true, spellRegrowth = true, spellRenew = true, spellRiptide = true,
    -- Heal fill
    healColor = "teal", healOpacity = 60,
    -- Overheal
    showOverheal = true, overhealColor = "paleBlue", overhealOpacity = 95, overhealHeight = 30,
    -- Tops off icon
    topOffIcon = "plus", iconSize = 100, iconPulse = false,
    -- Text
    showText = false, textPosition = "left", textSize = 10, textColor = "white",
}

ns.SPELLS = { "Rejuvenation", "Regrowth", "Renew", "Riptide" }

ns.lists = {
    colors = {
        { id = "teal", label = "Teal", rgb = { 0.3, 1, 0.8 } },
        { id = "green", label = "Green", rgb = { 0.35, 1, 0.35 } },
        { id = "cyan", label = "Cyan", rgb = { 0.2, 0.9, 1 } },
        { id = "paleBlue", label = "Pale blue", rgb = { 0.65, 0.85, 1 } },
        { id = "blue", label = "Blue", rgb = { 0.3, 0.5, 1 } },
        { id = "purple", label = "Purple", rgb = { 0.7, 0.45, 1 } },
        { id = "pink", label = "Pink", rgb = { 1, 0.55, 0.8 } },
    },
    textColors = {
        { id = "white", label = "White", rgb = { 1, 1, 1 } },
        { id = "teal", label = "Teal", rgb = { 0.3, 1, 0.8 } },
        { id = "green", label = "Green", rgb = { 0.35, 1, 0.35 } },
        { id = "paleBlue", label = "Pale blue", rgb = { 0.65, 0.85, 1 } },
    },
    icons = {
        { id = "plus", label = "Plus" },
        { id = "leaf", label = "Rejuvenation icon", path = "Interface\\Icons\\Spell_Nature_Rejuvenation" },
        { id = "none", label = "None" },
    },
    textPositions = {
        { id = "left", label = "Inside the bar, left" },
        { id = "center", label = "Centered on the bar" },
        { id = "right", label = "Inside the bar, right" },
        { id = "above", label = "Above the bar, right" },
    },
}

local function find(list, id)
    for _, entry in ipairs(list) do
        if entry.id == id then return entry end
    end
    return list[1]
end
ns.findEntry = find

function ns.setting(key)
    local db = ns.db and ns.db()
    if db and db[key] ~= nil then return db[key] end
    return ns.DEFAULTS[key]
end

function ns.colorOf(key, list)
    local rgb = find(list or ns.lists.colors, ns.setting(key)).rgb
    return rgb[1], rgb[2], rgb[3]
end

-- Fills in missing settings, and carries over the older /dil plates switch.
function ns.applyDefaults(db)
    if db.plates == false and db.showPlates == nil then db.showPlates = false end
    db.plates = nil
    for key, value in pairs(ns.DEFAULTS) do
        if db[key] == nil then db[key] = value end
    end
end
