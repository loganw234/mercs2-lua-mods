-- ContractFramework.lua  -  a save-safe custom-contract library for Mercenaries 2 modders.
--
-- DEPLOY: put this in scripts/OnLoad/ and give it a LOW number in lua_loader.ini so it loads
--   before any modder contract script, e.g.:
--       [OnLoad]
--       ContractFramework.lua=5
--       MyContracts.lua=15
--
-- WHY THIS IS SAFE (read once): the native contract system corrupts saves because it registers
--   into WifMissionData, serializes MrxTask nodes INTO the save, and drives missions through
--   dynamic_import + mrxbriefing + the MrxState load gate. This framework touches NONE of that.
--   A contract is an EPHEMERAL runtime object built only from safe primitives (Pg.Spawn / Event.* /
--   Object.* / MrxPmc). It never writes to the game save, so it can't corrupt one. Tradeoff: a
--   contract does not survive a save/reload (it's simply re-offered on the next level load).
--
-- MODDER API (the whole surface you need):
--   Contract.Register{ id=, title=, briefing=, reward={cash=,fuel=}, start={x,y,z,yaw},
--                      objectives = { Contract.Destroy{...}, Contract.Reach{...}, ... },
--                      onComplete=fn, onFail=fn }
--   Objective builders:  Contract.Destroy{ desc=, spawns={ {"Template",x,y,z,yaw}, ... } }
--                        Contract.Reach{  desc=, at={x,y,z}, radius= }
--                        Contract.Defend{ desc=, time=, target="PlacedObjectName" }   -- target optional
--   Contract.Board.Open()      -- show/hide the selection board (bind to a key in an OnKey script)
--   Contract.Accept(idOrDef)   -- start a contract directly (the board calls this)
--   Contract.UI.Panel{...} / Contract.UI.Bar{...}   -- reusable HUD widgets (need a .gfx; see README)

import("MrxPmc")
import("MrxUtil")
import("MrxGuiBase")
import("MrxGuiManager")

_G.Contract = _G.Contract or {}
local C = _G.Contract
C._registry = C._registry or {}   -- ordered array of defs (rebuilt each level load)
C._byId     = C._byId or {}        -- id -> def
C.tHandlers = C.tHandlers or {}
C.UI        = C.UI or {}

-- Objective marker icons per surface, taken straight from the base game's MrxTaskObjective family
-- (radar = "objective_*", in-world = "HUD_objective_*"; the PDA map uses "icon_yellow_mc"). This is
-- the reusable pattern the shipped missions use: mark a target on the round radar, the PDA map, AND
-- in-world all at once, keyed by the guid string.
local OBJ_ICONS = {
    destroy     = { rdr = "objective_destroy",     wld = "HUD_objective_destroy" },
    verify      = { rdr = "objective_verify",      wld = "HUD_objective_verify" },
    defend      = { rdr = "objective_defend",      wld = "HUD_objective_defend" },
    action      = { rdr = "objective_action",      wld = "HUD_objective_action" },
    destination = { rdr = "objective_deliverable", wld = "HUD_objective_deliverable" },
}

-- Fresh registry each load (OnLoad re-runs). Nothing here persists into the game save.
C._registry, C._byId = {}, {}

-- ============================================================
-- Runtime engine (one live contract instance at a time)
-- ============================================================
-- Each objective (and each background condition) runs as a self-contained "task" holding its own
-- events/guids/markers, so several can run at once (parallel mode) and each tears down on its own.
local function track(task, u) if u then task.guids[#task.guids + 1] = u end return u end
local function objRgb()
    local ok, r, g, b = pcall(MrxUtil.GetPrimaryObjectiveRgb)
    if ok and r then return r, g, b end
    return 255, 200, 0
end

-- ---- HUD narration: the base game's objective tray (Hud.ObjectiveTray:SetSlotToText, used by allcon002
-- /chicon008). Slot 1 = the current objective line (persistent); slot 3 = transient "radio" chatter that
-- clears itself. Literal text works, plus [white]/[red]/[green]/[yellow] colour + [bar<0-100>] tags.
local function hudLine(slot, text)
    if C._muteObj and slot == 1 then return end   -- a hideTracker contract draws its own HUD -> suppress the objective line
    if text == nil then pcall(function() Hud.ObjectiveTray:ClearSlot({ nSlot = slot }) end)
    else pcall(function() Hud.ObjectiveTray:SetSlotToText({ nSlot = slot, sText = tostring(text) }) end) end
end
local function hudSay(text, hold)                          -- one-shot radio line, auto-cleared (fire-and-forget so it always clears)
    if not text or text == "" then return end
    hudLine(3, tostring(text))
    pcall(Event.Create, Event.TimerRelative, { tonumber(hold) or 5 }, function() hudLine(3, nil) end)
    Loader.Printf("Contract:   \"" .. tostring(text) .. "\"")
end
-- ints from a plain number OR a {min,max} range; used for randomised counts. (engine ships math.randf.)
local function rspan(v) if type(v) == "table" then local a, b = v[1] or v.min or 0, v[2] or v.max or v[1] or 0
        return math.floor(a + math.randf(0, (b - a) + 0.999)) end
    return v end
local function rchance(c) return not c or c >= 1 or math.randf(0, 1) <= c end   -- true unless a <1 chance rolls against it

-- mark an EXISTING object as an objective on all three surfaces the base game uses at once: the round
-- radar (Hud.Radar:AddObjective), the PDA map (Pda.Map:AddBlip), and in-world (Marker.AddBlip). Keyed
-- by the guid string (sName) so cleanup can remove the radar/PDA marks. `kind` picks the icon set.
-- Returns (sName, worldMarkerHandle).
local function mark(task, uGuid, kind)
    local ic = OBJ_ICONS[kind] or OBJ_ICONS.action
    local r, g, b = objRgb()
    local sName = tostring(uGuid)
    local okn, s = pcall(Sys.GuidToString, uGuid); if okn and s then sName = s end
    task.marks = task.marks or {}
    task.marks[#task.marks + 1] = sName
    pcall(function() Hud.Radar:AddObjective({ sName = sName, uGuid = uGuid, sTexture = ic.rdr,
        nR = r, nG = g, nB = b, nWidth = 10.666667, nHeight = 10.666667, nSortOrder = 5 }) end)
    pcall(function() Pda.Map:AddBlip({ sName = sName, uGuid = uGuid, sTexture = "icon_yellow_mc", nSortOrder = 2 }) end)
    local wld
    local ok, m = pcall(Marker.AddBlip, uGuid, ic.wld, 32, r, g, b, 255, 2, 5, 175)
    if ok and m then task.markers[#task.markers + 1] = m; wld = m end
    return sName, wld
end

-- mark a ZONE: spawn an inert "TinyGeometry" anchor, draw the ground ring (Marker.AddDisc), and mark
-- it as a "destination" on radar + PDA + world - exactly like the Oil-job drop-off. TinyGeometry is
-- an empty-geometry placeholder; unlike "Verification Camera" it doesn't fire a support/camera call.
-- Returns a set {anchor,disc,sName,wld} for unmarkZone (race keeps only the current checkpoint).
local function markZone(task, x, y, z, radius)
    local ok, anchor = pcall(Pg.Spawn, "TinyGeometry", x, y, z)
    if not ok or not anchor then return end
    track(task, anchor)
    local r, g, b = objRgb()
    local set = { anchor = anchor }
    local dok, disc = pcall(Marker.AddDisc, anchor, radius or 15, r, g, b, 0.15)
    if dok and disc then task.markers[#task.markers + 1] = disc; set.disc = disc end
    set.sName, set.wld = mark(task, anchor, "destination")
    return set
end

-- remove one zone's whole marker set (race uses this so only the current checkpoint stays marked).
local function unmarkZone(set)
    if not set then return end
    if set.disc then pcall(Marker.Remove, set.disc) end
    if set.wld  then pcall(Marker.Remove, set.wld) end
    if set.sName then
        pcall(function() Hud.Radar:RemoveObjective({ sName = set.sName }) end)
        pcall(function() Pda.Map:RemoveBlip({ sName = set.sName }) end)
    end
    if set.anchor then pcall(Object.Remove, set.anchor) end
end
local function addEv(task, e) if e then task.events[#task.events + 1] = e end return e end

local function cleanupTask(task)
    for _, e in ipairs(task.events)  do pcall(Event.Delete, e) end
    for _, sName in ipairs(task.marks or {}) do            -- radar/PDA marks remove by name, not handle
        pcall(function() Hud.Radar:RemoveObjective({ sName = sName }) end)
        pcall(function() Pda.Map:RemoveBlip({ sName = sName }) end)
    end
    for _, m in ipairs(task.markers) do pcall(Marker.Remove, m) end
    for _, u in ipairs(task.guids)   do pcall(Object.Remove, u) end
    task.events, task.markers, task.guids, task.marks = {}, {}, {}, {}
end

function C._CleanupAll(inst)
    for _, t in ipairs(inst.tasks or {}) do cleanupTask(t) end
    inst.tasks = {}
end

-- ---- target sourcing: an objective's targets may be SPAWNED, NAMED (placed), or LIVE-QUERIED ----
local function hasLabel(u, lbl) local ok, r = pcall(Object.HasLabel, u, lbl); return ok and r end

local function collectInArea(x, y, z, r, kind, faction, label)
    local fns
    if kind == "humans" then fns = { Pg.FastCollectHumans }
    elseif kind == "vehicles" then fns = { Pg.FastCollectGroundVehicles, Pg.FastCollectFlying }
    elseif kind == "buildings" then fns = { Pg.FastCollectBuildings }
    else fns = { Pg.FastCollectHumans, Pg.FastCollectGroundVehicles, Pg.FastCollectFlying } end
    local seen, out = {}, {}
    for _, fn in ipairs(fns) do
        local ok, t = pcall(fn, x, y, z, r)
        if ok and type(t) == "table" then
            for _, u in pairs(t) do
                local key = u and tostring(u)
                if key and not seen[key] then
                    seen[key] = true
                    if (not faction or hasLabel(u, faction)) and (not label or hasLabel(u, label)) then out[#out + 1] = u end
                end
            end
        end
    end
    return out
end

-- flat list of target guids from obj.tSpawns (spawned + tracked for removal), obj.tObjects (named
-- placements) and obj.tWhere (a live FastCollect query). Existing world objects are NOT tracked, so
-- they're never removed on cleanup.
local function resolveTargets(inst, task, obj)
    local out = {}
    for _, s in ipairs(obj.tSpawns or {}) do
        local ok, u = pcall(Pg.Spawn, s[1], s[2], s[3], s[4])
        if ok and u then track(task, u); if s[5] then pcall(Object.SetYaw, u, s[5]) end; out[#out + 1] = u end
    end
    for _, name in ipairs(obj.tObjects or {}) do
        local ok, u = pcall(Pg.GetGuidByName, name)
        if ok and u then out[#out + 1] = u end
    end
    local w = obj.tWhere
    if w and w.area then
        local a = w.area
        for _, u in ipairs(collectInArea(a.x or a[1], a.y or a[2], a.z or a[3], a.r or a[4] or 50, w.kind, w.faction, w.label)) do
            out[#out + 1] = u
        end
    end
    return out
end

-- table-driven reward payout (cash/fuel confirmed; support/equipment via MrxPmc)
local function grantReward(r)
    if type(r) ~= "table" then return end
    if r.cash then pcall(MrxPmc.AddCashQty, r.cash, false, "[Generic.Wagers]") end
    if r.fuel then pcall(MrxPmc.AddFuelQty, r.fuel) end
    if type(r.support) == "table" then for id, n in pairs(r.support) do pcall(MrxPmc.AddSupportQty, id, n) end end
    if type(r.equipment) == "table" then for _, id in ipairs(r.equipment) do pcall(MrxPmc.AddEquipment, id) end end
end

-- Native completion fanfare = the music sting + a HUD banner. sType MUST be one of the shipped
-- EventFanfare styles or Hud.EventFanfare:Commence crashes on its PDA-log concat, so we clamp it.
-- "highscore" reads as a win by default; set def.fanfareType to any of the styles below.
local FANFARE_TYPES = { contact = true, support = true, stockpile = true, landingzone = true,
    hvtcapture = true, hvtkill = true, bounty = true, outfit = true, highscore = true }
local function showFanfare(d)
    pcall(MrxMusic.PlayFanfare, true)
    local sType = d.fanfareType; if not FANFARE_TYPES[sType] then sType = "highscore" end
    local sText = d.fanfare or ((d.title or d.id) .. " complete")
    pcall(function() Hud.EventFanfare:Commence({ sType = sType, vText = sText }) end)
end

function C._finish(inst, bWin)
    if not inst.bActive then return end
    inst.bActive = false
    C._muteObj = nil                   -- restore the objective tray for normal contracts
    hudLine(1, nil); hudLine(3, nil)   -- clear the HUD objective + chatter lines
    if inst.musicOn then pcall(MrxMusic.StopSpecialMusic) end   -- return to the normal soundtrack
    local d = inst.def
    -- snapshot final objective state for the board's Status() (persists until the next Accept)
    local fin = {}
    for i = 1, #(d.objectives or {}) do fin[i] = { done = inst.objDone[i] == true } end
    C.finished = { result = bWin and "complete" or "failed", objectives = fin }
    -- hide the custom board/tracker UI the instant the contract ends (the board registers C.onFinish);
    -- the fanfare below is the completion reveal, so nothing lingers in the custom UI.
    if type(C.onFinish) == "function" then pcall(C.onFinish, C.finished.result) end
    if bWin then
        grantReward(d.reward)
        local r = d.reward or {}
        Loader.Printf(string.format("Contract: *** COMPLETE '%s'  $%d / %d fuel ***",
            d.title or d.id, r.cash or 0, r.fuel or 0))
        showFanfare(d)
        if d.onComplete then pcall(d.onComplete) end
    else
        Loader.Printf("Contract: xxx FAILED '" .. (d.title or d.id) .. "'")
        if d.onFail then pcall(d.onFail) end
    end
    if C._restoreRelations then C._restoreRelations(inst) end   -- put faction stances back the way we found them
    C._CleanupAll(inst)
    C.active = nil
end

-- run ONE objective as its own task; onDone(true|false) reports its outcome (exactly once)
function C._run(inst, obj, onDone)
    local task = { events = {}, guids = {}, markers = {}, done = false }
    inst.tasks[#inst.tasks + 1] = task
    local h = C.tHandlers[obj.sType]
    if not h then Loader.Printf("Contract: no handler '" .. tostring(obj.sType) .. "'"); onDone(false); return task end
    Loader.Printf(string.format("Contract:   objective (%s) - %s", obj.sType, obj.sDesc or ""))
    if obj.sDesc and obj.sType ~= "survive" then hudLine(1, "[white]" .. obj.sDesc) end   -- survive draws its own countdown line
    if obj.sMsg then hudSay(obj.sMsg, 6) end                                               -- per-objective radio line
    h(inst, task, obj, function(bOk)
        if task.done or not inst.bActive then return end
        task.done = true
        cleanupTask(task)
        onDone(bOk)
    end)
    return task
end

-- Run an objective LIST in a mode ("sequential" default | "parallel"), calling onDone(true|false)
-- once the whole list resolves. markFn(index, ok) fires as each objective in THIS list finishes
-- (used at the top level to fill objDone for the board; nested groups pass no markFn). This single
-- function powers both the top-level runner and the `group` objective, so nesting is free.
function C._runList(inst, objs, mode, onDone, markFn)
    if mode == "parallel" then
        local nReq, doneFlag = 0, false
        for _, o in ipairs(objs) do if not o.optional then nReq = nReq + 1 end end
        if nReq == 0 then return onDone(true) end
        for idx, obj in ipairs(objs) do
            C._run(inst, obj, function(bOk)
                if not inst.bActive or doneFlag then return end
                if markFn then markFn(idx, bOk) end
                if obj.optional then
                    if bOk and obj.bonus then pcall(MrxPmc.AddCashQty, obj.bonus, false, "[Generic.Wagers]")
                        Loader.Printf("Contract:   bonus objective complete (+$" .. obj.bonus .. ")") end
                elseif bOk == false then
                    doneFlag = true; onDone(false)
                else
                    nReq = nReq - 1
                    if nReq <= 0 then doneFlag = true; onDone(true) end
                end
            end)
        end
    else
        local i = 0
        local function step(prevOk)
            if not inst.bActive then return end
            if prevOk == false then return onDone(false) end
            i = i + 1
            local obj = objs[i]
            if not obj then return onDone(true) end
            C._run(inst, obj, function(ok) if markFn then markFn(i, ok) end step(ok) end)
        end
        step(true)
    end
end

-- background conditions running for the WHOLE contract: an overall time limit, plus any def.fail
-- conditions (protect a target / stay in an area). A violated condition fails the contract.
function C._startBackground(inst)
    local d = inst.def
    if C._spawnUnits then C._spawnUnits(inst) end   -- spawn & group def.units FIRST so orders can command them
    if d.timeLimit then
        local task = { events = {}, guids = {}, markers = {}, done = false }
        inst.tasks[#inst.tasks + 1] = task
        addEv(task, Event.Create(Event.TimerRelative, { d.timeLimit }, function()
            if inst.bActive then Loader.Printf("Contract: time limit reached"); C._finish(inst, false) end
        end))
    end
    for _, cond in ipairs(d.fail or {}) do
        C._run(inst, cond, function(bOk) if inst.bActive and bOk == false then C._finish(inst, false) end end)
    end
    if C._startSupport then C._startSupport(inst) end   -- airstrikes / artillery / reinforcements + generic triggers
end

function C.Accept(idOrDef)
    -- co-op: only the host runs contracts. But in SINGLE-PLAYER Net.IsClient() can report true, which
    -- made this silently no-op every accept (log showed only "[cboard] accepted", no objectives). Gate
    -- on IsMultiplayer so SP always proceeds; only a real MP client is skipped.
    if Net.IsMultiplayer() and Net.IsClient() then return end
    local def = type(idOrDef) == "string" and C._byId[idOrDef] or idOrDef
    if type(def) ~= "table" then Loader.Printf("Contract.Accept: unknown contract"); return end
    if C.active and C.active.bActive then C.Abort() end
    C.finished = nil   -- clear any prior result so Status() reflects THIS contract
    if def.fResolve then pcall(def.fResolve, def) end   -- fill in any dynamic (e.g. player-relative) coords
    local inst = { def = def, bActive = true, tasks = {}, objDone = {}, startStamp = Sys.RealTimeStamp() }
    C.active = inst
    Loader.Printf("Contract: accepted '" .. (def.title or def.id) .. "'" .. (def.mode == "parallel" and " [parallel]" or ""))
    local function begin()
        if not inst.bActive then return end
        C._muteObj = def.hideTracker                                  -- HUD-owning modes suppress the objective tray line
        Loader.Printf("Contract: starting '" .. (def.title or def.id) .. "' (" .. #(def.objectives or {}) .. " objectives)")
        if def.intro then hudSay(def.intro, 7) end                    -- opening radio line

        -- the OPTIONAL relations/support/trigger setup must NEVER block the core objective runner:
        -- pcall each so a bad relation/support/trigger can't kill begin() before C._runList (that would
        -- leave the contract accepted with zero objectives). Errors are logged so we can still find them.
        if C._applyRelations then local ok, e = pcall(C._applyRelations, inst); if not ok then Loader.Printf("Contract: relations setup error -> " .. tostring(e)) end end
        local sbOk, sbE = pcall(C._startBackground, inst); if not sbOk then Loader.Printf("Contract: support/trigger setup error -> " .. tostring(sbE)) end
        -- ESCAPE HATCH: after heroes are placed + the contract's background is up, hand off to a bespoke
        -- gamemode. pcall'd so it can NEVER block the objective runner. def.onBegin(inst) is where custom
        -- modes (wave defense, etc.) start their own logic; the contract stays the lightweight launcher.
        if def.onBegin then local obOk, obE = pcall(def.onBegin, inst); if not obOk then Loader.Printf("Contract: onBegin error -> " .. tostring(obE)) end end
        C._runList(inst, def.objectives or {}, def.mode, function(ok) C._finish(inst, ok) end,
                   function(i, ok) if ok then inst.objDone[i] = true end end)
    end
    if def.start then
        local s = def.start
        local locs = {}
        if type(s[1]) == "table" then                     -- a LIST of spawns (co-op: one location per hero)
            for i, p in ipairs(s) do locs[i] = { p.x or p[1], p.y or p[2], p.z or p[3], p.yaw or p[4] or 0 } end
        else                                              -- a single spawn ({x=,y=,z=,yaw=} or {x,y,z,yaw})
            locs[1] = { s.x or s[1], s.y or s[2], s.z or s[3], s.yaw or s[4] or 0 }
        end
        MrxUtil.TeleportHeroesToLocations(locs, begin)   -- extra locations are ignored in single-player
    else
        begin()
    end
end

function C.Abort() if C.active then C._finish(C.active, false) end end

-- ============================================================
-- Objective handlers  -  fn(inst, task, obj, onDone); call onDone(true|false) once.
-- Push spawns/blips/events into `task` (its own bucket) so several can run at once in parallel mode.
-- ============================================================
C.tHandlers.chase = function(inst, task, obj, onDone)       -- destroy a FLEEING target before it reaches its escape point
    local guids = resolveTargets(inst, task, obj)
    local total = #guids
    if total == 0 then return onDone(true) end
    local ez = obj.tZone
    for _, u in ipairs(guids) do
        mark(task, u, "destroy")
        local a = u; local okd, drv = pcall(Vehicle.GetDriver, u); if okd and drv then a = drv end   -- steer the driver of a vehicle
        if ez and ez.x then pcall(Ai.Goal, { AIGuid = a, Goal = "MoveToPos", Location = { ez.x, ez.y, ez.z }, Priority = "HiPri", Force = true }) end
        pcall(Ai.SetHaste, a, obj.nHaste or 1)
    end
    local killed = 0
    for _, u in ipairs(guids) do
        addEv(task, Event.Create(Event.ObjectDeath, { u }, function()
            if not inst.bActive then return end
            killed = killed + 1; Loader.Printf("Contract:   runner down (" .. killed .. "/" .. total .. ")")
            if killed >= total then onDone(true) end
        end, {}))
    end
    if ez and ez.x then                                     -- fail the instant any target reaches the escape zone
        local r = ez.r or 15
        local function watch()
            if not inst.bActive or task.done then return end
            for _, u in ipairs(guids) do
                local ok, ux, _, uz = pcall(Object.GetPosition, u)
                if ok and ux then local dx, dz = ux - ez.x, uz - ez.z; if dx * dx + dz * dz <= r * r then Loader.Printf("Contract:   the target got away!"); return onDone(false) end end
            end
            addEv(task, Event.Create(Event.TimerRelative, { 0.5 }, watch))
        end
        watch()
    end
    if obj.nTime then addEv(task, Event.Create(Event.TimerRelative, { obj.nTime }, function()
        if inst.bActive and not task.done then Loader.Printf("Contract:   chase timed out"); onDone(false) end end)) end
end
C.tHandlers.survive = function(inst, task, obj, onDone)
    local left = obj.nTime or 60
    if obj.sTarget then                                 -- optional: fail if a protected unit (group/name) dies before the timer
        local grp = (inst.groups or {})[obj.sTarget]; local u = grp and grp[1]
        if not u then local ok, g = pcall(Pg.GetGuidByName, obj.sTarget); if ok then u = g end end
        if u then addEv(task, Event.Create(Event.ObjectDeath, { u }, function()
            if inst.bActive and not task.done then Loader.Printf("Contract:   protected target lost"); onDone(false) end end)) end
    end
    local function tick()
        if not inst.bActive or task.done then return end
        hudLine(1, "[white]" .. (obj.sDesc or "Hold out") .. "  (" .. math.max(0, math.floor(left)) .. "s)")
        if left <= 0 then return onDone(true) end
        left = left - 1
        addEv(task, Event.Create(Event.TimerRelative, { 1 }, tick))
    end
    tick()
end
C.tHandlers.destroy = function(inst, task, obj, onDone)
    local guids = resolveTargets(inst, task, obj)   -- spawned / named / live-queried
    local total = #guids
    if total == 0 then return onDone(true) end
    local quota, killed = obj.nQuota or total, 0
    for _, u in ipairs(guids) do
        mark(task, u, "destroy")
        addEv(task, Event.Create(Event.ObjectDeath, { u }, function()
            if not inst.bActive then return end
            killed = killed + 1; Loader.Printf("Contract:   target down (" .. killed .. "/" .. quota .. ")")
            if killed >= quota then onDone(true) end
        end, {}))
    end
end

C.tHandlers.reach = function(inst, task, obj, onDone)
    local z = obj.tZone or {}
    if not z.x then Loader.Printf("Contract: reach objective has no location"); return onDone(true) end
    local r = z.r or 15
    markZone(task, z.x, z.y, z.z, r)   -- ground ring + radar + PDA "destination" mark
    local function poll()
        if not inst.bActive or task.done then return end
        local uc = Player.GetLocalCharacter()
        if uc then local x, _, zz = Object.GetPosition(uc); local dx, dz = x - z.x, zz - z.z
            if dx * dx + dz * dz <= r * r then return onDone(true) end end
        addEv(task, Event.Create(Event.TimerRelative, { 0.25 }, poll))
    end
    poll()
end

C.tHandlers.defend = function(inst, task, obj, onDone)
    -- survive obj.nTime seconds; if obj.sTarget (a placed object name) is given, fail if it dies.
    if obj.sTarget then
        local uT = Pg.GetGuidByName(obj.sTarget)
        if uT then addEv(task, Event.Create(Event.ObjectDeath, { uT }, function()
            if inst.bActive then onDone(false) end end, {})) end
    end
    addEv(task, Event.Create(Event.TimerRelative, { obj.nTime or 60 }, function()
        if inst.bActive then onDone(true) end
    end))
    Loader.Printf(string.format("Contract:   hold for %d s", obj.nTime or 60))
end

-- --- DRAFT objective types (untested; same shape) -----------------------------------------------
-- collect: pick up items by walking near them; complete at quota (default: all).
C.tHandlers.collect = function(inst, task, obj, onDone)
    local remaining, r = {}, obj.nRadius or 4
    for _, s in ipairs(obj.tItems or {}) do
        local ok, u = pcall(Pg.Spawn, s[1], s[2], s[3], s[4])
        if ok and u then track(task, u); mark(task, u, "action"); remaining[#remaining + 1] = u end
    end
    local quota, got = obj.nQuota or #remaining, 0
    if #remaining == 0 then return onDone(true) end
    local function poll()
        if not inst.bActive or task.done then return end
        local uc = Player.GetLocalCharacter()
        if uc then
            local px, _, pz = Object.GetPosition(uc)
            for i = #remaining, 1, -1 do
                local ix, _, iz = Object.GetPosition(remaining[i])
                local dx, dz = px - ix, pz - iz
                if dx * dx + dz * dz <= r * r then
                    pcall(Object.Remove, remaining[i]); table.remove(remaining, i); got = got + 1
                    Loader.Printf("Contract:   collected (" .. got .. "/" .. quota .. ")")
                    if got >= quota then return onDone(true) end
                end
            end
        end
        addEv(task, Event.Create(Event.TimerRelative, { 0.25 }, poll))
    end
    poll()
end

-- escort: get a spawned unit/vehicle to a destination zone; fail if it dies. (Its follow/drive
-- behaviour is the modder's job - spawn a drivable vehicle, or a unit with follow AI.)
C.tHandlers.escort = function(inst, task, obj, onDone)
    local s = obj.tSpawn or {}
    local ok, u = pcall(Pg.Spawn, s[1], s[2], s[3], s[4])
    if not ok or not u then Loader.Printf("Contract: escort couldn't spawn"); return onDone(true) end
    track(task, u); mark(task, u, "defend")
    addEv(task, Event.Create(Event.ObjectDeath, { u }, function()
        if inst.bActive then onDone(false) end
    end, {}))
    local z = obj.tZone or {}; local r = z.r or 15
    if z.x then markZone(task, z.x, z.y, z.z, r) end   -- mark the drop-off zone
    local function poll()
        if not inst.bActive or task.done or not z.x then return end
        local ex, _, ez = Object.GetPosition(u); local dx, dz = ex - z.x, ez - z.z
        if dx * dx + dz * dz <= r * r then return onDone(true) end
        addEv(task, Event.Create(Event.TimerRelative, { 0.5 }, poll))
    end
    poll()
end

-- enter: player boards a vehicle (placed by name, or spawned). Completes on seat entry.
C.tHandlers.enter = function(inst, task, obj, onDone)
    local u = obj.sTarget and Pg.GetGuidByName(obj.sTarget)
    if not u and obj.tSpawn then local s = obj.tSpawn; local ok, uu = pcall(Pg.Spawn, s[1], s[2], s[3], s[4]); if ok then u = track(task, uu) end end
    if not u then Loader.Printf("Contract: enter has no vehicle"); return onDone(true) end
    mark(task, u, "action")
    addEv(task, Event.Create(Event.ObjectInSeat, { Player.GetAnyCharacter(), u, obj.sSeat or "d", "ei" }, function()
        if inst.bActive then onDone(true) end
    end, {}))
end

-- hold: stay in a zone until you've accumulated obj.nTime seconds inside it (capture-point style).
C.tHandlers.hold = function(inst, task, obj, onDone)
    local z = obj.tZone or {}
    if not z.x then Loader.Printf("Contract: hold has no location"); return onDone(true) end
    local r, need, held, step = z.r or 15, obj.nTime or 15, 0, 0.5
    markZone(task, z.x, z.y, z.z, r)   -- ground ring + radar + PDA "destination" mark
    local function poll()
        if not inst.bActive or task.done then return end
        local uc = Player.GetLocalCharacter()
        if uc then local x, _, zz = Object.GetPosition(uc); local dx, dz = x - z.x, zz - z.z
            if dx * dx + dz * dz <= r * r then held = held + step
                if held >= need then return onDone(true) end end end
        addEv(task, Event.Create(Event.TimerRelative, { step }, poll))
    end
    poll()
end

-- background fail-conditions (put in a contract's `fail = { ... }`; only ever fail, never complete).
C.tHandlers.protect = function(inst, task, obj, onDone)
    local u = obj.sTarget and Pg.GetGuidByName(obj.sTarget)
    if not u and obj.tSpawn then local s = obj.tSpawn; local ok, uu = pcall(Pg.Spawn, s[1], s[2], s[3], s[4]); if ok then u = track(task, uu) end end
    if not u then return end
    mark(task, u, "defend")
    addEv(task, Event.Create(Event.ObjectDeath, { u }, function()
        if inst.bActive then Loader.Printf("Contract:   protected target lost!"); onDone(false) end
    end, {}))
end

C.tHandlers.stay = function(inst, task, obj, onDone)
    local z = obj.tZone or {}; local r = z.r or 100
    if not z.x then return end
    local function poll()
        if not inst.bActive or task.done then return end
        local uc = Player.GetLocalCharacter()
        if uc then local x, _, zz = Object.GetPosition(uc); local dx, dz = x - z.x, zz - z.z
            if dx * dx + dz * dz > r * r then Loader.Printf("Contract:   left the mission area!"); return onDone(false) end end
        addEv(task, Event.Create(Event.TimerRelative, { 0.5 }, poll))
    end
    poll()
end

-- --- structural + advanced DRAFT objectives -----------------------------------------------------
-- group: a nested objective list with its own mode - gives full phase/tree nesting for free.
C.tHandlers.group = function(inst, task, obj, onDone)
    Loader.Printf("Contract:   -- group [" .. (obj.sMode or "sequential") .. "] " .. (obj.sDesc or ""))
    C._runList(inst, obj.tObjectives or {}, obj.sMode, onDone)
end

-- interact: approach a target/point and (optionally) hold it for nTime seconds. One primitive for
-- talk / plant / hack / sabotage / free-prisoner - the flavour is just the desc.
C.tHandlers.interact = function(inst, task, obj, onDone)
    local u, z = nil, obj.tZone
    if obj.sTarget then local ok, uu = pcall(Pg.GetGuidByName, obj.sTarget); if ok then u = uu end
    elseif obj.tSpawn then local s = obj.tSpawn; local ok, uu = pcall(Pg.Spawn, s[1], s[2], s[3], s[4]); if ok then u = track(task, uu) end end
    if u then local ok, x, y, zz = pcall(Object.GetPosition, u); if ok and x then z = { x = x, y = y, z = zz } end end
    if not z or not z.x then Loader.Printf("Contract: interact has no target/location"); return onDone(true) end
    if u then mark(task, u, "action") end
    local r, need, held, step = obj.nRadius or 4, obj.nTime or 0, 0, 0.5
    local function poll()
        if not inst.bActive or task.done then return end
        local uc = Player.GetLocalCharacter()
        if uc then
            local x, _, zz = Object.GetPosition(uc); local dx, dz = x - z.x, zz - z.z
            if dx * dx + dz * dz <= r * r then
                held = held + step
                if held >= need then return onDone(true) end
            else held = 0 end   -- must stay to "use" it
        end
        addEv(task, Event.Create(Event.TimerRelative, { step }, poll))
    end
    poll()
end

-- verify: HVT bounty. Completes when the HVT is killed; if obj.bCapture, also completes when the
-- player is adjacent while it's at low health (a subdue approximation - real subdue state isn't
-- reachable from Lua yet).
C.tHandlers.verify = function(inst, task, obj, onDone)
    local u
    if obj.sTarget then local ok, uu = pcall(Pg.GetGuidByName, obj.sTarget); if ok then u = uu end
    elseif obj.tSpawn then local s = obj.tSpawn; local ok, uu = pcall(Pg.Spawn, s[1], s[2], s[3], s[4]); if ok then u = track(task, uu) end end
    if not u then Loader.Printf("Contract: verify has no HVT"); return onDone(true) end
    mark(task, u, "verify")
    addEv(task, Event.Create(Event.ObjectDeath, { u }, function()
        if inst.bActive then Loader.Printf("Contract:   HVT verified (KIA)"); onDone(true) end
    end, {}))
    if obj.bCapture then
        local cr, chp = obj.nRadius or 3, obj.nCaptureHealth or 25
        local function poll()
            if not inst.bActive or task.done then return end
            local okp, px, _, pz = pcall(Object.GetPosition, Player.GetLocalCharacter())
            local okt, tx, _, tz = pcall(Object.GetPosition, u)
            local okh, hp = pcall(Object.GetHealth, u)
            if okp and okt and px and tx then
                local dx, dz = px - tx, pz - tz
                if okh and hp and hp <= chp and dx * dx + dz * dz <= cr * cr then
                    Loader.Printf("Contract:   HVT verified (captured)"); return onDone(true)
                end
            end
            addEv(task, Event.Create(Event.TimerRelative, { 0.3 }, poll))
        end
        poll()
    end
end

-- extract: reach an LZ. nBoardTime = 0 (or nil<=0) -> INSTANT (reach the LZ = extracted, no heli).
-- nBoardTime > 0 -> HOLD the LZ that many seconds (a heli optionally spawns in; leaving resets).
C.tHandlers.extract = function(inst, task, obj, onDone)
    local z = obj.tZone or {}
    if not z.x then Loader.Printf("Contract: extract has no zone"); return onDone(true) end
    local r, step, need = z.r or 15, 0.5, obj.nBoardTime or 3
    markZone(task, z.x, z.y, z.z, r)   -- ground ring + radar + PDA "destination" mark
    local boarding, held = false, 0
    local function poll()
        if not inst.bActive or task.done then return end
        local inzone = false
        local uc = Player.GetLocalCharacter()
        if uc then local x, _, zz = Object.GetPosition(uc); local dx, dz = x - z.x, zz - z.z; inzone = dx * dx + dz * dz <= r * r end
        if inzone then
            if need <= 0 then return onDone(true) end   -- INSTANT: reach the LZ and you're extracted
            if not boarding then
                boarding = true
                if obj.sHeli then local ok, h = pcall(Pg.Spawn, obj.sHeli, z.x, z.y + 4, z.z); if ok then track(task, h) end end
                Loader.Printf("Contract:   extraction inbound - hold the LZ")
            end
            held = held + step
            if held >= need then return onDone(true) end
        else
            boarding, held = false, 0
        end
        addEv(task, Event.Create(Event.TimerRelative, { step }, poll))
    end
    poll()
end

-- race: reach tCheckpoints in order (optionally within nTime); reports the run time. One board line.
C.tHandlers.race = function(inst, task, obj, onDone)
    local cps, r = obj.tCheckpoints or {}, obj.nRadius or 12
    local n = #cps
    if n == 0 then return onDone(true) end
    local idx, curSet = 0, nil
    local startStamp = Sys.RealTimeStamp()
    local function armNext()
        if curSet then unmarkZone(curSet); curSet = nil end
        idx = idx + 1
        if idx > n then
            local ok, e = pcall(Sys.TimeStampGetElapsed, startStamp)
            Loader.Printf(string.format("Contract:   race complete in %.1fs", (ok and e) or 0))
            return onDone(true)
        end
        local c = cps[idx]
        curSet = markZone(task, c[1], c[2], c[3], r)   -- full marker set on the current checkpoint only
        Loader.Printf(string.format("Contract:   checkpoint %d/%d", idx, n))
    end
    if obj.nTime then
        addEv(task, Event.Create(Event.TimerRelative, { obj.nTime }, function()
            if inst.bActive and not task.done then Loader.Printf("Contract:   race time expired"); onDone(false) end
        end))
    end
    local function poll()
        if not inst.bActive or task.done then return end
        local uc = Player.GetLocalCharacter()
        if uc and idx >= 1 and idx <= n then
            local c = cps[idx]
            local x, _, zz = Object.GetPosition(uc); local dx, dz = x - c[1], zz - c[3]
            if dx * dx + dz * dz <= r * r then
                armNext()
                if task.done or not inst.bActive then return end
            end
        end
        addEv(task, Event.Create(Event.TimerRelative, { 0.2 }, poll))
    end
    armNext()
    poll()
end

-- ============================================================
-- Objective builders (friendly sugar -> internal shape)
-- ============================================================
local function xyz(t) if t.x then return t.x, t.y, t.z else return t[1], t[2], t[3] end end
local function zone(at, radius, dr) if not at then return { r = radius or dr } end local x, y, z = xyz(at); return { x = x, y = y, z = z, r = radius or dr } end
-- passthrough optional/bonus (parallel mode) + mirror sType/sDesc to type/desc for the GFx board
local function ob(o, t) o.optional = t.optional; o.bonus = t.bonus; o.sMsg = t.msg; o.type = o.sType; o.desc = o.sDesc; return o end

function C.Destroy(t) return ob({ sType = "destroy", sDesc = t.desc, tSpawns = t.spawns, tObjects = t.objects, tWhere = t.where, nQuota = t.quota }, t) end
function C.Reach(t)   return ob({ sType = "reach",   sDesc = t.desc, tZone = zone(t.at, t.radius, 15) }, t) end
function C.Defend(t)  return ob({ sType = "defend",  sDesc = t.desc, nTime = t.time, sTarget = t.target }, t) end
function C.Collect(t) return ob({ sType = "collect", sDesc = t.desc, tItems = t.items, nQuota = t.quota, nRadius = t.radius }, t) end
function C.Escort(t)  return ob({ sType = "escort",  sDesc = t.desc, tSpawn = t.spawn, tZone = zone(t.to, t.radius, 15) }, t) end
function C.Enter(t)   return ob({ sType = "enter",   sDesc = t.desc, sTarget = t.target, tSpawn = t.spawn, sSeat = t.seat }, t) end
function C.Hold(t)    return ob({ sType = "hold",    sDesc = t.desc, tZone = zone(t.at, t.radius, 15), nTime = t.time }, t) end
function C.Group(t)    return ob({ sType = "group",    sDesc = t.desc, sMode = t.mode, tObjectives = t.objectives }, t) end
function C.Interact(t) local z; if t.at then local x, y, zz = xyz(t.at); z = { x = x, y = y, z = zz } end
                       return ob({ sType = "interact", sDesc = t.desc, sTarget = t.target, tSpawn = t.spawn, tZone = z, nRadius = t.radius or 4, nTime = t.time }, t) end
function C.Verify(t)   return ob({ sType = "verify",   sDesc = t.desc, sTarget = t.target, tSpawn = t.spawn, bCapture = t.capture, nCaptureHealth = t.captureHealth, nRadius = t.radius }, t) end
function C.Extract(t)  return ob({ sType = "extract",  sDesc = t.desc, tZone = zone(t.at, t.radius, 15), nBoardTime = t.boardTime, sHeli = t.heli }, t) end
function C.Race(t)     return ob({ sType = "race",     sDesc = t.desc, tCheckpoints = t.checkpoints, nRadius = t.radius, nTime = t.time }, t) end
function C.Survive(t)  return ob({ sType = "survive",  sDesc = t.desc, nTime = t.time, sTarget = t.target }, t) end
function C.Chase(t)    return ob({ sType = "chase",    sDesc = t.desc, tSpawns = t.spawns, tObjects = t.objects, tWhere = t.where, tZone = zone(t.escapeAt, t.escapeRadius, 15), nTime = t.time, nHaste = t.haste }, t) end
-- background fail-conditions for a contract's `fail = { ... }` list
function C.Protect(t)    return { sType = "protect", type = "protect", sDesc = t.desc, desc = t.desc, sTarget = t.target, tSpawn = t.spawn } end
function C.StayInArea(t) return { sType = "stay", type = "stay", sDesc = t.desc, desc = t.desc, tZone = zone(t.at, t.radius, 100) } end

-- ============================================================
-- Relationships, support call-ins, AI orders & generic triggers   (all ephemeral; torn down on finish)
--   def.relations = { { "Allied","PMC","friend" }, { "VZ","PMC","enemy" }, { "VZ","Allied","enemy" } }
--   def.units     = { { spawn=, x=,y=,z=, yaw=, group="A" }, ... }         framework-owned, grouped units
--   def.waypoints = { { id=, group="A", behavior="patrol"|"move"|"defend"|"attack"|"hold"|"face",
--                       points={ {x,y,z},... } | at={x,y,z}, radius=, speed=, loop=, target=, trigger= }, ... }
--   def.support   = { { id=, effect=, at={x,y,z}, radius=, owner=, <params>, trigger= }, ... }
--   def.triggers  = { { id=, kind="proximity"|"recurring"|"once"|"onDestroy"|"health"|"objective"|"cleared"|"all"|"count", ... } }
-- triggers' fires={} and support/order trigger={ref=id} may target support ids OR waypoint ids.
-- effects: artillery(ammo) / flyby(=airstrike, vehicle) / bombingrun(vehicle+ammo) / heli / reinforce(deliver=copter|paradrop) /
--   say(text) / music(cue) / vfx(particle) / damage(target,pct|kill) / vo(lines) / custom
-- objectives include: reach/destroy/defend/collect/escort/enter/hold/interact/verify/extract/race/survive/chase/group/protect/stay
-- trigger conditions: "immediate" | "once" | "recurring" | {proximity=r} | {onDestroy="nearest"|name}
--   | {onHealthBelow={target=,pct=}} | {onObjComplete=N} | {onCleared={faction=,radius=}} | {ref=id}
--   LOGIC GATES (as def.triggers entries): kind="all"/"count" with inputs={trigIds}, need=N (count) -> fire once satisfied.
-- AI verbs (def.waypoints behavior): move/patrol/defend/attack/hold/face + follow(target)/flee/enter(target,role)/deploy/animate(action).
-- NARRATION: def.intro (opening radio line), per-objective msg="..." (radio line on start), effect="say" (trigger-fired chatter);
--   all via Hud.ObjectiveTray. RANDOMISATION: support count={min,max}; unit spawn=<list> (pick one) + chance=0..1.
-- def.units[i].chance / .spawn=<list>. New objective: survive{ time=, target=<protect> }.
-- ============================================================
local FACTION_ABBREV = { Allied = "All", China = "Chi", Guerilla = "Gur", OC = "Oil", Pirate = "Pir", VZ = "VZ", PMC = "Pmc" }
local HELO_FACTION   = { Allied = "AL", China = "CH", Guerilla = "GR", OC = "OC", Pirate = "PR", VZ = "VZ" }
local REL_VALUE      = { friend = 100, ally = 100, allied = 100, neutral = 0, enemy = -100, hostile = -100 }
local function factionGuid(name) local ok, g = pcall(Pg.GetGuidByName, name); if ok then return g end end
local function evPos(ev) if ev.at then return xyz(ev.at) end return ev.x, ev.y, ev.z end
local function ownerGuid(ev) if ev.owner then return factionGuid(ev.owner) end end

-- ---- support effects: one-shot actions a trigger fires. Push spawns/events into `task` for cleanup.
local SUPPORT_EFFECTS = {}
SUPPORT_EFFECTS.artillery = function(inst, task, ev)          -- N shells rain onto the zone (spread), owned by `owner`
    local x, y, z = evPos(ev); if not x then return end
    local ammo, n, r, owner = ev.ammo or "Gunship Shell", rspan(ev.count) or 5, ev.radius or 14, ownerGuid(ev)
    for i = 1, n do
        local dx, dz = math.randf(0, 2 * r) - r, math.randf(0, 2 * r) - r
        addEv(task, Event.Create(Event.TimerRelative, { 0.35 * (i - 1) }, function()
            if inst.bActive then pcall(Airstrike.SpawnOrdnance, ammo, x + dx, y + 220, z + dz, 0, -100, 0, "impact", 1, owner) end
        end))
    end
end
SUPPORT_EFFECTS.flyby = function(inst, task, ev)              -- a support vehicle streaks over the zone
    local x, y, z = evPos(ev); if not x then return end
    pcall(Airstrike.Flyby, ev.vehicle or "Support Vehicle (Autogunship)", x - 50, z + 300, x, z, y + (ev.altitude or 120), ev.speed or 55)
end
SUPPORT_EFFECTS.airstrike = SUPPORT_EFFECTS.flyby
SUPPORT_EFFECTS.bombingrun = function(inst, task, ev)         -- an aircraft makes a pass and walks a stick of bombs onto the zone
    local x, y, z = evPos(ev); if not x then return end        -- (mirrors mrxbombingrun: Flyby the delivery vehicle, drop ordnance from it)
    local vehicle, bomb = ev.vehicle or "Support Vehicle (A10)", ev.ammo or "Bomb"
    local alt, speed, n, owner = y + (ev.altitude or 150), ev.speed or 160, rspan(ev.count) or 3, ownerGuid(ev)
    local uJet
    local function drop()                                      -- fires when the aircraft reaches the target
        if not inst.bActive then return end
        for i = 1, n do
            addEv(task, Event.Create(Event.TimerRelative, { 0.14 * (i - 1) }, function()
                if not inst.bActive then return end
                local jx, jy, jz = x, alt, z                    -- re-read the jet each drop so the stick walks under its path
                if uJet then local ok, a, b, c = pcall(Object.GetPosition, uJet); if ok and a then jx, jy, jz = a, b, c end end
                pcall(Airstrike.SpawnOrdnance, bomb, jx, jy, jz, 0, -60, 0, "impact", 1, owner)
            end))
        end
        Loader.Printf("Contract:   bombing run: " .. n .. "x " .. tostring(bomb))
    end
    local ok, jet = pcall(Airstrike.Flyby, vehicle, x - 350, z + 350, x, z, alt, speed, drop)
    if ok then uJet = jet end
end
SUPPORT_EFFECTS.heli = function(inst, task, ev)               -- a wave of N helicopters passes over, FANNED OUT so they never share airspace
    local x, y, z = evPos(ev); if not x then return end
    local tmpl, n = ev.template or "AH1Z", rspan(ev.count) or 3
    local stagger = ev.stagger or 1.6                          -- s between birds (0.8 was too tight -> they spawned into each other and exploded)
    local spread  = ev.spread or 45                            -- lateral gap between birds (was 6-14 -> overlapping spawns)
    for i = 1, n do
        local off = (i - 1) * spread                           -- fan each bird out on BOTH the start AND target point so no two ever overlap
        addEv(task, Event.Create(Event.TimerRelative, { stagger * (i - 1) }, function()
            if inst.bActive then pcall(Airstrike.Flyby, tmpl, x - 60 - off, z + 300 + off, x + off, z, y + (ev.altitude or 55), ev.speed or 45) end
        end))
    end
end
SUPPORT_EFFECTS.reinforce = function(inst, task, ev)         -- units arrive: deliver="copter"|"paradrop"|else direct spawn
    local x, y, z = evPos(ev); if not x then return end
    local fac, spawns = HELO_FACTION[ev.faction] or ev.faction or "VZ", ev.spawns or {}
    local function spawnOne(i, tmpl)
        local ox, oz = ((i - 1) % 3 - 1) * 4, math.floor((i - 1) / 3) * 4
        if ev.deliver == "copter" then pcall(MrxCopterDrop.Create, fac, tmpl, x + ox, y, z + oz, false)
        else local ok, u = pcall(Pg.Spawn, tmpl, x + ox, y, z + oz); if ok then track(task, u) end end
    end
    if ev.deliver == "paradrop" then                          -- a transport plane makes a pass, troops arrive under it
        pcall(Airstrike.Flyby, ev.vehicle or "Support Vehicle (Paradrop_AL)", x - 350, z + 350, x, z, y + (ev.altitude or 180), ev.speed or 140)
        for i, tmpl in ipairs(spawns) do addEv(task, Event.Create(Event.TimerRelative, { 1.5 + 0.2 * i }, function() if inst.bActive then spawnOne(i, tmpl) end end)) end
    else
        for i, tmpl in ipairs(spawns) do spawnOne(i, tmpl) end
    end
    Loader.Printf("Contract:   reinforcements inbound (" .. #spawns .. ", " .. (ev.deliver or "direct") .. ")")
end
SUPPORT_EFFECTS.custom = function(inst, task, ev) if type(ev.fn) == "function" then pcall(ev.fn, ev, task) end end
SUPPORT_EFFECTS.say = function(inst, task, ev) hudSay(ev.text or ev.msg, ev.hold) end   -- radio chatter / narration line (HUD)
SUPPORT_EFFECTS.music = function(inst, task, ev)             -- swell / stop the special mission music (MrxMusic, like the shipped contracts)
    if ev.stop or ev.cue == "stop" or ev.cue == "" then pcall(MrxMusic.StopSpecialMusic)
    else inst.musicOn = true; pcall(MrxMusic.PlaySpecialMusic, ev.cue or "mu_pmc_panicloop_01") end
end
SUPPORT_EFFECTS.vfx = function(inst, task, ev)              -- cosmetic explosions / fire / smoke (NO damage) via Airstrike.SpawnDirectedObject
    local x, y, z = evPos(ev); if not x then return end
    local particle, n, r = ev.particle or "global_particle_explosion_flash_large", rspan(ev.count) or 1, ev.radius or 0
    for i = 1, n do
        local dx, dz = (r > 0) and (math.randf(0, 2 * r) - r) or 0, (r > 0) and (math.randf(0, 2 * r) - r) or 0
        addEv(task, Event.Create(Event.TimerRelative, { 0.25 * (i - 1) }, function()
            if inst.bActive then pcall(Airstrike.SpawnDirectedObject, particle, x + dx, y + (ev.up or 1), z + dz, 0, 1, 0) end
        end))
    end
end
SUPPORT_EFFECTS.damage = function(inst, task, ev)          -- scripted damage / kill on a target GROUP (or named unit / area) - Object.SetHealth/Kill
    local guids = (inst.groups or {})[tostring(ev.target or "")] or {}
    if #guids == 0 and ev.target then local g = factionGuid(ev.target); if g then guids = { g } end end
    if #guids == 0 and ev.at then local x, y, z = evPos(ev); guids = collectInArea(x, y, z, ev.radius or 30, ev.kind, ev.faction) end
    local pct = ev.pct or 25
    for _, g in ipairs(guids) do
        if ev.kill then pcall(Object.Kill, g)
        else local ok, hp = pcall(Object.GetHealth, g); if ok and hp and hp > 0 then pcall(Object.SetHealth, g, hp * (pct / 100)) end end
    end
    Loader.Printf("Contract:   damage -> " .. #guids .. (ev.kill and " killed" or (" to " .. pct .. "%")))
end
SUPPORT_EFFECTS.vo = function(inst, task, ev)              -- play a voice-over line sequence (bring-your-own VO keys); no-op if VO isn't loaded
    if not (MrxVoSequence and MrxVoSequence.Start) then return end
    local lines = ev.lines; if type(lines) == "string" then lines = { lines } end
    if type(lines) ~= "table" or #lines == 0 then return end
    local seq = {}; for i, ln in ipairs(lines) do seq[#seq + 1] = ln; if i < #lines then seq[#seq + 1] = ev.gap or 1 end end
    pcall(MrxVoSequence.Start, seq)
end

-- ---- generic trigger arming (shared by support inline triggers AND named def.triggers) ----
local function armTrigger(inst, task, ev, trig, onFire)
    if trig == nil or trig == "immediate" then return onFire() end
    if trig == "once" then trig = { once = ev.delay or 3 } end
    if trig == "recurring" then trig = { recurring = ev.interval or 10, limit = ev.limit } end
    if type(trig) ~= "table" then return end
    if trig.ref then return end                                       -- dormant: a named trigger fires it
    if trig.once then
        addEv(task, Event.Create(Event.TimerRelative, { tonumber(trig.once) or 3 }, function() if inst.bActive then onFire() end end)); return
    end
    if trig.recurring then
        local iv, lim, cnt = trig.recurring, trig.limit, 0
        local function tick()
            if not inst.bActive then return end
            onFire(); cnt = cnt + 1
            if not (lim and cnt >= lim) then addEv(task, Event.Create(Event.TimerRelative, { iv }, tick)) end
        end
        addEv(task, Event.Create(Event.TimerRelative, { ev.delay or iv }, tick)); return
    end
    if trig.proximity then
        local zx, zy, zz; if trig.at then zx, zy, zz = xyz(trig.at) else zx, zy, zz = evPos(ev) end
        local r = trig.proximity
        local function poll()
            if not inst.bActive then return end
            local uc = Player.GetLocalCharacter()
            if uc and zx then
                local ok, px, _, pz = pcall(Object.GetPosition, uc)
                if ok and px then local dx, dz = px - zx, pz - zz; if dx * dx + dz * dz <= r * r then return onFire() end end
            end
            addEv(task, Event.Create(Event.TimerRelative, { 0.4 }, poll))
        end
        poll(); return
    end
    if trig.onDestroy then
        local od = trig.onDestroy
        if type(od) == "string" and od ~= "nearest" then           -- watch a named placement
            local g = factionGuid(od)
            if g then addEv(task, Event.Create(Event.ObjectDeath, { g }, function() if inst.bActive then onFire() end end)) end
            return
        end
        -- "nearest": poll the zone for the nearest object (objectives spawn late), then watch it die
        local zx, zy, zz; if type(od) == "table" and od.at then zx, zy, zz = xyz(od.at) else zx, zy, zz = evPos(ev) end
        local rr = (type(od) == "table" and od.radius) or trig.radius or 45
        local kind = type(od) == "table" and od.kind or nil
        local function findArm()
            if not inst.bActive or not zx then return end
            local best, bu
            for _, u in ipairs(collectInArea(zx, zy, zz, rr, kind)) do
                local ok, ux, _, uz = pcall(Object.GetPosition, u)
                if ok and ux then local dx, dz = ux - zx, uz - zz; local dd = dx * dx + dz * dz; if not best or dd < best then best, bu = dd, u end end
            end
            if bu then addEv(task, Event.Create(Event.ObjectDeath, { bu }, function() if inst.bActive then onFire() end end))
            else addEv(task, Event.Create(Event.TimerRelative, { 1 }, findArm)) end
        end
        findArm(); return
    end
    if trig.onHealthBelow then                                        -- fire when a target drops below pct% of its start-health
        local spec = trig.onHealthBelow
        local pct = (type(spec) == "table" and spec.pct) or (type(spec) == "number" and spec) or 50
        local name = (type(spec) == "table" and (spec.target or spec.group)) or trig.target
        local function gtarget() if not name then return end
            local grp = (inst.groups or {})[name]; if grp and grp[1] then return grp[1] end; return factionGuid(name) end
        local base
        local function poll()
            if not inst.bActive then return end
            local u = gtarget()
            if u then local ok, hp = pcall(Object.GetHealth, u)
                if ok and hp then base = base or (hp > 0 and hp) or base
                    if base and base > 0 and hp <= base * (pct / 100) then return onFire() end end end
            addEv(task, Event.Create(Event.TimerRelative, { 0.5 }, poll))
        end
        poll(); return
    end
    if trig.onObjComplete then                                        -- fire when top-level objective #N is marked done
        local idx = tonumber(trig.onObjComplete) or 1
        local function poll()
            if not inst.bActive then return end
            if inst.objDone and inst.objDone[idx] then return onFire() end
            addEv(task, Event.Create(Event.TimerRelative, { 0.4 }, poll))
        end
        poll(); return
    end
    if trig.onCleared then                                            -- fire when a wave is wiped out (0 targets remain in the zone)
        local od = trig.onCleared
        local zx, zy, zz; if trig.at then zx, zy, zz = xyz(trig.at) else zx, zy, zz = evPos(ev) end
        local r = (type(od) == "table" and od.radius) or trig.radius or 45
        local kind = type(od) == "table" and od.kind or nil
        local faction = type(od) == "table" and od.faction or nil
        local seen
        local function poll()
            if not inst.bActive or not zx then return end
            local n = #collectInArea(zx, zy, zz, r, kind, faction)
            if n > 0 then seen = true end                            -- only "cleared" once something was actually there
            if seen and n == 0 then return onFire() end
            addEv(task, Event.Create(Event.TimerRelative, { 0.8 }, poll))
        end
        poll(); return
    end
end
local function namedTrig(t)                                          -- normalise def.triggers entry -> armTrigger form
    if t.kind == "proximity" then return { proximity = t.radius or 15, at = t.at } end
    if t.kind == "recurring" then return { recurring = t.interval or 10, limit = t.limit } end
    if t.kind == "once" or t.kind == "timer" then return { once = t.delay or 3 } end
    if t.kind == "onDestroy" then return { onDestroy = t.target or "nearest", at = t.at, radius = t.radius } end
    if t.kind == "health" then return { onHealthBelow = { pct = t.pct or 50, target = t.target } } end
    if t.kind == "objective" then return { onObjComplete = t.index or t.obj or 1 } end
    if t.kind == "cleared" then return { onCleared = { radius = t.radius, faction = t.faction, kind = t.targetKind }, at = t.at, radius = t.radius } end
    return "immediate"
end

-- ---- relationships: record -> set as the modder asked -> restore on finish ----
function C._applyRelations(inst)
    inst.savedRel = {}
    for _, r in ipairs(inst.def.relations or {}) do
        local a, b = r.a or r[1], r.b or r[2]
        local set = tostring(r.set or r[3] or "neutral"):lower()
        local ga, gb, val = factionGuid(a), factionGuid(b), REL_VALUE[set] or 0
        if ga and gb then
            if b == "PMC" then pcall(MrxFactionManager.SetAttitudeMutable, FACTION_ABBREV[a]) end   -- make PMC-facing official (HUD) where possible
            if a == "PMC" then pcall(MrxFactionManager.SetAttitudeMutable, FACTION_ABBREV[b]) end
            local o1ok, o1 = pcall(Ai.GetRelation, ga, gb)
            local o2ok, o2 = pcall(Ai.GetRelation, gb, ga)
            inst.savedRel[#inst.savedRel + 1] = { ga, gb, o1ok and o1 }
            inst.savedRel[#inst.savedRel + 1] = { gb, ga, o2ok and o2 }
            pcall(Ai.SetRelation, ga, gb, val)                       -- directional: set both ways for a mutual stance
            pcall(Ai.SetRelation, gb, ga, val)
            Loader.Printf(string.format("Contract:   relation %s<->%s = %s", tostring(a), tostring(b), set))
        else
            Loader.Printf("Contract: relation skipped - unknown faction '" .. tostring(a) .. "' / '" .. tostring(b) .. "'")
        end
    end
end
function C._restoreRelations(inst)
    for _, s in ipairs(inst.savedRel or {}) do if s[3] then pcall(Ai.SetRelation, s[1], s[2], s[3]) end end
    inst.savedRel = {}
end

-- ============================================================
-- AI orders / waypoints   -   direct a SPAWNED unit GROUP to move / patrol / hold / attack
-- ------------------------------------------------------------
-- Units placed in def.units are spawned & OWNED by the contract, bucketed by group into
-- inst.groups[name] = { guid, ... }.  def.waypoints then issues Ai commands to whole groups.
--   def.units     = { { spawn="Chinese Elite Soldier", x=,y=,z=, yaw=, group="A" }, ... }
--   def.waypoints = { { id=, group="A", behavior="patrol", points={ {x,y,z},... }, loop=,
--                       at={x,y,z}, radius=, speed=0..1, target=<group>, priority=, trigger=<spec> }, ... }
-- behaviors (each built ONLY on the Ai.Goal / Ai.Anchor primitives the shipped contracts use):
--   move   -> MoveToPos(at)                     go to a spot and stop
--   patrol -> MoveToPos chain through points    walk a route (loops unless loop=false)
--   defend -> MoveToPos(at) + Anchor(radius)    hold an area, fight anything inside it
--   attack -> Attack(target group / nearest hero)   hunt a target
--   hold   -> Idle + Anchor(0)                  stand ground where spawned, don't give chase
--   face   -> Face(at)                          turn to face a point (staging / cutscene feel)
-- Orders are fired through the SAME trigger system as support, so a waypoint can be immediate
-- (default, after a short settle so vehicle crews are seated) or gated by a placed trigger.
local AI_PRI = { hi = "HiPri", high = "HiPri", med = "MedPri", medium = "MedPri", lo = "LoPri", low = "LoPri" }
local function aiPri(p) return AI_PRI[tostring(p or "hi"):lower()] or "HiPri" end
local function aiGoal(args) local ok, h = pcall(Ai.Goal, args); return ok and h end
local function setHaste(g, s) if s then pcall(Ai.SetHaste, g, s) end end
local function nearestHero() local ok, u = pcall(Player.GetLocalCharacter); if ok then return u end end
local function groupGuids(inst, name) return (inst.groups or {})[tostring(name or "")] or {} end
-- AI goals must target the DRIVER of a vehicle, not the vehicle hull (mirrors pircon004's chaser).
local function aiActor(g) local ok, drv = pcall(Vehicle.GetDriver, g); if ok and drv then return drv end return g end

local AI_BEHAVIORS = {}
AI_BEHAVIORS.move = function(inst, task, o, guids)
    local x, y, z = xyz(o.at or {}); if not x then return end
    local pri = aiPri(o.priority)
    for _, g in ipairs(guids) do local a = aiActor(g)
        aiGoal({ AIGuid = a, Goal = "MoveToPos", Location = { x, y, z }, Priority = pri, Force = true }); setHaste(a, o.speed) end
end
AI_BEHAVIORS.face = function(inst, task, o, guids)
    local x, y, z = xyz(o.at or {}); if not x then return end
    for _, g in ipairs(guids) do
        aiGoal({ AIGuid = aiActor(g), Goal = "Face", Target = { x, y, z }, Position = true, Priority = "HiPri" }) end
end
AI_BEHAVIORS.hold = function(inst, task, o, guids)
    for _, g in ipairs(guids) do local a = aiActor(g)
        pcall(Ai.Anchor, { AIGuid = a, AnchorRadius = 0 })
        aiGoal({ AIGuid = a, Goal = "Idle", Priority = "HiPri" }) end
end
AI_BEHAVIORS.defend = function(inst, task, o, guids)
    local x, y, z = xyz(o.at or {}); if not x then return end
    local r, pri = o.radius or 12, aiPri(o.priority)
    local ok, anchor = pcall(Pg.Spawn, "TinyGeometry", x, y, z); if ok and anchor then track(task, anchor) else anchor = nil end
    for _, g in ipairs(guids) do local a = aiActor(g)
        aiGoal({ AIGuid = a, Goal = "MoveToPos", Location = { x, y, z }, Priority = pri, Force = true }); setHaste(a, o.speed)
        if anchor then pcall(Ai.Anchor, { AIGuid = a, AnchorGuid = anchor, AnchorRadius = r }) end end
end
AI_BEHAVIORS.attack = function(inst, task, o, guids)
    local tgt; if o.target then tgt = groupGuids(inst, o.target)[1] end; if not tgt then tgt = nearestHero() end
    local pri = aiPri(o.priority or "med")
    for _, g in ipairs(guids) do local a = aiActor(g)
        if tgt then aiGoal({ AIGuid = a, Goal = "Attack", Target = tgt, Priority = pri })
        else local x, y, z = xyz(o.at or {}); if x then aiGoal({ AIGuid = a, Goal = "MoveToPos", Location = { x, y, z }, Priority = pri }) end end
        setHaste(a, o.speed) end
end
AI_BEHAVIORS.patrol = function(inst, task, o, guids)
    local pts = o.points or (o.at and { o.at }) or {}
    if #pts == 0 then return end
    local loop, pri = (o.loop ~= false and #pts >= 2), aiPri(o.priority)   -- a 1-point "patrol" is just a move (no busy-loop)
    for _, g in ipairs(guids) do local a = aiActor(g); setHaste(a, o.speed)
        local i = 0
        local function step()
            if not inst.bActive then return end
            i = i + 1; if i > #pts then if loop then i = 1 else return end end
            local x, y, z = xyz(pts[i]); if not x then return end
            aiGoal({ AIGuid = a, Goal = "MoveToPos", Location = { x, y, z }, Priority = pri, Force = true,
                     Callback = function(_, State) if State == 1 and inst.bActive then step() end end })
        end
        step()
    end
end

AI_BEHAVIORS.follow = function(inst, task, o, guids)          -- tail a target (player, or o.target group), re-issued so it keeps up
    local function tgt() if o.target then return groupGuids(inst, o.target)[1] end return nearestHero() end
    for _, g in ipairs(guids) do local a = aiActor(g)
        local function chase()
            if not inst.bActive then return end
            local t = tgt(); if t then aiGoal({ AIGuid = a, Goal = "MoveTo", Target = t, Priority = aiPri(o.priority), Force = true }) end
            setHaste(a, o.speed)
            addEv(task, Event.Create(Event.TimerRelative, { o.interval or 4 }, chase))
        end
        chase()
    end
end
AI_BEHAVIORS.flee = function(inst, task, o, guids)            -- break and run directly away from the nearest hero
    local hero = nearestHero(); local hx, hz
    if hero then local ok, x, _, z = pcall(Object.GetPosition, hero); if ok then hx, hz = x, z end end
    local dist = o.distance or 120
    for _, g in ipairs(guids) do local a = aiActor(g)
        local ok, gx, gy, gz = pcall(Object.GetPosition, g)
        if ok and gx then
            local dx, dz = gx - (hx or gx - 1), gz - (hz or gz)
            local len = math.sqrt(dx * dx + dz * dz); if len < 1 then dx, dz, len = 1, 0, 1 end
            aiGoal({ AIGuid = a, Goal = "MoveToPos", Location = { gx + dx / len * dist, gy, gz + dz / len * dist }, Priority = "HiPri", Force = true })
            setHaste(a, o.speed or 1)
        end
    end
end
AI_BEHAVIORS.enter = function(inst, task, o, guids)          -- board a vehicle (o.target = its group/name) as driver/gunner/passenger
    local veh = o.target and (groupGuids(inst, o.target)[1] or factionGuid(o.target)); if not veh then return end
    for _, g in ipairs(guids) do
        aiGoal({ AIGuid = g, Goal = "Enter", Target = veh, Role = o.role or "passenger", Priority = "HiPri", Force = true })
    end
end
AI_BEHAVIORS.deploy = function(inst, task, o, guids)         -- a transport disgorges its passengers (guids are the vehicles)
    for _, g in ipairs(guids) do pcall(Ai.Deploy, { Vehicle = g, Role = "Passenger", Priority = "HiPri", Force = true }) end
end
AI_BEHAVIORS.animate = function(inst, task, o, guids)        -- play a canned action: "Cower" (surrender), "Stand", ...
    for _, g in ipairs(guids) do pcall(Human.DoAction, g, o.action or "Cower") end
end

-- spawn def.units, bucket their guids by group, and track them for teardown (one task bucket).
function C._spawnUnits(inst)
    local d = inst.def
    inst.groups = inst.groups or {}
    if not d.units or #d.units == 0 then return end
    local task = { events = {}, guids = {}, markers = {}, done = false }
    inst.tasks[#inst.tasks + 1] = task
    local n = 0
    for _, u in ipairs(d.units) do
        local tmpl = u.spawn or u.template or u[1]
        if type(tmpl) == "table" then tmpl = tmpl[1 + math.floor(math.randf(0, #tmpl - 0.001))] end   -- pick one of a list
        local x, y, z = xyz(u.at or { u.x, u.y, u.z })
        if tmpl and x and rchance(u.chance) then                                                       -- u.chance<1 = probabilistic spawn
            local ok, g = pcall(Pg.Spawn, tmpl, x, y, z, u.yaw)
            if ok and g then
                track(task, g)
                if u.yaw then pcall(Object.SetYaw, g, u.yaw) end
                local grp = tostring(u.group or "A")
                inst.groups[grp] = inst.groups[grp] or {}
                inst.groups[grp][#inst.groups[grp] + 1] = g
                n = n + 1
            end
        end
    end
    if n > 0 then Loader.Printf("Contract:   spawned " .. n .. " grouped unit(s)") end
end

-- ---- support + AI orders + triggers runner (from _startBackground; one auto-cleaned task bucket) ----
function C._startSupport(inst)
    local d = inst.def
    if not (d.support or d.triggers or d.waypoints) then return end
    inst.support, inst.waypoints = {}, {}
    for _, ev in ipairs(d.support or {})   do if ev.id then inst.support[ev.id]   = ev end end
    for _, wp in ipairs(d.waypoints or {}) do if wp.id then inst.waypoints[wp.id] = wp end end
    local task = { events = {}, guids = {}, markers = {}, done = false }
    inst.tasks[#inst.tasks + 1] = task
    local function fireSupport(idOrEv)
        local ev = type(idOrEv) == "table" and idOrEv or inst.support[idOrEv]
        if not ev then return end
        local fx = SUPPORT_EFFECTS[ev.effect or "custom"]
        if fx then Loader.Printf("Contract:   support '" .. tostring(ev.id or ev.effect) .. "' fired"); pcall(fx, inst, task, ev) end
    end
    local function fireOrder(idOrWp)
        local wp = type(idOrWp) == "table" and idOrWp or inst.waypoints[idOrWp]
        if not wp then return end
        local fn, guids = AI_BEHAVIORS[wp.behavior or "move"], groupGuids(inst, wp.group)
        Loader.Printf(string.format("Contract:   order '%s' (%s) -> group %s [%d unit%s]",
            tostring(wp.id or wp.behavior), tostring(wp.behavior or "move"), tostring(wp.group), #guids, #guids == 1 and "" or "s"))
        if fn then pcall(fn, inst, task, wp, guids) end
    end
    local function fireById(id)                                     -- a named trigger's fires{} may name a support OR an order
        if inst.support[id]   then fireSupport(id) end
        if inst.waypoints[id] then fireOrder(id) end
    end
    for _, ev in ipairs(d.support or {}) do                          -- supports self-arm unless they wait on a named trigger
        local tr = ev.trigger
        if not (type(tr) == "table" and tr.ref) then armTrigger(inst, task, ev, tr, function() fireSupport(ev) end) end
    end
    for _, wp in ipairs(d.waypoints or {}) do                        -- orders self-arm; default = immediate after a short settle
        local tr = wp.trigger
        if not (type(tr) == "table" and tr.ref) then
            if tr == nil then tr = { once = wp.delay or 1.5 } end     -- let crews seat / units wake before ordering
            armTrigger(inst, task, wp, tr, function() fireOrder(wp) end)
        end
    end
    inst.trigFired = inst.trigFired or {}
    local function trigAction(t)                                      -- what a trigger (or gate) does when it fires
        inst.trigFired[t.id] = true
        for _, id in ipairs(t.fires or {}) do fireById(id) end
        for _, ev in ipairs(d.support or {})   do local tr = ev.trigger; if type(tr) == "table" and tr.ref == t.id then fireSupport(ev) end end
        for _, wp in ipairs(d.waypoints or {}) do local tr = wp.trigger; if type(tr) == "table" and tr.ref == t.id then fireOrder(wp) end end
    end
    for _, t in ipairs(d.triggers or {}) do
        if t.kind == "all" or t.kind == "count" then                 -- LOGIC GATE: fire once enough of its input triggers have fired
            local need = (t.kind == "all") and #(t.inputs or {}) or (t.need or #(t.inputs or {}))
            local function poll()
                if not inst.bActive then return end
                local n = 0; for _, id in ipairs(t.inputs or {}) do if inst.trigFired[id] then n = n + 1 end end
                if n >= need and need > 0 then Loader.Printf("Contract:   gate '" .. tostring(t.id) .. "' (" .. t.kind .. ") satisfied"); return trigAction(t) end
                addEv(task, Event.Create(Event.TimerRelative, { 0.4 }, poll))
            end
            poll()
        else
            armTrigger(inst, task, t, namedTrig(t), function() trigAction(t) end)   -- gates can chain: trigAction marks this fired too
        end
    end
end

-- ============================================================
-- Registration
-- ============================================================
function C.Register(def)
    if type(def) ~= "table" or not def.id then Loader.Printf("Contract.Register: table with an 'id' required"); return end
    if not def.objectives or #def.objectives == 0 then Loader.Printf("Contract.Register: '" .. def.id .. "' has no objectives") end
    if not C._byId[def.id] then C._registry[#C._registry + 1] = def end
    C._byId[def.id] = def
    Loader.Printf("Contract: registered '" .. def.id .. "'" .. (def.title and (" (" .. def.title .. ")") or ""))
end
function C.List() return C._registry end
C.All = C.List   -- alias the GFx board's preferred detection name (contracts.lua's API.list checks C.All first)

-- ============================================================
-- Status - the live state of the active contract, in exactly the shape the GFx board
-- (scripts/OnKey/contracts.lua) reads through its API.status() adapter:
--   { finished = nil|"complete"|"failed", progress = 0..1, timeLeft = sec,
--     objectives = { { done = bool }, ... } }  (parallel to the contract's own objectives)
-- The board owns all UI (the board window + Contract.UI.Panel/Bar tracker widgets); this framework
-- stays pure engine and just publishes state through here.
-- ============================================================
function C.Status()
    if C.finished then
        return { finished = C.finished.result,
                 progress = (C.finished.result == "complete") and 1 or nil,
                 objectives = C.finished.objectives }
    end
    local inst = C.active
    if not inst or not inst.bActive then return nil end
    local objs = inst.def.objectives or {}
    local st, done = { objectives = {} }, 0
    for i = 1, #objs do
        local d = inst.objDone[i] == true
        st.objectives[i] = { done = d }
        if d then done = done + 1 end
    end
    if #objs > 0 then st.progress = done / #objs end
    if inst.def.timeLimit and inst.startStamp then
        local ok, e = pcall(Sys.TimeStampGetElapsed, inst.startStamp)
        if ok and e then st.timeLeft = math.max(0, inst.def.timeLimit - e) end
    end
    return st
end

-- ============================================================
-- A built-in demo so the board isn't empty on a fresh install. Modders add their own via Register.
-- ============================================================
C.Register({
    id = "demo_convoy", title = "Demo: Wreck the Convoy", category = "DEMO",
    briefing = "Three cars, then reach the drop.",
    reward = { cash = 50000, fuel = 100 },
    objectives = {
        C.Destroy({ desc = "Destroy 3 cars" }),
        C.Reach({ desc = "Reach the drop-off", radius = 12 }),
    },
    -- fResolve runs at accept time to fill in dynamic coords (here, relative to the player). Real
    -- modder contracts use absolute coords from the creator and don't need this.
    fResolve = function(def)
        local uc = Player.GetLocalCharacter(); if not uc then return end
        local x, y, z = Object.GetPosition(uc)
        def.objectives[1].tSpawns = { { "Veyron", x + 8, y, z + 3, 0 }, { "Veyron", x + 10, y, z, 0 }, { "Veyron", x + 8, y, z - 3, 0 } }
        def.objectives[2].tZone   = { x = x + 40, y = y, z = z, r = 12 }
    end,
})

Loader.Printf("ContractFramework: loaded (" .. #C._registry .. " contract(s) registered)")
