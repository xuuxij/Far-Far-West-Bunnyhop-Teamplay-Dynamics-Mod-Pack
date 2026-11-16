-- Auto dash: hold the dash button and you dash once each time you land, so
-- chaining dashes does not need the button mashed.
-- A landing is the character going from falling to not falling. The dash is
-- made by running the game's own "dash pressed" handler on the player, so its
-- rules still apply: you must be moving in a direction, and you need a dash
-- ready (BP_Player_C.dashCount). The game gives the dash back 1 s after it was
-- used, and only on a frame when you are on the ground, so the landing is
-- remembered until then, as long as you stay on the ground and keep the
-- button held.
--
-- Keeps speed (its own switch, with a top speed slider): the game's dash is
-- LaunchCharacter(direction x (700, 700, 1000)) with the horizontal part added
-- to the speed you have. On the ground the engine brakes anything above walk
-- speed (550) within a few frames, so by the time the dash fires the speed you
-- came down with is gone and a chain never builds up. The horizontal speed
-- from just before the landing is remembered; right after the auto dash fires,
-- the launch the game just asked for (CharacterMovement.PendingLaunchVelocity,
-- applied on the next movement update) gets back what the ground took.

local M = {}

local DASH_ACTION = "IA_Dash"
local DASH_HANDLER = "InpActEvt_IA_Dash_K2Node_EnhancedInputActionEvent_10"
local REFILL_S = 1.0      -- the game's dash comes back this long after a dash (hard-coded in BP_Player)
local WAIT_EXTRA_S = 0.3  -- remember a landing for the refill plus this
local RETRY_S = 0.05
local KEYS_EVERY_S = 5    -- re-read the key binding this often, for rebinds
local KEEP_S = 0.5        -- a landing's speed is given back to a dash this soon after it
local CAP_MIN, CAP_STEP = 1000, 40 -- top speed slider: 1000 + 40 per step; 100 is no cap

local ctx, FFWUi, log
local action, actionNextSearch = nil, 0
local keys, keysAt = {}, -1e9
local wasFalling, pendingUntil, nextTry = false, nil, 0
local airX, airY = 0, 0                     -- horizontal speed at the last look while falling
local keptX, keptY, landedAt = nil, nil, -1e9 -- and at the landing
local diag = { landings = 0, tries = 0, dashes = 0, kept = 0, capped = 0, keepFails = 0, lastKept = 0, err = nil, held = false, falling = false }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

local function len(x, y) return math.sqrt(x * x + y * y) end

-- Top speed for the slider's percent; nil is no cap.
function M.capFor(pct)
    pct = tonumber(pct) or 50
    if pct >= 100 then return nil end
    return CAP_MIN + math.max(0, pct) * CAP_STEP
end

function M.capText(pct)
    local cap = M.capFor(pct)
    return cap and string.format("up to %d", cap) or "NO CAP"
end

-- The dash input action is an asset the player blueprint loads; searched for
-- (at most every 3 s) until it shows up.
local function findAction(t)
    if valid(action) then return action end
    action = nil
    if t < actionNextSearch then return nil end
    actionNextSearch = t + 3
    for _, a in ipairs(FindAllOf("InputAction") or {}) do
        if a:IsValid() and a:GetFName():ToString() == DASH_ACTION then
            action = a
            break
        end
    end
    return action
end

-- Names of the keys / buttons currently bound to dash.
local function readKeys(act, t)
    if t - keysAt < KEYS_EVERY_S then return end
    keysAt = t
    local found = {}
    local ok, err = pcall(function()
        local sub = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
        -- Comes back as a Lua table of wrapped FKey structs (LeftShift, Gamepad_FaceButton_Right ...).
        for _, e in ipairs(sub:QueryKeysMappedToAction(act)) do
            local name = e:get().KeyName:ToString()
            if name and name ~= "" and name ~= "None" then found[#found + 1] = name end
        end
    end)
    if not ok then diag.err = "key lookup: " .. tostring(err) end
    if #found > 0 then keys = found end
end

local function dashHeld(pc)
    if ctx.CONFIG.DEV_HOLD then return true end
    for _, name in ipairs(keys) do
        if try(function() return pc:IsInputKeyDown({ KeyName = FName(name) }) end) == true then return true end
    end
    return false
end

-- A pawn without the property (menus) hands back a placeholder object, not nil.
local function dashesReady(pawn)
    local n = try(function() return pawn.dashCount end)
    return (type(n) == "number") and n or 0
end

-- Gives the dash just fired the speed the landing took. gx, gy: the speed on
-- the ground when the dash fired, which the game's launch already includes.
local function keepSpeed(cmc, gx, gy, t)
    if not keptX or t - landedAt > KEEP_S or not ctx.option("autodashkeep") then return end
    if len(keptX, keptY) <= len(gx, gy) then return end -- the ground took nothing
    local px, py
    if not pcall(function() local p = cmc.PendingLaunchVelocity; px, py = p.X, p.Y end) then return end
    if type(px) ~= "number" or (px == 0 and py == 0) then return end -- no launch waiting: nothing to add to
    local nx, ny = px + keptX - gx, py + keptY - gy
    local n = len(nx, ny)
    local cap = M.capFor(ctx.value("autodashcap", 50))
    if cap and n > cap then
        local top = math.max(cap, len(px, py)) -- never slower than the game's own dash
        nx, ny = nx * top / n, ny * top / n
        diag.capped = diag.capped + 1
    end
    if ctx.setXY(cmc, "PendingLaunchVelocity", nx, ny) then
        diag.kept = diag.kept + 1
        diag.lastKept = len(nx, ny)
    else
        diag.keepFails = diag.keepFails + 1
    end
    if ctx.CONFIG.DEV_LOG then
        log(string.format("auto dash keep: landed %.0f, ground %.0f, game launch %.0f -> %.0f", len(keptX, keptY), len(gx, gy), len(px, py), len(nx, ny)))
    end
end

-- Runs the game's handler for a dash press; true when a dash was used up.
local function pressDash(pawn, act, t)
    local before = dashesReady(pawn)
    local cmc = try(function() return pawn.CharacterMovement end)
    local gx, gy
    if cmc then pcall(function() local v = cmc.Velocity; gx, gy = v.X, v.Y end) end
    -- action value, elapsed time, triggered time, source action
    local ok, err = pcall(function() pawn[DASH_HANDLER](pawn, {}, 0.0, 0.0, act) end)
    diag.tries = diag.tries + 1
    if not ok then
        diag.err = "dash call: " .. tostring(err)
        return true -- no point repeating a call that errors
    end
    local after = dashesReady(pawn)
    if ctx.CONFIG.DEV_LOG then log(string.format("auto dash try: dashes ready %d -> %d", before, after)) end
    local used = after < before
    if used and type(gx) == "number" then
        local okk, e = pcall(keepSpeed, cmc, gx, gy, t)
        if not okk then diag.err = "keep speed: " .. tostring(e) end
    end
    return used
end

function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
end

function M.tick(pc, t, inGame)
    if not inGame or not ctx.option("autodash") then
        wasFalling, pendingUntil, keptX = false, nil, nil
        return
    end
    local act = findAction(t)
    if not act then return end
    readKeys(act, t)
    local pawn = pc.Pawn
    local falling = try(function() return pawn.CharacterMovement:IsFalling() end) == true
    if falling then
        pcall(function() local v = pawn:GetVelocity(); airX, airY = v.X, v.Y end)
    end
    local landed = wasFalling and not falling
    wasFalling = falling
    local held = (landed or pendingUntil ~= nil) and dashHeld(pc)
    diag.falling, diag.held = falling, held
    if landed then
        diag.landings = diag.landings + 1
        keptX, keptY, landedAt = airX, airY, t
        pendingUntil = held and (t + REFILL_S + WAIT_EXTRA_S) or nil
        nextTry = t
    end
    if pendingUntil then
        if not held or falling or t > pendingUntil then
            pendingUntil = nil
        elseif t >= nextTry and dashesReady(pawn) > 0 then
            -- No dash happens while you stand still; keep trying until you move or let go.
            nextTry = t + RETRY_S
            if pressDash(pawn, act, t) then
                diag.dashes = diag.dashes + 1
                pendingUntil = nil
            end
        end
    end
end

function M.dump()
    local pc = FFWUi.localController()
    log(string.format("  auto dash: on=%s action=%s keys=%s held now=%s", tostring(ctx.option("autodash")),
        tostring(valid(action)), table.concat(keys, ","), tostring(pc and dashHeld(pc))))
    log(string.format("    landings=%d tries=%d dashes=%d falling=%s waiting=%s last error=%s", diag.landings, diag.tries,
        diag.dashes, tostring(diag.falling), tostring(pendingUntil ~= nil), tostring(diag.err)))
    log(string.format("    keeps speed=%s top=%s: kept %d times (%d at the top, %d writes failed), last launch %.0f",
        tostring(ctx.option("autodashkeep")), M.capText(ctx.value("autodashcap", 50)), diag.kept, diag.capped,
        diag.keepFails, diag.lastKept))
    local pawn = pc and try(function() return pc.Pawn end)
    if valid(pawn) then
        log(string.format("    dashes ready=%d", dashesReady(pawn)))
    end
end

return M
