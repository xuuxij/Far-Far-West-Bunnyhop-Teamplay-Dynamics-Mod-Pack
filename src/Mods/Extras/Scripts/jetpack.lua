-- Jetpack keeps speed: flying the jetpack no longer drags a fast player back
-- down to the jetpack's own speed.
-- On every frame it flies, BP_Item_Jetpack_C's tick sets the player's velocity
-- with LaunchCharacter(VInterpTo(velocity, target, delta, 8), override XY and Z).
-- The target is 1024 along the camera's heading (flattened unless you look up)
-- plus lift, so anything faster than 1024 is gone within about a third of a
-- second. A hook that runs after that tick (UE4SS runs Blueprint hooks after
-- the function) tops up the speed toward where you look, in the launch the
-- tick just asked for (CharacterMovement.PendingLaunchVelocity), to what it
-- was before the tick:
--   - only above the jetpack's own 1024, so normal flying is unchanged;
--   - never above the speed the flight started with, so it never adds speed;
--   - sideways speed still fades as the game has it, so steering with the
--     camera works as before and a hard turn still costs speed.
-- The take-off boost and teammates' jetpacks are left alone. The dive needs no
-- care: it turns the jetpack off (and its tick with it) before it launches you.
-- (hasJustStartedDive is no dive: the game sets it for the first 0.2 s of every
-- flight, to hold the dive back until then.)

local M = {}

local TICK_FN = "/Game/Items/BP_Item_Jetpack.BP_Item_Jetpack_C:ReceiveTick"
local CRUISE = 1024       -- the jetpack's own speed (a constant in its tick)
local NEW_FLIGHT_S = 0.3  -- no flight frame for this long: the next one starts a new flight

local ctx, FFWUi, log
local hooked, hookNextTry = false, 0
local lastFlightT, entry = -1e9, 0
local diag = { frames = 0, flights = 0, kept = 0, writeFails = 0, lastEntry = 0, lastKeep = 0, err = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

local function onFlightTick(self)
    if not ctx.option("jetkeep") then return end
    local pc = FFWUi.localController()
    if not pc then return end
    local item = self:get()
    local pawn, mine = item.owningPlayer, try(function() return pc.Pawn end)
    if not (valid(pawn) and valid(mine)) or pawn:GetAddress() ~= mine:GetAddress() then return end
    if item.isJetpacking ~= true or item.isUsingInitialBoost == true then return end
    local cmc = pawn.CharacterMovement
    local v, p = cmc.Velocity, cmc.PendingLaunchVelocity
    local vx, vy, px, py = v.X, v.Y, p.X, p.Y
    if px == 0 and py == 0 and p.Z == 0 then return end -- the tick launched nothing this frame
    diag.frames = diag.frames + 1
    local t = FFWUi.now()
    if t - lastFlightT > NEW_FLIGHT_S then
        entry = math.sqrt(vx * vx + vy * vy)
        diag.flights, diag.lastEntry = diag.flights + 1, entry
    end
    lastFlightT = t
    local f = pc.PlayerCameraManager:GetActorForwardVector()
    local fl = math.sqrt(f.X * f.X + f.Y * f.Y)
    if fl < 0.01 then return end -- looking straight up or down: no heading
    local dx, dy = f.X / fl, f.Y / fl
    local keep = math.min(vx * dx + vy * dy, entry) -- the speed toward where you look, as it was
    if keep <= CRUISE then return end
    local now = px * dx + py * dy
    if now >= keep then return end
    local add = keep - now
    if ctx.setXY(cmc, "PendingLaunchVelocity", px + dx * add, py + dy * add) then
        diag.kept, diag.lastKeep = diag.kept + 1, keep
    else
        diag.writeFails = diag.writeFails + 1
    end
end

-- The jetpack's class loads with the first jetpack; tried every 2 s until then.
local function tryHook(t)
    if hooked or t < hookNextTry then return end
    hookNextTry = t + 2
    if not valid(StaticFindObject(TICK_FN)) then return end
    local ok, err = pcall(function()
        RegisterHook(TICK_FN, function(self)
            local okh, e = pcall(onFlightTick, self)
            if not okh then diag.err = "tick: " .. tostring(e) end
        end)
    end)
    hooked = ok
    if ok then log("jetpack: hooked " .. TICK_FN) else diag.err = "hook: " .. tostring(err) end
end

function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
end

function M.tick(pc, t, inGame)
    if inGame and ctx.option("jetkeep") then tryHook(t) end
end

function M.dump()
    log(string.format("  jetpack keeps speed: on=%s hooked=%s flight frames=%d flights=%d kept=%d writes failed=%d last start speed=%.0f last kept=%.0f last error=%s",
        tostring(ctx.option("jetkeep")), tostring(hooked), diag.frames, diag.flights, diag.kept, diag.writeFails,
        diag.lastEntry, diag.lastKeep, tostring(diag.err)))
end

return M
