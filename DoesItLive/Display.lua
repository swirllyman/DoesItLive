-- DoesItLive display: the heal bar on the player frame, the personal resource display (the bars under the character)
-- and the target frame while the target is friendly, and on friendly nameplates (/dil plates). It shows what the
-- HoTs tracked in Tracking.lua still have to heal; /dil bar <amount> shows a fixed amount instead.
--
-- Everything stays inside the health bar. Lua never compares health (secret, even out of combat); the widgets do:
--   effective heal (teal): a bar the host's size pinned to the end of the green, clipped to the host
--   overheal (pale blue strip along the bottom, so the green stays readable): a reverse-filled bar spans the last
--     <heal> of the host; where it overlaps the green, that healing has nowhere to go
--   tops off (plus): a fill of <heal> out of the missing health, which stops at its full width once heal >= missing;
--     only the last icon-width of that very long bar is visible (same trick as DoesItDie's skull)
-- What it looks like and where it shows come from the settings (Settings.lua, set in Options.lua); the options
-- window's preview is a widget on a mock bar fed plain numbers (display.setPreview).
-- Loaded after Tracking.lua.

local _, ns = ...

local isSecret, probe, call, out, inCombat = ns.isSecret, ns.probe, ns.call, ns.out, ns.inCombat
local WHITE = "Interface\\Buttons\\WHITE8X8"

local display = {}
ns.display = display

local TOPS_OFF_BAR_LENGTH = 10000
local TEXTURE_DIR = "Interface\\AddOns\\DoesItLive\\Textures\\" -- made by tools/make_textures.py
local MAX_SEGMENTS = 8 -- per-HoT segments; more HoTs than this share the last one
local SMOOTH_RATE = 10 -- how fast the bar glides to a new value (higher = snappier)
local STRIPE_SCROLL_PERIOD = 8 -- px; the stripes repeat every 8px
local SHINE_WIDTH, SHINE_DURATION = 24, 0.9
local HOST_CHECK_SECONDS = 1
local FALLBACK_WIDTH, FALLBACK_HEIGHT = 124, 15 -- when a host's size can't be read
local MAX_LAYER_FRAMES = 300

local setting = ns.setting
local testAmount -- /dil bar <n>: shown instead of the tracked HoTs
local previews = {} -- the options window's mock bars
local lookVersion = 0 -- bumped when a setting changes, so each widget re-applies its look

-- Which setting turns each place on.
local PLACE_SETTING = { player = "showPlayer", personal = "showPersonal", target = "showTarget", plate = "showPlates",
    pet = "showPet", raid = "showRaid" }

local spellShown = ns.spellShown

-- The healing to show on a unit (0: nothing), and per HoT ({ name, amount } list, or nil).
local function amountFor(unit)
    if testAmount then return testAmount, nil end
    if unit == nil then return 0, nil end
    return ns.tracking.breakdown(unit, spellShown)
end

local function nothingToShow()
    return not testAmount and not ns.tracking.any() and next(previews) == nil
end

-- A plain value from region:method(), or nil if it errors or is secret.
local function plain(region, method, ...)
    if type(region) ~= "table" or type(region[method]) ~= "function" then return nil end
    local ok, value = pcall(region[method], region, ...)
    if not ok or isSecret(value) then return nil end
    return value
end

local function plainSize(region, method)
    local value = plain(region, method)
    return type(value) == "number" and value > 0 and value or nil
end

-- Each finder returns: the health bar, the region its visible part is limited to, its mask (or nil), the path, and
-- the whole unit frame (to layer above). In order: the Advanced tab's custom frame, a known replacement frame
-- (EllesmereUI's, BetterBlizzFrames' bigger bars), Blizzard's.
local function firstFound(...)
    for i = 1, select("#", ...) do
        local finder = select(i, ...)
        local found = { pcall(finder) }
        if found[1] and found[2] then return select(2, unpack(found)) end
    end
end

local function isBar(region)
    return type(region) == "table" and type(region.GetStatusBarTexture) == "function"
end

local function customFinder(key)
    return function()
        local path = setting(key)
        if type(path) ~= "string" or strtrim(path) == "" then return nil end
        local bar = ns.resolveFramePath(path)
        if isBar(bar) then return bar, bar, nil, "custom " .. strtrim(path), ns.frameRoot(bar) end
    end
end

-- EllesmereUI draws its own unit frames, globals named like these, with the bar at .Health (target and focus
-- verified by DoesItDie's users; player and pet follow the same naming, unverified: logAddonFrames shows what's there).
local ELLESMERE_FRAMES = { player = "EllesmereUIUnitFrames_Player", target = "EllesmereUIUnitFrames_Target",
    pet = "EllesmereUIUnitFrames_Pet" }

local function ellesmereFinder(kind)
    return function()
        local name = ELLESMERE_FRAMES[kind]
        local bar = ns.resolveFramePath(name .. ".Health")
        if isBar(bar) then return bar, bar, nil, name .. ".Health (EllesmereUI)", _G[name] end
    end
end

-- BetterBlizzFrames hides Blizzard's bar (alpha 0) and draws a bigger one of its own; BBF.HealthBar gives that one
-- while it's active, else Blizzard's (which the Blizzard finder handles, mask and all).
local function betterBlizzFinder(frame, blizzardBar)
    return function()
        local unitFrame, bar = frame(), nil
        if unitFrame then bar = ns.betterBlizzHealthBar(unitFrame) end
        if isBar(bar) and bar ~= blizzardBar() then return bar, bar, nil, "BetterBlizzFrames' health bar", unitFrame end
    end
end

local function findInContent(main, fallback, frameName, frame)
    local container = main and main.HealthBarsContainer
    if container and container.HealthBar then
        -- Forever's bar is 20 tall in a 15 tall container; a mask hides the rest.
        return container.HealthBar, container, container.HealthBarMask, frameName .. " HealthBarsContainer.HealthBar", frame
    end
    local bar = (main and main.HealthBar) or fallback
    if bar then return bar, bar, nil, frameName .. " (older layout)", frame end
end

local function findBlizzardPlayerBar()
    local content = PlayerFrame and PlayerFrame.PlayerFrameContent
    return findInContent(content and content.PlayerFrameContentMain, PlayerFrameHealthBar, "PlayerFrame", PlayerFrame)
end

local function findBlizzardTargetBar()
    local content = TargetFrame and TargetFrame.TargetFrameContent
    return findInContent(content and content.TargetFrameContentMain, TargetFrameHealthBar, "TargetFrame", TargetFrame)
end

local function findPlayerBar()
    return firstFound(customFinder("customPlayerBar"), ellesmereFinder("player"),
        betterBlizzFinder(function() return PlayerFrame end, function() return (findBlizzardPlayerBar()) end),
        findBlizzardPlayerBar)
end

local function findTargetBar()
    return firstFound(customFinder("customTargetBar"), ellesmereFinder("target"),
        betterBlizzFinder(function() return TargetFrame end, function() return (findBlizzardTargetBar()) end),
        findBlizzardTargetBar)
end

local function findBlizzardPetBar()
    local bar = PetFrameHealthBar or (PetFrame and PetFrame.healthbar)
    if bar then return bar, bar, PetFrameHealthBarMask, "PetFrameHealthBar", PetFrame end
end

local function findPetBar()
    return firstFound(customFinder("customPetBar"), ellesmereFinder("pet"), findBlizzardPetBar)
end

local function findPersonalBar()
    local prd = PersonalResourceDisplayFrame
    local container = prd and prd.HealthBarsContainer
    local bar = (container and (container.healthBar or container.healthbar)) or (prd and prd.healthbar)
    if bar then return bar, bar, nil, "PersonalResourceDisplayFrame health bar", prd end
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "player")
        local unitFrame = ok and type(plate) == "table" and plate.UnitFrame
        bar = unitFrame and (unitFrame.healthBar or unitFrame.HealthBar)
        if bar then return bar, bar, nil, "player nameplate UnitFrame.healthBar", plate end
    end
end

local function makeInvisibleBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    return bar, bar:GetStatusBarTexture()
end

-- parent: the nameplate, whose scale, fading and visibility the widget then follows; nil for the unit frames.
local function createWidget(name, unit, find, parent)
    local w = { name = name, unit = unit, find = find, plate = parent }

    w.root = CreateFrame("Frame", nil, parent or UIParent)
    w.root:Hide()
    w.clip = CreateFrame("Frame", nil, w.root) -- the host's visible area
    w.clip:SetClipsChildren(true)

    w.healBar, w.healFill = makeInvisibleBar(w.clip)
    w.healTex = w.healBar:CreateTexture(nil, "ARTWORK")
    w.healTex:SetColorTexture(0.3, 1, 0.8, 0.6)
    w.healTex:SetPoint("TOPLEFT", w.healFill, "TOPLEFT")
    w.healTex:SetPoint("BOTTOMRIGHT", w.healFill, "BOTTOMRIGHT")
    w.maskable = { w.healTex } -- every texture drawn inside the bar (the player and target bars are masked)

    -- A color per HoT: running-total bars (bar i filled to HoT 1 + ... + HoT i), each segment drawn from the end of
    -- the one before to the end of its own, so it's exactly that HoT's share on the (secret) health scale.
    w.segments = {}
    for i = 1, MAX_SEGMENTS do
        local bar, fillEnd = makeInvisibleBar(w.clip)
        local texture = w.healBar:CreateTexture(nil, "ARTWORK", nil, 1)
        texture:SetPoint("TOPLEFT", i == 1 and w.healFill or w.segments[i - 1].fillEnd, i == 1 and "TOPLEFT" or "TOPRIGHT")
        texture:SetPoint("BOTTOMRIGHT", fillEnd, "BOTTOMRIGHT")
        texture:Hide()
        local divider = w.healBar:CreateTexture(nil, "OVERLAY", nil, 1)
        divider:SetColorTexture(0, 0, 0, 0.85)
        divider:SetWidth(1)
        divider:SetPoint("TOP", fillEnd, "TOPRIGHT")
        divider:SetPoint("BOTTOM", fillEnd, "BOTTOMRIGHT")
        divider:Hide()
        w.segments[i] = { bar = bar, fillEnd = fillEnd, texture = texture, divider = divider }
        w.maskable[#w.maskable + 1] = texture
        w.maskable[#w.maskable + 1] = divider
    end

    -- Clipped to the heal: scrolling stripes and the shine sweep move across the whole bar but only show there.
    w.spanClip = CreateFrame("Frame", nil, w.clip)
    w.spanClip:SetPoint("TOPLEFT", w.healFill, "TOPLEFT")
    w.spanClip:SetPoint("BOTTOMRIGHT", w.healFill, "BOTTOMRIGHT")
    w.spanClip:SetClipsChildren(true)
    w.stripes = w.spanClip:CreateTexture(nil, "ARTWORK")
    w.stripes:SetTexture(TEXTURE_DIR .. "Stripes", "REPEAT", "REPEAT")
    w.stripes:SetHorizTile(true)
    w.stripes:SetVertTile(true)
    w.stripeScroll = w.stripes:CreateAnimationGroup()
    w.stripeScroll:SetLooping("REPEAT")
    local stripeMove = w.stripeScroll:CreateAnimation("Translation")
    stripeMove:SetOffset(STRIPE_SCROLL_PERIOD, 0)
    stripeMove:SetDuration(0.6)
    w.shine = w.spanClip:CreateTexture(nil, "OVERLAY")
    w.shine:SetTexture(TEXTURE_DIR .. "Shine")
    w.shine:SetBlendMode("ADD")
    w.shine:SetWidth(SHINE_WIDTH)
    w.shineSweep = w.shine:CreateAnimationGroup()
    w.shineSweep:SetLooping("REPEAT")
    w.shineMove = w.shineSweep:CreateAnimation("Translation")
    w.shineMove:SetDuration(SHINE_DURATION)
    w.shineMove:SetSmoothing("IN_OUT")
    w.maskable[#w.maskable + 1] = w.stripes
    w.maskable[#w.maskable + 1] = w.shine

    -- Outline, inner glow, flash and spark, around the heal span. The glow fades inward: outside the span it would
    -- be clipped away by the bar's edges.
    w.effects = CreateFrame("Frame", nil, w.clip)
    w.effects:SetAllPoints(w.clip)
    w.edges, w.glows = {}, {}
    local function edge(horizontal, point1, point2)
        local texture = w.effects:CreateTexture(nil, "OVERLAY", nil, 7)
        texture:SetPoint(point1, w.healFill, point1)
        texture:SetPoint(point2, w.healFill, point2)
        w.edges[#w.edges + 1] = { texture = texture, horizontal = horizontal }
        w.maskable[#w.maskable + 1] = texture
    end
    edge(true, "TOPLEFT", "TOPRIGHT")
    edge(true, "BOTTOMLEFT", "BOTTOMRIGHT")
    edge(false, "TOPLEFT", "BOTTOMLEFT")
    edge(false, "TOPRIGHT", "BOTTOMRIGHT")
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local texture = w.effects:CreateTexture(nil, "BORDER")
        texture:SetTexture(WHITE)
        texture:SetBlendMode("ADD")
        if side == "TOP" or side == "BOTTOM" then
            texture:SetPoint(side .. "LEFT", w.healFill, side .. "LEFT")
            texture:SetPoint(side .. "RIGHT", w.healFill, side .. "RIGHT")
        else
            texture:SetPoint("TOP" .. side, w.healFill, "TOP" .. side)
            texture:SetPoint("BOTTOM" .. side, w.healFill, "BOTTOM" .. side)
        end
        w.glows[#w.glows + 1] = { texture = texture, side = side }
        w.maskable[#w.maskable + 1] = texture
    end
    w.outlinePulse = w.effects:CreateAnimationGroup()
    w.outlinePulse:SetLooping("BOUNCE")
    local pulseAlpha = w.outlinePulse:CreateAnimation("Alpha")
    pulseAlpha:SetFromAlpha(1)
    pulseAlpha:SetToAlpha(0.3)
    pulseAlpha:SetDuration(0.9)
    pulseAlpha:SetSmoothing("IN_OUT")

    w.flash = w.effects:CreateTexture(nil, "OVERLAY")
    w.flash:SetPoint("TOPLEFT", w.healFill, "TOPLEFT")
    w.flash:SetPoint("BOTTOMRIGHT", w.healFill, "BOTTOMRIGHT")
    w.flash:SetColorTexture(1, 1, 1, 1)
    w.flash:SetBlendMode("ADD")
    w.flash:SetAlpha(0)
    w.flashAnim = w.flash:CreateAnimationGroup()
    local flashIn = w.flashAnim:CreateAnimation("Alpha")
    flashIn:SetFromAlpha(0)
    flashIn:SetToAlpha(0.7)
    flashIn:SetDuration(0.08)
    flashIn:SetOrder(1)
    local flashOut = w.flashAnim:CreateAnimation("Alpha")
    flashOut:SetFromAlpha(0.7)
    flashOut:SetToAlpha(0)
    flashOut:SetDuration(0.5)
    flashOut:SetSmoothing("OUT")
    flashOut:SetOrder(2)
    w.maskable[#w.maskable + 1] = w.flash

    w.spark = w.effects:CreateTexture(nil, "OVERLAY", nil, 6)
    w.spark:SetTexture(TEXTURE_DIR .. "Spark")
    w.spark:SetBlendMode("ADD")
    w.spark:SetWidth(12)
    w.spark:SetPoint("TOP", w.healFill, "TOPRIGHT")
    w.spark:SetPoint("BOTTOM", w.healFill, "BOTTOMRIGHT")
    w.spark:SetAlpha(0)
    w.sparkPunch = w.spark:CreateAnimationGroup()
    local sparkIn = w.sparkPunch:CreateAnimation("Alpha")
    sparkIn:SetFromAlpha(0)
    sparkIn:SetToAlpha(1)
    sparkIn:SetDuration(0.08)
    sparkIn:SetOrder(1)
    local sparkOut = w.sparkPunch:CreateAnimation("Alpha")
    sparkOut:SetFromAlpha(1)
    sparkOut:SetToAlpha(0)
    sparkOut:SetDuration(0.45)
    sparkOut:SetSmoothing("OUT")
    sparkOut:SetOrder(2)
    w.maskable[#w.maskable + 1] = w.spark

    w.strip = CreateFrame("Frame", nil, w.clip) -- the bottom of the visible area, for the overheal
    w.strip:SetClipsChildren(true)
    w.overBar, w.overFill = makeInvisibleBar(w.strip)
    w.overBar:SetReverseFill(true)
    w.overClip = CreateFrame("Frame", nil, w.overBar)
    w.overClip:SetPoint("TOPLEFT", w.overFill, "TOPLEFT")
    w.overClip:SetPoint("BOTTOMRIGHT", w.overFill, "BOTTOMRIGHT")
    w.overClip:SetClipsChildren(true)
    w.overTex = w.overClip:CreateTexture(nil, "ARTWORK")
    w.overTex:SetColorTexture(0.65, 0.85, 1, 0.95)
    w.maskable[#w.maskable + 1] = w.overTex

    w.iconWindow = CreateFrame("Frame", nil, w.clip)
    w.iconWindow:SetClipsChildren(true)
    w.iconBar, w.iconFill = makeInvisibleBar(w.iconWindow)
    w.iconBar:SetPoint("RIGHT", w.iconWindow, "RIGHT")
    -- The plus: a dark cross behind a light one, centered half an icon left of the fill's end.
    w.plus = {}
    for i = 1, 4 do
        local texture = w.iconBar:CreateTexture(nil, "OVERLAY", nil, i <= 2 and 1 or 2)
        if i <= 2 then texture:SetColorTexture(0, 0.15, 0.1, 1) else texture:SetColorTexture(0.85, 1, 0.95, 1) end
        w.plus[i] = texture
    end
    w.iconTex = w.iconBar:CreateTexture(nil, "OVERLAY", nil, 3) -- the picture icons
    w.iconTex:SetPoint("RIGHT", w.iconFill, "RIGHT")
    w.pulse = w.iconBar:CreateAnimationGroup()
    w.pulse:SetLooping("BOUNCE")
    local fade = w.pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(0.6)
    fade:SetSmoothing("IN_OUT")
    -- The text isn't clipped: "above the bar" is outside it.
    w.textLayer = CreateFrame("Frame", nil, w.root)
    w.textLayer:SetAllPoints(w.root)
    w.text = w.textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    -- Bottom to top. Levels are set one by one: siblings at equal depth would otherwise share a level, and the
    -- overheal drew over the plus.
    w.layers = { w.root, w.clip, w.healBar, w.spanClip, w.effects, w.strip, w.overBar, w.overClip, w.iconWindow,
        w.iconBar, w.textLayer }
    return w
end

local widgets = {
    createWidget("player", "player", findPlayerBar),
    createWidget("personal", "player", findPersonalBar),
    createWidget("target", "target", findTargetBar),
    createWidget("pet", "pet", findPetBar),
}

local function sizeIcon(w, size)
    w.iconWindow:SetSize(size, size)
    w.iconBar:SetSize(TOPS_OFF_BAR_LENGTH, size)
    w.iconTex:SetSize(size, size)
    local long, thick = size - 4, math.max(2, math.floor(size / 5 + 0.5))
    local dims = { { long + 2, thick + 2 }, { thick + 2, long + 2 }, { long, thick }, { thick, long } }
    for i, texture in ipairs(w.plus) do
        texture:SetSize(dims[i][1], dims[i][2])
        texture:ClearAllPoints()
        texture:SetPoint("CENTER", w.iconFill, "RIGHT", -size / 2, 0)
    end
end

local FONT_FALLBACK = "Fonts\\FRIZQT__.TTF"

-- Colors, opacities, icon and text from the settings. Sizes that depend on the host are set in attach.
local function setFill(texture, fill, r, g, b, a)
    texture:SetTexture(fill.path, fill.tiled and "REPEAT" or nil, fill.tiled and "REPEAT" or nil)
    texture:SetHorizTile(fill.tiled or false)
    texture:SetVertTile(fill.tiled or false)
    if fill.gradient and CreateColor then
        texture:SetVertexColor(1, 1, 1, 1)
        local ok = pcall(texture.SetGradient, texture, "HORIZONTAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, a))
        if not ok then texture:SetVertexColor(r, g, b, a) end
    else
        texture:SetVertexColor(r, g, b, a)
    end
end

local function applyLook(w)
    w.lookVersion = lookVersion
    local r, g, b = ns.colorOf("healColor")
    local opacity = setting("healOpacity") / 100
    local fill = ns.findEntry(ns.lists.fills, setting("fillTexture"))
    local bySpell = setting("hotColors") == "bySpell"
    -- Scrolling stripes are drawn by the moving texture in the span clip instead of the fill.
    local scrolling = fill.id == "stripes" and setting("scrollStripes") and not bySpell
    setFill(w.healTex, fill, r, g, b, opacity)
    w.healTex:SetShown(not bySpell and not scrolling)
    w.stripes:SetVertexColor(r, g, b, opacity)
    w.stripes:SetShown(scrolling)
    if scrolling then w.stripeScroll:Play() else w.stripeScroll:Stop() end
    -- Segments take the fill's texture, flat if it fades (the fade belongs to the whole heal).
    local segmentFill = fill.gradient and ns.lists.fills[1] or fill
    for _, segment in ipairs(w.segments) do
        segment.fill = segmentFill
        segment.texture:SetTexture(segmentFill.path, segmentFill.tiled and "REPEAT" or nil,
            segmentFill.tiled and "REPEAT" or nil)
        segment.texture:SetHorizTile(segmentFill.tiled or false)
        segment.texture:SetVertTile(segmentFill.tiled or false)
        if not bySpell then
            segment.texture:Hide()
            segment.divider:Hide()
        end
    end

    -- Outline
    local style = setting("outlineStyle")
    local or_, og, ob = ns.colorOf("outlineColor")
    local oa = setting("outlineOpacity") / 100
    for _, e in ipairs(w.edges) do
        local texture = e.texture
        if style == "dashed" then
            texture:SetTexture(TEXTURE_DIR .. (e.horizontal and "DashH" or "DashV") .. setting("dashLength"), "REPEAT", "REPEAT")
            texture:SetHorizTile(e.horizontal)
            texture:SetVertTile(not e.horizontal)
        else
            texture:SetTexture(WHITE)
            texture:SetHorizTile(false)
            texture:SetVertTile(false)
        end
        texture:SetVertexColor(or_, og, ob, oa)
        if e.horizontal then texture:SetHeight(setting("outlineThickness")) else texture:SetWidth(setting("outlineThickness")) end
        texture:SetShown(style ~= "none")
    end
    if setting("pulseOutline") then w.outlinePulse:Play() else w.outlinePulse:Stop() end

    -- Inner glow, in the outline color (the heal color without an outline)
    local gr, gg, gb = or_, og, ob
    if style == "none" then gr, gg, gb = r, g, b end
    local size = setting("glowSize")
    for _, glow in ipairs(w.glows) do
        local texture = glow.texture
        local inner, outer = CreateColor and CreateColor(gr, gg, gb, 0.7), CreateColor and CreateColor(gr, gg, gb, 0)
        if glow.side == "TOP" or glow.side == "BOTTOM" then texture:SetHeight(size) else texture:SetWidth(size) end
        if inner then
            if glow.side == "TOP" then pcall(texture.SetGradient, texture, "VERTICAL", outer, inner)
            elseif glow.side == "BOTTOM" then pcall(texture.SetGradient, texture, "VERTICAL", inner, outer)
            elseif glow.side == "LEFT" then pcall(texture.SetGradient, texture, "HORIZONTAL", inner, outer)
            else pcall(texture.SetGradient, texture, "HORIZONTAL", outer, inner) end
        end
        texture:SetShown(setting("showGlow"))
    end

    w.spark:SetVertexColor(math.min(1, r + 0.4), math.min(1, g + 0.4), math.min(1, b + 0.4), 1)
    w.spark:SetShown(setting("showSpark"))

    -- Shine sweep: from just left of the bar across it, then waits out the rest of the interval.
    w.shineSweep:Stop()
    w.shine:SetShown(setting("showShine"))
    if setting("showShine") then
        w.shineMove:SetOffset((w.lastWidth or FALLBACK_WIDTH) + SHINE_WIDTH, 0)
        w.shineMove:SetStartDelay(math.max(0, setting("shineInterval") - SHINE_DURATION))
        w.shineSweep:Play()
    end

    r, g, b = ns.colorOf("overhealColor")
    w.overTex:SetColorTexture(r, g, b, setting("overhealOpacity") / 100)
    w.strip:SetShown(setting("showOverheal"))
    local icon = ns.findEntry(ns.lists.icons, setting("topOffIcon"))
    for _, texture in ipairs(w.plus) do texture:SetShown(icon.id == "plus") end
    w.iconTex:SetShown(icon.path ~= nil)
    if icon.path then w.iconTex:SetTexture(icon.path) end
    w.iconWindow:SetShown(icon.id ~= "none")
    if setting("iconPulse") and icon.id ~= "none" then w.pulse:Play() else w.pulse:Stop() end
    local fontOK, font = pcall(function() return (GameFontHighlightSmall:GetFont()) end)
    w.text:SetFont(fontOK and type(font) == "string" and font or FONT_FALLBACK, setting("textSize"), "OUTLINE")
    w.text:SetTextColor(ns.colorOf("textColor", ns.lists.textColors))
    w.textLayer:SetShown(setting("showText"))
end

local function placeText(w, area)
    w.text:ClearAllPoints()
    local position = setting("textPosition")
    if position == "center" then
        w.text:SetPoint("CENTER", area, "CENTER")
    elseif position == "right" then
        w.text:SetPoint("RIGHT", w.iconWindow, "LEFT", -2, 0)
    elseif position == "above" then
        w.text:SetPoint("BOTTOMRIGHT", area, "TOPRIGHT", 0, 2)
    else
        w.text:SetPoint("LEFT", area, "LEFT", 4, 0)
    end
end

local STRATA_RANK = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

-- The highest strata and level anywhere in a unit frame (DoesItDie's way). The health bar's own level isn't enough:
-- it can be secret, Edit Mode re-layers the frames after addons load, and a click raises them.
local function topLayer(frame)
    local topStrata, topRank, level, visited, unreadable = "BACKGROUND", 1, 0, 0, 0
    local function visit(f, depth)
        visited = visited + 1
        if visited > MAX_LAYER_FRAMES then return end
        local s, l = plain(f, "GetFrameStrata"), plain(f, "GetFrameLevel")
        if STRATA_RANK[s or ""] and type(l) == "number" then
            local rank = STRATA_RANK[s]
            if rank > topRank then
                topStrata, topRank, level = s, rank, l
            elseif rank == topRank and l > level then
                level = l
            end
        else
            unreadable = unreadable + 1
        end
        if depth < 6 and type(f.GetChildren) == "function" then
            local children = { pcall(f.GetChildren, f) } -- [1] is whether it worked
            for i = 2, children[1] and #children or 1 do
                if visited > MAX_LAYER_FRAMES then break end
                -- One frame that can't be walked mustn't lose the rest.
                if type(children[i]) == "table" then pcall(visit, children[i], depth + 1) end
            end
        end
    end
    visit(frame, 0)
    return topStrata, level, visited, unreadable
end

local function updateLayer(w, frame)
    local ok, err = pcall(function()
        if w.preview then -- above the options window
            for i, layer in ipairs(w.layers) do
                layer:SetFrameStrata("FULLSCREEN")
                layer:SetFrameLevel(10 + i)
            end
            return
        end
        if w.plate then -- as in DoesItDie: the plate's strata, above its health bar
            local strata, level = plain(w.addonBar and w.bar or w.plate, "GetFrameStrata"), plain(w.bar, "GetFrameLevel")
            for i, layer in ipairs(w.layers) do
                if strata then layer:SetFrameStrata(strata) end
                if type(level) == "number" then layer:SetFrameLevel(math.min(level + 20 + i, 9999)) end
            end
            return
        end
        local strata, level, visited, unreadable = topLayer(frame)
        -- Being above the frame's own tree isn't enough: at LOW/1001, above every (readable) frame in PlayerFrame,
        -- the bar didn't show in-game (why is unknown); at MEDIUM it does. Never go below MEDIUM/1001.
        local found = strata .. "/" .. level
        if STRATA_RANK[strata] < STRATA_RANK.MEDIUM then
            strata, level = "MEDIUM", 1001
        elseif strata == "MEDIUM" then
            level = math.max(level, 1001)
        end
        level = math.min(level, 9900)
        for i, layer in ipairs(w.layers) do
            layer:SetFrameStrata(strata)
            layer:SetFrameLevel(level + i)
        end
        local signature = strata .. "/" .. level
        if signature ~= w.layerSignature then
            w.layerSignature = signature
            out(string.format("BAR %s layer: above %s (found %s, %d frames, %d unreadable; the bar itself: %s/%s)", w.name,
                signature, found, visited, unreadable, tostring(plain(w.bar, "GetFrameStrata") or "unreadable"),
                tostring(plain(w.bar, "GetFrameLevel") or "unreadable")))
        end
    end)
    if not ok and not w.layerErrorLogged then
        w.layerErrorLogged = true
        out("BAR " .. w.name .. " layer ERROR " .. tostring(err), true)
    end
end

-- Lays the widget over its host. Runs again whenever the host or its size or scale changes.
local function attach(w, bar, area, mask, path)
    local readWidth, readHeight = plainSize(bar, "GetWidth"), plainSize(bar, "GetHeight")
    local width = readWidth or w.lastWidth or FALLBACK_WIDTH
    local height = readHeight or w.lastHeight or FALLBACK_HEIGHT
    w.lastWidth, w.lastHeight = width, height
    local areaHeight = plainSize(area, "GetHeight") or height
    local stripHeight = math.max(2, math.floor(areaHeight * setting("overhealHeight") / 100 + 0.5))
    local scale = plainSize(bar, "GetEffectiveScale") or 1
    local uiScale = plainSize(w.plate or UIParent, "GetEffectiveScale") or 1
    local signature = table.concat({ path, width, height, areaHeight, scale, uiScale, lookVersion }, "|")
    if w.bar == bar and w.signature == signature then return true end
    local ok, err = pcall(function()
        local green = bar:GetStatusBarTexture()
        w.root:SetScale(scale / uiScale) -- the host's units (the personal bars have their own size setting)
        w.root:ClearAllPoints()
        w.root:SetAllPoints(area)
        w.clip:ClearAllPoints()
        w.clip:SetAllPoints(area)

        w.healBar:ClearAllPoints()
        w.healBar:SetPoint("TOPLEFT", green, "TOPRIGHT")
        w.healBar:SetPoint("BOTTOMLEFT", green, "BOTTOMRIGHT")
        w.healBar:SetWidth(width)
        for _, segment in ipairs(w.segments) do
            segment.bar:ClearAllPoints()
            segment.bar:SetPoint("TOPLEFT", green, "TOPRIGHT")
            segment.bar:SetPoint("BOTTOMLEFT", green, "BOTTOMRIGHT")
            segment.bar:SetWidth(width)
        end
        w.stripes:ClearAllPoints()
        w.stripes:SetPoint("TOPLEFT", bar, "TOPLEFT", -STRIPE_SCROLL_PERIOD * 2, 0)
        w.stripes:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
        w.shine:ClearAllPoints()
        w.shine:SetPoint("TOPRIGHT", bar, "TOPLEFT")
        w.shine:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT")

        w.strip:ClearAllPoints()
        w.strip:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT")
        w.strip:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT")
        w.strip:SetHeight(stripHeight + (mask and 1 or 0)) -- the mask hides about the bottom pixel
        w.overBar:ClearAllPoints()
        w.overBar:SetAllPoints(bar)
        w.overTex:ClearAllPoints()
        w.overTex:SetPoint("TOPLEFT", bar, "TOPLEFT")
        w.overTex:SetPoint("BOTTOMRIGHT", green, "BOTTOMRIGHT")

        w.iconWindow:ClearAllPoints()
        w.iconWindow:SetPoint("RIGHT", area, "RIGHT", -1, 0)
        sizeIcon(w, math.max(6, math.floor(math.min(areaHeight, 18) * setting("iconSize") / 100)))
        placeText(w, area)
    end)
    if ok and w.mask ~= mask then
        local maskOK, maskErr = pcall(function()
            for _, texture in ipairs(w.maskable) do
                if w.mask then texture:RemoveMaskTexture(w.mask) end
                if mask then texture:AddMaskTexture(mask) end
            end
        end)
        w.mask = mask
        if not maskOK then out("BAR " .. w.name .. " mask ERROR " .. tostring(maskErr), true) end
    end
    w.bar, w.area, w.signature = bar, area, signature
    if w.quiet and ok then return ok end
    out(string.format("BAR attach %s to %s %.1fx%.1f (size read %s, visible height %.1f, scale %.2f, mask %s): %s", w.name,
        path, width, height, readWidth and readHeight and "yes" or "NO", areaHeight, scale, mask and "yes" or "no",
        ok and "ok" or ("ERROR " .. tostring(err))), not ok)
    return ok
end

local function childKeys(frame)
    local keys = {}
    for k, v in pairs(frame) do
        if type(k) == "string" and type(v) == "table" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

local function logNotFound(w)
    if w.missingLogged then return end
    w.missingLogged = true
    local detail = ""
    if w.name == "personal" then
        pcall(function()
            if PersonalResourceDisplayFrame then
                detail = " PersonalResourceDisplayFrame keys: " .. childKeys(PersonalResourceDisplayFrame)
            end
        end)
    end
    out("BAR " .. w.name .. " health bar not found." .. detail, true)
end

local function checkHost(w)
    local ok, bar, area, mask, path, frame = pcall(w.find)
    if not ok or not bar then
        w.attached = false
        if not w.quiet then logNotFound(w) end
        return
    end
    w.attached = attach(w, bar, area, mask, path)
    updateLayer(w, frame or bar)
end

-- Only units you can assist: enemies are DoesItDie's.
local function canShow(unit)
    if unit == "preview" then return true end
    if unit == nil then return false end
    if unit == "player" then return true end
    local ok, assist = pcall(UnitCanAssist, "player", unit)
    return ok and not isSecret(assist) and assist == true
end

-- Why a bar isn't showing goes to the log, once per change.
local function setState(w, state)
    if w.state == state then return end
    w.state = state
    if w.quiet then return end
    out("BAR " .. w.name .. " state: " .. state)
end

local function describeRegion(region)
    local ok, left, bottom, width, height = pcall(region.GetRect, region)
    local rect = "no rect"
    if ok and left ~= nil then
        rect = string.format("%s,%s %sx%s", probe(left), probe(bottom), probe(width), probe(height))
    end
    return string.format("rect %s visible=%s alpha=%s layer=%s/%s", rect,
        tostring(plain(region, "IsVisible")), tostring(plain(region, "GetEffectiveAlpha") or "unreadable"),
        tostring(plain(region, "GetFrameStrata") or "unreadable"), tostring(plain(region, "GetFrameLevel") or "unreadable"))
end

-- Where everything really ended up, a second after a bar starts showing (an empty bar can be hidden, underneath,
-- elsewhere or clipped away, and these tell which).
local function logPlacement(w)
    C_Timer.After(1, function()
        if w.state ~= "shown" then return end
        pcall(function()
            for _, entry in ipairs({ { "host", w.bar }, { "area", w.area }, { "root", w.root }, { "clip", w.clip },
                { "strip", w.strip }, { "overClip", w.overClip }, { "iconWindow", w.iconWindow }, { "iconBar", w.iconBar } }) do
                out("BAR " .. w.name .. " " .. entry[1] .. ": " .. describeRegion(entry[2]))
            end
        end)
    end)
end

local animating = false -- some bar is still gliding: the driver then updates every frame

-- The amount drawn: glides toward the real one with "Smooth motion" (and grows in from nothing).
local function smoothed(w, target)
    local now = GetTime()
    local elapsed = now - (w.lastStep or now)
    w.lastStep = now
    if not setting("smoothMotion") then
        w.shownAmount = target
        return target
    end
    local shown = w.shownAmount or 0
    shown = shown + (target - shown) * math.min(1, elapsed * SMOOTH_RATE)
    if math.abs(target - shown) < 0.5 then shown = target end
    if shown ~= target then animating = true end
    w.shownAmount = shown
    return shown
end

local function updateWidget(w)
    local amount, parts
    if w.preview then
        amount, parts = w.preview.amount(), w.preview.parts and w.preview.parts()
    else
        amount, parts = amountFor(w.unit)
    end
    local place = PLACE_SETTING[w.name]
    local hidden = place and not setting(place) and "hidden, turned off in the options"
        or amount <= 0 and "hidden, nothing to heal"
        or not w.attached and "hidden, not attached"
        or not canShow(w.unit) and "hidden, unit not friendly"
        or plain(w.bar, "IsVisible") == false and "hidden, its health bar isn't visible"
    if hidden then
        w.root:Hide()
        w.shownAmount, w.lastTarget = 0, 0
        setState(w, hidden)
        return
    end
    if w.lookVersion ~= lookVersion then applyLook(w) end
    -- A new HoT (more healing to come than a moment ago): flash and spark.
    if amount > (w.lastTarget or 0) + 0.5 then
        if setting("flashOnApply") then
            w.flashAnim:Stop()
            w.flashAnim:Play()
        end
        if setting("showSpark") then
            w.sparkPunch:Stop()
            w.sparkPunch:Play()
        end
    end
    w.lastTarget = amount
    local shown = smoothed(w, amount)
    local scale = amount > 0 and shown / amount or 0
    local ok, err = pcall(function()
        local maxHealth, missing
        if w.preview then
            maxHealth, missing = w.preview.max(), w.preview.max() - w.preview.health()
        else
            maxHealth, missing = UnitHealthMax(w.unit), UnitHealthMissing(w.unit)
        end
        w.text:SetText(string.format("+%d", math.floor(amount + 0.5)))
        w.healBar:SetMinMaxValues(0, maxHealth)
        w.healBar:SetValue(shown)
        local bySpell = setting("hotColors") == "bySpell" and parts ~= nil
        local total, opacity = 0, setting("healOpacity") / 100
        for i, segment in ipairs(w.segments) do
            local part = bySpell and parts[i]
            if part then
                total = total + part.amount * scale
                if i == MAX_SEGMENTS then -- the rest share the last segment
                    for j = i + 1, #parts do total = total + parts[j].amount * scale end
                end
                segment.bar:SetMinMaxValues(0, maxHealth)
                segment.bar:SetValue(total)
                local r, g, b = ns.colorOf(ns.spellKey("color", ns.displayGroup(part.name)))
                segment.texture:SetVertexColor(r, g, b, opacity)
                segment.texture:Show()
                segment.divider:SetShown(setting("segmentDividers") and parts[i + 1] ~= nil and i < MAX_SEGMENTS)
            else
                segment.texture:Hide()
                segment.divider:Hide()
            end
        end
        -- Without per-HoT parts (the test bar) the one color fills in, even in "a color per HoT".
        local wantsSingle = not bySpell
        if wantsSingle ~= (w.healTex:IsShown() or w.stripes:IsShown()) then
            local fill = ns.findEntry(ns.lists.fills, setting("fillTexture"))
            local scrolling = fill.id == "stripes" and setting("scrollStripes")
            w.healTex:SetShown(wantsSingle and not scrolling)
            w.stripes:SetShown(wantsSingle and scrolling)
        end
        w.overBar:SetMinMaxValues(0, maxHealth)
        w.overBar:SetValue(shown)
        -- From -1, so full health (nothing missing) is still a range to fill, and counts as topped off.
        w.iconBar:SetMinMaxValues(-1, missing)
        w.iconBar:SetValue(shown)
        if not w.plate then w.root:SetAlpha(plain(w.bar, "GetEffectiveAlpha") or 1) end
    end)
    w.root:SetShown(ok)
    if ok and w.state ~= "shown" then logPlacement(w) end
    setState(w, ok and "shown" or "hidden, update failed")
    if not ok and not w.errorLogged then
        w.errorLogged = true
        out("BAR update " .. w.name .. " ERROR " .. tostring(err), true)
    end
end

-- Friendly nameplates: one widget per plate frame (Blizzard reuses the frames for other units).
local MAX_PLATE_LOG_LINES = 60
local plateWidgets = setmetatable({}, { __mode = "k" }) -- plate frame -> widget
local activePlates = {} -- nameplate unit -> widget
local failedPlates = {} -- nameplate unit -> true: nothing to draw on, don't try again until it's another unit
local plateLogLines, platePlacementLogged = 0, false

local function platesWanted()
    return not nothingToShow() and setting("showPlates") and true or false
end

-- Nameplate addons (from DoesItDie's Nameplates.lua, where each is verified or noted): the health bar a plate shows,
-- the frame our widget goes on, where it was found, and whether it's an addon's bar (drawn in its own strata).
local function barShown(bar)
    local ok, visible = pcall(bar.IsVisible, bar)
    if ok and not isSecret(visible) and visible == false then return false end
    local okAlpha, alpha = pcall(bar.GetEffectiveAlpha, bar)
    if okAlpha and type(alpha) == "number" and not isSecret(alpha) and alpha <= 0 then return false end
    return true
end

local function isStatusBar(value)
    if type(value) ~= "table" or type(value.GetObjectType) ~= "function" then return false end
    local ok, kind = pcall(value.GetObjectType, value)
    return ok and kind == "StatusBar"
end

local function forbiddenFrame(frame)
    local ok, result = pcall(function() return frame.IsForbidden and frame:IsForbidden() end)
    return not ok or result == true
end

-- The Advanced tab's nameplate keys, from Blizzard's plate: "UnitFrame.healthBar".
local function resolveFromPlate(plate, path)
    local current = plate
    for key in string.gmatch(path, "[^%.]+") do
        local ok, value = pcall(function() return current[key] end)
        if not ok or type(value) ~= "table" then return nil end
        current = value
    end
    if current ~= plate and isStatusBar(current) then return current end
end

-- Platynator: its display frames are reassigned between units and may hang off UIParent; the active one for a
-- unit has .unit and a health widget with .statusBar. Scanned (throttled) when a unit has none.
local platyDisplays, platyLastScan = {}, -math.huge
local function platyBarFor(unit)
    for frame in pairs(platyDisplays) do
        if frame.unit == unit and frame:IsShown() and type(frame.widgets) == "table" then
            for _, widget in ipairs(frame.widgets) do
                if type(widget.details) == "table" and widget.details.kind == "health" and widget.statusBar then
                    return widget.statusBar
                end
            end
        end
    end
end
local function findPlatynatorBar(plate, unit)
    if not (Platynator and unit) then return nil end
    local bar = platyBarFor(unit)
    if bar or GetTime() - platyLastScan < 2 then return bar end
    platyLastScan = GetTime()
    for _, parent in ipairs({ UIParent, plate }) do
        for _, child in ipairs({ parent:GetChildren() }) do
            if type(child.widgets) == "table" and type(child.Install) == "function" and type(child.SetUnit) == "function" then
                platyDisplays[child] = true
            end
        end
    end
    return platyBarFor(unit)
end

-- Threat Plates: its plate frame hangs off WorldFrame; the plate references it while active.
local function findThreatPlatesBar(plate)
    local tp = plate.TPFrame
    if type(tp) ~= "table" or not tp.Active or type(tp.visual) ~= "table" then return nil end
    local bar = tp.visual.Healthbar or tp.visual.healthbar
    if isStatusBar(bar) and not forbiddenFrame(bar) and barShown(bar) then return bar end
end

-- Other plate addons (Plater, KUI, ...): a shown StatusBar under a field named like "health" among the frames
-- inside the plate (breadth-first, Blizzard's UnitFrame skipped, each field under its own pcall), cached per plate
-- and searched again at most once a second.
local searchCache = setmetatable({}, { __mode = "k" })
local function isUnder(frame, plate)
    local current = frame
    for _ = 1, 12 do
        local ok, parent = pcall(current.GetParent, current)
        if not ok or parent == nil then return false end
        if parent == plate then return true end
        current = parent
    end
    return false
end
local function tableFields(container, plainTable)
    local ok, fields = pcall(function()
        local found, count = {}, 0
        for key, value in pairs(container) do
            count = count + 1
            if plainTable and count > 200 then return nil end
            if type(key) == "string" and type(value) == "table" then found[#found + 1] = { key, value } end
        end
        return found
    end)
    if not ok or not fields then return nil end
    table.sort(fields, function(a, b) return a[1] < b[1] end)
    return fields
end
local function searchHealthBar(plate)
    local blizzardBar = plate.UnitFrame and plate.UnitFrame.healthBar
    local queue, seen, head = { { node = plate, path = "", depth = 0, plainTable = false } }, { [plate] = true }, 1
    while queue[head] do
        local item = queue[head]
        head = head + 1
        local fields = tableFields(item.node, item.plainTable)
        if fields then
            for _, field in ipairs(fields) do
                local key, value = field[1], field[2]
                local ok, found = pcall(function()
                    return key:lower():find("health", 1, true) and value ~= blizzardBar and isStatusBar(value)
                        and not forbiddenFrame(value) and isUnder(value, plate) and barShown(value)
                end)
                if ok and found then return value, item.path .. key end
            end
            if item.depth < 4 then
                for _, field in ipairs(fields) do
                    local value = field[2]
                    if not seen[value] and value ~= plate.UnitFrame then
                        seen[value] = true
                        local isFrameValue = pcall(function() return value:GetObjectType() end)
                        local ok, visit = pcall(function()
                            if isFrameValue then
                                return not isStatusBar(value) and not forbiddenFrame(value) and isUnder(value, plate)
                            end
                            return true
                        end)
                        if ok and visit then
                            queue[#queue + 1] = { node = value, path = item.path .. field[1] .. ".", depth = item.depth + 1,
                                plainTable = not isFrameValue }
                        end
                    end
                end
            end
        end
    end
end
local function autoHealthBar(plate)
    local cached, now = searchCache[plate], GetTime()
    if cached and cached.bar and barShown(cached.bar) then return cached.bar, cached.path end
    if cached and now - cached.at < 1 then return nil end
    local ok, bar, path = pcall(searchHealthBar, plate)
    if not ok then bar, path = nil, nil end
    searchCache[plate] = { bar = bar, path = path, at = now }
    return bar, path
end

-- In order: the custom keys, EllesmereUI's own plate (our widget goes on it, to fade and scale with it),
-- Platynator, Threat Plates, Blizzard's bar while shown, the automatic search. Nothing when only a hidden bar is left.
local function plateHealthBar(plate, unit)
    local custom = strtrim(setting("customPlateBar") or "")
    if custom ~= "" then
        local bar = resolveFromPlate(plate, custom)
        if bar and barShown(bar) then return bar, "custom " .. custom, plate, true end
    end
    local eui = EllesmereNameplates_NS
    local euiPlate = type(eui) == "table" and type(eui.plates) == "table" and unit and eui.plates[unit]
    if type(euiPlate) == "table" and euiPlate.nameplate == plate and isBar(euiPlate.health) then
        return euiPlate.health, "EllesmereUI plate.health", euiPlate, true
    end
    local okPlaty, platyBar = pcall(findPlatynatorBar, plate, unit)
    if okPlaty and platyBar then return platyBar, "Platynator health widget", plate, true end
    local okTP, tpBar = pcall(findThreatPlatesBar, plate)
    if okTP and tpBar then return tpBar, "Threat Plates TPFrame.visual.Healthbar", plate, true end
    local unitFrame = plate.UnitFrame
    if type(unitFrame) == "table" then
        local container = unitFrame.HealthBarsContainer
        local bar, path
        if unitFrame.healthBar then
            bar, path = unitFrame.healthBar, "UnitFrame.healthBar"
        elseif container and container.healthBar then
            bar, path = container.healthBar, "UnitFrame.HealthBarsContainer.healthBar"
        elseif unitFrame.HealthBar then
            bar, path = unitFrame.HealthBar, "UnitFrame.HealthBar"
        end
        if bar and barShown(bar) then return bar, path, plate, false end
    end
    local found, path = autoHealthBar(plate)
    if found then return found, "auto " .. path, plate, true end
    return nil, type(unitFrame) == "table" and "no shown health bar (a plate addon this can't read?)" or "no UnitFrame"
end

local function isForbidden(frame)
    local ok, forbidden = pcall(function() return frame.IsForbidden and frame:IsForbidden() end)
    return not ok or (isSecret(forbidden) or forbidden == true)
end

local function logPlate(unit, what)
    plateLogLines = plateLogLines + 1
    if plateLogLines > MAX_PLATE_LOG_LINES then return end
    local inInstance, instanceType = "?", "?"
    if IsInInstance then
        local ok, a, b = pcall(IsInInstance)
        if ok then inInstance, instanceType = probe(a), probe(b) end
    end
    out(string.format("PLATE %s %s assist=%s instance=%s (%s) combat=%s", tostring(unit), what,
        call("UnitCanAssist", "player", unit), inInstance, instanceType, tostring(inCombat())))
end

local function releasePlate(unit)
    local w = activePlates[unit]
    if not w then return end
    activePlates[unit] = nil
    w.unit, w.state = nil, nil
    w.root:Hide()
end

local function addPlate(unit)
    if not platesWanted() or type(unit) ~= "string" or isSecret(unit) then return end
    if activePlates[unit] or failedPlates[unit] or amountFor(unit) <= 0 then return end
    failedPlates[unit] = true -- until it works out
    local okSelf, isSelf = pcall(UnitIsUnit, unit, "player")
    if okSelf and not isSecret(isSelf) and isSelf == true then return end -- the personal bars are drawn already
    if not canShow(unit) then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or type(plate) ~= "table" then
        -- In instances the client may keep friendly plates from addons entirely.
        local okAll, hiddenPlate = pcall(C_NamePlate.GetNamePlateForUnit, unit, true)
        logPlate(unit, "plate not reachable" .. (okAll and type(hiddenPlate) == "table" and " (forbidden)" or ""))
        return
    end
    if isForbidden(plate) then
        logPlate(unit, "plate forbidden")
        return
    end
    local okBar, bar, path, host, addonBar = pcall(plateHealthBar, plate, unit)
    if not okBar or not bar or isForbidden(bar) then
        logPlate(unit, "plate ok, bar not reachable: " .. tostring(okBar and path or bar))
        return
    end
    local w = plateWidgets[host]
    if not w then
        local created
        created, w = pcall(createWidget, "plate", unit, nil, host)
        if not created then
            logPlate(unit, "widget ERROR " .. tostring(w))
            return
        end
        w.quiet = true
        plateWidgets[host] = w
    end
    w.addonBar = addonBar
    w.find = function()
        local found, foundPath = plateHealthBar(plate, w.unit)
        return found, found, nil, foundPath, plate
    end
    w.unit, w.errorLogged, w.layerErrorLogged = unit, false, false
    activePlates[unit] = w
    failedPlates[unit] = nil
    checkHost(w)
    if not platePlacementLogged then
        platePlacementLogged = true
        w.quiet = false -- the first plate's placement is logged in full
        updateWidget(w)
        w.quiet = true
    else
        w.state = "shown" -- skips the placement log
        updateWidget(w)
    end
    logPlate(unit, string.format("plate ok, bar %s visible=%s drawn=%s", path, tostring(plain(bar, "IsVisible")),
        tostring(w.state)))
end

local function refreshPlates()
    if not platesWanted() then
        for unit in pairs(activePlates) do releasePlate(unit) end
        return
    end
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    for i = 1, 40 do
        if UnitExists("nameplate" .. i) then addPlate("nameplate" .. i) end
    end
end

-- Blizzard's party and raid frames (CompactUnitFrames: .unit and .healthBar). Frames are handed other units as the
-- group changes, so they're scanned once a second and on roster changes; only frames whose unit has heals get a
-- widget, and only those are updated (a walk over every frame every update made DoesItDie stutter, its issue #36).
local RAID_FRAME_NAMES = {}
for i = 1, 5 do
    RAID_FRAME_NAMES[#RAID_FRAME_NAMES + 1] = "CompactPartyFrameMember" .. i
    RAID_FRAME_NAMES[#RAID_FRAME_NAMES + 1] = "CompactPartyFramePet" .. i
end
for group = 1, 8 do
    for member = 1, 5 do RAID_FRAME_NAMES[#RAID_FRAME_NAMES + 1] = "CompactRaidGroup" .. group .. "Member" .. member end
end
for i = 1, 80 do RAID_FRAME_NAMES[#RAID_FRAME_NAMES + 1] = "CompactRaidFrame" .. i end

local raidWidgets = setmetatable({}, { __mode = "k" }) -- frame -> widget
local activeRaid = {} -- frame -> widget, while its unit has heals to show
local raidLogged = false

local function frameUnit(frame)
    local ok, unit = pcall(function() return frame.displayedUnit or frame.unit end)
    if not ok or type(unit) ~= "string" or isSecret(unit) or unit == "" then return nil end
    return unit
end

local function releaseRaid(frame)
    local w = activeRaid[frame]
    if not w then return end
    activeRaid[frame] = nil
    w.unit, w.state = nil, nil
    w.root:Hide()
end

local function scanRaidFrames()
    local wanted = not nothingToShow() and setting("showRaid")
    for _, name in ipairs(RAID_FRAME_NAMES) do
        local frame = _G[name]
        if type(frame) == "table" then
            local unit = wanted and plain(frame, "IsVisible") ~= false and frameUnit(frame)
            if unit and amountFor(unit) > 0 and type(frame.healthBar) == "table" then
                local w = raidWidgets[frame]
                if not w then
                    w = createWidget("raid", unit, function()
                        return frame.healthBar, frame.healthBar, nil, name .. ".healthBar", frame
                    end)
                    w.quiet = true
                    raidWidgets[frame] = w
                    if not raidLogged then
                        raidLogged = true
                        out("BAR raid frames: drawing on " .. name .. " (" .. unit .. ")")
                    end
                end
                if w.unit ~= unit then w.lastTarget, w.shownAmount = 0, 0 end
                w.unit = unit
                activeRaid[frame] = w
                checkHost(w)
            else
                releaseRaid(frame)
            end
        end
    end
end

local function hideAll()
    for frame in pairs(activeRaid) do releaseRaid(frame) end
    for _, w in ipairs(widgets) do
        w.root:Hide()
        w.shownAmount, w.lastTarget = 0, 0
        setState(w, "hidden, nothing to heal")
    end
    for unit in pairs(activePlates) do releasePlate(unit) end
    for _, w in pairs(previews) do w.root:Hide() end
end

local driver = CreateFrame("Frame")
local sinceUpdate, sinceCheck, showing = 0, 0, false
driver:SetScript("OnUpdate", function(_, elapsed)
    if nothingToShow() then
        if showing then
            showing = false
            hideAll()
        end
        return
    end
    if not showing then
        showing, sinceCheck = true, HOST_CHECK_SECONDS -- find the frames right away
    end
    sinceUpdate, sinceCheck = sinceUpdate + elapsed, sinceCheck + elapsed
    if sinceUpdate < (animating and 0 or 0.1) then return end
    sinceUpdate = 0
    animating = false
    local check = sinceCheck >= HOST_CHECK_SECONDS
    if check then sinceCheck = 0 end
    for _, w in ipairs(widgets) do
        if check then checkHost(w) end
        updateWidget(w)
    end
    if check then refreshPlates() end
    for _, w in pairs(activePlates) do
        if check then checkHost(w) end
        updateWidget(w)
    end
    if check then scanRaidFrames() end
    for _, w in pairs(activeRaid) do updateWidget(w) end
    for _, w in pairs(previews) do updateWidget(w) end
end)

-- What each place is drawing on, for the Advanced tab ("not found" before it's been looked for).
function display.status(name)
    for _, w in ipairs(widgets) do
        if w.name == name then
            if not w.bar then
                local ok, _, _, _, path = pcall(w.find)
                return ok and path and ("|cff888888" .. path .. " (not drawn yet)|r") or "|cff888888not found|r"
            end
            local path = (w.signature or ""):match("^([^|]*)")
            if path and path:find("^custom ") then return "|cff66ff66" .. path:sub(8) .. "|r" end
            return path or "?"
        end
    end
    return "?"
end

-- Logs (once, a few seconds after loading) which EllesmereUI frames exist, so their names can be checked.
function display.logAddonFrames()
    if type(EllesmereUI) ~= "table" and type(EllesmereNameplates_NS) ~= "table"
        and type(_G.EllesmereUIUnitFrames_Target) ~= "table" then return end
    local found = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and name:find("^EllesmereUI") and type(value) == "table"
            and type(value.GetObjectType) == "function" then
            found[#found + 1] = name .. (isBar(value.Health) and " (.Health)" or "")
            if #found >= 60 then break end
        end
    end
    table.sort(found)
    out("ADDON EllesmereUI frames: " .. (#found > 0 and table.concat(found, ", ") or "none found"))
end

function display.onTargetChanged()
    if nothingToShow() then return end
    for _, w in ipairs(widgets) do
        if w.unit == "target" then
            checkHost(w)
            updateWidget(w)
        end
    end
end

-- Something changed (a HoT came or went): update now instead of at the next tenth of a second.
function display.refresh()
    if nothingToShow() then
        showing = false
        hideAll()
        return
    end
    showing = true
    for _, w in ipairs(widgets) do
        checkHost(w)
        updateWidget(w)
    end
    refreshPlates()
    for _, w in pairs(activePlates) do updateWidget(w) end
    scanRaidFrames()
    for _, w in pairs(activeRaid) do updateWidget(w) end
    for _, w in pairs(previews) do
        checkHost(w)
        updateWidget(w)
    end
end

-- The group changed: the party and raid frames may show other units now.
function display.onRosterChanged()
    if nothingToShow() then return end
    scanRaidFrames()
    for _, w in pairs(activeRaid) do updateWidget(w) end
end

-- A setting changed: every widget re-applies its look and re-lays itself over its host.
function display.settingsChanged()
    lookVersion = lookVersion + 1
    for unit in pairs(failedPlates) do failedPlates[unit] = nil end
    if not setting("showPlates") then
        for unit in pairs(activePlates) do releasePlate(unit) end
    end
    display.refresh()
end

local previewWidgets = {} -- by name, kept between openings of the window

-- The options window's preview: name -> { bar, area, health(), max(), amount() } of plain numbers, or nil to stop.
function display.setPreview(name, host)
    local w = previewWidgets[name]
    if not host then
        previews[name] = nil
        if w then w.root:Hide() end
        display.refresh()
        return
    end
    if not w then
        w = createWidget("preview " .. name, "preview", nil, nil)
        w.quiet = true
        previewWidgets[name] = w
    end
    w.preview = host
    w.find = function() return host.bar, host.area or host.bar, nil, "options preview " .. name, nil end
    w.signature = nil
    previews[name] = w
    display.refresh()
end

function display.onPlateAdded(unit)
    if type(unit) ~= "string" or isSecret(unit) then return end
    releasePlate(unit)
    failedPlates[unit] = nil
    addPlate(unit)
end

function display.onPlateRemoved(unit)
    if type(unit) ~= "string" or isSecret(unit) then return end
    releasePlate(unit)
    failedPlates[unit] = nil
end

function display.setTestBar(amount)
    if amount and amount <= 0 then amount = nil end
    testAmount = amount
    for _, w in ipairs(widgets) do
        w.errorLogged, w.missingLogged, w.layerErrorLogged, w.state, w.layerSignature = false, false, false, nil, nil
    end
    plateLogLines, platePlacementLogged = 0, false
    for unit in pairs(activePlates) do releasePlate(unit) end
    for unit in pairs(failedPlates) do failedPlates[unit] = nil end
    display.refresh()
    if amount then
        out(string.format("Test heal bar: a fixed %d healing on your player frame, personal resource bar, friendly target and friendly nameplates (not your HoTs). Teal = will heal, pale blue strip = overheal, plus = tops off. /dil bar to go back to your HoTs.", amount), true)
    else
        out("Test heal bar off: showing your HoTs.", true)
    end
end

function display.togglePlates()
    local db = ns.db()
    if not db then return end
    db.showPlates = not setting("showPlates")
    out("Heal bar on friendly nameplates " .. (db.showPlates and "ON" or "OFF") .. ".", true)
    display.settingsChanged()
end
