-- DoesItLive options window (/dil), built like DoesItDie's.
--
-- Left: a live preview. The addon's real drawing code (Display.lua) draws on a mock player frame and a mock friendly
-- nameplate here, fed plain numbers from the preview sliders. Right: tabbed settings. Top: presets.
--
-- Controls are built from basic widgets (CheckButton, Slider, Button) rather than Blizzard templates, so they
-- don't depend on templates behaving the same in Forever. Settings are written straight to DoesItLiveDB.

local _, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local WINDOW_WIDTH, WINDOW_HEIGHT = 920, 500
local HEADER_HEIGHT = 52
local PREVIEW_WIDTH = 270
local ROW_HEIGHT = 26
local SETTINGS_LAYOUT = { label = 170, control = 190 }
local CHECK_LAYOUT = { label = 210, control = 26 } -- the two-column lists
local COLOR_LAYOUT = { label = 130, control = 130 }
local COLUMN_WIDTH = 300
local PREVIEW_LAYOUT = { label = 92, control = 130 }
local DISABLED_ALPHA = 0.35
local SIMULATION_STEP = 0.5 -- seconds; one HoT tick per step

-- Presets only set the look; where it shows and which HoTs count are left alone.
local PRESETS = {
    { id = "default", label = "Default", values = { -- the same as ns.DEFAULTS' look
        healColor = "teal", healOpacity = 25, fillTexture = "flat", hotColors = "bySpell", segmentDividers = true,
        outlineStyle = "dashed", dashLength = 4, outlineThickness = 1, outlineColor = "teal", outlineOpacity = 20,
        smoothMotion = true, flashOnApply = true, pulseOutline = false, showSpark = false, showGlow = false,
        glowSize = 4, showShine = false, shineInterval = 4, scrollStripes = false,
        showOverheal = true, overhealColor = "teal", overhealOpacity = 100, overhealHeight = 30,
        topOffIcon = "plus", iconSize = 100, iconPulse = false,
        showText = false, textPosition = "left", textSize = 10, textColor = "white",
    } },
    { id = "subtle", label = "Subtle", values = {
        healColor = "green", healOpacity = 35, fillTexture = "gradient", hotColors = "single", outlineStyle = "none",
        smoothMotion = true, flashOnApply = false, pulseOutline = false, showSpark = false, showGlow = false,
        showShine = false, scrollStripes = false,
        showOverheal = true, overhealColor = "paleBlue", overhealOpacity = 70, overhealHeight = 20,
        topOffIcon = "plus", iconSize = 80, iconPulse = false, showText = false,
    } },
    { id = "perHot", label = "Per HoT", values = {
        healOpacity = 70, fillTexture = "smooth", hotColors = "bySpell", segmentDividers = true,
        outlineStyle = "solid", outlineThickness = 1, outlineColor = "paleBlue", outlineOpacity = 80,
        smoothMotion = true, flashOnApply = true, pulseOutline = false, showSpark = true, showGlow = false,
        showShine = false, scrollStripes = false,
        showOverheal = true, overhealColor = "paleBlue", overhealOpacity = 95, overhealHeight = 30,
        topOffIcon = "plus", iconSize = 100, iconPulse = false, showText = true, textPosition = "left",
    } },
    { id = "juicy", label = "Juicy", values = {
        healColor = "cyan", healOpacity = 90, fillTexture = "stripes", hotColors = "single",
        outlineStyle = "dashed", dashLength = 4, outlineThickness = 1, outlineColor = "teal", outlineOpacity = 90,
        smoothMotion = true, flashOnApply = true, pulseOutline = true, showSpark = true, showGlow = true, glowSize = 5,
        showShine = true, shineInterval = 3, scrollStripes = true,
        showOverheal = true, overhealColor = "purple", overhealOpacity = 100, overhealHeight = 45,
        topOffIcon = "leaf", iconSize = 120, iconPulse = true, showText = true, textPosition = "left", textSize = 11,
    } },
}

for _, spell in ipairs(ns.SPELLS) do
    local key = ns.spellKey("color", spell)
    PRESETS[1].values[key] = ns.DEFAULTS[key]
end

local window
local controls = {} -- every row, refreshed after each change
local tabs, activeTab = {}, nil
local menu -- shared dropdown list
local simulation

-- Preview numbers, in % of the mock unit's max health.
local preview = { health = 55, heal = 30 }
local PREVIEW_SPLIT = { { name = "Rejuvenation", share = 0.6 }, { name = "Regrowth", share = 0.4 } }

local function db() return ns.db() end
local function print(msg) ns.out(msg, true) end

local function setBackdrop(frame, shade, alpha)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(shade, shade, shade, alpha or 1)
    frame:SetBackdropBorderColor(0.28, 0.28, 0.3, 1)
end

---------------------------------------------------------------------------
-- Preview
---------------------------------------------------------------------------

local function refreshControls()
    for _, control in ipairs(controls) do control:Refresh() end
end

local function updatePreview()
    if not window then return end
    window.healthBar:SetValue(preview.health)
    window.plateBar:SetValue(preview.health)
    local missing = 100 - preview.health
    if preview.heal <= 0 then
        window.status:SetText("No HoTs on them")
    elseif preview.heal >= missing then
        window.status:SetText(string.format("|cff66ffccTops them off|r, %d%% overheal", preview.heal - missing))
    else
        window.status:SetText(string.format("Leaves them %d%% short of full", missing - preview.heal))
    end
    ns.display.refresh()
end

local function stopSimulation()
    if simulation then
        simulation:Cancel()
        simulation = nil
    end
    if window then window.simulateButton:SetText("Simulate HoTs") end
end

-- A scripted heal: hurt, a HoT lands, it ticks the health up, a second HoT lands and tops them off.
local function startSimulation()
    stopSimulation()
    preview.health, preview.heal = 35, 0
    local step = 0
    simulation = C_Timer.NewTicker(SIMULATION_STEP, function()
        step = step + 1
        if step == 1 then
            preview.heal = 30
        elseif step == 4 then
            preview.heal = preview.heal + 45
        else
            local tick = math.min(preview.heal, 7)
            preview.heal = preview.heal - tick
            preview.health = math.min(100, preview.health + tick)
        end
        updatePreview()
        refreshControls()
        if step > 4 and preview.heal <= 0 then stopSimulation() end
    end)
    window.simulateButton:SetText("Stop")
    updatePreview()
    refreshControls()
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------

local function changed()
    ns.display.settingsChanged()
    refreshControls()
end

local function makeRow(parent, labelText, opts)
    local layout = opts.layout or SETTINGS_LAYOUT
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(layout.label + layout.control + 50, ROW_HEIGHT)
    row.layout = layout
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("LEFT", 6, 0)
    row.label:SetWidth(layout.label - 8)
    row.label:SetJustifyH("LEFT")
    row.label:SetText(labelText)
    row.enabledIf = opts.enabledIf
    if opts.tooltip then
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(labelText, 1, 1, 1)
            GameTooltip:AddLine(opts.tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    function row:ApplyEnabled(widget)
        local enabled = not self.enabledIf or self.enabledIf(ns.setting)
        self:SetAlpha(enabled and 1 or DISABLED_ALPHA)
        widget:EnableMouse(enabled)
        if widget.EnableMouseWheel then widget:EnableMouseWheel(enabled) end
    end
    table.insert(controls, row)
    return row
end

local function checkbox(parent, key, labelText, opts)
    opts = opts or {}
    local row = makeRow(parent, labelText, opts)
    local box = CreateFrame("CheckButton", nil, row)
    box:SetSize(24, 24)
    box:SetPoint("LEFT", row, "LEFT", row.layout.label, 0)
    box:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    box:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    box:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    box:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    box:SetScript("OnClick", function(self)
        db()[key] = self:GetChecked() and true or false
        changed()
    end)
    function row:Refresh()
        box:SetChecked(ns.setting(key) and true or false)
        self:ApplyEnabled(box)
    end
    return row
end

-- get/set work on any value (settings or preview numbers).
local function sliderRow(parent, labelText, min, max, step, get, set, opts)
    opts = opts or {}
    local row = makeRow(parent, labelText, opts)
    local slider = CreateFrame("Slider", nil, row)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(row.layout.control - 44, 18)
    slider:SetPoint("LEFT", row, "LEFT", row.layout.label + 2, 0)
    slider:SetMinMaxValues(min, max)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0.3, 0.3, 0.32, 1)
    track:SetHeight(4)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:GetThumbTexture():SetSize(18, 24)
    local valueText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    local suffix = opts.suffix or ""
    local updating = false
    slider:SetScript("OnValueChanged", function(_, value)
        if updating or type(value) ~= "number" then return end
        value = math.floor(value / step + 0.5) * step
        valueText:SetText(value .. suffix)
        set(value)
    end)
    slider:SetScript("OnMouseWheel", function(self, delta)
        local value = self:GetValue()
        if type(value) == "number" then self:SetValue(value + delta * step) end
    end)
    function row:Refresh()
        updating = true
        local value = get()
        slider:SetValue(value)
        valueText:SetText(math.floor(value / step + 0.5) * step .. suffix)
        updating = false
        self:ApplyEnabled(slider)
    end
    return row
end

local function slider(parent, key, labelText, min, max, step, opts)
    return sliderRow(parent, labelText, min, max, step,
        function() return ns.setting(key) end,
        function(value)
            db()[key] = value
            changed()
        end, opts)
end

local function closeMenu()
    if menu then menu:Hide() end
end

-- Shared dropdown list under `owner`; entries may carry an rgb swatch.
local function openMenu(owner, list, current, pick)
    if not menu then
        menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:EnableMouse(true)
        setBackdrop(menu, 0.08, 0.98)
        menu.buttons = {}
        pcall(menu.RegisterEvent, menu, "GLOBAL_MOUSE_DOWN")
        menu:SetScript("OnEvent", function(self)
            if not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then self:Hide() end
        end)
    end
    if menu:IsShown() and menu.owner == owner then return menu:Hide() end
    menu.owner = owner
    for i, entry in ipairs(list) do
        local button = menu.buttons[i]
        if not button then
            button = CreateFrame("Button", nil, menu)
            button:SetHeight(20)
            local highlight = button:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints()
            highlight:SetColorTexture(1, 1, 1, 0.1)
            button.swatch = button:CreateTexture(nil, "ARTWORK")
            button.swatch:SetSize(12, 12)
            button.swatch:SetPoint("LEFT", 8, 0)
            button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            button.text:SetJustifyH("LEFT")
            menu.buttons[i] = button
        end
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -4 - (i - 1) * 20)
        button:SetPoint("RIGHT", menu, "RIGHT", -1, 0)
        button.swatch:SetShown(entry.rgb ~= nil)
        if entry.rgb then button.swatch:SetColorTexture(entry.rgb[1], entry.rgb[2], entry.rgb[3], 1) end
        button.text:ClearAllPoints()
        button.text:SetPoint("LEFT", entry.rgb and 26 or 8, 0)
        button.text:SetText(entry.id == current and ("|cffffd100" .. entry.label .. "|r") or entry.label)
        button:SetScript("OnClick", function()
            menu:Hide()
            pick(entry.id)
        end)
        button:Show()
    end
    for i = #list + 1, #menu.buttons do menu.buttons[i]:Hide() end
    menu:SetSize(owner:GetWidth() or 190, #list * 20 + 8)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    menu:Show()
end

local function choice(parent, key, labelText, list, opts)
    opts = opts or {}
    local row = makeRow(parent, labelText, opts)
    local button = CreateFrame("Button", nil, row, "BackdropTemplate")
    button:SetSize(row.layout.control, 22)
    button:SetPoint("LEFT", row, "LEFT", row.layout.label, 0)
    setBackdrop(button, 0.13)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.06)
    local swatch = button:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(12, 12)
    swatch:SetPoint("LEFT", 8, 0)
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    local arrow = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetText("v")
    button:SetScript("OnClick", function(self)
        openMenu(self, list, ns.setting(key), function(id)
            db()[key] = id
            changed()
        end)
    end)
    function row:Refresh()
        local entry = ns.findEntry(list, ns.setting(key))
        text:SetText(entry.label)
        swatch:SetShown(entry.rgb ~= nil)
        if entry.rgb then swatch:SetColorTexture(entry.rgb[1], entry.rgb[2], entry.rgb[3], 1) end
        text:ClearAllPoints()
        text:SetPoint("LEFT", entry.rgb and 26 or 8, 0)
        text:SetPoint("RIGHT", -20, 0)
        self:ApplyEnabled(button)
    end
    return row
end

local function pushButton(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function actionRow(parent, labelText, buttonText, onClick, opts)
    opts = opts or {}
    local row = makeRow(parent, labelText, opts)
    local button = pushButton(row, buttonText, 90, onClick)
    button:SetPoint("LEFT", row, "LEFT", row.layout.label, 0)
    row.button = button
    function row:Refresh() self:ApplyEnabled(button) end
    return row
end

local function infoRow(parent, labelText, getText, opts)
    opts = opts or {}
    local row = makeRow(parent, labelText, opts)
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", row, "LEFT", row.layout.label, 0)
    text:SetWidth(row.layout.control + 40)
    text:SetJustifyH("LEFT")
    function row:Refresh() text:SetText(getText()) end
    return row
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

local function selectTab(tab)
    closeMenu()
    activeTab = tab
    for _, other in ipairs(tabs) do
        local selected = other == tab
        other.content:SetShown(selected)
        other.button.text:SetTextColor(selected and 1 or 0.6, selected and 0.82 or 0.6, selected and 0 or 0.6)
        other.button.underline:SetShown(selected)
    end
end

-- A tab whose methods add rows top to bottom and remember the setting keys, for "Reset this tab".
local function addTab(name)
    local area = window.settingsArea
    local tab = { keys = {}, y = 0 }
    tab.content = CreateFrame("Frame", nil, area)
    tab.content:SetPoint("TOPLEFT", area, "TOPLEFT", 8, -40)
    tab.content:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -8, 40)
    tab.content:Hide()

    local button = CreateFrame("Button", nil, area)
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.text:SetText(name)
    button:SetSize((button.text:GetStringWidth() or 60) + 16, 26)
    button.text:SetPoint("CENTER")
    button.underline = button:CreateTexture(nil, "ARTWORK")
    button.underline:SetColorTexture(1, 0.82, 0, 1)
    button.underline:SetHeight(2)
    button.underline:SetPoint("BOTTOMLEFT", 3, 0)
    button.underline:SetPoint("BOTTOMRIGHT", -3, 0)
    local previous = tabs[#tabs]
    if previous then
        button:SetPoint("LEFT", previous.button, "RIGHT", 2, 0)
    else
        button:SetPoint("TOPLEFT", area, "TOPLEFT", 8, -8)
    end
    button:SetScript("OnClick", function() selectTab(tab) end)
    tab.button = button

    tab.x = 0
    local function place(row, key)
        row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", tab.x, -tab.y)
        tab.y = tab.y + ROW_HEIGHT
        if key then table.insert(tab.keys, key) end
        return row
    end
    function tab:checkbox(key, ...) return place(checkbox(self.content, key, ...), key) end
    function tab:slider(key, ...) return place(slider(self.content, key, ...), key) end
    function tab:choice(key, ...) return place(choice(self.content, key, ...), key) end
    function tab:action(...) return place(actionRow(self.content, ...)) end
    function tab:info(...) return place(infoRow(self.content, ...)) end
    function tab:gap() self.y = self.y + 8 end
    function tab:column(index)
        self.x, self.y = (index - 1) * COLUMN_WIDTH, 0
    end

    table.insert(tabs, tab)
    return tab
end

local function resetTab(tab)
    for _, key in ipairs(tab.keys) do db()[key] = ns.DEFAULTS[key] end
    changed()
end

local function applyPreset(preset)
    for key, value in pairs(preset.values) do db()[key] = value end
    changed()
    print(preset.label .. " preset applied.")
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function buildTabs()
    local lists = ns.lists

    local show = addTab("Show on")
    show:checkbox("showPlayer", "Your player frame")
    show:checkbox("showPersonal", "Bars under your character", { tooltip = "The personal resource display. Turn it "
        .. "on in Options > Combat if you don't see it." })
    show:checkbox("showTarget", "Friendly target", { tooltip = "Your target's frame, when you can assist it." })
    show:checkbox("showPlates", "Friendly nameplates", { tooltip = "Nameplates of friendly players and NPCs. "
        .. "Friendly players need their health bars on: untick \"show only name\" under friendly players in "
        .. "Options > Nameplates. In dungeons the game may keep friendly nameplates from addons." })
    show:checkbox("showPet", "Your pet's frame", { tooltip = "For Mend Pet, Health Funnel and your HoTs on your pet." })

    -- What to track: each group on or off, and each spell in it, in two columns.
    local NOTES = {
        ["Wild Growth"] = "Its ticks start big and shrink, and it reaches the group members it healed a second after the "
            .. "cast. Both are estimates.",
        ["Devouring Plague"] = "Rough: assumes it heals you for all of its damage.",
        ["Drain Life"] = "Ends when the channel does.",
        ["Mend Pet"] = "Ends when the channel does.",
        ["Health Funnel"] = "Ends when the channel does.",
        ["Healing Stream Totem"] = "It lasts 5 minutes, so only its next 10 seconds show (5 ticks), on you and your party. "
            .. "Ends with the totem.",
        ["Lightwell"] = "The renew you get by clicking a Lightwell. Placing one heals no one.",
        ["Penance"] = "The two hits after the first, when cast on a friend.",
        ["Bandages"] = "First Aid. Ends when the channel does (damage interrupts it).",
        ["Food and drink"] = "Ends when you stand up (checked out of combat, which is when you eat).",
        ["Other"] = "Anything else of yours whose tooltip heals over time.",
    }
    local track = addTab("What to track")
    local function trackGroup(category)
        local on = function(s) return s("cat" .. category.id) ~= false end
        track:checkbox("cat" .. category.id, "|cffffd100" .. category.label .. "|r", { layout = CHECK_LAYOUT,
            tooltip = category.id == "Group" and "Contingency Plan isn't here: its tooltip gives no amounts, and it only "
                .. "starts below 35% health, which addons can't see." or nil })
        for _, spell in ipairs(category.spells) do
            track:checkbox(ns.spellKey("spell", spell), "    " .. spell,
                { layout = CHECK_LAYOUT, enabledIf = on, tooltip = NOTES[spell] })
        end
    end
    local columnOf = { Others = 1, Self = 1, Pet = 2, Group = 2, Items = 2 }
    local column
    for _, category in ipairs(ns.CATEGORIES) do
        if columnOf[category.id] ~= column then
            column = columnOf[category.id]
            track:column(column)
        else
            track:gap()
        end
        trackGroup(category)
    end

    local single = function(s) return s("hotColors") ~= "bySpell" end
    local bySpell = function(s) return s("hotColors") == "bySpell" end
    local bar = addTab("Bar")
    bar:choice("fillTexture", "Fill style", lists.fills, { tooltip = "The healing still to come, from the end of "
        .. "the green." })
    bar:choice("hotColors", "HoT colors", lists.hotColors, { tooltip = "One color for all your HoTs, or one "
        .. "segment per HoT in its own color." })
    bar:choice("healColor", "Heal color", lists.colors, { enabledIf = single })
    bar:info("", function() return bySpell(ns.setting) and "Colors per HoT: on the HoT colors tab." or "" end)
    bar:checkbox("segmentDividers", "Dividers between HoTs", { enabledIf = bySpell })
    bar:slider("healOpacity", "Opacity", 10, 100, 5, { suffix = "%" })

    local colors = addTab("HoT colors")
    local colorColumn
    for _, category in ipairs(ns.CATEGORIES) do
        local wanted = (category.id == "Others" or category.id == "Self") and 1 or 2
        if wanted ~= colorColumn then
            colorColumn = wanted
            colors:column(wanted)
        end
        colors:info("|cffffd100" .. category.label .. "|r", function() return "" end, { layout = COLOR_LAYOUT })
        for _, spell in ipairs(category.spells) do
            colors:choice(ns.spellKey("color", spell), "  " .. spell, lists.colors, { layout = COLOR_LAYOUT,
                enabledIf = bySpell })
        end
    end

    local hasOutline = function(s) return s("outlineStyle") ~= "none" end
    local outline = addTab("Outline")
    outline:choice("outlineStyle", "Outline", lists.outlines, { tooltip = "A line around the healing still to come." })
    outline:choice("dashLength", "Dash length", lists.dashLengths,
        { enabledIf = function(s) return s("outlineStyle") == "dashed" end })
    outline:slider("outlineThickness", "Thickness", 1, 4, 1, { enabledIf = hasOutline })
    outline:choice("outlineColor", "Color", lists.colors, { enabledIf = hasOutline })
    outline:slider("outlineOpacity", "Opacity", 10, 100, 5, { suffix = "%", enabledIf = hasOutline })
    outline:checkbox("pulseOutline", "Pulse outline", { enabledIf = hasOutline,
        tooltip = "Gently pulses the outline, glow and spark." })

    local effects = addTab("Effects")
    effects:checkbox("smoothMotion", "Smooth motion",
        { tooltip = "The bar grows in when a HoT lands and glides down at each tick instead of jumping." })
    effects:checkbox("flashOnApply", "Flash on new HoT")
    effects:checkbox("showSpark", "Spark", { tooltip = "A bright flare at the heal's end when a HoT lands." })
    effects:checkbox("showGlow", "Glow", { tooltip = "A soft glow inside the heal's edges, in the outline color "
        .. "(the heal color without an outline)." })
    effects:slider("glowSize", "Glow size", 2, 10, 1, { enabledIf = function(s) return s("showGlow") end })
    effects:checkbox("showShine", "Shine sweep")
    effects:slider("shineInterval", "Shine every", 2, 10, 1,
        { suffix = "s", enabledIf = function(s) return s("showShine") end })
    effects:checkbox("scrollStripes", "Scroll stripes", { tooltip = "Animates the diagonal stripes fill.",
        enabledIf = function(s) return s("fillTexture") == "stripes" and single(s) end })

    local hasOverheal = function(s) return s("showOverheal") end
    local hasIcon = function(s) return s("topOffIcon") ~= "none" end
    local over = addTab("Overheal & icon")
    over:checkbox("showOverheal", "Show overheal", { tooltip = "A strip along the bottom of the green for the "
        .. "healing that would go past full health." })
    over:choice("overhealColor", "Overheal color", lists.colors, { enabledIf = hasOverheal })
    over:slider("overhealOpacity", "Overheal opacity", 10, 100, 5, { suffix = "%", enabledIf = hasOverheal })
    over:slider("overhealHeight", "Overheal height", 10, 100, 5, { suffix = "%", enabledIf = hasOverheal,
        tooltip = "In % of the health bar's height. 100% covers the end of the green." })
    over:gap()
    over:choice("topOffIcon", "Tops off icon", lists.icons, { tooltip = "Shows at the right end of the health bar "
        .. "when your HoTs will fill it." })
    over:slider("iconSize", "Icon size", 50, 140, 10, { suffix = "%", enabledIf = hasIcon,
        tooltip = "In % of the health bar's height (it can't grow past the bar)." })
    over:checkbox("iconPulse", "Pulse the icon", { enabledIf = hasIcon })

    local showsText = function(s) return s("showText") end
    local icon = addTab("Text")
    icon:checkbox("showText", "Show heal text", { tooltip = "The healing still to come, like +830." })
    icon:choice("textPosition", "Text position", lists.textPositions, { enabledIf = showsText })
    icon:slider("textSize", "Text size", 7, 18, 1, { enabledIf = showsText })
    icon:choice("textColor", "Text color", lists.textColors, { enabledIf = showsText })

    local advanced = addTab("Advanced")
    advanced:checkbox("echo", "Echo log to chat", { tooltip = "Prints every log line (casts, estimates, drops) to "
        .. "chat. The log is saved to SavedVariables\\DoesItLive.lua on /reload or logout either way." })
    advanced:action("Your HoTs now", "List", function() SlashCmdList.DOESITLIVE("hots") end,
        { tooltip = "Lists what's tracked: spell, target, healing left and ticks. Same as /dil hots." })
    advanced:action("Test bar", "Show 800", function() SlashCmdList.DOESITLIVE("bar 800") end,
        { tooltip = "Shows a fixed 800 healing everywhere instead of your HoTs (/dil bar 800). Click Back to "
            .. "return to your HoTs." })
    local back = pushButton(controls[#controls], "Back", 70, function() SlashCmdList.DOESITLIVE("bar") end)
    back:SetPoint("LEFT", controls[#controls].button, "RIGHT", 6, 0)
    advanced:gap()
    advanced:action("All settings", "Reset", function()
        for key, value in pairs(ns.DEFAULTS) do db()[key] = value end
        changed()
        print("All settings reset.")
    end, { tooltip = "Puts every setting on every tab back to its default." })
end

local function buildPreview(pane)
    local title = pane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Live preview")

    -- Mock player frame: portrait on the left, name, health bar.
    local mock = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    mock:SetSize(PREVIEW_WIDTH - 24, 70)
    mock:SetPoint("TOP", pane, "TOP", 0, -40)
    setBackdrop(mock, 0.03)
    local portrait = mock:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(50, 50)
    portrait:SetPoint("LEFT", mock, "LEFT", 10, 0)
    portrait:SetTexture("Interface\\Icons\\Ability_Druid_TravelForm")
    local mask = mock:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(portrait)
    portrait:AddMaskTexture(mask)
    local healthBar = CreateFrame("StatusBar", nil, mock)
    healthBar:SetSize(PREVIEW_WIDTH - 100, 16)
    healthBar:SetPoint("LEFT", portrait, "RIGHT", 10, -6)
    healthBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    healthBar:SetStatusBarColor(0.1, 0.8, 0.1)
    healthBar:SetMinMaxValues(0, 100)
    local back = healthBar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0.08, 0.08, 0.08, 1)
    local name = mock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("BOTTOMLEFT", healthBar, "TOPLEFT", 0, 4)
    name:SetText("Your friend")
    window.healthBar = healthBar

    local health = sliderRow(pane, "Health", 0, 100, 1,
        function() return preview.health end,
        function(value)
            stopSimulation()
            preview.health = value
            updatePreview()
        end, { layout = PREVIEW_LAYOUT, suffix = "%" })
    health:SetPoint("TOPLEFT", mock, "BOTTOMLEFT", -4, -14)
    local heal = sliderRow(pane, "HoT healing", 0, 100, 1,
        function() return preview.heal end,
        function(value)
            stopSimulation()
            preview.heal = value
            updatePreview()
        end, { layout = PREVIEW_LAYOUT, suffix = "%", tooltip = "Healing your HoTs still have to do, in % of "
            .. "max health: a Rejuvenation (60%) and a Regrowth (40%)." })
    heal:SetPoint("TOPLEFT", health, "BOTTOMLEFT", 0, 0)

    window.simulateButton = pushButton(pane, "Simulate HoTs", 130, function()
        if simulation then stopSimulation() else startSimulation() end
    end)
    window.simulateButton:SetPoint("TOPLEFT", heal, "BOTTOMLEFT", 6, -10)

    window.status = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    window.status:SetPoint("TOPLEFT", window.simulateButton, "BOTTOMLEFT", 0, -14)
    window.status:SetWidth(PREVIEW_WIDTH - 30)
    window.status:SetJustifyH("LEFT")

    -- Mock friendly nameplate (green, like Blizzard's).
    local plateLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    plateLabel:SetPoint("TOPLEFT", window.status, "BOTTOMLEFT", 0, -20)
    plateLabel:SetText("Nameplate")
    local plate = CreateFrame("Frame", nil, pane)
    plate:SetSize(140, 26)
    plate:SetPoint("TOPLEFT", plateLabel, "BOTTOMLEFT", 50, -6)
    local plateName = plate:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    plateName:SetPoint("TOP", plate, "TOP")
    plateName:SetText("Your friend")
    local plateBar = CreateFrame("StatusBar", nil, plate)
    plateBar:SetSize(140, 10)
    plateBar:SetPoint("BOTTOM", plate, "BOTTOM")
    plateBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    plateBar:SetStatusBarColor(0.1, 0.8, 0.1)
    plateBar:SetMinMaxValues(0, 100)
    local plateBack = plateBar:CreateTexture(nil, "BACKGROUND")
    plateBack:SetAllPoints()
    plateBack:SetColorTexture(0.08, 0.08, 0.08, 1)
    window.plateBar = plateBar

    local function host(bar)
        return { bar = bar, area = bar, max = function() return 100 end, health = function() return preview.health end,
            amount = function() return preview.heal end,
            parts = function() -- two sample HoTs, for "A color per HoT"
                local parts = {}
                for i, sample in ipairs(PREVIEW_SPLIT) do parts[i] = { name = sample.name, amount = preview.heal * sample.share } end
                return parts
            end }
    end
    window.hosts = { frame = host(healthBar), plate = host(plateBar) }

    local hint = pane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 12, 12)
    hint:SetWidth(PREVIEW_WIDTH - 24)
    hint:SetJustifyH("LEFT")
    hint:SetText("Drawn by the same code as in game. Your real HoTs keep showing while this is open.")
end

local function createWindow()
    window = CreateFrame("Frame", "DoesItLiveOptions", UIParent, "BackdropTemplate")
    window:Hide()
    window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    setBackdrop(window, 0.06, 0.97)
    table.insert(UISpecialFrames, "DoesItLiveOptions") -- Escape closes it

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -18)
    title:SetText("DoesItLive")

    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -12)

    local presetLabel = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    local previous
    for i = #PRESETS, 1, -1 do
        local preset = PRESETS[i]
        local button = pushButton(window, preset.label, 72, function() applyPreset(preset) end)
        if previous then
            button:SetPoint("RIGHT", previous, "LEFT", -4, 0)
        else
            button:SetPoint("RIGHT", close, "LEFT", -8, 0)
        end
        previous = button
    end
    presetLabel:SetPoint("RIGHT", previous, "LEFT", -8, 0)
    presetLabel:SetText("Presets")

    local pane = CreateFrame("Frame", nil, window, "BackdropTemplate")
    pane:SetPoint("TOPLEFT", 10, -HEADER_HEIGHT)
    pane:SetPoint("BOTTOMLEFT", 10, 10)
    pane:SetWidth(PREVIEW_WIDTH)
    setBackdrop(pane, 0.09)
    buildPreview(pane)

    local area = CreateFrame("Frame", nil, window, "BackdropTemplate")
    area:SetPoint("TOPLEFT", pane, "TOPRIGHT", 10, 0)
    area:SetPoint("BOTTOMRIGHT", -10, 10)
    setBackdrop(area, 0.09)
    window.settingsArea = area

    local divider = area:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.28, 0.28, 0.3, 1)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 8, -34)
    divider:SetPoint("TOPRIGHT", -8, -34)

    buildTabs()
    local reset = pushButton(area, "Reset this tab", 120, function() resetTab(activeTab) end)
    reset:SetPoint("BOTTOMRIGHT", -10, 10)

    window:SetScript("OnShow", function()
        for name, host in pairs(window.hosts) do ns.display.setPreview(name, host) end
        refreshControls()
        updatePreview()
    end)
    window:SetScript("OnHide", function()
        stopSimulation()
        closeMenu()
        for name in pairs(window.hosts) do ns.display.setPreview(name, nil) end
    end)
    selectTab(tabs[1])
end

function ns.openOptions()
    if not db() then return end
    if not window then createWindow() end
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

-- Options > AddOns > DoesItLive: a short page with a button that opens the window.
function ns.registerOptions()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local panel = CreateFrame("Frame")
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("DoesItLive")
    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    text:SetText("Settings have their own window with a live preview. You can also type /dil.")
    local open = pushButton(panel, "Open DoesItLive options", 200, function()
        if SettingsPanel and SettingsPanel:IsShown() then pcall(HideUIPanel, SettingsPanel) end
        if not (window and window:IsShown()) then ns.openOptions() end
    end)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    local category = Settings.RegisterCanvasLayoutCategory(panel, "DoesItLive")
    Settings.RegisterAddOnCategory(category)
end
