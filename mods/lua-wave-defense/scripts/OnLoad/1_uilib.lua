-- =====================================================================
--  uilib.lua -- modular in-game UI kit for Mercenaries 2 modders (v2.0)
--
--  v2 REWRITE: same movies, same friendly API, brand-new engine room.
--  v1 drove input with an always-on 33Hz IsKeyDown poll + focus model that
--  misbehaved in-game. v2 is rebuilt on the exact plumbing that made
--  ForgeMenu rock-solid:
--     * input via Loader.PopKeyEvents() (edge drain) + GetKeyboardState()
--     * a self-re-arming Event.TimerRelative heartbeat with a generation
--       guard that RUNS ONLY WHILE SOMETHING IS ACTIVE and idles otherwise
--     * async-load warm-up re-paints (the movie loads a frame late, so the
--       first paint can be dropped - we re-send it for a few ticks)
--     * every engine call wrapped in pcall
--  Movies: ui_list.gfx  ui_panel.gfx  ui_bar.gfx  ui_toast.gfx
--          ui_confirm.gfx  ui_input.gfx   (all already in your wad)
--
--  ============================ QUICK REFERENCE ========================
--  UI.Menu{ title, key, x, y, onClose }          <- the ForgeMenu-style star
--      A declarative drill-down menu. You only declare categories + entries;
--      an entry runs a plain function. Put :toggle() at the end of your
--      OnKey file (the toggle key opens/closes it).
--        local m = UI.Menu{ title = "MY MENU", key = "F8" }
--        m:entry("Do a thing", function(ctx) ctx:hint("done") end)
--        m:category("Spawns", function(c)
--            c:entry("Tank", function(ctx) ctx:spawn("M1A2 (Full)", 8) end)
--            c:category("Enemies", function(cc) cc:entry(...) end)   -- nests
--        end)
--        m:toggle()
--      Entry actions get ctx: ctx.x/y/z/yaw, ctx.char/player,
--        ctx:spawn(template[,dist])  ctx:hint(msg)  ctx:print(msg)  ctx:close()
--      A label may be a function returning a string (live ON/OFF toggles).
--      :entry :category :header(text) :toggle :open :close :isOpen
--
--  UI.List{ x, y, title, crumb, hint, items, empty, focus,
--           onChoose, onBack, onSelect }         <- the raw list (advanced)
--      10 visible rows, section headers the cursor skips, scrollbar, body
--      that auto-resizes to content. Swap :items() in onChoose for drill-downs.
--      items = { {header="SECTION"}, {label="Entry", any=yourdata}, ... }
--      :items(t)  :selected()->item,i  :select(i)  :paint()
--      :title(s)  :crumb(s)  :hint(s)
--      onChoose(item,i,list)  onSelect(item,i,list)  onBack(list)
--
--  UI.Panel{ x, y, title, lines }
--      Title bar + up to 8 lines, body auto-resizes.  :title(s) :line(i,s) :fit(n) :clear()
--
--  UI.Bar{ x, y, label, value }
--      Label + progress bar.  :set(0..1)  :label(s)
--
--  UI.Toast("text"[, { ttl = seconds }])
--      Transient notification, 3 stacked slots, oldest replaced, auto-hides.
--
--  UI.Confirm{ text, title, yes, no, onResult }
--      Modal yes/no. Grabs keys (Left/Right pick, Enter choose, Esc = no;
--      defaults to NO), restores focus, then onResult(true|false). One at a time.
--
--  UI.Input{ prompt, text, max, onSubmit, onCancel }
--      One-shot typed prompt. Enter -> onSubmit(text), Esc -> onCancel().
--      US-layout shifted symbols (edit PUNCT for other layouts). One at a time.
--
--  Every widget also has:  :show() :hide() :focus() :blur() :destroy()  (chainable)
--  Utilities:  UI.wrap(s,width)->lines   UI.comma(n)   UI.fmt_time(s)
--  Focus:  UI.Focus(w)  UI.Focused()   (exactly one widget hears keys)
--
--  DEPLOY
--    1) uilib.lua -> scripts/OnLoad/  and register it:  [OnLoad] uilib.lua=5
--       (loads once at world load; re-runs harmlessly on reload)
--    2) the six ui_*.gfx movies injected in your wad (already done).
--    3) your menu -> scripts/OnKey/MyMenu.lua with a toggle key in [OnKey],
--       and `local KEYVAL="f8"` in its first 10 lines. Guard with:
--         if not (UI and UI.Menu) then Loader.Printf("load uilib first"); return end
--  KEY NOTE: pick a toggle key that ISN'T an arrow / Enter / Esc / Backspace -
--    those drive the focused widget while it is open.
-- =====================================================================

import("MrxGuiBase")
import("MrxGuiManager")

_G.UI = _G.UI or {}
UI._S = UI._S or {}                 -- internals; survive re-runs
local S = UI._S

UI.VERSION = "2.2"   -- 2.2: UI.Menu ForgeMenu parity (persistent per-id state = real toggle, no leak),
                     -- + :switch / ctx:confirm/ask/toast / UI.KEYS remap / UI.hero + reload-safe reset.
                     -- 2.2a: ctx:spawn rejects blank templates (Pg.Spawn("") is a native CTD pcall can't catch).
                     -- 2.1: SetLocation corner-coords fix (broken toasts/dialogs); added UI.Chat + UI.Board
UI.FILES = UI.FILES or {
    list = "ui_list.gfx", panel = "ui_panel.gfx", bar = "ui_bar.gfx",
    toast = "ui_toast.gfx", confirm = "ui_confirm.gfx", input = "ui_input.gfx",
    chat = "chat.gfx", board = "contracts.gfx",   -- the two richer movies UI.Chat / UI.Board wrap
}
-- Widget coordinates live in a fixed 640x480 virtual canvas (Scaleform scales it to any resolution),
-- so the right edge is x=640 and the bottom is y=480. Toasts default to the RIGHT side (320 wide,
-- right-aligned with an 8px margin), a little below the top corner so a top-right panel/chat has room.
UI.TOAST_W     = UI.TOAST_W or 160          -- half-size toasts (was 320)
UI.TOAST_H     = UI.TOAST_H or 22           -- (was 44)
UI.TOAST_GAP   = UI.TOAST_GAP or 25         -- vertical spacing between stacked toasts (was 50)
UI.TOAST_X     = UI.TOAST_X or (640 - UI.TOAST_W - 8)   -- right-aligned (= 472 at W=160)
UI.TOAST_Y     = UI.TOAST_Y or 150
UI.TOAST_SLOTS = UI.TOAST_SLOTS or 3
UI.TOAST_TTL   = UI.TOAST_TTL or 4          -- seconds

local TICK   = 0.05                          -- heartbeat interval (s)
local WARMUP = 8                             -- ticks of re-paint after a widget shows (defeats async movie load)

-- ============================ utilities ==============================
function UI.wrap(s, width)
    s = tostring(s or ""); width = width or 46
    local out = {}
    while #s > width do
        local cut = width
        for i = width, math.max(1, width - 15), -1 do
            if s:sub(i, i) == " " then cut = i; break end
        end
        out[#out + 1] = s:sub(1, cut)
        s = s:sub(cut + 1):gsub("^%s+", "")
    end
    if #s > 0 then out[#out + 1] = s end
    if #out == 0 then out[1] = "" end
    return out
end

function UI.comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local r = s:reverse():gsub("(%d%d%d)", "%1,")
    return (r:reverse():gsub("^,", ""))
end

function UI.fmt_time(sec)
    sec = math.floor(tonumber(sec) or 0)
    local m = math.floor(sec / 60)
    local s2 = sec - m * 60
    if s2 < 10 then return m .. ":0" .. s2 end
    return m .. ":" .. s2
end

-- ========================= engine forward decls ======================
local ensureTick, register

-- ============================ core plumbing ==========================
local function make_widget(file, x, y, w, h)
    local player = Player.GetLocalPlayer()
    local wg = MrxGuiBase.FlashWidget:new()
    pcall(function() wg:SetOwner(player) end)
    -- SetLocation takes CORNER coords (x1, y1, x2, y2), NOT (x, y, width, height).
    -- Passing w/h as the corners makes any widget whose w<x or h<y collapse into an
    -- inverted rect and render as a giant smear (that was the "broken toasts" bug).
    wg:SetLocation(x, y, x + w, y + h)
    wg:SetSwfFile(file, nil, nil)
    MrxGuiBase.AddWidget(wg)
    pcall(function() wg:SetVisible(true) end)
    pcall(function() MrxGuiManager.AddWidgetToHud(player, wg) end)
    return wg
end

-- focus: exactly one widget hears keys. Setting it swallows any buffered keys
-- (so the toggle press doesn't leak in) and wakes the heartbeat.
local function ui_focus(o)
    S.focus = o
    pcall(Loader.ClearKeyEvents)
    ensureTick()
end
function UI.Focus(w) ui_focus(w) end
function UI.Focused() return S.focus end

-- show/hide/focus/blur/destroy shared by every widget object.
local function attach_common(o)
    function o:show()
        if o.w then pcall(function() o.w:SetVisible(true) end) end
        o._shown = true
        o._warmup = WARMUP
        ensureTick()
        pcall(function() o:_repaint() end)
        return self
    end
    function o:hide()
        if o.w then pcall(function() o.w:SetVisible(false) end) end
        o._shown = false
        if S.focus == o then S.focus = nil end
        return self
    end
    function o:destroy()
        -- no widget-removal API in the loader reference, so hide + drop the
        -- reference and let it fall out of the live list. Prefer reuse.
        if S.focus == o then S.focus = nil end
        if o.w then pcall(function() o.w:SetVisible(false) end) end
        o.w = nil
        return self
    end
    function o:focus() ui_focus(o); return self end
    function o:blur() if S.focus == o then S.focus = nil end return self end
    function o:_repaint() end            -- widgets override to re-send their state
end

-- body-resize easing target (the "Forge feel"); waking the heartbeat animates it
local function set_target(o, pct)
    o._tgt = pct
    ensureTick()
end

-- ============================ input maps =============================
-- Navigation keys, remappable globally (Windows VK codes). e.g. UI.KEYS.up = 0x57 -- 'W'
UI.KEYS = UI.KEYS or { up = 0x26, down = 0x28, left = 0x25, right = 0x27, enter = 0x0D, esc = 0x1B }
local function navName(vk)
    local k = UI.KEYS
    if vk == k.up then return "up"
    elseif vk == k.down then return "down"
    elseif vk == k.left then return "left"
    elseif vk == k.right then return "right"
    elseif vk == k.enter then return "enter"
    elseif vk == k.esc then return "esc" end
    return nil
end

-- vk -> { n = normal char, s = shifted char }  (US layout; edit for others)
local CHAR = {}
for c = 0x41, 0x5A do CHAR[c] = { n = string.char(c + 32), s = string.char(c) } end
local DIGSHIFT = { [0] = ")", "!", "@", "#", "$", "%", "^", "&", "*", "(" }
for d = 0, 9 do CHAR[0x30 + d] = { n = tostring(d), s = DIGSHIFT[d] } end
CHAR[0x20] = { n = " ", s = " " }
local PUNCT = {
    { 0xBC, ",", "<" }, { 0xBE, ".", ">" }, { 0xBF, "/", "?" }, { 0xBD, "-", "_" },
    { 0xBB, "=", "+" }, { 0xBA, ";", ":" }, { 0xDE, "'", "\"" }, { 0xDB, "[", "{" },
    { 0xDD, "]", "}" }, { 0xDC, "\\", "|" }, { 0xC0, "`", "~" },
}
for _, p in ipairs(PUNCT) do CHAR[p[1]] = { n = p[2], s = p[3] } end

-- player pose helper (for UI.Menu ctx:spawn)
local function pose()
    local char = Player.GetLocalCharacter()
    local player = Player.GetLocalPlayer()
    if not char then return nil, nil, nil, 0, nil, player end
    local ok, px, py, pz = pcall(Object.GetPosition, char)
    if not ok or not px then return nil, nil, nil, 0, char, player end
    local yaw = 0
    local oky, yv = pcall(Object.GetYaw, char); if oky and yv then yaw = yv end
    return px, py, pz, yaw, char, player
end

-- convenience shortcuts modders reach for constantly
function UI.hero() return Player.GetLocalCharacter() end       -- local character guid (nil if none)
function UI.heroPos() return pose() end                        -- x, y, z, yaw, char, player

-- ======================= the shared heartbeat ========================
-- Services: (1) keys for the focused widget, (2) warm-up re-paints + size
-- easing for live widgets, (3) toast lifetimes, (4) input caret blink.
local function service(dt)
    -- 1. keyboard: only the focused widget hears anything, edge-drained
    local f = S.focus
    if f and f._keyvk and f.w and f._shown ~= false then
        local ev = Loader.PopKeyEvents()
        if ev and ev ~= "" then
            local ks = Loader.GetKeyboardState()
            local shift = ks and (string.byte(ks, 0x10 + 1) or 0) >= 128
            for i = 1, #ev do
                if S.focus ~= f then break end          -- an action changed focus (closed / opened a modal): stop feeding the old widget
                f:_keyvk(string.byte(ev, i), shift)
            end
        end
    end
    -- 2. live widgets: warm-up re-paint + resize easing
    if S.live then
        for i = #S.live, 1, -1 do
            local o = S.live[i]
            if not o or not o.w then
                table.remove(S.live, i)
            else
                if o._warmup and o._warmup > 0 then
                    o._warmup = o._warmup - 1
                    pcall(function() o:_repaint() end)
                end
                if o._cur and o._tgt and o._cur ~= o._tgt then
                    local d = o._tgt - o._cur
                    if d > 0.5 or d < -0.5 then o._cur = o._cur + d * 0.35 else o._cur = o._tgt end
                    if o._setsize then o._setsize(o._cur) end
                end
            end
        end
    end
    -- 3. toasts
    if S.toasts then
        for i = 1, UI.TOAST_SLOTS do
            local t = S.toasts[i]
            if t and t.ttl then
                if t.warmup and t.warmup > 0 then t.warmup = t.warmup - 1; pcall(t.repaint) end
                t.ttl = t.ttl - dt
                if t.ttl <= 0 then t.ttl = nil; pcall(function() t.w:SetVisible(false) end) end
            end
        end
    end
    -- 4. input caret blink
    if f and f._isInput and f.w and f._shown ~= false then
        f._blinkClock = (f._blinkClock or 0) + dt
        if f._blinkClock >= 0.35 then f._blinkClock = 0; f._blink = not f._blink; f:_echo() end
    end
end

local function needsTick()
    if S.focus then return true end
    if S.live then
        for _, o in ipairs(S.live) do
            if o.w and ((o._warmup and o._warmup > 0) or (o._cur and o._tgt and o._cur ~= o._tgt)) then
                return true
            end
        end
    end
    if S.toasts then
        for i = 1, UI.TOAST_SLOTS do if S.toasts[i] and S.toasts[i].ttl then return true end end
    end
    return false
end

-- start the heartbeat if it isn't already running; it self-stops when idle.
ensureTick = function()
    if S.running then return end
    S.running = true
    S.tickGen = (S.tickGen or 0) + 1
    local myGen = S.tickGen
    S.stamp = Sys.RealTimeStamp()
    local function loop()
        if not S.running or S.tickGen ~= myGen then return end   -- superseded / stopped
        local dt = TICK
        if S.stamp then
            local e = Sys.TimeStampGetElapsed(S.stamp)
            if e and e > 0 then dt = e end
            Sys.TimeStampMark(S.stamp)
        end
        if dt > 0.25 then dt = 0.25 end
        local ok, err = pcall(service, dt)
        if not ok then Loader.Printf("[uilib] tick error: " .. tostring(err)) end
        if needsTick() then
            Event.Create(Event.TimerRelative, { TICK }, loop)
        else
            S.running = false                                    -- idle -> stop; ensureTick restarts on demand
        end
    end
    Event.Create(Event.TimerRelative, { TICK }, loop)
end

register = function(o)
    S.live = S.live or {}
    for _, e in ipairs(S.live) do if e == o then return end end
    S.live[#S.live + 1] = o
end

-- =============================== UI.List =============================
function UI.List(opts)
    opts = opts or {}
    local o = {}
    o.w = make_widget(UI.FILES.list, opts.x or 40, opts.y or 60, opts.w or 320, opts.h or 360)
    o._shown = true
    local function c(fn, args) if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end end
    o._call = c
    attach_common(o); register(o)
    o._cur, o._tgt = 100, 100
    o._setsize = function(v) c("SetSize", { v }) end
    o._items, o._sel, o._off = {}, 1, 0
    o._title, o._crumb, o._hint = opts.title, opts.crumb, opts.hint
    o.onChoose, o.onBack, o.onSelect = opts.onChoose, opts.onBack, opts.onSelect

    local VIS, TOP, PITCH, TRH, BODY = 10, 64, 24, 232, 296

    local function selectable(i) local it = o._items[i]; return it ~= nil and not it.header end
    local function nearest(from, dir)
        local i = from
        while i >= 1 and i <= #o._items do
            if selectable(i) then return i end
            i = i + dir
        end
        return nil
    end
    local function hdr_text(it)
        if it.header == true then return tostring(it.label or "") end
        return tostring(it.header)
    end

    function o:paint()
        local n = #o._items
        if n > 0 then
            if not selectable(o._sel) then o._sel = nearest(o._sel, 1) or nearest(o._sel, -1) or 1 end
            local s0 = o._sel - 1
            if o._off > s0 then o._off = s0 end
            if s0 > o._off + VIS - 1 then o._off = s0 - VIS + 1 end
            if o._off < 0 then o._off = 0 end
        else
            o._off = 0
        end
        for i = 0, VIS - 1 do
            local it = o._items[o._off + i + 1]
            if not it then c("SetRow", { i, "" }); c("SetHdr", { i, "" })
            elseif it.header then c("SetHdr", { i, hdr_text(it) }); c("SetRow", { i, "" })
            else c("SetRow", { i, tostring(it.label or "?") }); c("SetHdr", { i, "" }) end
        end
        if n == 0 then
            c("SetHdr", { 0, tostring(opts.empty or "EMPTY") }); c("SetSelected", { -1 }); c("SetScroll", { 0, 0 })
        else
            if selectable(o._sel) then c("SetSelected", { (o._sel - 1) - o._off }) else c("SetSelected", { -1 }) end
            if n > VIS then
                local th = TRH * VIS / n; if th < 16 then th = 16 end
                local ty = TOP + (TRH - th) * o._off / (n - VIS)
                c("SetScroll", { math.floor(ty), math.floor(th) })
            else
                c("SetScroll", { 0, 0 })
            end
        end
        local shown = n; if shown > VIS then shown = VIS end; if shown < 1 then shown = 1 end
        set_target(o, 100 * (PITCH * shown + 12) / BODY)
        return self
    end

    function o:_repaint()
        if o._title then c("SetTitle", { tostring(o._title) }) end
        if o._crumb then c("SetCrumb", { tostring(o._crumb) }) end
        if o._hint then c("SetHint", { tostring(o._hint) }) end
        o:paint()
        if o._setsize then o._setsize(o._cur) end
    end

    function o:title(s) o._title = s; c("SetTitle", { tostring(s) }) return self end
    function o:crumb(s) o._crumb = s; c("SetCrumb", { tostring(s) }) return self end
    function o:hint(s)  o._hint = s;  c("SetHint",  { tostring(s) }) return self end
    function o:items(t)
        o._items = t or {}
        o._sel = nearest(1, 1) or 1
        o._off = 0
        return o:paint()
    end
    function o:selected() return o._items[o._sel], o._sel end
    function o:select(i) if selectable(i) then o._sel = i; o:paint() end return self end

    function o:_keyvk(vk)
        local k = navName(vk); if not k then return end
        if k == "up" or k == "down" then
            local d = (k == "up") and -1 or 1
            local t = nearest(o._sel + d, d)
            if t and t ~= o._sel then
                o._sel = t; o:paint()
                if o.onSelect then pcall(o.onSelect, o._items[o._sel], o._sel, o) end
            end
        elseif k == "enter" or k == "right" then
            local it = o._items[o._sel]
            if it and not it.header and o.onChoose then pcall(o.onChoose, it, o._sel, o) end
        elseif k == "left" or k == "esc" then
            if o.onBack then pcall(o.onBack, o) end
        end
    end

    if o._title then c("SetTitle", { tostring(o._title) }) end
    if o._crumb then c("SetCrumb", { tostring(o._crumb) }) end
    if o._hint then c("SetHint", { tostring(o._hint) }) end
    o:items(opts.items or {})
    o._cur = o._tgt; o._setsize(o._cur)
    o._warmup = WARMUP
    if opts.focus then o:focus() end
    ensureTick()
    return o
end

-- =============================== UI.Panel ============================
local function panel_px(n) return 40 + 18 * n end

function UI.Panel(opts)
    opts = opts or {}
    local o = {}
    o.w = make_widget(UI.FILES.panel, opts.x or 20, opts.y or 120, opts.w or 300, opts.h or 200)
    o._shown = true
    local function c(fn, args) if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end end
    o._call = c
    attach_common(o); register(o)
    o._lines = 8
    o._titleStr = opts.title
    o._L = {}
    o._cur, o._tgt = 100, 100
    o._setsize = function(v) c("SetSize", { v }) end
    function o:title(s) o._titleStr = s; c("SetTitle", { tostring(s) }) return self end
    function o:fit(n)
        n = tonumber(n) or 0; if n < 0 then n = 0 end; if n > 8 then n = 8 end
        o._lines = n
        set_target(o, 100 * panel_px(n) / 200)
        return self
    end
    function o:line(i, s)
        o._L[i] = tostring(s)
        c("SetLine", { i, tostring(s) })
        if o._L[i]:gsub("%s", "") ~= "" and (i + 1) > (o._lines or 0) then o:fit(i + 1) end
        return self
    end
    function o:clear()
        for i = 0, 7 do o._L[i] = ""; c("SetLine", { i, "" }) end
        o:fit(0)
        return self
    end
    function o:_repaint()
        if o._titleStr then c("SetTitle", { tostring(o._titleStr) }) end
        for i = 0, 7 do if o._L[i] then c("SetLine", { i, o._L[i] }) end end
        if o._setsize then o._setsize(o._cur) end
    end
    if opts.title then o:title(opts.title) end
    o:fit(opts.lines or 0)
    o._cur = o._tgt; o._setsize(o._cur)
    o._warmup = WARMUP
    ensureTick()
    return o
end

-- =============================== UI.Bar =============================
function UI.Bar(opts)
    opts = opts or {}
    local o = {}
    o.w = make_widget(UI.FILES.bar, opts.x or 20, opts.y or 330, opts.w or 300, opts.h or 36)
    o._shown = true
    local function c(fn, args) if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end end
    o._call = c
    attach_common(o); register(o)
    o._pct, o._labelStr = 0, opts.label
    function o:set(v)
        v = tonumber(v) or 0; if v < 0 then v = 0 end; if v > 1 then v = 1 end
        o._pct = math.floor(v * 100)
        c("SetBar", { o._pct })
        return self
    end
    function o:label(s) o._labelStr = s; c("SetLabel", { tostring(s) }) return self end
    function o:_repaint()
        if o._labelStr then c("SetLabel", { tostring(o._labelStr) }) end
        c("SetBar", { o._pct })
    end
    if opts.label then o:label(opts.label) end
    o:set(opts.value or 0)
    o._warmup = WARMUP
    ensureTick()
    return o
end

-- ============================== UI.Toast ============================
function UI.Toast(text, opts)
    opts = opts or {}
    S.toasts = S.toasts or {}
    local pick, soonest
    for i = 1, UI.TOAST_SLOTS do
        local t = S.toasts[i]
        if not t or not t.ttl then pick = i; break end
        if not soonest or t.ttl < S.toasts[soonest].ttl then soonest = i end
    end
    pick = pick or soonest or 1
    local t = S.toasts[pick]
    if not t then
        t = {}
        t.w = make_widget(UI.FILES.toast, UI.TOAST_X, UI.TOAST_Y + (pick - 1) * UI.TOAST_GAP, UI.TOAST_W, UI.TOAST_H)
        S.toasts[pick] = t
    end
    local function c(fn, args) if t.w then pcall(function() t.w:CallActionScriptCallback(fn, args) end) end end
    local lines = UI.wrap(tostring(text), 46)
    t.l0, t.l1 = lines[1] or "", lines[2] or ""
    t.repaint = function() c("SetLine", { 0, t.l0 }); c("SetLine", { 1, t.l1 }) end
    t.repaint()
    pcall(function() t.w:SetVisible(true) end)
    t.ttl = (opts.ttl or UI.TOAST_TTL)
    t.warmup = WARMUP
    function t:dismiss() t.ttl = nil; pcall(function() t.w:SetVisible(false) end) end
    ensureTick()
    return t
end

-- ============================= UI.Confirm ===========================
function UI.Confirm(opts)
    opts = opts or {}
    local o = S.confirm
    if not o then
        o = {}
        o.w = make_widget(UI.FILES.confirm, opts.x or 180, opts.y or 200, 300, 110)
        local function c(fn, args) if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end end
        o._call = c
        attach_common(o); register(o)
        function o:_resolve(res)
            o:hide()
            S.focus = o._prev; o._prev = nil
            local cb = o._cb; o._cb = nil
            if cb then pcall(cb, res) end
        end
        function o:_repaint()
            c("SetTitle", { o._t or "CONFIRM" })
            c("SetMsg", { 0, o._m0 or "" }); c("SetMsg", { 1, o._m1 or "" })
            c("SetOpt", { 0, o._o0 or "YES" }); c("SetOpt", { 1, o._o1 or "NO" })
            c("SetPick", { o._pick or 1 })
        end
        function o:_keyvk(vk)
            local k = navName(vk); if not k then return end
            if k == "left" or k == "right" or k == "up" or k == "down" then
                o._pick = 1 - (o._pick or 1); c("SetPick", { o._pick })
            elseif k == "enter" then o:_resolve(o._pick == 0)
            elseif k == "esc" then o:_resolve(false) end
        end
        S.confirm = o
    end
    local msg = UI.wrap(tostring(opts.text or "Are you sure?"), 44)
    o._t = tostring(opts.title or "CONFIRM")
    o._m0, o._m1 = msg[1] or "", msg[2] or ""
    o._o0, o._o1 = tostring(opts.yes or "YES"), tostring(opts.no or "NO")
    o._pick = 1                                        -- default highlight = NO
    o._cb = opts.onResult
    o._prev = S.focus
    o._warmup = WARMUP
    o:_repaint()
    o:show()
    o:focus()
    return o
end

-- ============================== UI.Input ============================
function UI.Input(opts)
    opts = opts or {}
    local o = S.input
    if not o then
        o = {}
        o.w = make_widget(UI.FILES.input, opts.x or 160, opts.y or 260, 340, 56)
        local function c(fn, args) if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end end
        o._call = c
        attach_common(o); register(o)
        o._isInput = true
        function o:_echo()
            local t = o._text or ""
            if #t > 40 then t = "..." .. t:sub(#t - 40 + 1) end
            c("SetInput", { "> " .. t .. (o._blink and "_" or " ") })
        end
        function o:_repaint() c("SetTitle", { o._t or "INPUT" }); o:_echo() end
        function o:_char(ch)
            if #(o._text or "") < (o._max or 120) then o._text = (o._text or "") .. ch; o:_echo() end
        end
        function o:_bs()
            local t = o._text or ""
            if #t > 0 then o._text = t:sub(1, #t - 1); o:_echo() end
        end
        function o:_finish(useCancel)
            o:hide()
            S.focus = o._prev; o._prev = nil
            local sub, can = o._cb, o._cancel
            o._cb, o._cancel = nil, nil
            if useCancel then
                if can then pcall(can) end
            else
                if sub then pcall(sub, o._text or "") end
            end
        end
        function o:_keyvk(vk, shift)
            if vk == 0x0D then o:_finish(false)
            elseif vk == 0x1B then o:_finish(true)
            elseif vk == 0x08 then o:_bs()
            else local m = CHAR[vk]; if m then o:_char(shift and m.s or m.n) end end
        end
        S.input = o
    end
    o._t = tostring(opts.prompt or "INPUT -- ENTER SUBMIT   ESC CANCEL")
    o._text = tostring(opts.text or "")
    o._max = opts.max or 120
    o._cb, o._cancel = opts.onSubmit, opts.onCancel
    o._blink, o._blinkClock = true, 0
    o._prev = S.focus
    o._warmup = WARMUP
    o:_repaint()
    o:show()
    o:focus()
    return o
end

-- =============================== UI.Menu ============================
-- ForgeMenu-style declarative drill-down, rendered on a reused UI.List.
local function resolveLabel(node)
    local l = node.label
    if type(l) == "function" then local ok, v = pcall(l); l = ok and v or "?" end
    return tostring(l or "?")
end

local MenuBuilder = {}
MenuBuilder.__index = MenuBuilder
function MenuBuilder:entry(label, action)
    if type(action) ~= "function" then
        Loader.Printf("[uilib] Menu entry '" .. tostring(label) .. "' needs a function as 2nd arg")
        action = function() end
    end
    self._children[#self._children + 1] = { label = label, action = action }
    return self
end
function MenuBuilder:header(text)
    self._children[#self._children + 1] = { header = tostring(text) }
    return self
end
-- a labelled ON/OFF toggle entry: get() -> current bool, set(newBool, ctx) applies it.
-- Renders "<label>: ON" / "<label>: OFF" and flips on pick. Saves the dynamic-label boilerplate.
function MenuBuilder:switch(label, get, set)
    self._children[#self._children + 1] = {
        label = function() return tostring(label) .. ": " .. ((get and get()) and "ON" or "OFF") end,
        action = function(ctx) local nv = not (get and get()); if set then set(nv, ctx) end end,
    }
    return self
end
function MenuBuilder:category(label, buildFn)
    local node = { label = label, children = {} }
    self._children[#self._children + 1] = node
    local child = setmetatable({ _children = node.children }, MenuBuilder)
    if type(buildFn) == "function" then buildFn(child) end
    return child
end

local Menu = setmetatable({}, { __index = MenuBuilder })
Menu.__index = Menu

local function menu_ctx(menu)
    local px, py, pz, yaw, char, player = pose()
    local ctx = { x = px, y = py, z = pz, yaw = yaw or 0, char = char, player = player, _menu = menu }
    function ctx:hint(msg)  UI.Toast(tostring(msg)) end
    function ctx:toast(msg) UI.Toast(tostring(msg)) end             -- alias of :hint (clearer intent)
    function ctx:print(msg) Loader.Printf("[uilib] " .. tostring(msg)) end
    function ctx:close()    self._menu:close() end
    function ctx:confirm(text, onYes, onNo)                         -- pop a yes/no dialog from a menu action
        UI.Confirm{ text = text, onResult = function(yes)
            if yes then if onYes then pcall(onYes) end elseif onNo then pcall(onNo) end
        end }
    end
    function ctx:ask(prompt, onSubmit, onCancel)                    -- pop a typed prompt from a menu action
        UI.Input{ prompt = prompt, onSubmit = onSubmit, onCancel = onCancel }
    end
    function ctx:spawn(template, dist)
        -- Guard the native call: Pg.Spawn("") hard-CRASHES the engine (empty name -> null asset in C++),
        -- and pcall canNOT catch a native crash - only Lua errors. So reject blank templates up front.
        if type(template) ~= "string" or template:match("^%s*$") then
            self:hint("NO TEMPLATE SET"); return nil
        end
        if not px then self:hint("NO PLAYER POSITION"); return nil end
        local sx, sz = px, pz
        if dist and dist ~= 0 then
            local yr = math.rad(yaw or 0)
            sx = px - math.sin(yr) * dist
            sz = pz + math.cos(yr) * dist
        end
        local ok, u = pcall(Pg.Spawn, template, sx, py, sz)
        if ok and u then pcall(Object.SetYaw, u, yaw or 0); return u end
        self:hint("SPAWN FAILED: " .. tostring(template))
        return nil
    end
    return ctx
end

-- Runtime state persists across the OnKey re-run, keyed by menu id, so :toggle() really toggles and the
-- list widget is reused instead of leaked. (The menu OBJECT is rebuilt each run and carries the tree.)
local function menu_rt(id)
    S.menus = S.menus or {}
    S.menus[id] = S.menus[id] or { open = false }
    return S.menus[id]
end

function Menu:_paint()
    local lvl = self._stack[#self._stack]
    local rows = {}
    for _, node in ipairs(lvl.children) do
        if node.header then rows[#rows + 1] = { header = node.header }
        elseif node.children then rows[#rows + 1] = { label = resolveLabel(node) .. "  >", _node = node }
        else rows[#rows + 1] = { label = resolveLabel(node), _node = node } end
    end
    self._rt.list:items(rows)
    local crumb = resolveLabel(self._root)
    for i = 2, #self._stack do crumb = crumb .. " > " .. resolveLabel(self._stack[i]) end
    self._rt.list:crumb(crumb)
end

function Menu:_choose(it)
    local node = it and it._node
    if not node then return end
    if node.children then
        self._stack[#self._stack + 1] = node
        self:_paint()
    elseif node.action then
        local ok, err = pcall(node.action, menu_ctx(self))
        if not ok then Loader.Printf("[uilib] menu action error: " .. tostring(err)); UI.Toast("ERROR (see log)") end
        if self._rt.open then                       -- re-render so DYNAMIC labels (:switch / cyclers) show the change
            local list = self._rt.list
            local keep = list and list._sel          -- keep the cursor where it is (a re-items resets it to the top)
            self:_paint()
            if list and keep then list:select(keep) end
        end
    end
end

function Menu:_back()
    if #self._stack > 1 then
        self._stack[#self._stack] = nil
        self:_paint()
    else
        self:close()
    end
end

function Menu:open()
    local rt = self._rt
    if rt.open then return self end
    if not (Player.GetLocalPlayer() and Player.GetLocalCharacter()) then
        Loader.Printf("[uilib] no local player yet - can't open menu '" .. tostring(self._title) .. "'")
        return self
    end
    -- only one UI.Menu open at a time (they share the same on-screen slot)
    if S.openId and S.openId ~= self._id then
        local o = S.menus and S.menus[S.openId]
        if o and o.open then
            if o.list then pcall(function() o.list:hide():blur() end) end
            o.open = false
            if o.menu and o.menu._onClose then pcall(o.menu._onClose) end
        end
    end
    local hint = "UP/DOWN MOVE   ENTER PICK   LEFT BACK"
    if self._key then hint = hint .. "   " .. tostring(self._key) .. " CLOSE" end
    if not rt.list then
        rt.list = UI.List{ x = self._x, y = self._y, title = self._title, hint = hint,
            onChoose = function(it) self:_choose(it) end, onBack = function() self:_back() end }
    else
        rt.list.onChoose = function(it) self:_choose(it) end
        rt.list.onBack   = function() self:_back() end
        rt.list:title(self._title):hint(hint)
    end
    rt.menu = self                       -- current run's object (holds this run's tree + action closures)
    self._stack = { self._root }
    self:_paint()
    rt.list:show():focus()
    rt.open = true
    S.openId = self._id
    return self
end

function Menu:close()
    local rt = self._rt
    if not rt.open then return self end
    if rt.list then rt.list:hide():blur() end
    rt.open = false
    if S.openId == self._id then S.openId = nil end
    if self._onClose then pcall(self._onClose) end
    return self
end

function Menu:toggle() if self._rt.open then self:close() else self:open() end return self end
function Menu:isOpen() return self._rt.open == true end

-- UI.Menu{ title, id, key, x, y, onClose }  (or UI.Menu("TITLE"))
--   id  : distinct runtime-state key; defaults to title. Give separate menus distinct titles/ids.
--   key : your toggle key's name, shown in the hint (display only).
function UI.Menu(opts)
    if type(opts) == "string" then opts = { title = opts } end
    opts = opts or {}
    local title = opts.title or "MENU"
    local id = opts.id or title
    local root = { label = title, children = {} }
    local m = setmetatable({
        _root = root, _children = root.children,
        _title = title, _id = id,
        _key = opts.key, _x = opts.x or 40, _y = opts.y or 60,
        _onClose = opts.onClose,
        _rt = menu_rt(id),
    }, Menu)
    return m
end

-- =============================== UI.Chat ============================
-- A scrolling message log (chat.gfx) with an optional typed input line.
--   local ch = UI.Chat{ x, y, title, onSubmit }
--   ch:push("a message")                 -- add a line (keeps the last 5 visible; body auto-resizes)
--   ch:prompt()                          -- enter input mode: type, Enter -> push + onSubmit(text), Esc cancels
--   ch:title(s)  ch:clear()
function UI.Chat(opts)
    opts = opts or {}
    local o = {}
    o.w = make_widget(UI.FILES.chat, opts.x or 20, opts.y or 400, opts.w or 360, opts.h or 132)
    o._shown = true
    local function c(fn, args) if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end end
    o._call = c
    attach_common(o); register(o)
    o._titleStr = opts.title
    o._log = {}
    o._max = opts.max or 60
    o._cur, o._tgt = 100, 100
    o._setsize = function(v) c("SetSize", { v }) end
    o.onSubmit = opts.onSubmit
    local BASE_H = 132

    local function paintLog()
        local total = #o._log
        local shown = total; if shown > 5 then shown = 5 end
        for i = 0, 4 do
            if i < shown then c("SetMsg", { i, o._log[total - shown + i + 1] or "" }) else c("SetMsg", { i, "" }) end
        end
        if shown < 1 then shown = 1 end
        set_target(o, 100 * (50 + 16 * shown) / BASE_H)
    end
    o._paintLog = paintLog

    function o:title(s) o._titleStr = s; c("SetTitle", { tostring(s) }) return self end
    function o:push(text)
        for _, line in ipairs(UI.wrap(tostring(text), 52)) do o._log[#o._log + 1] = line end
        while #o._log > o._max do table.remove(o._log, 1) end
        paintLog()
        return self
    end
    function o:clear() o._log = {}; paintLog(); return self end

    function o:_echo()
        local t = o._text or ""
        if #t > 44 then t = "..." .. t:sub(#t - 44 + 1) end
        c("SetInput", { "> " .. t .. (o._blink and "_" or " ") })
    end
    function o:prompt(onSubmit)
        o._text = ""; o._blink, o._blinkClock = true, 0; o._isInput = true
        if onSubmit then o.onSubmit = onSubmit end
        o:_echo(); o:focus()
        return self
    end
    function o:_endInput()
        o._isInput = false
        c("SetInput", { " " })
        if S.focus == o then S.focus = nil end
    end
    function o:_keyvk(vk, shift)
        if not o._isInput then return end
        if vk == 0x0D then
            local t = o._text or ""
            o:_endInput()
            if #t > 0 then o:push(t); if o.onSubmit then pcall(o.onSubmit, t) end end
        elseif vk == 0x1B then o:_endInput()
        elseif vk == 0x08 then local t = o._text or ""; if #t > 0 then o._text = t:sub(1, #t - 1); o:_echo() end
        else local m = CHAR[vk]; if m and #(o._text or "") < 200 then o._text = (o._text or "") .. (shift and m.s or m.n); o:_echo() end end
    end

    function o:_repaint()
        if o._titleStr then c("SetTitle", { tostring(o._titleStr) }) end
        paintLog()
        if o._isInput then o:_echo() end
        if o._setsize then o._setsize(o._cur) end
    end

    if opts.title then o:title(opts.title) end
    paintLog()
    o._cur = o._tgt; o._setsize(o._cur)
    o._warmup = WARMUP
    ensureTick()
    return o
end

-- =============================== UI.Board ===========================
-- A two-pane board (contracts.gfx): a scrolling list on the left + a details pane on the right
-- (category line, up to 4 reward lines, up to 8 objective lines, a progress bar + progress text).
--   local b = UI.Board{ x, y, title, hint, items, focus, onSelect, onChoose, onBack }
--   b:items({ {header="SECTION"}, {label="Entry", any=data}, ... })   -- same item shape as UI.List
--   b:detail({ category="OIL FIELD", rewards={"$5000","Fuel +200"},
--              objectives={"Destroy 3 tanks","Reach the LZ"}, progress=0.4, progressText="2/5" })
--   b:title(s)  b:hint(s)   -- onSelect(item,i,board) fires on every move so you can refresh :detail
function UI.Board(opts)
    opts = opts or {}
    local o = {}
    o.w = make_widget(UI.FILES.board, opts.x or 60, opts.y or 60, opts.w or 660, opts.h or 420)
    o._shown = true
    local function c(fn, args) if o.w then pcall(function() o.w:CallActionScriptCallback(fn, args) end) end end
    o._call = c
    attach_common(o); register(o)
    o._items, o._sel, o._off = {}, 1, 0
    o._titleStr, o._hintStr = opts.title, opts.hint
    o.onSelect, o.onChoose, o.onBack = opts.onSelect, opts.onChoose, opts.onBack

    local VIS, TOP, PITCH, TRK_Y, TRK_H = 12, 64, 26, 64, 312

    local function selectable(i) local it = o._items[i]; return it ~= nil and not it.header end
    local function nearest(from, dir)
        local i = from
        while i >= 1 and i <= #o._items do
            if selectable(i) then return i end
            i = i + dir
        end
        return nil
    end
    local function fireSelect()
        if o.onSelect then pcall(o.onSelect, o._items[o._sel], o._sel, o) end
    end

    function o:paint()
        local n = #o._items
        if n > 0 then
            if not selectable(o._sel) then o._sel = nearest(o._sel, 1) or nearest(o._sel, -1) or 1 end
            local s0 = o._sel - 1
            if o._off > s0 then o._off = s0 end
            if s0 > o._off + VIS - 1 then o._off = s0 - VIS + 1 end
            if o._off < 0 then o._off = 0 end
        else
            o._off = 0
        end
        for i = 0, VIS - 1 do
            local it = o._items[o._off + i + 1]
            if not it then c("SetRow", { i, "" }); c("SetHdr", { i, "" })
            elseif it.header then c("SetHdr", { i, tostring(it.header) }); c("SetRow", { i, "" })
            else c("SetRow", { i, tostring(it.label or "?") }); c("SetHdr", { i, "" }) end
        end
        if n == 0 then
            c("SetHdr", { 0, tostring(opts.empty or "EMPTY") }); c("SetSelected", { -1 }); c("SetScroll", { 0, 0 })
        else
            if selectable(o._sel) then c("SetSelected", { (o._sel - 1) - o._off }) else c("SetSelected", { -1 }) end
            if n > VIS then
                local th = TRK_H * VIS / n; if th < 18 then th = 18 end
                local ty = TRK_Y + (TRK_H - th) * o._off / (n - VIS)
                c("SetScroll", { math.floor(ty), math.floor(th) })
            else
                c("SetScroll", { 0, 0 })
            end
        end
        return self
    end

    function o:title(s) o._titleStr = s; c("SetTitle", { tostring(s) }) return self end
    function o:hint(s)  o._hintStr = s;  c("SetHint",  { tostring(s) }) return self end
    function o:detail(d)
        d = d or {}
        c("SetCat", { tostring(d.category or " ") })
        local rw = d.rewards or {}
        for i = 0, 3 do c("SetReward", { i, tostring(rw[i + 1] or " ") }) end
        local ob = d.objectives or {}
        for i = 0, 7 do c("SetObj", { i, tostring(ob[i + 1] or " ") }) end
        c("SetBar", { math.floor((tonumber(d.progress) or 0) * 100) })
        c("SetProg", { tostring(d.progressText or " ") })
        o._detail = d
        return self
    end
    function o:items(t)
        o._items = t or {}
        o._sel = nearest(1, 1) or 1
        o._off = 0
        o:paint()
        fireSelect()
        return self
    end
    function o:selected() return o._items[o._sel], o._sel end
    function o:select(i) if selectable(i) then o._sel = i; o:paint(); fireSelect() end return self end

    function o:_keyvk(vk)
        local k = navName(vk); if not k then return end
        if k == "up" or k == "down" then
            local d = (k == "up") and -1 or 1
            local t = nearest(o._sel + d, d)
            if t and t ~= o._sel then o._sel = t; o:paint(); fireSelect() end
        elseif k == "enter" or k == "right" then
            local it = o._items[o._sel]
            if it and not it.header and o.onChoose then pcall(o.onChoose, it, o._sel, o) end
        elseif k == "left" or k == "esc" then
            if o.onBack then pcall(o.onBack, o) end
        end
    end

    function o:_repaint()
        if o._titleStr then c("SetTitle", { tostring(o._titleStr) }) end
        if o._hintStr then c("SetHint", { tostring(o._hintStr) }) end
        o:paint()
        if o._detail then o:detail(o._detail) end
    end

    if o._titleStr then c("SetTitle", { tostring(o._titleStr) }) end
    if o._hintStr then c("SetHint", { tostring(o._hintStr) }) end
    o:items(opts.items or {})
    o:detail(opts.detail or {})
    o._warmup = WARMUP
    if opts.focus then o:focus() end
    ensureTick()
    return o
end

-- =============================== boot ===============================
-- This OnLoad file re-runs on every world (re)load, by which point the engine has torn down every
-- FlashWidget from the previous world. Forget all stale handles + state so everything rebuilds cleanly
-- (singletons on next use, menus/lists on next open) and no orphaned heartbeat or focus survives a load.
S.live, S.focus, S.running, S.openId = {}, nil, false, nil
S.confirm, S.input, S.toasts = nil, nil, nil
if S.menus then for _, rt in pairs(S.menus) do rt.list = nil; rt.open = false; rt.menu = nil end end

Loader.Printf("[uilib] UI kit v" .. UI.VERSION .. " " .. (S.loaded and "reloaded" or "loaded")
    .. " -- Menu List Panel Bar Toast Confirm Input Chat Board")
S.loaded = true
