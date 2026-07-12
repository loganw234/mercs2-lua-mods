-- =====================================================================
--  contracts.lua -- contract board + HUD widget layer for the movies
--  contracts.gfx / cpanel.gfx / cbar.gfx.
--
--  WHAT THIS FILE OWNS (UI side only):
--    * The two-pane board: category-grouped contract list on the left
--      (categories auto-detected from what modders register), details /
--      rewards / objectives / progress on the right.
--    * The flow: browse -> accept (double-Enter) -> board closes ->
--      tracker widgets stay up -> complete/fail teardown. While a
--      contract is active the board is LOCKED: reopening it shows the
--      active contract with a cancel option behind a confirm step.
--    * Contract.UI.Panel / Contract.UI.Bar -- reusable HUD widgets so
--      modders and the engine never touch Scaleform directly.
--
--  WHAT IT DOES NOT OWN: registering, running, and paying contracts.
--  That's your framework. The two sides meet ONLY in the API adapter
--  block below -- wire those four functions to your engine's names.
--  Until a framework is detected the board runs in DEMO mode: fake
--  contracts, simulated progress (one objective per ~4s), so the whole
--  UI can be shaken out standalone before the engine works.
--
--  KEYS:  KEYVAL toggles the board. Up/Down select (hold to repeat),
--         Right/Enter accept or confirm, Left backs out of prompts.
--
--  DEPLOY:  save as   <game>\scripts\OnKey\contracts.lua  (KEYVAL below auto-binds - no ini line needed)
--           and put contracts.gfx, cpanel.gfx, cbar.gfx with your movies.
--           Reads the framework via ContractFramework.lua's Contract.All/Accept/Abort/Status.
-- =====================================================================
local KEYVAL = "f5"              -- key that runs this script (auto-binds; was "home", clashed with WeaponTest.lua)

import("MrxGuiBase")
import("MrxGuiManager")

_G.CBOARD = _G.CBOARD or {}      -- survives the re-run on each keypress
local S = _G.CBOARD

-- Lua -> board movie: call one of its script functions (guarded).
local function call(fn, args)
    if S.w then pcall(function() S.w:CallActionScriptCallback(fn, args or {}) end) end
end

-- ================== Contract.UI widget layer =========================
-- Defined at file scope so it exists from the first time this script
-- runs. If your framework needs Panel/Bar before the board key is ever
-- pressed, move this file (or just this block) to a loader section that
-- runs at startup instead of [OnKey].
_G.Contract = _G.Contract or {}
Contract.UI = Contract.UI or {}

local function make_widget(file, x, y, w, h)
    local player = Player.GetLocalPlayer()
    local wg = MrxGuiBase.FlashWidget:new()
    pcall(function() wg:SetOwner(player) end)
    wg:SetLocation(x, y, w, h)
    wg:SetSwfFile(file, nil, nil)
    MrxGuiBase.AddWidget(wg)
    pcall(function() wg:SetVisible(true) end)
    pcall(function() MrxGuiManager.AddWidgetToHud(player, wg) end)
    return wg
end

-- Contract.UI.Panel{ x=, y=, w=, h=, title= }
--   :title(s)  :line(i, s)  (i = 0..7)  :clear()  :show()  :hide()  :destroy()
-- All methods return self, so calls chain.
function Contract.UI.Panel(opts)
    opts = opts or {}
    local o = {}
    o.w = make_widget("cpanel.gfx", opts.x or 20, opts.y or 120, opts.w or 300, opts.h or 200)
    local function c(fn, args)
        if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end
    end
    function o:title(s) c("SetTitle", { tostring(s) }) return self end
    function o:line(i, s) c("SetLine", { i, tostring(s) }) return self end
    function o:clear() for i = 0, 7 do c("SetLine", { i, "" }) end return self end
    function o:show() if o.w then pcall(function() o.w:SetVisible(true) end) end return self end
    function o:hide() if o.w then pcall(function() o.w:SetVisible(false) end) end return self end
    function o:destroy()
        -- No widget-removal API appears in the loader reference, so this
        -- hides and drops the reference. If your loader has a real remove
        -- call, put it here.
        if o.w then pcall(function() o.w:SetVisible(false) end) end
        o.w = nil
        return self
    end
    if opts.title then o:title(opts.title) end
    return o
end

-- Contract.UI.Bar{ x=, y=, w=, h=, label=, value= }
--   :set(v)  (v = 0..1)  :label(s)  :show()  :hide()  :destroy()
function Contract.UI.Bar(opts)
    opts = opts or {}
    local o = {}
    o.w = make_widget("cbar.gfx", opts.x or 20, opts.y or 330, opts.w or 300, opts.h or 36)
    local function c(fn, args)
        if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end
    end
    function o:set(v)
        v = tonumber(v) or 0
        if v < 0 then v = 0 end
        if v > 1 then v = 1 end
        c("SetBar", { math.floor(v * 100) })
        return self
    end
    function o:label(s) c("SetLabel", { tostring(s) }) return self end
    function o:show() if o.w then pcall(function() o.w:SetVisible(true) end) end return self end
    function o:hide() if o.w then pcall(function() o.w:SetVisible(false) end) end return self end
    function o:destroy()
        if o.w then pcall(function() o.w:SetVisible(false) end) end
        o.w = nil
        return self
    end
    if opts.label then o:label(opts.label) end
    if opts.value then o:set(opts.value) end
    return o
end

--#region gfxforge:build
-- Creates the board FlashWidget and loads contracts.gfx. (No fscommand
-- events: the movie is display-only, all input is handled Lua-side.)
local function build()
    local player = Player.GetLocalPlayer()
    local w = MrxGuiBase.FlashWidget:new()
    pcall(function() w:SetOwner(player) end)
    w:SetLocation(60, 60, 660, 420)          -- x, y, then the movie w, h
    w:SetSwfFile("contracts.gfx", nil, nil)
    MrxGuiBase.AddWidget(w)
    pcall(function() w:SetVisible(true) end)
    pcall(function() MrxGuiManager.AddWidgetToHud(player, w) end)
    S.w = w
    return w
end
--#endregion

-- All board logic lives in this user block so "Sync from scene" never
-- touches it. Wiring points are marked with ==== banners.
--#user helpers

-- ============ 1. LAYOUT / BEHAVIOUR CONSTANTS ========================
local VISIBLE   = 12             -- list slots in the movie (row0..row11)
local LIST_TOP  = 64             -- must match SetSelected in the movie
local ROW_PITCH = 26
local TRACK_Y   = 64             -- scrollbar track top
local TRACK_H   = 312            -- scrollbar track height
local TRACKER   = true           -- auto tracker widgets while a contract runs
local TRK_PX    = 12             -- tracker panel position (tucked into the top-left corner)
local TRK_PY    = 24
local LINGER    = 80             -- polls (~4s) the result stays on screen

-- ============ 2. FRAMEWORK ADAPTER (wire me) =========================
-- These four functions are the ONLY place the board touches your
-- engine. Each one tries a few likely names, so if your draft already
-- uses one of them it may just work; otherwise replace the bodies.
local API = {}

-- (a) list(): array of registered contract tables -- the exact shape
--     modders pass to Contract.Register (id, title, category, reward,
--     objectives, mode, timeLimit, optional/bonus, fail). Return nil to
--     put the board in DEMO mode.
function API.list()
    if _G.Contract then
        local C = _G.Contract
        if type(C.All) == "function" then
            local ok, r = pcall(C.All)
            if ok and type(r) == "table" then return r end
        end
        local spots = { "_registry", "registry", "Contracts", "contracts" }
        for _, k in ipairs(spots) do
            if type(C[k]) == "table" then return C[k] end
        end
    end
    return nil
end

-- (b) accept(c): start contract c. Return true on success.
function API.accept(c)
    if _G.Contract and type(Contract.Accept) == "function" then
        local ok = pcall(Contract.Accept, c.id)
        if not ok then ok = pcall(Contract.Accept, c) end
        return ok
    end
    return S.demo == true            -- demo mode pretends it worked
end

-- (c) cancel(c): abort the running contract (your engine cleans up).
function API.cancel(c)
    if _G.Contract then
        local names = { "Cancel", "Abort", "Abandon" }
        for _, n in ipairs(names) do
            if type(Contract[n]) == "function" then
                if pcall(Contract[n], c and c.id) then return true end
                if pcall(Contract[n], c) then return true end
            end
        end
    end
    return true
end

-- (d) status(): state of the running contract. Expected shape:
--     { finished   = nil | "complete" | "failed",
--       progress   = 0..1                  (optional),
--       timeLeft   = seconds               (optional),
--       objectives = { { done = bool }, ... }  -- parallel to c.objectives }
--     Return nil if unknown; the board then shows static info only and
--     completion must be noticed by you (or the player cancels).
function API.status()
    if _G.Contract and type(Contract.Status) == "function" then
        local ok, st = pcall(Contract.Status)
        if ok and type(st) == "table" then return st end
    end
    -- DEMO simulation: one objective completes every ~4 seconds.
    if S.demo and S.active then
        S.demoTicks = (S.demoTicks or 0) + 1
        local obs = S.active.objectives or {}
        local done = math.floor(S.demoTicks / 16)
        local st = { objectives = {} }
        for i = 1, #obs do st.objectives[i] = { done = (i <= done) } end
        if #obs > 0 then st.progress = done / #obs end
        if st.progress and st.progress > 1 then st.progress = 1 end
        if S.active.timeLimit then
            st.timeLeft = S.active.timeLimit - S.demoTicks * 0.25
            if st.timeLeft < 0 then st.timeLeft = 0 end
        end
        if done >= #obs then st.finished = "complete" end
        return st
    end
    return nil
end

-- ============ 3. DEMO CONTRACTS (used only when API.list() is nil) ===
local DEMO_CONTRACTS = {
    { id = "demo_ambush", title = "Ambush", category = "RAIDS",
      reward = { cash = 75000, fuel = 150 },
      objectives = {
          { type = "destroy", desc = "Wreck the convoy" },
          { type = "defend",  desc = "Hold 60s", time = 60 },
          { type = "reach",   desc = "Extract", radius = 15 },
      } },
    { id = "demo_holdhunt", title = "Hold & Hunt", category = "RAIDS",
      mode = "parallel", timeLimit = 300,
      reward = { cash = 120000 },
      objectives = {
          { type = "hold",    desc = "Hold the yard 90s" },
          { type = "destroy", desc = "Hunt the patrol" },
          { type = "collect", desc = "Grab 3 supply crates", optional = true, bonus = 15000 },
      },
      fail = { { type = "stayinarea", desc = "Stay in the district" } } },
    { id = "demo_escort", title = "Milk Run", category = "LOGISTICS",
      reward = { cash = 40000 },
      objectives = {
          { type = "enter",  desc = "Board the truck" },
          { type = "escort", desc = "Deliver it intact" },
      } },
}

-- ======================= internals below =============================
local function get_contracts()
    local t = API.list()
    if t == nil then
        S.demo = true
        return DEMO_CONTRACTS
    end
    S.demo = false
    if #t == 0 and next(t) ~= nil then       -- id->contract map: flatten
        local a = {}
        for _, v in pairs(t) do a[#a + 1] = v end
        return a
    end
    return t
end

local function comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local r = s:reverse()
    r = r:gsub("(%d%d%d)", "%1,")
    local out = r:reverse()
    out = out:gsub("^,", "")
    return out
end

local function fmt_time(sec)
    sec = math.floor(tonumber(sec) or 0)
    local m = math.floor(sec / 60)
    local s2 = sec - m * 60
    if s2 < 10 then return m .. ":0" .. s2 end
    return m .. ":" .. s2
end

local function obj_prefix(o)
    local t = o.type or o.kind or o.task
    if t then return "[" .. tostring(t):upper() .. "] " end
    return ""
end

-- Rebuild the flat display list: categories auto-detected from whatever
-- modders registered, alpha-sorted, contracts alpha-sorted within.
local function rebuild()
    local cs = get_contracts()
    local cats, order = {}, {}
    for _, c in ipairs(cs) do
        local cat = tostring(c.category or c.cat or "GENERAL"):upper()
        if not cats[cat] then cats[cat] = {}; order[#order + 1] = cat end
        cats[cat][#cats[cat] + 1] = c
    end
    table.sort(order)
    for _, cat in ipairs(order) do
        table.sort(cats[cat], function(a, b)
            return tostring(a.title or a.id) < tostring(b.title or b.id)
        end)
    end
    S.list = {}
    for _, cat in ipairs(order) do
        S.list[#S.list + 1] = { header = cat }
        for _, c in ipairs(cats[cat]) do S.list[#S.list + 1] = { c = c } end
    end
end

-- Find the nearest selectable (non-header) entry walking direction dir.
local function nearest_selectable(from, dir)
    local n = #S.list
    local i = from
    while i >= 0 and i <= n - 1 do
        if S.list[i + 1] and S.list[i + 1].c then return i end
        i = i + dir
    end
    return nil
end

-- Fill the right-hand details pane for contract c; st = live status or
-- nil for browse mode.
local function refresh_details(c, st)
    if not c then
        call("SetTitle", { "SELECT A CONTRACT" })
        call("SetCat", { " " })
        for i = 0, 3 do call("SetReward", { i, " " }) end
        for i = 0, 7 do call("SetObj", { i, " " }) end
        call("SetBar", { 0 })
        call("SetProg", { " " })
        return
    end
    call("SetTitle", { tostring(c.title or c.id or "?") })

    local meta = tostring(c.category or c.cat or "GENERAL"):upper()
    if c.mode then meta = meta .. "    MODE " .. tostring(c.mode):upper() end
    if c.timeLimit then meta = meta .. "    TIME " .. fmt_time(c.timeLimit) end
    if c.fail and #c.fail > 0 then meta = meta .. "    FAIL CONDS " .. #c.fail end
    call("SetCat", { meta })

    -- rewards: cash first, then the rest alphabetically
    local rw = {}
    local r = c.reward or {}
    if r.cash then rw[#rw + 1] = "CASH  $" .. comma(r.cash) end
    local rest = {}
    for k in pairs(r) do if k ~= "cash" then rest[#rest + 1] = k end end
    table.sort(rest)
    for _, k in ipairs(rest) do
        rw[#rw + 1] = tostring(k):upper() .. "  " .. tostring(r[k])
    end
    for i = 0, 3 do
        local s = rw[i + 1] or " "
        if i == 3 and #rw > 4 then s = "+" .. (#rw - 3) .. " MORE" end
        call("SetReward", { i, s })
    end

    -- objectives (8 slots; overflow collapses into "+N MORE")
    local obs = c.objectives or {}
    local n = #obs
    local sob = st and st.objectives
    local seq = tostring(c.mode or "sequential") ~= "parallel"
    local cur_marked = false
    for i = 0, 7 do
        local o = obs[i + 1]
        local s = " "
        if i == 7 and n > 8 then
            s = "+" .. (n - 7) .. " MORE"
        elseif o then
            local tick = "- "
            if st then
                local done = sob and sob[i + 1] and sob[i + 1].done
                if done then tick = "[x] "
                elseif seq and not cur_marked then tick = "[>] "; cur_marked = true
                else tick = "[ ] " end
            end
            s = tick .. obj_prefix(o) .. tostring(o.desc or ("objective " .. (i + 1)))
            if o.optional then
                s = s .. "  *BONUS"
                if o.bonus then s = s .. " $" .. comma(o.bonus) end
            end
        end
        call("SetObj", { i, s })
    end

    -- progress line + bar
    if st then
        local done, total = 0, n
        if sob then for _, x in ipairs(sob) do if x.done then done = done + 1 end end end
        local p = st.progress
        if not p and total > 0 then p = done / total end
        call("SetBar", { math.floor((p or 0) * 100) })
        local pr
        if st.finished == "complete" then pr = "COMPLETE"
        elseif st.finished == "failed" then pr = "FAILED"
        else
            pr = "IN PROGRESS  " .. done .. "/" .. total
            if st.timeLeft then pr = pr .. "    TIME " .. fmt_time(st.timeLeft) end
        end
        call("SetProg", { pr })
    else
        call("SetBar", { 0 })
        call("SetProg", { "ENTER TO ACCEPT" })
    end
end

-- Browse state: category-grouped list + details of the selection.
local function refresh_browse()
    local n = #S.list
    if n > 0 then
        if S.sel > n - 1 then S.sel = nearest_selectable(n - 1, -1) or 0 end
        if S.off > S.sel then S.off = S.sel end
        if S.sel > S.off + VISIBLE - 1 then S.off = S.sel - VISIBLE + 1 end
        if S.off < 0 then S.off = 0 end
    end
    for i = 0, VISIBLE - 1 do
        local e = S.list[S.off + i + 1]
        if not e then
            call("SetRow", { i, "" }); call("SetHdr", { i, "" })
        elseif e.header then
            call("SetHdr", { i, e.header }); call("SetRow", { i, "" })
        else
            call("SetRow", { i, tostring(e.c.title or e.c.id) }); call("SetHdr", { i, "" })
        end
    end
    if n == 0 then
        call("SetHdr", { 0, "NO CONTRACTS REGISTERED" })
        call("SetSelected", { -1 })
        call("SetScroll", { 0, 0 })
        refresh_details(nil, nil)
        call("SetHint", { "REGISTER CONTRACTS VIA Contract.Register{}" })
        return
    end
    call("SetSelected", { S.sel - S.off })
    if n > VISIBLE then
        local th = TRACK_H * VISIBLE / n
        if th < 18 then th = 18 end
        local ty = TRACK_Y + (TRACK_H - th) * S.off / (n - VISIBLE)
        call("SetScroll", { math.floor(ty), math.floor(th) })
    else
        call("SetScroll", { 0, 0 })
    end
    local e = S.list[S.sel + 1]
    refresh_details(e and e.c or nil, nil)
    if S.armed then
        call("SetHint", { "PRESS ENTER AGAIN TO ACCEPT   LEFT BACK OUT" })
    else
        call("SetHint", { "UP/DOWN SELECT   ENTER ACCEPT   " .. KEYVAL:upper() .. " CLOSE" })
    end
end

-- Locked state: contract running, board only offers cancel + confirm.
local function refresh_lock()
    for i = 0, VISIBLE - 1 do
        call("SetRow", { i, "" }); call("SetHdr", { i, "" })
    end
    call("SetHdr", { 0, "ACTIVE CONTRACT" })
    call("SetRow", { 1, tostring(S.active.title or S.active.id) })
    if S.mode == "confirm" then
        call("SetRow", { 3, "CONFIRM CANCEL?" })
        call("SetHint", { "ENTER CONFIRM CANCEL   LEFT KEEP CONTRACT" })
    else
        call("SetRow", { 3, "CANCEL CONTRACT" })
        call("SetHint", { "ENTER CANCEL (ASKS TO CONFIRM)   " .. KEYVAL:upper() .. " CLOSE" })
    end
    call("SetSelected", { 3 })
    call("SetScroll", { 0, 0 })
    refresh_details(S.active, S.last_st)
end

local function refresh()
    if S.mode == "browse" then refresh_browse() else refresh_lock() end
end

-- ---- tracker widgets (stay up while the board is closed) ------------
local function tracker_destroy()
    if S.tpanel then S.tpanel:destroy(); S.tpanel = nil end
    if S.tbar then S.tbar:destroy(); S.tbar = nil end
end

local function tracker_up(c)
    if not TRACKER then return end
    tracker_destroy()
    if c and c.hideTracker then return end   -- contract opts out of the board tracker (draws its own HUD, e.g. wave defense)
    S.trkTitle = tostring(c.title or c.id)
    -- one cohesive panel (no separate progress-bar widget); progress rides in the title
    S.tpanel = Contract.UI.Panel{ x = TRK_PX, y = TRK_PY, title = S.trkTitle }
    local obs = c.objectives or {}
    for i = 0, 7 do
        local o = obs[i + 1]
        if o then S.tpanel:line(i, "[ ] " .. tostring(o.desc or "objective")) end
    end
end

local function tracker_update(c, st)
    if not (TRACKER and S.tpanel) then return end
    local obs = c.objectives or {}
    local sob = st.objectives
    local done, total = 0, #obs
    if sob then for _, x in ipairs(sob) do if x.done then done = done + 1 end end end
    for i = 0, 7 do
        local o = obs[i + 1]
        if o then
            local d = sob and sob[i + 1] and sob[i + 1].done
            local s = (d and "[x] " or "[ ] ") .. tostring(o.desc or "objective")
            if o.optional then s = s .. "  *BONUS" end
            S.tpanel:line(i, s)
        end
    end
    local lbl = "   " .. done .. "/" .. total
    if st.timeLeft then lbl = lbl .. "   " .. fmt_time(st.timeLeft) end
    S.tpanel:title((S.trkTitle or "CONTRACT") .. lbl)
end

-- ---- actions ---------------------------------------------------------
local function do_accept(c)
    if API.accept(c) then
        S.active, S.mode, S.armed = c, "active", nil
        S.last_st, S.demoTicks, S.warned = nil, 0, nil
        tracker_up(c)
        Loader.Printf("[cboard] accepted: " .. tostring(c.id or c.title))
        -- board closes, widgets stay up
        S.shown = false
        pcall(function() S.w:SetVisible(false) end)
    else
        call("SetHint", { "ACCEPT FAILED -- SEE LOG" })
        Loader.Printf("[cboard] accept FAILED: " .. tostring(c.id or c.title))
    end
end

local function do_cancel()
    API.cancel(S.active)
    Loader.Printf("[cboard] cancelled: " .. tostring(S.active and (S.active.id or S.active.title)))
    tracker_destroy()
    S.active, S.last_st, S.armed = nil, nil, nil
    S.mode = "browse"
    rebuild()
    S.sel = nearest_selectable(S.sel or 0, 1) or nearest_selectable(#S.list - 1, -1) or 0
    refresh()
    call("SetHint", { "CONTRACT CANCELLED" })
end

local function choose()
    if S.mode == "browse" then
        local e = S.list[S.sel + 1]
        if not (e and e.c) then return end
        if S.armed == S.sel then
            S.armed = nil
            do_accept(e.c)
        else
            S.armed = S.sel               -- double-Enter guard
            refresh()
        end
    elseif S.mode == "active" then
        S.mode = "confirm"
        refresh()
    elseif S.mode == "confirm" then
        do_cancel()
    end
end

local function back()
    if S.mode == "confirm" then
        S.mode = "active"
        refresh()
    elseif S.mode == "browse" and S.armed then
        S.armed = nil
        refresh()
    end
end

local function move(d)
    if S.mode ~= "browse" or #S.list == 0 then return end
    local t = nearest_selectable(S.sel + d, d)
    if t and t ~= S.sel then
        S.sel = t
        S.armed = nil
        refresh()
    end
end

-- ---- key polling + live status --------------------------------------
local REPEAT_DELAY = 7           -- ~0.35s before repeating starts
local REPEAT_RATE  = 2           -- then ~every 0.10s
-- Input (perf fix): 2 lua-bridge calls/tick instead of one Loader.IsKeyDown PER KEY (that per-key
-- polling was the framerate hit with the board open). Discrete presses come from ONE Loader.PopKeyEvents
-- ring drain (VK edges, focus-gated, captures arrows/Enter); the two repeatable nav keys' HOLD comes
-- from ONE Loader.GetKeyboardState snapshot. See poll().
local function navUp()   move(-1) end
local function navDown() move(1) end
local KEY_ACTIONS = {          -- VK -> initial-press action
    [0x26] = navUp,            -- Up
    [0x28] = navDown,          -- Down
    [0x25] = back,             -- Left  (back)
    [0x27] = choose,           -- Right (open / accept)
    [0x0D] = choose,           -- Enter (open / accept)
}
local REPEAT_KEYS = {          -- only Up/Down auto-repeat while held
    { code = 0x26, held = 0, fn = navUp },
    { code = 0x28, held = 0, fn = navDown },
}

-- Tear the tracker widgets down immediately with NO lingering completion message (the framework
-- shows a native fanfare instead). Called by the framework's C.onFinish hook (instant, in sync with
-- the fanfare) and as the status_tick fallback if the framework didn't call it (e.g. DEMO mode).
local function finish_teardown()
    tracker_destroy()
    S.trkTTL = nil
    S.active, S.last_st, S.armed = nil, nil, nil
    S.mode = "browse"
    rebuild()
    S.sel = nearest_selectable(0, 1) or 0
    if S.shown then refresh() end
end
-- let the framework hide our UI the instant a contract ends, in sync with its fanfare
if _G.Contract then _G.Contract.onFinish = finish_teardown end

-- Runs every ~0.25s: pull status, drive widgets, detect completion.
local function status_tick()
    if not S.active then return end
    local st = API.status()
    if not st then
        if not S.warned then
            S.warned = true
            Loader.Printf("[cboard] no status source -- wire API.status() for live tracking")
        end
        return
    end
    S.last_st = st
    if st.finished then
        Loader.Printf("[cboard] contract " .. tostring(st.finished) .. ": "
            .. tostring(S.active.id or S.active.title))
        finish_teardown()                 -- hide instantly, no message; the framework fanfare is the cue
    else
        tracker_update(S.active, st)
        if S.shown and S.mode ~= "browse" then refresh_lock() end
    end
end

local function poll()
    Event.Create(Event.TimerRelative, { 0.05 }, poll)   -- ~20x/sec, self-reschedules
    -- tracker teardown countdown runs even while the board is hidden
    if S.trkTTL then
        S.trkTTL = S.trkTTL - 1
        if S.trkTTL <= 0 then S.trkTTL = nil; tracker_destroy() end
    end
    S.stTick = (S.stTick or 0) + 1
    if S.stTick >= 5 then S.stTick = 0; status_tick() end
    if not S.w or not S.shown then
        for _, k in ipairs(REPEAT_KEYS) do k.held = 0 end
        S.wasShown = false
        return                                    -- board closed: don't touch the key buffers at all
    end
    if not S.wasShown then pcall(Loader.ClearKeyEvents); S.wasShown = true end   -- just opened: drop stale edges
    -- discrete presses: one ring drain, fire each key's initial press in order
    local ev = Loader.PopKeyEvents()
    if ev and ev ~= "" then
        for i = 1, #ev do
            local a = KEY_ACTIONS[string.byte(ev, i)]
            if a then a() end
        end
    end
    -- hold-to-repeat (Up/Down): ONE keyboard snapshot; the initial press already fired above, so the
    -- held counter only starts the delayed repeat (held reaches REPEAT_DELAY without re-firing the press).
    local ks = Loader.GetKeyboardState()
    if ks then
        for _, k in ipairs(REPEAT_KEYS) do
            if string.byte(ks, k.code + 1) >= 128 then
                k.held = k.held + 1
                if k.held > REPEAT_DELAY and ((k.held - REPEAT_DELAY) % REPEAT_RATE) == 0 then k.fn() end
            else
                k.held = 0
            end
        end
    end
end
--#enduser

-- ---- build on first press, hide/show on repeat ----------------------
local ok, err = pcall(function()
    if not S.w then
        build()
        S.shown, S.mode = true, "browse"
        S.sel, S.off = 0, 0
        rebuild()
        S.sel = nearest_selectable(0, 1) or 0
        -- SetSwfFile is async: a refresh() right here fires before the movie has loaded and gets
        -- dropped (that was the "needs an input before it populates" bug). Re-push once it's ready.
        Event.Create(Event.TimerRelative, { 0.15 }, function() if S.shown then refresh() end end)
        Event.Create(Event.TimerRelative, { 0.40 }, function() if S.shown then refresh() end end)
        Loader.Printf("[cboard] built -- " .. KEYVAL .. " toggles the board"
            .. (S.demo and "  (DEMO DATA: no framework detected)" or ""))
    else
        S.shown = not S.shown
        pcall(function() S.w:SetVisible(S.shown) end)
        if S.shown then
            if S.mode == "browse" then
                rebuild()                 -- pick up newly registered contracts
                local e = S.list[S.sel + 1]
                if not (e and e.c) then S.sel = nearest_selectable(0, 1) or 0 end
            end
            refresh()
        end
        Loader.Printf("[cboard] " .. (S.shown and "shown" or "hidden"))
    end
end)
if not ok then Loader.Printf("[cboard] ERROR: " .. tostring(err)) end
if S.w and not S.pollOn then S.pollOn = true; poll() end
