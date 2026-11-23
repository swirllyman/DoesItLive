-- DoesItLive settings: defaults (filled into DoesItLiveDB on load) and the choices the options window offers.
-- Read them through ns.setting(key), which falls back to the default before the saved settings are loaded.
-- Colors and icons stay apart from DoesItDie's: no red, gold or white fills, no skull, X, checkmark or sunglasses.
-- The defaults are Joe's own settings of 2026-11-22.
-- Loaded after Probe.lua.

local _, ns = ...

ns.DEFAULTS = {
    -- Where
    showPlayer = true, showPersonal = true, showTarget = true, showPlates = true,
    -- Which HoTs
    spellRejuvenation = true, spellRegrowth = true, spellRenew = true, spellRiptide = true,
    -- Heal fill
    healColor = "teal", healOpacity = 25, fillTexture = "flat",
    hotColors = "bySpell", segmentDividers = true,
    colorRejuvenation = "teal", colorRegrowth = "green", colorRenew = "cyan", colorRiptide = "blue",
    -- Outline around the heal
    outlineStyle = "dashed", dashLength = 4, outlineThickness = 1, outlineColor = "teal", outlineOpacity = 20,
    -- Animation and effects
    smoothMotion = true, flashOnApply = true, pulseOutline = false, showSpark = false,
    showGlow = false, glowSize = 4, showShine = false, shineInterval = 4, scrollStripes = false,
    -- Overheal
    showOverheal = true, overhealColor = "teal", overhealOpacity = 100, overhealHeight = 30,
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
    fills = {
        { id = "flat", label = "Flat", path = "Interface\\Buttons\\WHITE8X8" },
        { id = "smooth", label = "Health bar texture", path = "Interface\\TargetingFrame\\UI-StatusBar" },
        { id = "raid", label = "Raid bar texture", path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
        { id = "stripes", label = "Diagonal stripes", path = "Interface\\AddOns\\DoesItLive\\Textures\\Stripes",
          tiled = true },
        { id = "gradient", label = "Fade in from left", path = "Interface\\Buttons\\WHITE8X8", gradient = true },
    },
    hotColors = {
        { id = "single", label = "One color" },
        { id = "bySpell", label = "A color per HoT" },
    },
    outlines = {
        { id = "none", label = "None" },
        { id = "solid", label = "Solid" },
        { id = "dashed", label = "Dashed" },
    },
    dashLengths = { -- tools/make_textures.py makes these
        { id = 1, label = "Fine dots (1px)" },
        { id = 2, label = "Dots (2px)" },
        { id = 4, label = "Short dashes (4px)" },
        { id = 8, label = "Dashes (8px)" },
        { id = 16, label = "Long dashes (16px)" },
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
