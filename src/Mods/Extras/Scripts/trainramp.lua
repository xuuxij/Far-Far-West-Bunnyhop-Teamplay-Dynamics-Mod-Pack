-- More enemies after the train: once the extraction train has pulled in and
-- waits for everyone to board, the enemy waves spawn 25% faster every step
-- (picked in OPTIONS: 30 s to 3 min), up to 4x. Each step shows on every
-- player's screen as a big red "1.6x" that slowly fades.
-- Only the host's game runs the waves, so only the host's switch and step
-- count. The host's copy shows its own step straight away and sends it as a
-- team-chat line ("ENEMY SPAWNS 1.6x"); every other copy of this mod spots
-- that line and shows the same big text (as the kill streaks do).
-- How the waves are sped up: a storm wave (BP_Event_Storm and the train
-- waves built on it) spawns each enemy tier on a looping timer it sets by
-- function name (F_SpawnEasy, F_SpawnNormal, F_SpawnHard, F_SpawnVeryHard),
-- every base delay x player-count curve x difficulty curve seconds. Setting a
-- timer again by the same name replaces it, so a step sets the running ones
-- again with a shorter time. A timer's interval is its elapsed plus its
-- remaining time; when the game sets one again itself, that is its new base.

local UEHelpers = require("UEHelpers")

local M = {}

local TRAIN_CLASS = "/Game/GPE/Assets/Train/BP_TrainExtraction.BP_TrainExtraction_C"
local WAVE_CLASS = "/Game/Events/BP_Event_Storm.BP_Event_Storm_C"
local SPAWN_FNS = { "F_SpawnEasy", "F_SpawnNormal", "F_SpawnHard", "F_SpawnVeryHard" }
-- The step time, picked from a dropdown in OPTIONS (its number is kept under "trainstep").
M.STEP_CHOICES = {
    { name = "30 s", seconds = 30 }, { name = "1 min", seconds = 60 }, { name = "1 min 30 s", seconds = 90 },
    { name = "2 min", seconds = 120 }, { name = "2 min 30 s", seconds = 150 }, { name = "3 min", seconds = 180 },
}
-- Defaults; "trainpct" and "traincap" in settings-options.txt (values=...) change them.
local STEP_PCT, CAP = 25, 4
local MIN_INTERVAL_S = 0.05
local CHECK_EVERY_S = 1
local CHAT_PREFIX = "ENEMY SPAWNS "

-- Big red text in the upper middle, under where the kill streaks are called out.
local RED = { R = 1.0, G = 0.03, B = 0.02, A = 1.0 }
local W, H, Y = 640, 176, 320
local HOLD_S, FADE_IN_S, FADE_OUT_S = 1.5, 0.1, 3.0

-- FS_ChatMessage fields, as in announcer.lua (wrong keys crash the game).
local CHAT = {
    name = "playerName_12_F312750C4535B7687009F18A1D6070C0",
    text = "text_5_B3D2581E44A0B1B9B8DDEA8054C14F28",
    color = "color_10_FA4504B645E6947C5B39F59CAD18D9FE",
    ps = "playerState_15_953D6504499D70822566D9A138F9A95A",
}

local ctx, FFWUi, C, log
local nextCheck = 0
local ramp = { arrivedAt = nil, level = 0, stepAt = 0, nextAt = 0, mult = 1 }
local timers = {}    -- wave address .. function -> { wave, fn, base, set }
local chat = { count = nil, last = nil }
local showing = nil  -- { text, t0 }
local panel, ui = nil, nil
local diag = { host = false, train = "not seen", waves = 0, timers = 0, sets = 0, sent = 0, heard = 0, err = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

local function str(v)
    if type(v) == "string" then return v end
    return try(function() return v:ToString() end) or tostring(v)
end

local function ksl() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
local function gs() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end

local function actorsOf(pc, path)
    local cls = StaticFindObject(path)
    if not valid(cls) then return {} end
    local out, list = {}, {}
    if not pcall(function() gs():GetAllActorsOfClass(pc, cls, out) end) then return {} end
    for _, entry in ipairs(out) do
        local a = try(function() return entry:get() end)
        if valid(a) then list[#list + 1] = a end
    end
    return list
end

-- 1.25 -> "1.25", 1.5625 -> "1.6", 1.95 -> "2", 3.81 -> "3.8"
function M.multText(m)
    local s = string.format(m < 1.5 and "%.2f" or "%.1f", m)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s .. "x"
end

local function stepPct() return math.max(1, tonumber(ctx.value("trainpct", STEP_PCT)) or STEP_PCT) end
local function cap() return math.max(1, tonumber(ctx.value("traincap", CAP)) or CAP) end

function M.stepSeconds()
    local i = math.floor(tonumber(ctx.value("trainstep", 1)) or 1)
    local c = M.STEP_CHOICES[i] or M.STEP_CHOICES[1]
    return c.seconds
end

local function multFor(level)
    return math.min(cap(), (1 + stepPct() / 100) ^ level)
end

---------------------------------------------------------------------------
-- The big text
---------------------------------------------------------------------------
local function show(m)
    showing = { text = M.multText(m), t0 = FFWUi.now() }
end

local function buildPanel()
    local p = FFWUi.newPanel("TrainRamp", { zOrder = 57 })
    if not p then return end
    p:setSize(W, H)
    p:setPosition(0.5, 0, 0, Y)
    -- Soft dark patch behind the number, so it holds up against a bright sky.
    p:image((W - 420) / 2, 0, 420, H, { R = 0, G = 0, B = 0, A = 0.55 }, { path = FFWUi.TEXTURES.glow, drawAs = 1, margin = 0.5, size = 128 })
    local big = p:text(0, 0, 118, RED, { width = W, justify = 1, height = 140 })
    pcall(function()
        big.widget.Font.OutlineSettings.OutlineSize = 4
        local oc = big.widget.Font.OutlineSettings.OutlineColor
        oc.R, oc.G, oc.B, oc.A = 0, 0, 0, 0.85
    end)
    ui = {
        big = big,
        sub = p:text(0, 138, 22, C.text, { font = "text", width = W, justify = 1, height = 30 }),
    }
    FFWUi.setText(ui.sub, "ENEMY SPAWN RATE")
    panel = p
    p:show()
end

local function draw(pc, t)
    if panel and not panel:valid() then panel, ui = nil, nil end
    if not showing then
        if panel then panel:setShown(false) end
        return
    end
    local age = t - showing.t0
    local total = FADE_IN_S + HOLD_S + FADE_OUT_S
    if age >= total or not ctx.active(pc) then
        showing = nil
        if panel then panel:setShown(false) end
        return
    end
    if not panel then buildPanel() end
    if not panel then return end
    FFWUi.setText(ui.big, showing.text)
    local a = 1
    if age < FADE_IN_S then a = age / FADE_IN_S end
    if age > FADE_IN_S + HOLD_S then a = 1 - (age - FADE_IN_S - HOLD_S) / FADE_OUT_S end
    panel:setOpacity(math.floor(math.max(0, a) * 40 + 0.5) / 40)
    panel:setShown(FFWUi.gameHudShown())
end

---------------------------------------------------------------------------
-- Host: speeding the waves up
---------------------------------------------------------------------------
local function trainWaiting(pc)
    local trains = actorsOf(pc, TRAIN_CLASS)
    if #trains == 0 then
        diag.train = "not seen"
        return false
    end
    for _, tr in ipairs(trains) do
        if try(function() return tr.isWaitingForPlayers end) == true then
            diag.train = "waiting for players"
            return true
        end
    end
    diag.train = "not arrived"
    return false
end

-- Sets every running spawn timer of every wave to its base time / mult.
local function applyToWaves(pc, mult)
    local k = ksl()
    if not valid(k) then
        diag.err = "KismetSystemLibrary not found"
        return
    end
    local seen, nTimers = {}, 0
    local waves = actorsOf(pc, WAVE_CLASS)
    diag.waves = #waves
    for _, wave in ipairs(waves) do
        local wa = wave:GetAddress()
        for _, fn in ipairs(SPAWN_FNS) do
            local ok, err = pcall(function()
                if not k:K2_TimerExists(wave, fn) then return end
                local rate = k:K2_GetTimerElapsedTime(wave, fn) + k:K2_GetTimerRemainingTime(wave, fn)
                if type(rate) ~= "number" or rate <= 0 then return end
                local key = wa .. fn
                seen[key] = true
                nTimers = nTimers + 1
                local tr = timers[key]
                if not tr then
                    tr = { wave = wave, fn = fn, base = rate }
                    timers[key] = tr
                elseif math.abs(rate - (tr.set or tr.base)) > (tr.set or tr.base) * 0.02 then
                    tr.base, tr.set = rate, nil -- the game set this timer again itself
                end
                local want = math.max(MIN_INTERVAL_S, tr.base / mult)
                if math.abs(rate - want) > want * 0.01 then
                    k:K2_SetTimer(wave, fn, want, true, false, 0, 0)
                    tr.set = want
                    diag.sets = diag.sets + 1
                end
            end)
            if not ok then diag.err = "timer " .. fn .. ": " .. tostring(err) end
        end
    end
    for key in pairs(timers) do
        if not seen[key] then timers[key] = nil end -- that wave or timer ended
    end
    diag.timers = nTimers
end

-- Puts every timer this changed back to the game's own time.
local function restore()
    local k = ksl()
    for _, tr in pairs(timers) do
        if tr.set and valid(tr.wave) and valid(k) then
            pcall(function()
                if k:K2_TimerExists(tr.wave, tr.fn) then k:K2_SetTimer(tr.wave, tr.fn, tr.base, true, false, 0, 0) end
            end)
        end
    end
    timers = {}
end

local function broadcast(pc, m)
    local ok, err = pcall(function()
        local ps = pc.PlayerState
        ps:F_AddMessageToChat_Server({
            [CHAT.name] = str(ps:GetPlayerName()),
            [CHAT.text] = FText(CHAT_PREFIX .. M.multText(m)),
            [CHAT.color] = RED,
            [CHAT.ps] = ps,
        })
    end)
    if ok then diag.sent = diag.sent + 1 else diag.err = "chat send: " .. tostring(err) end
end

local function announce(pc, m)
    show(m)
    broadcast(pc, m)
    log(string.format("train ramp: %s (level %d)", M.multText(m), ramp.level))
end

local function stop()
    restore()
    ramp.arrivedAt, ramp.level, ramp.mult = nil, 0, 1
end

local function hostTick(pc, t)
    if not ctx.option("trainramp") then
        if ramp.arrivedAt then stop() end
        return
    end
    if not ramp.arrivedAt then
        if not trainWaiting(pc) then return end
        ramp.arrivedAt, ramp.level, ramp.mult = t, 0, 1
        ramp.stepAt, ramp.nextAt = t, t + M.stepSeconds()
        announce(pc, 1)
    elseif t >= ramp.nextAt and ramp.mult < cap() then
        ramp.level = ramp.level + 1
        ramp.mult = multFor(ramp.level)
        ramp.stepAt, ramp.nextAt = t, t + M.stepSeconds()
        announce(pc, ramp.mult)
    end
    applyToWaves(pc, ramp.mult)
end

---------------------------------------------------------------------------
-- Everybody else: the host's steps, read from the chat
---------------------------------------------------------------------------
local function readChat(pc)
    local ok, err = pcall(function()
        local arr = UEHelpers.GetGameInstance().chatMessages
        local n = #arr
        local lastText = (n > 0) and str(arr[n][CHAT.text]) or nil
        if chat.count == nil then -- first look: nothing here is news
            chat.count, chat.last = n, lastText
            return
        end
        local from = chat.count + 1
        if n < chat.count or (n == chat.count and lastText ~= chat.last) then from = n end -- list was trimmed
        chat.count, chat.last = n, lastText
        local mine = pc.PlayerState:GetAddress()
        for i = math.max(1, from), n do
            local m = arr[i]
            local sender = try(function() return m[CHAT.ps]:GetAddress() end)
            if sender ~= mine then
                local num = str(m[CHAT.text]):match("^" .. CHAT_PREFIX .. "(%d+%.?%d*)x$")
                if num and tonumber(num) then
                    show(tonumber(num))
                    diag.heard = diag.heard + 1
                end
            end
        end
    end)
    if not ok then diag.err = "chat read: " .. tostring(err) end
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------
function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
    C = FFWUi.COLORS
end

function M.fastTick(pc, t)
    if showing then draw(pc, t) end
end

function M.tick(pc, t, inGame)
    if not inGame then return end
    readChat(pc)
    if t < nextCheck then return end
    nextCheck = t + CHECK_EVERY_S
    diag.host = try(function() return pc:HasAuthority() end) == true
    if diag.host then
        local ok, err = pcall(hostTick, pc, t)
        if not ok then diag.err = "host: " .. tostring(err) end
    end
end

-- The switch or the step time changed in OPTIONS (game thread). A new step
-- time counts from the last step, so the level never drops.
function M.changed(pc)
    if not ramp.arrivedAt then return end
    if not ctx.option("trainramp") then
        stop()
        return
    end
    ramp.nextAt = ramp.stepAt + M.stepSeconds()
    nextCheck = 0
end

function M.reset()
    ramp.arrivedAt, ramp.level, ramp.mult = nil, 0, 1
    timers, chat.count, showing = {}, nil, nil
end

function M.destroy()
    if panel then panel:destroy() end
    panel, ui = nil, nil
end

function M.dump()
    local now = FFWUi.now()
    log(string.format("  train ramp: on=%s host=%s train=%s step=%ds +%g%% cap %gx, ramp %s, waves=%d timers=%d sets=%d sent=%d heard=%d last error=%s",
        tostring(ctx.option("trainramp")), tostring(diag.host), diag.train, M.stepSeconds(), stepPct(), cap(),
        ramp.arrivedAt and string.format("%s for %ds, next in %ds", M.multText(ramp.mult), math.floor(now - ramp.arrivedAt), math.max(0, math.floor(ramp.nextAt - now))) or "not started",
        diag.waves, diag.timers, diag.sets, diag.sent, diag.heard, tostring(diag.err)))
    for _, tr in pairs(timers) do
        log(string.format("    %s every %.2f s (game's own %.2f s)", tr.fn, tr.set or tr.base, tr.base))
    end
end

return M
