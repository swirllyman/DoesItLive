-- DoesItLive settings: defaults (filled into DoesItLiveDB on load) and the choices the options window offers.
-- Read them through ns.setting(key), which falls back to the default before the saved settings are loaded.
-- Colors and icons stay apart from DoesItDie's: no red, gold or white fills, no skull, X, checkmark or sunglasses.
-- The defaults are Joe's own settings of 2026-11-22.
-- Loaded after Probe.lua.

local _, ns = ...

ns.DEFAULTS = {
    -- Where
    showPlayer = true, showPersonal = true, showTarget = true, showPlates = true, showPet = true, showRaid = true,
    -- Which HoTs
    -- (catX and spellX for every category and spell below are added after this table)
    -- Heal fill
    healColor = "teal", healOpacity = 25, fillTexture = "flat",
    hotColors = "bySpell", segmentDividers = true,
    -- (colorX for every spell: SPELL_COLORS below)
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
    -- Unit frame addons the addon doesn't know: a frame path (Frames.lua), or keys from the nameplate
    customPlayerBar = "", customTargetBar = "", customPetBar = "", customPlateBar = "",
}

-- What can be tracked, in groups the options show (Tracking.lua has how each one heals). The last group catches
-- anything of yours whose tooltip heals over time (bandages, food, Lightwell's renew, ...).
ns.CATEGORIES = {
    { id = "Others", label = "HoTs on others",
      spells = { "Rejuvenation", "Regrowth", "Renew", "Riptide", "Wild Growth" } },
    { id = "Self", label = "Heals on yourself", spells = { "Siphon Life", "Drain Life", "Devouring Plague" } },
    { id = "Pet", label = "Heals on your pet", spells = { "Mend Pet", "Health Funnel" } },
    { id = "Group", label = "Group and placed", spells = { "Healing Stream Totem", "Lightwell", "Penance" } },
    { id = "Items", label = "Bandages, food and others", spells = { "Bandages", "Food and drink", "Other" } },
}
-- Per-HoT colors: different within each group.
local SPELL_COLORS = {
    ["Rejuvenation"] = "teal", ["Regrowth"] = "green", ["Renew"] = "cyan", ["Riptide"] = "blue", ["Wild Growth"] = "purple",
    ["Siphon Life"] = "pink", ["Drain Life"] = "magenta", ["Devouring Plague"] = "lavender",
    ["Mend Pet"] = "lime", ["Health Funnel"] = "mint",
    ["Healing Stream Totem"] = "sky", ["Lightwell"] = "paleBlue", ["Penance"] = "mint",
    ["Bandages"] = "sky", ["Food and drink"] = "lime", ["Other"] = "teal",
}

ns.SPELLS, ns.CATEGORY_OF = {}, {}
-- A spell's setting key: "spell" .. "WildGrowth" (no spaces).
function ns.spellKey(prefix, name)
    return prefix .. name:gsub("%s", "")
end
for _, category in ipairs(ns.CATEGORIES) do
    ns.DEFAULTS["cat" .. category.id] = true
    for _, spell in ipairs(category.spells) do
        ns.SPELLS[#ns.SPELLS + 1] = spell
        ns.CATEGORY_OF[spell] = category.id
        ns.DEFAULTS[ns.spellKey("spell", spell)] = true
        ns.DEFAULTS[ns.spellKey("color", spell)] = SPELL_COLORS[spell]
    end
end

-- The options entry a tracked spell counts under: itself, or a name from the last group.
function ns.displayGroup(name)
    if ns.CATEGORY_OF[name] then return name end
    if name == "First Aid" or name:find("Bandage") then return "Bandages" end
    if name == "Food" or name == "Refreshment" or name == "Drink" or name:find("Food") then return "Food and drink" end
    if name:find("Lightwell") then return "Lightwell" end
    return "Other"
end

-- Whether the options let this spell count (its group and itself on).
function ns.spellShown(name)
    local group = ns.displayGroup(name)
    return ns.setting("cat" .. ns.CATEGORY_OF[group]) ~= false and ns.setting(ns.spellKey("spell", group)) ~= false
end

ns.lists = {
    colors = {
        { id = "teal", label = "Teal", rgb = { 0.3, 1, 0.8 } },
        { id = "green", label = "Green", rgb = { 0.35, 1, 0.35 } },
        { id = "cyan", label = "Cyan", rgb = { 0.2, 0.9, 1 } },
        { id = "paleBlue", label = "Pale blue", rgb = { 0.65, 0.85, 1 } },
        { id = "blue", label = "Blue", rgb = { 0.3, 0.5, 1 } },
        { id = "purple", label = "Purple", rgb = { 0.7, 0.45, 1 } },
        { id = "pink", label = "Pink", rgb = { 1, 0.55, 0.8 } },
        { id = "magenta", label = "Magenta", rgb = { 0.95, 0.4, 0.95 } },
        { id = "lavender", label = "Lavender", rgb = { 0.8, 0.7, 1 } },
        { id = "lime", label = "Lime", rgb = { 0.7, 1, 0.3 } },
        { id = "mint", label = "Mint", rgb = { 0.6, 1, 0.75 } },
        { id = "sky", label = "Sky", rgb = { 0.5, 0.75, 1 } },
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
