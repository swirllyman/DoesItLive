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
-- Loaded after Tracking.lua.

local _, ns = ...

local isSecret, probe, call, out, inCombat = ns.isSecret, ns.probe, ns.call, ns.out, ns.inCombat
local WHITE = "Interface\\Buttons\\WHITE8X8"

local display = {}
ns.display = display

local TOPS_OFF_BAR_LENGTH = 10000
local HOST_CHECK_SECONDS = 1
local FALLBACK_WIDTH, FALLBACK_HEIGHT = 124, 15 -- when a host's size can't be read
local MAX_LAYER_FRAMES = 300

local testAmount -- /dil bar <n>: shown instead of the tracked HoTs

-- The healing to show on a unit (0: nothing).
local function amountFor(unit)
    if testAmount then return testAmount end
    if unit == nil then return 0 end
    return ns.tracking.remaining(unit)
end

local function nothingToShow()
    return not testAmount and not ns.tracking.any()
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
-- the whole unit frame (to layer above).
local function findInContent(main, fallback, frameName, frame)
    local container = main and main.HealthBarsContainer
    if container and container.HealthBar then
        -- Forever's bar is 20 tall in a 15 tall container; a mask hides the rest.
        return container.HealthBar, container, container.HealthBarMask, frameName .. " HealthBarsContainer.HealthBar", frame
    end
    local bar = (main and main.HealthBar) or fallback
    if bar then return bar, bar, nil, frameName .. " (older layout)", frame end
end

local function findPlayerBar()
    local content = PlayerFrame and PlayerFrame.PlayerFrameContent
    return findInContent(content and content.PlayerFrameContentMain, PlayerFrameHealthBar, "PlayerFrame", PlayerFrame)
end

local function findTargetBar()
    local content = TargetFrame and TargetFrame.TargetFrameContent
    return findInContent(content and content.TargetFrameContentMain, TargetFrameHealthBar, "TargetFrame", TargetFrame)
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
    -- Bottom to top. Levels are set one by one: siblings at equal depth would otherwise share a level, and the
    -- overheal drew over the plus.
    w.layers = { w.root, w.clip, w.healBar, w.strip, w.overBar, w.overClip, w.iconWindow, w.iconBar }
    return w
end

local widgets = {
    createWidget("player", "player", findPlayerBar),
    createWidget("personal", "player", findPersonalBar),
    createWidget("target", "target", findTargetBar),
}

local function sizeIcon(w, size)
    w.iconWindow:SetSize(size, size)
    w.iconBar:SetSize(TOPS_OFF_BAR_LENGTH, size)
    local long, thick = size - 4, math.max(2, math.floor(size / 5 + 0.5))
    local dims = { { long + 2, thick + 2 }, { thick + 2, long + 2 }, { long, thick }, { thick, long } }
    for i, texture in ipairs(w.plus) do
        texture:SetSize(dims[i][1], dims[i][2])
        texture:ClearAllPoints()
        texture:SetPoint("CENTER", w.iconFill, "RIGHT", -size / 2, 0)
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
        if w.plate then -- as in DoesItDie: the plate's strata, above its health bar
            local strata, level = plain(w.plate, "GetFrameStrata"), plain(w.bar, "GetFrameLevel")
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
    local stripHeight = math.max(3, math.floor(areaHeight * 0.3 + 0.5))
    local scale = plainSize(bar, "GetEffectiveScale") or 1
    local uiScale = plainSize(w.plate or UIParent, "GetEffectiveScale") or 1
    local signature = table.concat({ path, width, height, areaHeight, scale, uiScale }, "|")
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
        sizeIcon(w, math.max(8, math.floor(math.min(areaHeight, 18))))
    end)
    if ok and w.mask ~= mask then
        local maskOK, maskErr = pcall(function()
            for _, texture in ipairs({ w.healTex, w.overTex }) do
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

local function updateWidget(w)
    local amount = amountFor(w.unit)
    local hidden = amount <= 0 and "hidden, nothing to heal"
        or not w.attached and "hidden, not attached"
        or not canShow(w.unit) and "hidden, unit not friendly"
        or plain(w.bar, "IsVisible") == false and "hidden, its health bar isn't visible"
    if hidden then
        w.root:Hide()
        setState(w, hidden)
        return
    end
    local ok, err = pcall(function()
        local maxHealth = UnitHealthMax(w.unit)
        w.healBar:SetMinMaxValues(0, maxHealth)
        w.healBar:SetValue(amount)
        w.overBar:SetMinMaxValues(0, maxHealth)
        w.overBar:SetValue(amount)
        -- From -1, so full health (nothing missing) is still a range to fill, and counts as topped off.
        w.iconBar:SetMinMaxValues(-1, UnitHealthMissing(w.unit))
        w.iconBar:SetValue(amount)
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
    local db = ns.db()
    return not nothingToShow() and not (db and db.plates == false)
end

local function plateHealthBar(plate)
    local unitFrame = plate.UnitFrame
    if type(unitFrame) ~= "table" then return nil, "no UnitFrame" end
    local container = unitFrame.HealthBarsContainer
    if unitFrame.healthBar then return unitFrame.healthBar, "UnitFrame.healthBar" end
    if container and container.healthBar then return container.healthBar, "UnitFrame.HealthBarsContainer.healthBar" end
    if unitFrame.HealthBar then return unitFrame.HealthBar, "UnitFrame.HealthBar" end
    return nil, "no health bar in UnitFrame"
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
    local okBar, bar, path = pcall(plateHealthBar, plate)
    if not okBar or not bar or isForbidden(bar) then
        logPlate(unit, "plate ok, bar not reachable: " .. tostring(okBar and path or bar))
        return
    end
    local w = plateWidgets[plate]
    if not w then
        local created
        created, w = pcall(createWidget, "plate", unit, nil, plate)
        if not created then
            logPlate(unit, "widget ERROR " .. tostring(w))
            return
        end
        w.quiet = true
        w.find = function()
            local found, foundPath = plateHealthBar(plate)
            return found, found, nil, foundPath, plate
        end
        plateWidgets[plate] = w
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

local function hideAll()
    for _, w in ipairs(widgets) do
        w.root:Hide()
        setState(w, "hidden, nothing to heal")
    end
    for unit in pairs(activePlates) do releasePlate(unit) end
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
    if sinceUpdate < 0.1 then return end
    sinceUpdate = 0
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
end)

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
    db.plates = db.plates == false
    out("Heal bar on friendly nameplates " .. (db.plates and "ON" or "OFF") .. ".", true)
    refreshPlates()
end
