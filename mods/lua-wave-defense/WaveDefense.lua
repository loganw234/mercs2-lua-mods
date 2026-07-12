-- =====================================================================
-- WaveDefense.lua  (OnLoad)  --  wave-defense gamemode: engine + store + arena, ONE FILE.
--
-- Combines ContractFramework (launcher via def.onBegin) + ModNet (co-op sync, host-authoritative)
-- + uilib (HUD + intermission board + setup menu). Two currencies: XP (persistent, per-machine SaveVar)
-- UNLOCKS catalog items; CASH (native MrxPmc) BUYS unlocked items in the between-wave shop.
--
-- FLOW: accept "Wave Defense" (F5 board) -> configure -> for each wave an INTERMISSION opens (buy with
-- cash + unlock with XP + READY). When BOTH players ready (or the host FORCES), the wave spawns from the
-- arena's spawn points; clear it -> next intermission. Fixed:win after N / endless:high score.
--
-- AUTHORITY: the sim runs on the authority only (SP or co-op host, ModNet.IsAuthority()); it writes live
-- state to ModNet.Shared("wd"). HUD + intermission run on BOTH machines off that shared table. Purchase
-- EFFECTS run LOCALLY on the buyer (props/vehicles/emplacements/buffs/supports); only AI-unit spawns
-- would route to the host (client can run everything else locally).
--
-- DEPLOY: OnLoad/WaveDefense.lua AFTER 1_uilib + 1_ModNet + 1_ContractFramework. Self-contained -- the
-- old WaveDefStore.lua + WaveDefUnlocks.lua (F8) are folded in here and removed.
-- =====================================================================

if not (_G.ModNet and _G.Contract and _G.UI and UI.Board and UI.Menu) then
    if Loader and Loader.Printf then
        Loader.Printf("[WaveDef] need ModNet + ContractFramework + uilib (UI.Board/Menu) first (check [OnLoad] order)")
    end
    return
end
pcall(function() import("MrxPmc") end)
pcall(function() import("MrxSupportData") end)   -- tSupportData[key].oSupport for quick-menu equip
pcall(function() import("MrxGuiBase") end)       -- GetWidgetByNameAndOwner -> raw "Support Menu" widget (snapshot + wipe)

_G.WaveDef = _G.WaveDef or {}
local W = _G.WaveDef

-- Recover a stranded economy deduction: if a prior run banked the campaign wallet (deducted it for the
-- isolated run economy) but never restored it -- a crash / hard reload -- give it back now. Cleared on a
-- clean finish, so this is a no-op in the normal case.
do
    local s = Loader and Loader.LoadVar and Loader.LoadVar("WaveDef_savedCash")
    if type(s) == "number" and s > 0 then
        pcall(function() MrxPmc.AddCashQty(s - (MrxPmc.GetCashQty() or 0)) end)   -- set cash back to the saved total
        if Loader.SaveVar then Loader.SaveVar("WaveDef_savedCash", 0) end
        W.savedCash = nil
    end
end

-- SAVE GUARD: while a run is live the campaign wallet is deducted to $0 (isolated economy). The death ->
-- medevac flow fires a savegame in that window; if it lands at $0 and the player quits before the wallet
-- is restored (or never saves again), their money is gone. So SUPPRESS savegames while W.run is set --
-- they resume the instant the run tears down (W.stop sets W.run = nil). Wrapped once, mirrors ModNet's hook.
if Pg and Pg.SaveGame and not W._origSaveGame then
    W._origSaveGame = Pg.SaveGame
    Pg.SaveGame = function(...)
        if _G.WaveDef and _G.WaveDef.run then
            if Loader and Loader.Printf then Loader.Printf("[WaveDef] savegame suppressed (run active)") end
            return
        end
        return W._origSaveGame(...)
    end
end

local TICK = 0.5
local S = ModNet.Shared("wd")                 -- host writes / both read (last-writer-wins)
local function put(k, v) if S[k] ~= v then S[k] = v end end

-- ===== helpers =====
local function safe(fn, ...) local ok, a, b, c = pcall(fn, ...); if ok then return a, b, c end end
local function rtime() return safe(Sys.RealTime) or 0 end
local function hostPose()
    local ch = Player.GetLocalCharacter(); if not ch then return nil end
    local x, y, z = safe(Object.GetPosition, ch); if not x then return nil, nil, nil, ch end
    return x, y, z, ch
end
-- self-contained PRNG. The old Park-Miller MINSTD (state*16807 up to ~3.6e13, mod 2^31) DEGENERATED to a
-- stuck value in the engine's Lua -- every crate/unit pick came out identical. This ZX-Spectrum generator
-- keeps ALL arithmetic under 2^23 (state*75 <= 4.9M, mod 65537) so it stays exact no matter the engine's
-- number type. Full period 65536, verified well-distributed. (Used by the weighted rosters + the drops.)
W._rng = W._rng or ((math.floor(rtime() * 1000) % 65536) + 1)   -- seed in 1..65536
local function rnd() W._rng = (W._rng * 75) % 65537; return W._rng / 65537 end
-- one-time probe (temporary): the next log confirms rnd() now VARIES in-engine + reveals big-number handling.
if Loader and Loader.Printf then
    local big = 1000000 * 16807
    Loader.Printf(string.format("[WaveDef] rng probe: %.4f %.4f %.4f %.4f | 1e6*16807=%s mod2^31=%s",
        rnd(), rnd(), rnd(), rnd(), tostring(big), tostring(big % 2147483647)))
end

-- ===== config (schema drives setup UI + save/load; keys are "WaveDef_<key>") =====
W.CONFIG = {
    { key = "mode",        label = "Mode",              default = "endless", values = { "endless", "fixed" } },
    { key = "waves",       label = "Waves (fixed)",     default = 10,        values = { 5, 10, 15, 20, 30 } },
    { key = "factions",    label = "Factions (mix)",    default = 1,         values = { 1, 2, 3, 4, 5, 6 } },
    { key = "baseCount",   label = "Wave 1 size",       default = 12,        values = { 6, 12, 18, 24, 30 } },
    { key = "perWave",     label = "+ Per wave",        default = 6,         values = { 2, 4, 6, 8, 12 } },
    { key = "arena",       label = "Arena",             default = "arena_a", values = { "arena_a", "none" } },
    { key = "arenaRadius", label = "Ring radius (none)", default = 25,       values = { 15, 20, 25, 30, 40 } },
}
function W.saveVal(key, v) Loader.SaveVar("WaveDef_" .. key, v) end
function W.loadCfg()
    local cfg = {}
    for _, c in ipairs(W.CONFIG) do local v = Loader.LoadVar("WaveDef_" .. c.key); cfg[c.key] = (v == nil) and c.default or v end
    return cfg
end
local function defaultCfg() return W.loadCfg() end

-- ===== MODIFIERS (difficulty levers, opened from the setup menu). Each active lever multiplies the XP/cash
-- reward (harder -> more, assists -> less); rewardMult = product of active levers, clamped. Saved per-key. =====
W.MODIFIERS = {
    { key = "mSize", label = "Wave Size",       kind = "mult", vals = { 0.5, 1, 1.5, 2, 3 },   rew = { 0.7, 1, 1.3, 1.7, 2.4 } },
    { key = "mHp",   label = "Enemy Health",     kind = "mult", vals = { 0.5, 1, 1.5, 2, 3 },   rew = { 0.7, 1, 1.3, 1.6, 2.2 } },
    { key = "mSpd",  label = "Enemy Speed",      kind = "mult", vals = { 0.6, 1, 1.3, 1.6, 2 }, rew = { 0.8, 1, 1.2, 1.4, 1.7 } },
    { key = "mAir",  label = "Enemy Airstrikes", kind = "opt",  vals = { "off", "normal", "heavy" }, rew = { 0.85, 1, 1.35 } },
    { key = "mArch", label = "Special Waves",    kind = "opt",  vals = { "rare", "normal", "frequent", "chaos" }, rew = { 0.9, 1, 1.2, 1.4 } },   -- how often a wave is a special archetype (chaos = every eligible non-boss wave)
    { key = "mBoss", label = "Boss Rush (every 3)",    kind = "toggle", rew = 1.4 },
    { key = "mStore",label = "No Store",               kind = "toggle", rew = 1.6 },
    { key = "mGlass",label = "Glass Cannon (half HP)", kind = "toggle", rew = 1.7 },
    { key = "mRich", label = "Rich Start (+$25k)",     kind = "toggle", rew = 0.7 },
    { key = "mAll",  label = "Force All 6 Factions",   kind = "toggle", rew = 1.25 },
    { key = "mEarly",label = "All Threats @ Wave 1 (test)", kind = "toggle", rew = 1 },   -- strikes/veh/heli/boss from wave 1
    { key = "mShell",label = "Sustained Shelling",          kind = "toggle", rew = 1.5 },  -- a strike near the player every ~10s
    { key = "mTarget",label = "Target Acquisition",         kind = "toggle", rew = 1.4 },  -- strikes home in if you hold still
}
-- effective start-wave for a threat: 1 if the "All Threats @ Wave 1" test lever is on, else its normal value.
local function early(run, n) return (run.mods and run.mods.mEarly) and 1 or n end
function W.loadMods()
    local m = {}
    for _, mod in ipairs(W.MODIFIERS) do
        local v = Loader.LoadVar("WaveDef_" .. mod.key)
        if v == nil then                                                           -- neutral default (off / 1x / normal)
            if mod.kind == "toggle" then v = false else v = mod.vals[2] end         -- (can't `x and false or y` -- false breaks it)
        end
        m[mod.key] = v
    end
    return m
end
local function modRewardMult(m)
    local mult = 1
    for _, mod in ipairs(W.MODIFIERS) do
        local v = m[mod.key]
        if mod.kind == "toggle" then if v then mult = mult * mod.rew end
        else for i, x in ipairs(mod.vals) do if x == v then mult = mult * mod.rew[i]; break end end end
    end
    return math.max(0.25, math.min(5, mult))
end

-- ===== enemy ROSTERS (weighted spawn strings per faction, from the MissionForge catalog). Entry
-- {t=template, w=weight} -- tune weights for difficulty. abbrev = MrxFactionManager faction key. =====
local function U(t, w) return { t = t, w = w or 6 } end
local ROSTERS = {
    VZ = { abbrev = "Vza", inf = {
        U("VZ Soldier",10), U("VZ Defender (Rifle)",6), U("VZ Heavy (Light MG)",5), U("VZ Heavy (Heavy MG)",4),
        U("VZ Heavy (RPG)",4), U("VZ Defender (MG)",4), U("VZ Sniper",3), U("VZ Defender (Sniper)",3),
        U("VZ Officer",3), U("VZ Defender (AT)",3), U("VZ Elite",2), U("VZ Defender (AA)",2),
        U("VZ Heavy (AA Missile)",2), U("VZ Tank Commander",2), U("VZ Deathsquad",2),
        U("VZ Deathsquad B",2), U("VZ Deathsquad C",2),
    }, veh = {
        U("M113 (VZ) (Full)",6), U("M151 .50Cal (VZ) (Full)",6), U("Scorpion90 (Full)",5), U("M35 (Guntruck) (VZ) (Full)",5),
        U("AMX30 Elite (Full)",3), U("AMX30 AA (Driver)",3), U("M113 AA (VZ) (Full)",3), U("M35 (AA) (VZ) (Full)",3),
    }, heli = { U("Mi35 (Full)",3), U("Alouette3 Elite (Full)",3), U("Mi26 (VZ) (Driver)",2) }},
    GUERILLA = { abbrev = "Gur", inf = {
        U("Guerilla Soldier",10), U("Guerilla Soldier B",8), U("Guerilla Soldier (Female)",6), U("Guerilla Soldier B (Female)",6),
        U("Guerilla Heavy",5), U("Guerilla Heavy (Light MG)",4), U("Guerilla Heavy (RPG)",4), U("Guerilla Officer",3),
        U("Guerilla Officer (Female)",3), U("Guerilla Elite Soldier",2), U("Guerilla Tank Commander",2),
        U("Jungle Elite",2),
    }, veh = {
        U("M113 (GR) (Full)",6), U("M151 (MG) (GR) (DriverGunner)",6), U("M551 (Full)",4), U("M35 (Guntruck) (GR) (Full)",5),
        U("M113 AA (GR) (Full)",3), U("M35 (AA) (GR) (Full)",3),
    }, heli = { U("UH1 Attack",4), U("UH1 Superiority",3), U("UH1 Elite",2) }},
    CHINA = { abbrev = "Chi", inf = {
        U("Chinese Soldier",10), U("Chinese Airborne",6), U("Chinese Heavy (Light MG)",4), U("Chinese Heavy (RPG)",4),
        U("Chinese Airborne (Light MG)",4), U("Chinese Airborne (AT)",3), U("Chinese Officer",3), U("Chinese Sniper",3),
        U("Chinese Paratrooper",3), U("Chinese Heavy (AA)",2), U("Chinese Elite Soldier",2), U("Chinese Medic",2),
        U("Chinese Sailor",2), U("Chinese Tank Commander",2),
        U("Chinese Sailor (Light MG)",3), U("Chinese Sailor (AA)",2),
    }, veh = {
        U("WZ551 (Full)",6), U("NGLV (MG) (Full)",6), U("NGLV (GL) (Full)",5), U("ZTZ63a (Full)",5),
        U("ZBD2000 (Full)",4), U("ZTZ98 (Full)",3), U("PLZ45 (Full)",3), U("PGZ95 (Driver)",3), U("SX2150 (MLRS) (Full)",2),
    }, heli = { U("WZ10 (Full)",3), U("Ka29b (Full)",3) }},
    ALLIED = { abbrev = "All", inf = {
        U("Allied Soldier",10), U("Allied Airborne",5), U("Allied Sailor",4), U("Allied Heavy (Light MG)",4),
        U("Allied Airborne (Light MG)",4), U("Allied Sailor (Light MG)",3), U("Allied Airborne (AT)",3), U("Allied Paratrooper",3),
        U("Allied Officer",3), U("Allied Heavy (AT Rocket)",3), U("Allied Heavy (AA)",2), U("Allied Medic",2),
        U("Allied Sailor (AA)",2), U("Allied Pilot",2),
    }, veh = {
        U("HMMWV (Armored) (50Cal) (Full)",6), U("LAVIII (25mm) (Full)",5), U("LAVIII (Minigun) (Full)",5), U("M2A3 (Driver)",5),
        U("HMMWV (Armored) (GL) (Full)",5), U("M1A2 (Full)",3), U("LAVIII (AT) (Full)",3), U("HMMWV (Armored) (TOW) (Full)",3),
        U("HMMWV (Avenger) (Full)",3), U("LAVIII (AD) (Full)",3),
    }, heli = { U("AH1Z (Full)",3), U("MH53J (Full)",2) }},
    OC = { abbrev = "Oil", inf = {
        U("OC Soldier",10), U("OC Defender (Rifle)",6), U("OC Heavy (Light MG)",4), U("OC Heavy (RPG)",4),
        U("OC Defender (MG)",4), U("OC Heavy (Grenade Launcher)",3), U("OC Defender (AT)",3), U("OC Defender (Sniper)",3),
        U("OC Sniper",3), U("OC Officer",3), U("OC Defender (AA)",2), U("OC Elite",2), U("OC Tank Commander",2),
        U("OC Executive",2), U("OC Pilot",2),
    }, veh = {
        U("EXT (Full)",6), U("EXT (GL) (Full)",5), U("Stingray II (Full)",5), U("Guntruck (OC) (Full)",5), U("EXT (TOW) (Full)",3),
    }, heli = { U("Coanda Gunship (Full)",3), U("Coanda Attack (Full)",3), U("Coanda Superiority (Full)",3) }},
    PIRATE = { abbrev = "Pir", inf = {
        U("Pirate Thug",10), U("Pirate Thug (Female)",6), U("Pirate Thug (Shotgun)",5), U("Pirate Thug (RPG)",4),
        U("Pirate Sailor",3), U("Pirate Officer",3), U("Pirate Officer (RPG)",3), U("Pirate Thug (AA)",2), U("Pirate Pilot",2),
        U("Pirate Thug (Female AA)",2), U("Pirate Sailor (Drinker)",2),
    }, veh = { U("T300 (M60)",6) },
    heli = { U("Alouette3 Attack (PR) (Full)",4), U("Alouette3 Transport (PR) (Full)",2) }},
}
local FACTION_ORDER = { "VZ", "GUERILLA", "CHINA", "ALLIED", "OC", "PIRATE" }   -- a combo of N = the first N

-- weighted pick from a combined pool of the active factions' infantry (built once per run in W.begin)
local function buildPool(active, cat)
    cat = cat or "inf"
    local list, total = {}, 0
    for _, f in ipairs(active) do
        for _, e in ipairs(ROSTERS[f] and ROSTERS[f][cat] or {}) do total = total + (e.w or 1); list[#list + 1] = { t = e.t, acc = total } end
    end
    return { list = list, total = total }
end
local function pickUnit(pool)
    if not pool or pool.total <= 0 then return "VZ Soldier" end
    local r = rnd() * pool.total
    for _, e in ipairs(pool.list) do if r <= e.acc then return e.t end end
    return pool.list[#pool.list].t
end
local function rndInt(n) if n < 1 then return 1 end return 1 + math.floor(rnd() * n) end
-- enemy HP modifier. This build has NO SetMaxHealth, so: <1 lowers current health (works directly); >1
-- tags the entry for REGEN (healed toward max in regenPass) which acts as an effective-HP multiplier.
local function applyHp(e, mult)
    if not e or not e.u or not mult or mult == 1 then return end
    safe(function()
        local mx = Object.GetMaxHealth(e.u) or 0
        if mult < 1 then Object.SetHealth(e.u, math.max(1, mx * mult))
        elseif mx > 0 then e.maxHp = mx; e.regen = (mult - 1) * mx * 0.1 end
    end)
end

-- ===== faction relations: make the active enemy factions HOSTILE to the player but FRIENDLY to each
-- other (so any mix attacks you without infighting). MrxFactionManager, host-side. =====
pcall(function() import("MrxFactionManager") end)
local function fmCall(name, ...)
    local m = _G.MrxFactionManager
    local f = (m and m[name]) or _G[name]
    if type(f) == "function" then return safe(f, ...) end
end
local function setupRelations(active)
    local abbr = {}
    for _, f in ipairs(active) do local a = ROSTERS[f] and ROSTERS[f].abbrev; if a then abbr[#abbr + 1] = a end end
    W._relAbbr, W._relSnap = abbr, {}                            -- snapshot ORIGINAL relations FIRST so we can restore on run end
    for _, a in ipairs(abbr) do
        W._relSnap[a] = { pmc = fmCall("GetRelation", a, "Pmc") }
        for _, b in ipairs(abbr) do if a ~= b then W._relSnap[a][b] = fmCall("GetRelation", a, b) end end
    end
    for _, a in ipairs(abbr) do
        fmCall("SetAttitudeMutable", a)
        fmCall("SetRelation", a, "Pmc", -100, true)              -- hostile to the player
        for _, b in ipairs(abbr) do if a ~= b then fmCall("SetRelation", a, b, 100, true) end end   -- friendly to each other
    end
    -- native reporting is left ON: the report -> pursuit -> reinforcement loop is engine-driven and reliable,
    -- and lets the player kill the "caller" to prevent backup. We ADOPT those units (adoptStrays) to track them.
    Loader.Printf("[WaveDef] relations: " .. table.concat(abbr, "+") .. " hostile->Pmc, friendly (native reporting ON)")
end
local function restoreRelations()                               -- put faction relations back to their pre-run values
    local abbr, snap = W._relAbbr, W._relSnap
    if not (abbr and snap) then return end
    for _, a in ipairs(abbr) do
        local s = snap[a]
        if s then
            if s.pmc ~= nil then fmCall("SetRelation", a, "Pmc", s.pmc, true) end
            for _, b in ipairs(abbr) do if a ~= b and s[b] ~= nil then fmCall("SetRelation", a, b, s[b], true) end end
        end
    end
    W._relAbbr, W._relSnap = nil, nil
    if Loader and Loader.Printf then Loader.Printf("[WaveDef] relations restored") end
end

-- ===== BOSS system (extensible): add a template here to add a boss. Boss waves = every BOSS_EVERY.
-- fields: name, template, hp (max-health x multiplier, best-effort), add/addEvery (spawns adds while alive). =====
local BOSS_EVERY  = 5
local SPAWN_BATCH = 6      -- enemies spawned per engine tick (paces big waves; avoids a frame spike)
local MAX_ACTIVE  = 140    -- HARD cap on concurrent enemy AI (live test: ~200 ok, 600 CTDs). Over this we STAGGER:
                           -- hold spawns until kills free up room, so the wave total still arrives but never all at once.
-- Bosses are ROLLED each boss wave as a PREFIX (rank/title = a mechanic bundle) over a random BODY (the
-- physical template) with a codename -- so bosses feel different across runs instead of a fixed script.
-- "General" is the summoner. Themed on the game's military/merc world. Any prefix can ride any body.
local BOSS_PREFIXES = {   -- title,   hp = effective-HP mult (via regen),  haste,  add/addEvery = summons troops
    { title = "General",   hp = 5, haste = 1.15, add = true, addEvery = 4 },   -- summoner: keeps calling in troops
    { title = "Colonel",   hp = 4, haste = 1.35 },                             -- quick, aggressive commander
    { title = "Warlord",   hp = 7, haste = 1.00 },                             -- pure tank, slow and grindy
    { title = "Commander", hp = 5, haste = 1.20, add = true, addEvery = 6 },   -- summons on a slower cadence
    { title = "Butcher",   hp = 3, haste = 1.65 },                             -- rushdown: glassier but very fast
    { title = "Marshal",   hp = 6, haste = 1.30, add = true, addEvery = 5 },   -- the elite: tanky, fast, and summons
}
local BOSS_BODIES = {   -- the template that physically shows up
    "Guerilla Boss", "Allied Boss", "Chinese Boss", "OC Boss", "VZ MinerUnionBoss", "Blanco", "Solano",
}
local BOSS_CODENAMES = {   -- proper-noun flavor themed to the setting's factions
    "Solano", "Blanco", "Reyes", "Vega", "Herrera", "Marquez", "Castillo", "Zhao", "Chen", "Hawke", "Voss", "Kessler",
}
local function rollBoss()   -- prefix (mechanic) x body (template) x codename (name) -> a fresh boss def
    local pre = BOSS_PREFIXES[rndInt(#BOSS_PREFIXES)]
    return { name = pre.title .. " " .. BOSS_CODENAMES[rndInt(#BOSS_CODENAMES)],
             template = BOSS_BODIES[rndInt(#BOSS_BODIES)],
             hp = pre.hp, haste = pre.haste, add = pre.add, addEvery = pre.addEvery }
end

-- ===== ARENAS (authored in MissionForge). spawn point = {x, y, z, radius}; radius tiers the unit type:
-- <=5 infantry, <=15 vehicle, >15 heli. Enemies spawn from these points; the player defends the center.
-- cfg.arena="none" falls back to a ring around the host. =====
local ARENAS = {
    arena_a = {
        name = "Arena A",
        center = { 2675.52, -13.75, -1040.18 },
        spawns = {
            {2705.36,-13.31,-1108.11,3.0},{2710.38,-14.27,-1122.84,3.0},{2693.04,-13.46,-1119.45,3.0},
            {2698.39,-13.88,-1133.29,3.0},{2742.72,-13.59,-1069.84,3.0},{2754.83,-13.52,-1063.94,3.0},
            {2757.36,-14.26,-1077.47,3.0},{2744.51,-13.67,-1081.17,3.0},{2746.06,-19.99,-1167.47,3.0},
            {2744.03,-18.27,-1155.31,3.0},{2756.35,-17.83,-1155.36,3.0},{2635.83,-13.33,-1155.58,3.0},
            {2626.56,-13.41,-1161.04,3.0},{2620.09,-13.43,-1149.31,3.0},{2544.43,-13.72,-1024.47,3.0},
            {2534.05,-13.72,-1025.37,3.0},{2520.57,-13.67,-1033.06,3.0},{2530.96,-13.72,-1033.50,3.0},
            {2502.03,-13.45,-1043.79,3.0},{2493.84,-13.55,-1035.01,3.0},{2483.89,-13.70,-1024.60,3.0},
            {2474.36,-13.84,-1013.94,3.0},{2446.10,-14.06,-987.69,3.0},{2454.75,-14.06,-979.90,3.0},
            {2453.79,-14.06,-967.67,3.0},{2462.18,-14.06,-949.02,3.0},{2460.28,-13.83,-924.44,3.0},
            {2462.72,-13.38,-905.10,3.0},{2476.74,-13.75,-897.60,3.0},{2481.76,-14.00,-877.11,3.0},
            {2498.05,-17.11,-865.35,3.0},{2501.60,-17.11,-861.82,3.0},{2548.55,-14.56,-853.12,3.0},
            {2552.22,-14.60,-848.32,3.0},{2639.99,-13.97,-864.05,3.0},{2658.06,-13.78,-874.28,3.0},
            {2670.24,-13.81,-887.31,3.0},{2689.50,-13.97,-906.22,3.0},{2699.81,-13.97,-918.29,3.0},
            {2789.45,-13.94,-948.42,3.0},{2787.76,-13.80,-966.21,3.0},{2784.22,-13.83,-982.02,3.0},
            {2773.38,-13.83,-992.51,3.0},{2742.22,-13.86,-995.46,3.0},{2677.20,-13.87,-913.32,3.0},
            {2670.64,-13.87,-906.63,3.0},{2665.44,-13.87,-900.33,3.0},{2651.00,-13.87,-908.40,3.0},
            {2657.16,-13.87,-918.29,3.0},{2774.60,-13.78,-1013.28,3.0},{2767.40,-13.87,-1019.85,3.0},
            {2774.64,-13.62,-1017.62,3.0},
            {2843.16,-24.65,-1221.62,10.8},{2869.07,-24.65,-1191.17,10.8},{2713.63,-14.57,-1137.39,10.8},
            {2776.62,-13.57,-1060.21,10.8},{2757.60,-13.98,-857.46,10.8},{2683.28,-13.97,-844.80,7.5},
            {2737.92,-14.01,-772.52,22.4},{2726.63,-14.01,-724.54,22.4},{2758.14,-14.01,-810.98,22.4},
        },
    },
}
local function bucketArena(a)                                     -- pre-sort spawn points into tiers
    a.inf, a.veh, a.heli = {}, {}, {}
    for _, p in ipairs(a.spawns) do
        local r = p[4] or 3
        if r <= 5 then a.inf[#a.inf + 1] = p elseif r <= 15 then a.veh[#a.veh + 1] = p else a.heli[#a.heli + 1] = p end
    end
    if #a.inf == 0 then a.inf = a.spawns end                     -- fallback: any point can take infantry
    return a
end
for _, a in pairs(ARENAS) do bucketArena(a) end

-- ===== persistence: best + XP + unlock flags (per machine; cheatable-OK) =====
local function loadv(k) return Loader and Loader.LoadVar and Loader.LoadVar(k) end
local function savev(k, v) if Loader and Loader.SaveVar then Loader.SaveVar(k, v) end end
local function loadBest() return tonumber(loadv("WaveDef_best")) or 0 end
local function saveBest(n) savev("WaveDef_best", n) end
local function getXP()    return tonumber(loadv("WaveDef_xp")) or 0 end
local function bankXP(n)   savev("WaveDef_xp", getXP() + (tonumber(n) or 0)) end
local function spendXP(n)  n = tonumber(n) or 0; if getXP() >= n then savev("WaveDef_xp", getXP() - n); return true end return false end
local function unlockKey(id) return "WaveDef_unlock_" .. tostring(id) end
local function isUnlocked(it) if (it.xp or 0) <= 0 then return true end return loadv(unlockKey(it.id)) == true end
local function doUnlock(it) savev(unlockKey(it.id), true) end

-- ===== cash + effects (native economy; all effects LOCAL to the buyer) =====
local function getCash()  return tonumber(safe(MrxPmc and MrxPmc.GetCashQty)) or 0 end
local function addCash(n) safe(function() MrxPmc.AddCashQty(n, nil, "[Generic.ShopItems]") end) end
local function restoreEconomy()                                 -- put the campaign wallet back (idempotent + guarded)
    if not W.savedCash then return end
    addCash((W.savedCash or 0) - getCash())                     -- set the wallet back to the banked total
    safe(function() Loader.SaveVar("WaveDef_savedCash", 0) end)
    W.savedCash = nil
end
-- equip a support into the HUD quick-select menu. `Hud.SupportMenu:AddItem{ sName, sIcon, oSupport }` is
-- the REAL path the game's own freebie (mrxsupportdata) + PDA-equip (mrxguipda) systems use -- the earlier
-- Pda.Support:SetEquippedItem angle was a dead end. `oSupport` = MrxSupportData.tSupportData[id].oSupport,
-- whose Init() already calls oSupport:SetSupportName(id), so the menu's stock/trigger bind to the SAME key
-- we AddSupportQty into. Runs LOCALLY per machine (each HUD is local); we TRACK what we add so each support
-- shows once and we remove exactly what we added at run end (the campaign menu + default transport stay put).
local function supportData(id)
    local M = _G.MrxSupportData
    return M and M.tSupportData and M.tSupportData[id]
end
W._equipped = W._equipped or {}
local function equipSupport(id)
    if not id or W._equipped[id] then return end                 -- already in the menu (AddSupportQty just tops up stock)
    local td = supportData(id); if not (td and td.oSupport) then return end
    safe(function() Hud.SupportMenu:AddItem({ vPlayer = nil, sName = td.sName, sIcon = td.sIcon, oSupport = td.oSupport, bAnimate = true, bDontNetSync = true }) end)
    W._equipped[id] = td.sName or id
end
-- the raw "Support Menu" HUD widget (the Hud.SupportMenu wrapper only exposes Add/Remove; we need the
-- widget for a snapshot of its item list + RemoveAll).
local function supportMenu()
    local p = safe(Player.GetLocalPlayer); if not p then return nil end
    local G = _G.MrxGuiBase
    if G and G.GetWidgetByNameAndOwner then return safe(G.GetWidgetByNameAndOwner, "Support Menu", p) end
end
-- run START: record whatever supports the player walked in with, then WIPE the menu down to the transport
-- "no-option" default -- the support analogue of the isolated cash economy, so campaign supports can't be
-- used in the arena. (RemoveAll clears the display list; the native stockpile is untouched.)
local function isolateSupports()
    local w = supportMenu()
    local saved = {}
    if w and w.CustomData and w.CustomData.tItemList then
        for _, it in ipairs(w.CustomData.tItemList) do saved[#saved + 1] = { sName = it.sName, sIcon = it.sIcon, oSupport = it.oSupport } end
    end
    W._savedSupports = saved
    if w and w.RemoveAll then safe(function() w:RemoveAll() end) end
    W._equipped = {}                                             -- our run's grants start from an empty menu
end
-- run END: clear our wave-defense grants, then restore exactly what the player had on entry.
local function restoreSupports()
    local w = supportMenu()
    if w and w.RemoveAll then safe(function() w:RemoveAll() end) end
    for _, it in ipairs(W._savedSupports or {}) do
        safe(function() Hud.SupportMenu:AddItem({ vPlayer = nil, sName = it.sName, sIcon = it.sIcon, oSupport = it.oSupport, bDontNetSync = true }) end)
    end
    W._savedSupports = nil; W._equipped = {}
end
local function grantSupport(id, n)
    safe(function() MrxPmc.AddSupportQty(id, n or 1, false, 0) end)   -- into the stockpile
    equipSupport(id)                                                  -- + show it in the quick-select menu
end
local function fmtCash(n) n = n or getCash(); return "$" .. (UI.comma and UI.comma(n) or tostring(n)) end
local function toast(m) if UI.Toast then safe(function() UI.Toast(m) end) end end
local function buyerCtx()
    local char = safe(UI.hero) or safe(Player and Player.GetLocalCharacter)
    local x, y, z, yaw
    if UI.heroPos then x, y, z = safe(UI.heroPos) end
    if not x and char then local ok, px, py, pz = pcall(Object.GetPosition, char); if ok then x, y, z = px, py, pz end end
    if char then local ok, yv = pcall(Object.GetYaw, char); if ok then yaw = yv end end
    yaw = yaw or 0
    local fx = (x or 0) + 6 * math.cos(math.rad(yaw))            -- 6m in front (until ghost-preview placement)
    local fz = (z or 0) + 6 * math.sin(math.rad(yaw))
    return { char = char, x = x, y = y, z = z, yaw = yaw, fx = fx, fz = fz }
end
local function spawnAt(tmpl, ctx)
    if type(tmpl) ~= "string" or tmpl:match("^%s*$") then return nil end   -- blank template hard-CTDs Pg.Spawn
    local u = safe(function() return Pg.Spawn(tmpl, ctx.fx, ctx.y or 0, ctx.fz) end)
    if u then safe(function() Object.SetYaw(u, ctx.yaw) end) end
    return u
end
local FX = {}
function FX.support(id) return function() grantSupport(id, 1); toast(id .. " -> support slots") end end
function FX.spawn(tmpl, kind) return function(ctx) local u = spawnAt(tmpl, ctx); toast(u and ((kind or "item") .. " placed") or "PLACE FAILED") end end
function FX.invuln(sec) return function(ctx)
    if not ctx.char then return end
    safe(function() Object.SetInvincible(ctx.char, true, "WaveDef") end)
    toast("INVINCIBLE " .. sec .. "s")
    if Event and Event.Create then Event.Create(Event.TimerRelative, { sec }, function() safe(function() Object.SetInvincible(ctx.char, false, "WaveDef") end) end) end
end end
function FX.heal() return function(ctx)
    if not ctx.char then return end
    safe(function() Object.SetHealth(ctx.char, Object.GetMaxHealth(ctx.char) or 100) end)
    toast("HEALED TO FULL")
end end

-- ===== CATALOG (single data source: drives BUY (cash) and UNLOCK (xp)). NOTE: support sIds NEEDS-VERIFY
-- vs MrxSupportData.tSupportData. =====
local CATALOG = {
    -- SUPPORT: weapon resupply (cheap; delivers a weapon) + airstrike call-ins (all real MrxSupportData keys)
    { id="sup_rpg",       name="RPG Resupply",      cat="SUPPORT", xp=0,    cost=1200,  desc="An RPG + rockets air-dropped to your stockpile.",   effect=FX.support("rpg") },
    { id="sup_airstrike", name="Airstrike",         cat="SUPPORT", xp=0,    cost=2500,  desc="A bombing run, added to your support stockpile.",   effect=FX.support("bombingrun") },
    { id="sup_cluster",   name="Cluster Bomb",      cat="SUPPORT", xp=500,  cost=3500,  desc="A wide scatter of bomblets over the target area.",  effect=FX.support("clusterbomb") },
    { id="sup_artillery", name="Artillery",         cat="SUPPORT", xp=800,  cost=3500,  desc="Rolling artillery barrage on a marked area.",       effect=FX.support("artillery") },
    { id="sup_rocket",    name="Rocket Artillery",  cat="SUPPORT", xp=1200, cost=4500,  desc="A saturating volley of rockets.",                   effect=FX.support("rocketartillery") },
    { id="sup_bunker",    name="Bunker Buster",     cat="SUPPORT", xp=2000, cost=6000,  desc="Penetrator bomb -- great on the tough targets.",    effect=FX.support("bunkerbuster") },
    { id="sup_laser",     name="Laser-Guided Bomb", cat="SUPPORT", xp=2800, cost=8000,  desc="Pinpoint guided bomb on a marked point.",           effect=FX.support("laserguidedbomb") },
    { id="sup_carpet",    name="Carpet Bomb",       cat="SUPPORT", xp=3800, cost=11000, desc="A long carpet of bombs across the field.",          effect=FX.support("carpetbomb") },
    { id="sup_fuelair",   name="Fuel-Air Bomb",     cat="SUPPORT", xp=4500, cost=14000, desc="A devastating thermobaric blast.",                  effect=FX.support("fuelairbomb") },
    { id="sup_nuke",      name="Tactical Nuke",     cat="SUPPORT", xp=5500, cost=18000, desc="The big one -- clears a wave. Keep your distance.", effect=FX.support("nuke") },
    { id="sup_cruise",    name="Cruise Missile",    cat="SUPPORT", xp=6500, cost=24000, desc="Long-range precision cruise missile.",              effect=FX.support("cruisemissile") },
    { id="sup_moab",      name="MOAB",              cat="SUPPORT", xp=9000, cost=35000, desc="Mother of all bombs. Absolute devastation.",        effect=FX.support("moab") },
    -- UPGRADE: consumable buffs
    { id="up_heal",       name="Field Medkit (full heal)", cat="UPGRADE", xp=0,    cost=1500,  desc="Instantly restore your health to full.",     effect=FX.heal() },
    { id="up_invuln",     name="Adrenaline (10s invuln)",  cat="UPGRADE", xp=1200, cost=4000,  desc="10s of invincibility to reset a bad fight.", effect=FX.invuln(10) },
    { id="up_invuln2",    name="Combat Stim (25s invuln)", cat="UPGRADE", xp=3500, cost=10000, desc="25s of invincibility -- push the line.",      effect=FX.invuln(25) },
    -- VEHICLE: spawned EMPTY at your feet -- climb in
    { id="veh_hmmwv",     name="Light 4x4 (Softtop)", cat="VEHICLE", xp=0,    cost=1500, desc="A fast unarmoured runabout at your feet.", effect=FX.spawn("HMMWV (Softtop)", "vehicle") },
    { id="veh_gun4x4",    name="Armed 4x4 (.50cal)",  cat="VEHICLE", xp=1000, cost=3000, desc="Armoured HMMWV with a .50cal up top.",     effect=FX.spawn("HMMWV (Armored) (50Cal)", "vehicle") },
    { id="veh_lav",       name="LAVIII (Minigun)",    cat="VEHICLE", xp=2000, cost=5000, desc="Wheeled APC with a minigun turret.",       effect=FX.spawn("LAVIII (Minigun)", "vehicle") },
    { id="veh_brad",      name="M2A3 Bradley",        cat="VEHICLE", xp=2500, cost=6500, desc="Tracked IFV -- cannon and armour.",        effect=FX.spawn("M2A3", "vehicle") },
    { id="veh_tank",      name="Heavy Tank (M1A2)",   cat="VEHICLE", xp=3000, cost=8000, desc="Main battle tank. Empty -- climb in.",     effect=FX.spawn("M1A2", "vehicle") },
    -- EMPLACEMENT: placed weapon mounts
    { id="emp_mg",        name="MG Emplacement",       cat="EMPLACEMENT", xp=1000, cost=1800, desc="A mounted machine-gun nest.",         effect=FX.spawn("Emplaced MG3 (Allied)", "emplacement") },
    { id="emp_gl",        name="Grenade MG",           cat="EMPLACEMENT", xp=1500, cost=2500, desc="Mounted automatic grenade launcher.", effect=FX.spawn("Emplaced GL", "emplacement") },
    { id="emp_rr",        name="Recoilless Rifle (AT)",cat="EMPLACEMENT", xp=2000, cost=3000, desc="Mounted anti-tank recoilless rifle.", effect=FX.spawn("Emplaced Recoiless Rifle (Allied)", "emplacement") },
    { id="emp_tow",       name="TOW Emplacement",      cat="EMPLACEMENT", xp=2500, cost=3500, desc="Anti-vehicle guided-missile emplacement.", effect=FX.spawn("Emplaced TOW (Allied)", "emplacement") },
    -- PROP: physical placeable cover (real _global_ props, not the AI cover-hint markers)
    { id="prop_sandbag",  name="Sandbag Wall",     cat="PROP", xp=0, cost=400, desc="A sandbag wall to break line of sight.", effect=FX.spawn("_global_sandbagsstraighta", "cover") },
    { id="prop_barricade",name="Barricade",        cat="PROP", xp=0, cost=400, desc="A wooden barricade for quick cover.",     effect=FX.spawn("_global_barricadea", "cover") },
    { id="prop_concrete", name="Concrete Barrier", cat="PROP", xp=0, cost=600, desc="A heavy concrete barrier -- solid cover.",effect=FX.spawn("_global_concretebarrier01", "cover") },
    { id="prop_barrel",   name="Explosive Barrel", cat="PROP", xp=0, cost=300, desc="Explosive barrels -- cover with a bang.", effect=FX.spawn("_global_explosivebarrel", "cover") },
}
local CAT_ORDER = { "SUPPORT", "UPGRADE", "VEHICLE", "EMPLACEMENT", "PROP" }

-- ===== co-op reward receivers (client applies host-signalled cash + XP; host ignores its own loopback) =====
ModNet.On("wd_reward", function(_, amount) if ModNet.IsAuthority() then return end safe(function() MrxPmc.AddCashQty(tonumber(amount) or 0) end) end)
ModNet.On("wd_xp",     function(_, amount) if ModNet.IsAuthority() then return end local n = tonumber(amount) or 0; bankXP(n); W.runXP = (W.runXP or 0) + n end)
local XP_PER_KILL, XP_PER_WAVE, XP_WIN = 10, 100, 500
local function awardXP(n)
    n = math.floor((tonumber(n) or 0) * (W.rewardMult or 1)); if n <= 0 then return end   -- modifier reward scaling
    bankXP(n)                                                    -- bank locally (per-machine)
    W.runXP = (W.runXP or 0) + n                                 -- accumulate this run's XP (results screen)
    if ModNet.IsCoop() then ModNet.Send("wd_xp", n) end          -- partner banks its own copy
end

-- ===== enemy minimap blips + drops (M6) =====
-- Blips help players FIND enemies (host/SP only: the client doesn't hold the host-spawned guids). Drops:
-- a killed enemy may leave a bright colored beacon; walking over it grants the effect. Drops are host-
-- spawned + replicated to the client (position markers); collection is local to each player. (rnd() up top.)
local ENEMY_RGB = { 235, 60, 60 }
local function addEnemyBlip(u, idx)
    local b = { sName = "wd_e" .. idx }
    -- MINIMAP (radar) + PDA map only. NO Marker.AddBlip -- that's the floating over-the-head world marker.
    pcall(function() Hud.Radar:AddObjective({ sName = b.sName, uGuid = u, sTexture = "objective_action", nR = ENEMY_RGB[1], nG = ENEMY_RGB[2], nB = ENEMY_RGB[3], nWidth = 10.666667, nHeight = 10.666667, nSortOrder = 5 }) end)
    pcall(function() Pda.Map:AddBlip({ sName = b.sName, uGuid = u, sTexture = "icon_yellow_mc", nSortOrder = 2 }) end)
    return b
end
local function removeEnemyBlip(b)
    if not b then return end
    if b.blip then pcall(Marker.Remove, b.blip) end
    if b.sName then pcall(function() Hud.Radar:RemoveObjective({ sName = b.sName }) end); pcall(function() Pda.Map:RemoveBlip({ sName = b.sName }) end) end
end
-- faction tags for Pg.FastCollect* (full NAMES -- different from the SetRelation abbrevs). Used to sweep for
-- engine-spawned reinforcement units: adopt them live (adoptStrays) + scrub any stragglers on run end.
local COLLECT_TAG = { VZ = "VZ", GUERILLA = "Guerilla", CHINA = "China", ALLIED = "Allied", OC = "OC", PIRATE = "Pirate" }
local function sweepArena(run)                                  -- run end: scrub any hostile strays we didn't track (natives)
    if not (run and run.center and run.factions) then return end
    for _, f in ipairs(run.factions) do
        local tag = COLLECT_TAG[f]
        if tag then
            local hs = safe(function() return Pg.FastCollectHumans(run.center.x, run.center.y, run.center.z, 160, tag .. " && Human") end)
            if type(hs) == "table" then for _, u in ipairs(hs) do pcall(Object.Remove, u) end end
        end
    end
end
local function clearEnemies(run)                                -- pull blips AND despawn the units (arena cleanup on run end)
    for _, e in ipairs(run and run.enemies or {}) do
        removeEnemyBlip(e.blip); e.blip = nil
        if e.u then pcall(Object.Remove, e.u) end
    end
    if run and run.boss then removeEnemyBlip(run.boss.blip); if run.boss.u then pcall(Object.Remove, run.boss.u) end; run.boss = nil end
    sweepArena(run)                                             -- + scrub untracked native reinforcements
end

-- "ideal" spawn points: near the reference (the player) but not right on top; nearest first, capped.
local MIN_SPAWN_D, MAX_SPAWN_D, ACTIVE_PTS = 18, 80, 24   -- use more spawn points -> fewer enemies per point
local function idealPoints(pts, rx, rz)
    local scored = {}
    for _, p in ipairs(pts) do local dx, dz = p[1] - rx, p[3] - rz; scored[#scored + 1] = { p = p, d = dx * dx + dz * dz } end
    table.sort(scored, function(a, b) return a.d < b.d end)
    local out = {}
    for _, s in ipairs(scored) do local dist = math.sqrt(s.d)
        if dist >= MIN_SPAWN_D and dist <= MAX_SPAWN_D then out[#out + 1] = s.p; if #out >= ACTIVE_PTS then break end end end
    if #out < 4 then out = {}
        for _, s in ipairs(scored) do if math.sqrt(s.d) >= MIN_SPAWN_D then out[#out + 1] = s.p; if #out >= ACTIVE_PTS then break end end end end
    if #out == 0 then out = pts end
    return out
end

local DROP_R, DROP_CHANCE, CRATE_SHARE = 6, 0.15, 0.6   -- CRATE_SHARE = fraction of drops that are physical crates
local DROPS = {
    { name = "AIRSTRIKE",   rgb = { 60, 150, 255 }, w = 3, fx = function() grantSupport("bombingrun", 1) end },
    { name = "ARTILLERY",   rgb = { 255, 150, 40 }, w = 3, fx = function() grantSupport("artillery", 1) end },
    { name = "FULL HEAL",   rgb = { 90, 255, 120 }, w = 3, fx = function(ctx) if ctx.char then safe(function() Object.SetHealth(ctx.char, Object.GetMaxHealth(ctx.char) or 100) end) end end },
    { name = "INVINCIBLE",  rgb = { 255, 60, 60 },  w = 2, fx = function(ctx) FX.invuln(20)(ctx) end },
    { name = "CASH +2500",  rgb = { 255, 210, 40 }, w = 4, fx = function() addCash(2500) end },
    { name = "CARPET BOMB", rgb = { 255, 90, 40 },  w = 2, fx = function() grantSupport("carpetbomb", 1) end },
    { name = "TAC NUKE",    rgb = { 200, 60, 255 }, w = 1, fx = function() grantSupport("nuke", 1) end },
}
local DROP_WT = 0; for _, d in ipairs(DROPS) do DROP_WT = DROP_WT + d.w end
local function pickDrop() local r = rnd() * DROP_WT; local acc = 0
    for i, d in ipairs(DROPS) do acc = acc + d.w; if r <= acc then return i end end; return 1 end
W.drops = W.drops or {}
local function removeDrop(id)
    local dr = W.drops[id]; if not dr then return end
    if dr.disc then pcall(Marker.Remove, dr.disc) end
    if dr.blip then pcall(Marker.Remove, dr.blip) end
    if dr.u then pcall(Object.Remove, dr.u) end
    W.drops[id] = nil
end
local function addDrop(id, typeIdx, x, y, z)
    local d = DROPS[typeIdx]; if not d then return end
    local m = { type = typeIdx, x = x, y = y, z = z }
    local ok, u = pcall(Pg.Spawn, "TinyGeometry", x, y, z)
    if ok and u then m.u = u
        local okd, disc = pcall(Marker.AddDisc, u, DROP_R, d.rgb[1], d.rgb[2], d.rgb[3], 0.4); if okd then m.disc = disc end
        local okb, bl = pcall(Marker.AddBlip, u, "HUD_objective_deliverable", 30, d.rgb[1], d.rgb[2], d.rgb[3], 255, 2, 5, 240); if okb then m.blip = bl end
    end
    W.drops[id] = m
end
-- ----- supply crates: physical breakable loot props (the game's own Supply Drop / Pickup entities).
-- Unlike the coded beacon pickups above, a crate is just Pg.Spawn'd at the death spot -- the player breaks
-- it for native loot (weapons / health / ammo / cash), no collection logic needed. Rarer = higher value.
-- Replicated so BOTH machines spawn their own local crate (the native break pays each player their loot).
local CRATES = {
    { name = "Ammo",             t = "Ammo Pickup (Bullet)",     w = 10 },
    { name = "Guerilla cache",   t = "Supply Drop (Guerilla)",   w = 8 },
    { name = "VZ cache",         t = "Supply Drop (VZ)",         w = 8 },
    { name = "Light MG",         t = "Supply Drop (Light MG)",   w = 7 },
    { name = "CQB kit",          t = "Supply Drop (CQB)",        w = 7 },
    { name = "Cash",             t = "Pickup (Cash)",            w = 7 },
    { name = "RPG",              t = "Supply Drop (RPG)",        w = 5 },
    { name = "Grenade launcher", t = "Supply Drop (GL)",         w = 5 },
    { name = "C4",               t = "Supply Drop (C4)",         w = 5 },
    { name = "Health",           t = "Supply Drop (Health)",     w = 5 },
    { name = "Sniper",           t = "Supply Drop (Sniper)",     w = 4 },
    { name = "Covert kit",       t = "Supply Drop (Covert)",     w = 4 },
    { name = "AA launcher",      t = "Supply Drop (AA)",         w = 3 },
    { name = "Anti-tank",        t = "Supply Drop (AT AL)",      w = 3 },
    { name = "Fuel",             t = "Fuel Pickup (Large)",      w = 3 },
    { name = "Support crate",    t = "Supply Drop (Support)",    w = 2 },
    { name = "Blanco stash",     t = "Supply Drop (Blanco)",     w = 2 },
    { name = "BLUEPRINTS",       t = "Supply Drop (Blueprints)", w = 1 },
    { name = "TREASURE",         t = "Supply Drop (Treasure)",   w = 1 },
}
local CRATE_WT = 0; for _, c in ipairs(CRATES) do CRATE_WT = CRATE_WT + c.w end
local function pickCrate() local r = rnd() * CRATE_WT; local acc = 0
    for _, c in ipairs(CRATES) do acc = acc + c.w; if r <= acc then return c end end; return CRATES[1] end
W.crates = W.crates or {}
local MAX_LIVE_CRATES, CRATE_FALLBACK = 40, "Ammo Pickup (Bullet)"
local function spawnCrateLocal(tmpl, x, y, z)                    -- returns true if the template actually spawned
    if type(tmpl) ~= "string" or tmpl:match("^%s*$") then return false end
    local ok, u = pcall(Pg.Spawn, tmpl, x, y, z)
    if ok and u then
        W.crates[#W.crates + 1] = u
        if #W.crates > MAX_LIVE_CRATES then pcall(Object.Remove, table.remove(W.crates, 1)) end   -- retire the oldest
        return true
    end
    return false
end
local function clearCrates() for _, u in ipairs(W.crates) do pcall(Object.Remove, u) end W.crates = {} end
ModNet.On("wd_crate", function(_, msg)                           -- client: spawn its own local copy of the crate
    if ModNet.IsAuthority() then return end
    if type(msg) == "table" then spawnCrateLocal(msg[1], msg[2], msg[3], msg[4]) end
end)
local function spawnCrate(x, y, z)                               -- authority: drop a physical crate + replicate it
    local c = pickCrate()
    local tmpl, ok = c.t, spawnCrateLocal(c.t, x, y, z)
    if not ok then tmpl = CRATE_FALLBACK; spawnCrateLocal(tmpl, x, y, z) end   -- some Supply Drop templates won't Pg.Spawn -> guarantee loot
    if Loader and Loader.Printf then Loader.Printf("[WaveDef] crate pick=" .. c.name .. " tmpl='" .. c.t .. "' -> " .. (ok and "ok" or "FAIL(->ammo)")) end
    if ModNet.IsCoop() then ModNet.Send("wd_crate", { tmpl, x, y, z }) end   -- replicate the template that actually spawned
    toast(c.name .. " crate!")
end
local function clearDrops() for id in pairs(W.drops) do removeDrop(id) end; clearCrates() end
ModNet.On("wd_drop", function(_, msg)                            -- client: replicate a host-spawned drop
    if ModNet.IsAuthority() then return end
    if type(msg) == "table" then addDrop(msg[1], msg[2], msg[3], msg[4], msg[5]) end
end)
ModNet.On("wd_dropget", function(_, id) removeDrop(id) end)      -- both: a drop was collected -> remove it
W.dropSeq = W.dropSeq or 0
local function spawnDrop(x, y, z)                                -- authority only (enemy-death path)
    if rnd() > DROP_CHANCE then return end
    if rnd() < CRATE_SHARE then spawnCrate(x, y, z); return end  -- most drops are physical breakable crates
    W.dropSeq = W.dropSeq + 1; local id = W.dropSeq; local typeIdx = pickDrop()   -- ...the rest are coded beacon pickups
    addDrop(id, typeIdx, x, y, z)
    if ModNet.IsCoop() then ModNet.Send("wd_drop", { id, typeIdx, x, y, z }) end
    toast(DROPS[typeIdx].name .. " dropped!")
end
local function pollDrops()                                       -- both machines: collect near the LOCAL player
    if not next(W.drops) then return end
    local ch = Player.GetLocalCharacter(); if not ch then return end
    local px, _, pz = safe(Object.GetPosition, ch); if not px then return end
    for id, dr in pairs(W.drops) do
        local dx, dz = dr.x - px, dr.z - pz
        if dx * dx + dz * dz <= DROP_R * DROP_R then
            local d = DROPS[dr.type]; if d then safe(d.fx, buyerCtx()); toast("GOT " .. d.name) end
            removeDrop(id)
            if ModNet.IsCoop() then ModNet.Send("wd_dropget", id) end
        end
    end
end
-- killstreak: every KILLSTREAK kills in a run grants BOTH players a free call-in (host-counted + replicated).
local KILLSTREAK, KILLSTREAK_SUP = 25, { "bombingrun", "artillery", "clusterbomb", "rocketartillery" }
ModNet.On("wd_streak", function(_, id)                           -- client: grant its own copy of the streak reward
    if ModNet.IsAuthority() then return end
    grantSupport(tostring(id), 1); toast("KILLSTREAK!  " .. tostring(id))
end)
local function onEnemyDied(e)                                    -- authority: count kill + blip off + maybe drop
    e.dead = true
    removeEnemyBlip(e.blip); e.blip = nil
    local run = W.run
    if run then run.kills = (run.kills or 0) + 1; run.waveKills = (run.waveKills or 0) + 1 end
    awardXP(XP_PER_KILL)
    if run and run.kills > 0 and run.kills % KILLSTREAK == 0 then   -- killstreak reward -> free support for both
        local pick = KILLSTREAK_SUP[rndInt(#KILLSTREAK_SUP)]
        grantSupport(pick, 1); toast("KILLSTREAK x" .. run.kills .. "!  " .. pick)
        if ModNet.IsCoop() then ModNet.Send("wd_streak", pick) end
    end
    local x, y, z = e.sx, e.sy, e.sz
    local cx, cy, cz = safe(Object.GetPosition, e.u); if cx then x, y, z = cx, cy, cz end
    spawnDrop(x, y, z)
end

-- ===== enemy support strikes: past a threshold the enemy bombards the defended area (dodge the red markers) =====
local ENEMY_STRIKE_START, STRIKE_EVERY = 3, 12   -- first striking wave; ticks between strikes (12*0.5s = 6s)
local STRIKE_DELAY, STRIKE_R, STRIKE_SPREAD = 3.5, 10, 32
local STRIKE_TRACK_R, TARGET_MOVE = 26, 12   -- strikes land within R of the player (wide + dodgeable); holding still tightens accuracy
local STRIKE_SHELL, STRIKE_FALL_H = "Artillery Shell", 350   -- a REAL falling shell (Airstrike.SpawnOrdnance), drops from +H and explodes on impact
local function strikeCount(run)                                 -- strikes this wave (escalating), gated by the Air modifier
    local air = (run.mods and run.mods.mAir) or "normal"
    if air == "off" then return 0 end
    local wave = run.wave or 0
    local start = early(run, (air == "heavy") and 2 or ENEMY_STRIKE_START)
    if wave < start then return 0 end
    local base, per = (air == "heavy") and 0.4 or 0.25, (air == "heavy") and 0.08 or 0.06
    if rnd() > math.min(base + per * (wave - start), 0.9) then return 0 end
    return 1 + math.floor((wave - start) / 2) + ((air == "heavy") and 1 or 0)
end
local function strikeImpact(x, y, z)                            -- BOTH machines: a controlled hit on the local player (the falling shell makes the real blast)
    local ch = Player.GetLocalCharacter(); if not ch then return end
    local px, _, pz = safe(Object.GetPosition, ch); if not px then return end
    local dx, dz = px - x, pz - z
    if dx * dx + dz * dz <= STRIKE_R * STRIKE_R then             -- guaranteed hit if the blast lands on you (in case the AoE misses)
        local cur = safe(Object.GetHealth, ch) or 0; local mx = safe(Object.GetMaxHealth, ch) or 100
        safe(function() Object.SetHealth(ch, math.max(1, cur - mx * 0.4)) end)
        toast("HIT BY AIRSTRIKE!")
    end
end
-- the plane + the real falling shell. These run on EACH machine (host via fireEnemyStrike, client via the
-- wd_strike handler -> warnStrike), because Airstrike.Flyby / SpawnOrdnance spawn LOCALLY (not auto-networked,
-- like our other Pg.Spawns) -- so both players must run them or the co-op partner sees a flash with no bomb.
-- Airstrike.Flyby takes a template NAME string (global "Support Vehicle (...)" planes resolve, unlike our
-- roster templates via GetGuidByName). Shell = MasterCheatMenu's DropOrdnanceAt call shape (position-based).
local FLYBY_PLANES = { "Support Vehicle (OV10)", "Support Vehicle (Tucano)" }   -- small light planes (the game's own ambient flyby craft)
local function launchFlyby(x, y, z)
    local ang = rnd() * 6.2832; local d = 260
    local sx, sz = x + d * math.cos(ang), z + d * math.sin(ang)
    safe(function() Airstrike.Flyby(FLYBY_PLANES[rndInt(#FLYBY_PLANES)], sx, sz, x, z, (y or 0) + 90, d / STRIKE_DELAY) end)
end
local function dropShell(x, y, z)                             -- a real shell falls from +STRIKE_FALL_H at 100/s and explodes on IMPACT via its fuze
    safe(function() Airstrike.SpawnOrdnance(STRIKE_SHELL, x, (y or 0) + STRIKE_FALL_H, z, 0, -100, 0, "impact", 1) end)
end
local function warnStrike(x, y, z)                             -- BOTH machines: flash + the plane + the falling shell + the controlled hit
    toast("INCOMING AIRSTRIKE!")
    launchFlyby(x, y, z); dropShell(x, y, z)                   -- spawn the plane + the actual bomb LOCALLY on this machine
    local anchor = safe(function() return Pg.Spawn("TinyGeometry", x, y, z) end)
    if not (anchor and Event and Event.Create) then strikeImpact(x, y, z); return end
    -- MissionForge's proven pattern: the disc doesn't animate, so we Remove + re-AddDisc each blink. The
    -- interval shrinks (0.5s -> 0.08s) so it flashes slowly at first, rapidly right before impact.
    local st = { disc = nil, on = false, elapsed = 0 }
    local function step()
        if st.disc then pcall(Marker.Remove, st.disc); st.disc = nil end
        if st.elapsed >= STRIKE_DELAY then pcall(Object.Remove, anchor); strikeImpact(x, y, z); return end
        st.on = not st.on
        local frac = st.elapsed / STRIKE_DELAY                  -- 0 -> 1 over the warning
        if st.on then                                            -- "on" blink: brighter + more opaque as impact nears
            local okd, d = pcall(Marker.AddDisc, anchor, STRIKE_R, 255, 50, 40, 0.3 + 0.45 * frac)
            if okd then st.disc = d end
        end
        local interval = math.max(0.08, 0.5 - 0.42 * frac)      -- flash SLOW -> FAST
        st.elapsed = st.elapsed + interval
        Event.Create(Event.TimerRelative, { interval }, step)
    end
    step()
end
ModNet.On("wd_strike", function(_, msg) if ModNet.IsAuthority() then return end if type(msg) == "table" then warnStrike(msg[1], msg[2], msg[3]) end end)
-- strike targeting: land near a PLAYER (the host), within STRIKE_TRACK_R. Target Acquisition tightens the
-- radius the longer the player holds still and resets it the moment they move > TARGET_MOVE.
local function updateAcquisition(run)                          -- authority, per tick
    if not (run.mods and run.mods.mTarget) then run.acqMul = 1; return end
    local px, _, pz = hostPose(); if not px then return end
    local lp = run.acqPos
    if lp then
        local dx, dz = px - lp.x, pz - lp.z
        if dx * dx + dz * dz <= TARGET_MOVE * TARGET_MOVE then run.acqMul = math.max(0.06, (run.acqMul or 1) - 0.015)  -- held still -> tighten slowly (~30s to pinpoint)
        else run.acqPos = { x = px, z = pz }; run.acqMul = 1 end                                                       -- moved -> reset spread
    else run.acqPos = { x = px, z = pz }; run.acqMul = 1 end
end
local function strikeTargetPos(run)                            -- a spot within R of the host player (R shrinks w/ Target Acquisition)
    local px, py, pz = hostPose()
    if not px then local c = run.center; return c.x, c.y, c.z end
    local r = STRIKE_TRACK_R * ((run.mods and run.mods.mTarget) and (run.acqMul or 1) or 1)
    local ang = rnd() * 6.2832; local rr = r * math.sqrt(rnd())
    return px + rr * math.cos(ang), py, pz + rr * math.sin(ang)
end
local function fireEnemyStrike(run)                            -- authority: pick the target near the player, run the strike, replicate to co-op
    local x, y, z = strikeTargetPos(run)
    warnStrike(x, y, z)                                          -- host: flash + plane + falling shell + controlled hit
    if ModNet.IsCoop() then ModNet.Send("wd_strike", { x, y, z }) end   -- client runs the SAME warnStrike (flash + plane + shell + hit)
    Loader.Printf("[WaveDef] enemy airstrike inbound")
end

-- ===== shared publish / alive count =====
local function publish(run)
    put("state", run.state); put("wave", run.wave)
    put("enemiesLeft", run.left or 0); put("enemiesTotal", run.total or 0)
    put("best", run.best or 0); put("kills", run.kills or 0); put("cash", run.cash or 0)
    put("newBest", run.newBest and true or false)               -- results screen: endless high-score beaten this run
    put("factions", run.factionsLabel or "")                    -- readable faction mix (e.g. "VZ+GUERILLA")
    put("rewardPct", math.floor((W.rewardMult or 1) * 100 + 0.5))  -- difficulty reward multiplier as an int %
end
local function countAlive(run)
    local n = 0
    for _, e in ipairs(run.enemies or {}) do
        if e.u and not e.dead then
            local hp = safe(Object.GetHealth, e.u)
            if hp and hp > 0 then n = n + 1 else onEnemyDied(e) end
        end
    end
    return n
end
local REGEN_EVERY = 3
local function regenPass(run)                                    -- heal tanky enemies/boss toward max (the tank mechanic here)
    for _, e in ipairs(run.enemies or {}) do
        if e.u and not e.dead and e.regen and e.maxHp then
            local cur = safe(Object.GetHealth, e.u)
            if cur and cur > 0 and cur < e.maxHp then safe(function() Object.SetHealth(e.u, math.min(e.maxHp, cur + e.regen)) end) end
        end
    end
    local b = run.boss
    if b and b.u and b.regen and b.maxHp then
        local cur = safe(Object.GetHealth, b.u)
        if cur and cur > 0 and cur < b.maxHp then safe(function() Object.SetHealth(b.u, math.min(b.maxHp, cur + b.regen)) end) end
    end
end

-- ===== spawn: paced batches from the arena's infantry points, weighted from the run's faction pool =====
-- a geometry-safe AUTHORED point near a world position (for boss-summoned adds -- spawning them in a ring
-- around the boss clipped walls when the boss stood near cover; authored points are known-safe). Picks
-- randomly among the few closest so adds cluster near the boss but still spread over safe ground.
local function nearBossPoint(run, bx, bz)
    local pts = run.spawnPts
    if not pts or #pts == 0 then return nil end
    local scored = {}
    for _, p in ipairs(pts) do local dx, dz = p[1] - bx, p[3] - bz; scored[#scored + 1] = { p = p, d = dx * dx + dz * dz } end
    table.sort(scored, function(a, b) return a.d < b.d end)
    return scored[rndInt(math.min(3, #scored))].p
end
local function spawnBoss(run)
    local def = rollBoss()                                       -- prefix (mechanic) x body (template) x codename -> varies each boss wave/run
    local pts = run.spawnPts
    local x, y, z
    if pts and #pts > 0 then local p = pts[1]; x, y, z = p[1], p[2], p[3]
    else x, y, z = run.center.x, run.center.y, run.center.z + 20 end
    local u = safe(Pg.Spawn, def.template, x, y, z)
    if not u then Loader.Printf("[WaveDef] boss spawn FAILED: " .. def.template); return end
    safe(function() Object.SetHealth(u, Object.GetMaxHealth(u) or 999) end)      -- full health
    local _, _, _, hch = hostPose()
    if hch then safe(function() Ai.Goal({ AIGuid = u, Goal = "Attack", Target = hch, Priority = "HiPri", Force = true }) end) end
    safe(function() Ai.SetHaste(u, def.haste or 1.25) end)
    run.boss = { u = u, def = def, blip = addEnemyBlip(u, 900000 + run.wave), tick = 0 }
    local bmx = safe(Object.GetMaxHealth, u) or 0                                -- tanky via REGEN (no SetMaxHealth in this build)
    local bk = (def.hp or 3) * (run.mods and run.mods.mHp or 1)
    if bmx > 0 and bk > 1 then run.boss.maxHp = bmx; run.boss.regen = (bk - 1) * bmx * 0.06 end
    toast("BOSS: " .. def.name)
    Loader.Printf("[WaveDef] BOSS " .. def.name .. " (" .. def.template .. ") hp x" .. (def.hp or 3))
end
local function spawnOne(run, hch, p, idx)                       -- p = a chosen authored (geometry-safe) point; idx = spawn ordinal
    local x, y, z
    if p then
        local r = 0.75                                           -- TIGHT jitter: the point CENTER is the known-safe spot. A sub-metre
        local ang = rnd() * 6.2832; local rr = r * math.sqrt(rnd())   -- offset just avoids exact overlap; AI shove each other apart.
        x, y, z = p[1] + rr * math.cos(ang), p[2], p[3] + rr * math.sin(ang)
    else
        local center = run.center
        local ang = 2 * math.pi * ((idx or 1) / math.max(1, run.toSpawn)); local r = run.cfg.arenaRadius or 25
        x, y, z = center.x + r * math.cos(ang), center.y, center.z + r * math.sin(ang)
    end
    local tmpl = run.airborne or pickUnit(run.pool)              -- airborne wave -> paratroopers chuting in from altitude
    local u = safe(Pg.Spawn, tmpl, x, run.airborne and (y + (run.airborneAlt or 45)) or y, z)
    if u then
        if hch then safe(function() Ai.Goal({ AIGuid = u, Goal = "Attack", Target = hch, Priority = "HiPri", Force = true }) end) end
        safe(function() Ai.SetHaste(u, 1.6 * (run.mods and run.mods.mSpd or 1) * (run.waveHaste or 1)) end)
        local e = { u = u, blip = addEnemyBlip(u, run.wave * 10000 + (idx or #run.enemies + 1)), sx = x, sy = y, sz = z }
        applyHp(e, run.mods and run.mods.mHp)
        run.enemies[#run.enemies + 1] = e
    end
end
-- crewed vehicle / heli from the arena's veh/heli tier (AI units -> host only). isHeli picks the pool + tier.
local function spawnVeh(run, hch, isHeli)
    local arena = run.arena
    local pts = arena and (isHeli and arena.heli or arena.veh) or nil
    if not pts or #pts == 0 then pts = run.spawnPts end          -- fallback to the infantry points
    if not pts or #pts == 0 then return end
    local p = pts[rndInt(#pts)]
    local tmpl = pickUnit(isHeli and run.heliPool or run.vehPool); if not tmpl then return end
    local y = p[2] + (isHeli and 18 or 0)                         -- helis a bit up
    local u = safe(Pg.Spawn, tmpl, p[1], y, p[3])
    if u then
        if hch then safe(function() Ai.Goal({ AIGuid = u, Goal = "Attack", Target = hch, Priority = "HiPri", Force = true }) end) end
        local e = { u = u, blip = addEnemyBlip(u, run.wave * 10000 + 5000 + #run.enemies), sx = p[1], sy = y, sz = p[3], veh = true }
        applyHp(e, run.mods and run.mods.mHp)
        run.enemies[#run.enemies + 1] = e
    end
    return u
end
local function stillSpawning(run)
    return (run.spawned or 0) < (run.toSpawn or 0) or (run.vehSpawned or 0) < (run.vehToSpawn or 0) or (run.heliSpawned or 0) < (run.heliToSpawn or 0)
end
local function activeAI(run)                                    -- conservative live-AI tally for the cap (a crewed vehicle = several AI)
    local n = 0
    for _, e in ipairs(run.enemies or {}) do if e.u and not e.dead then n = n + (e.veh and 5 or 1) end end
    if run.boss and run.boss.u then n = n + 1 end
    return n
end
-- adopt native reinforcements: the report -> pursuit loop makes the ENGINE spawn backup units (no Lua hook),
-- so we periodically sweep for hostile-faction humans near the arena that we did NOT spawn and tag them as
-- ours (attack goal + blip + counted + cleaned up). Dedup by guid, cap-aware, guarded (best-effort -- the
-- "[WaveDef] adopted N" log line confirms it works in-engine; if 0, the COLLECT_TAG filter needs fixing).
local function adoptStrays(run)
    if not (run and run.center and run.factions) then return end
    local have = {}
    for _, e in ipairs(run.enemies) do if e.u then have[e.u] = true end end
    if run.boss and run.boss.u then have[run.boss.u] = true end
    local _, _, _, hch = hostPose()
    local n = 0
    for _, f in ipairs(run.factions) do
        local tag = COLLECT_TAG[f]
        local list = tag and safe(function() return Pg.FastCollectHumans(run.center.x, run.center.y, run.center.z, 110, tag .. " && Human") end)
        if type(list) == "table" then
            for _, u in ipairs(list) do
                if u and not have[u] and activeAI(run) < MAX_ACTIVE then
                    have[u] = true
                    if hch then safe(function() Ai.Goal({ AIGuid = u, Goal = "Attack", Target = hch, Priority = "HiPri", Force = true }) end) end
                    run.enemies[#run.enemies + 1] = { u = u, blip = addEnemyBlip(u, 720000 + #run.enemies), adopted = true }
                    run.total = (run.total or 0) + 1; n = n + 1
                end
            end
        end
    end
    if n > 0 and Loader and Loader.Printf then Loader.Printf("[WaveDef] adopted " .. n .. " native reinforcement unit(s)") end
end
local POINT_COOLDOWN = 3   -- spawn-batch ticks a point must REST before reuse: lets the last unit step off so we never
                           -- stack two units on one point (they were spawning into each other / geometry). Points are geometry-safe.
local function spawnBatch(run)                                   -- pace the wave in, but never exceed MAX_ACTIVE concurrent (CTD guard)
    local _, _, _, hch = hostPose()
    local room = MAX_ACTIVE - activeAI(run)
    if room <= 0 then return end                                 -- at the cap -> stagger: wait for kills to free room
    local pts = run.spawnPts
    run.stick = (run.stick or 0) + 1                             -- spawn-batch tick (drives the per-point cooldown)
    run.ptCd = run.ptCd or {}
    local placed = 0
    if pts and #pts > 0 then
        for i = 1, #pts do                                       -- one unit per RESTED point -> spread + no stacking
            if placed >= SPAWN_BATCH or room <= 0 or (run.spawned or 0) >= (run.toSpawn or 0) then break end
            if (run.stick - (run.ptCd[i] or -99)) >= POINT_COOLDOWN then
                run.spawned = run.spawned + 1; spawnOne(run, hch, pts[i], run.spawned); run.ptCd[i] = run.stick
                placed = placed + 1; room = room - 1
            end
        end
    else                                                        -- no arena points: fall back to the ring
        local n = math.min(SPAWN_BATCH, (run.toSpawn or 0) - (run.spawned or 0), room)
        for _ = 1, n do run.spawned = run.spawned + 1; spawnOne(run, hch, nil, run.spawned); room = room - 1 end
    end
    if room > 5 and (run.vehSpawned or 0) < (run.vehToSpawn or 0) then run.vehSpawned = run.vehSpawned + 1; spawnVeh(run, hch, false); room = room - 5 end
    if room > 5 and (run.heliSpawned or 0) < (run.heliToSpawn or 0) then run.heliSpawned = run.heliSpawned + 1; spawnVeh(run, hch, true) end
end
-- ===== reinforcement (copter drop, triggered by the native REPORT UI). When an enemy finishes reporting you
-- (kill the caller to stop it!), we hook FinishedReporting to run OUR drop instead of the finicky engine
-- reinforcement (which we also suppress). MrxCopterDrop.Create winches a CREWED faction vehicle to a spot
-- near you and returns the cargo guid -- reliable + server-only + auto-networked, so we just track the cargo. =====
-- Reinforcement (compromise per Logan): rather than heli-dropped troops (all native DELIVERIES fail here --
-- MrxCopterDrop/Airstrike.Flyby resolve cargo via Pg.GetGuidByName, which can't see our roster templates),
-- the report calls back an ARMED VEHICLE (APC) or a GUNSHIP by default, with a chance of heavier AIR SUPPORT
-- (a bombing run on the player). All via the proven `spawnVeh` / `fireEnemyStrike` paths -- full control.
local function reinforceDrop(run)                               -- authority (report-triggered)
    if not (run and run.state == "active" and run.factions) then return end
    if activeAI(run) >= MAX_ACTIVE - 6 then return end          -- respect the CTD cap
    if rnd() < 0.2 then                                          -- 20%: heavier support -- an air strike on the player
        fireEnemyStrike(run); toast("ENEMY AIR SUPPORT INBOUND!"); Loader.Printf("[WaveDef] report-called air support (strike)")
        return
    end
    local _, _, _, hch = hostPose()
    local isHeli = false                                        -- default: armed vehicle; 40% -> a gunship (if the heli pool has any)
    if rnd() < 0.4 and run.heliPool and (run.heliPool.total or 0) > 0 then isHeli = true end
    local u = spawnVeh(run, hch, isHeli)                        -- reuse the proven crewed-vehicle spawn (arena veh/heli point + Attack)
    if u then
        run.total = (run.total or 0) + 1
        toast(isHeli and "ENEMY GUNSHIP INBOUND!" or "ARMOR REINFORCEMENTS INBOUND!")
        Loader.Printf("[WaveDef] report-called " .. (isHeli and "gunship" or "armed vehicle"))
    end
end
-- hook the native report system (reload-safe: re-wrap if the module reloaded; never double-wrap). Keep its
-- meter UI + kill-the-caller; suppress the engine pursuit-reinforcement during a run; add our drop on completion.
do
    local fm = _G.MrxFactionManager
    if fm then
        if type(fm.IncrementPursuit) == "function" and fm.IncrementPursuit ~= W._wdIncWrap then
            local orig = fm.IncrementPursuit
            local w = function(...) if W.run and W.run.state then return end return orig(...) end
            W._wdIncWrap = w; fm.IncrementPursuit = w
        end
        if type(fm.FinishedReporting) == "function" and fm.FinishedReporting ~= W._wdRepWrap then
            local orig = fm.FinishedReporting
            local w = function(uGuid, sAbbrev)
                local ok = pcall(orig, uGuid, sAbbrev)          -- native UI / relation / cleanup
                if W.run and W.run.state == "active" then pcall(reinforceDrop, W.run) end   -- then OUR drop
                return ok
            end
            W._wdRepWrap = w; fm.FinishedReporting = w
            if Loader and Loader.Printf then Loader.Printf("[WaveDef] report hook installed -> copter-drop reinforcements") end
        end
    end
end
-- ===== WAVE ARCHETYPES: each non-boss wave rolls a "flavor" that reshapes what spawns and is announced on the
-- banner. Host-authoritative -- the co-op client just sees the resulting units (native replication + the client
-- blip sweep) and the shared strikes (existing wd_strike channel). Gated by wave number + active factions;
-- NORMAL is the common default. This is the scaffold for adding variety without touching the core spawn loop. =====
local AIRBORNE_TROOP = { ALLIED = "Allied Paratrooper", CHINA = "Chinese Paratrooper" }   -- native chute troopers (ONLY these factions have them)
local AIRBORNE_ALT, AIRBORNE_BARRAGE = 45, 6   -- drop altitude (chute down onto the safe authored point) + softening strikes first
local function airborneTemplate(run)           -- the paratrooper template if an airdrop-capable faction is active, else nil
    for _, f in ipairs(run.factions or {}) do if AIRBORNE_TROOP[f] then return AIRBORNE_TROOP[f] end end
    return nil
end
local function barrageStrike(run)              -- a strike spread across the arena (vs. fireEnemyStrike, which tracks the player)
    local pts, x, y, z = run.spawnPts
    if pts and #pts > 0 then local p = pts[rndInt(#pts)]; x, y, z = p[1], p[2], p[3]
    else local c = run.center; x, y, z = c.x, c.y, c.z end
    x = x + (rnd() - 0.5) * 24; z = z + (rnd() - 0.5) * 24
    warnStrike(x, y, z)                                          -- both machines run the shell/flash (client via wd_strike)
    if ModNet.IsCoop() then ModNet.Send("wd_strike", { x, y, z }) end
end
local function startAirborne(run)              -- saturating barrage, then the paratroopers chute in (they spawn via the normal infantry budget)
    for i = 1, AIRBORNE_BARRAGE do
        if Event and Event.Create then Event.Create(Event.TimerRelative, { 0.35 * i }, function() if W.run == run and run.state == "active" then barrageStrike(run) end end) end
    end
    Loader.Printf("[WaveDef] AIRBORNE ASSAULT inbound (" .. tostring(run.airborne) .. ")")
end
local WAVE_ARCHETYPES = {
    -- id, label (banner text; "" = a silent normal wave), weight, minWave, req(run) optional gate, apply(run) reshape
    { id = "normal",   label = "",                weight = 100 },
    { id = "blitz",    label = "BLITZ",           weight = 16, minWave = 2,
      apply = function(run) run.toSpawn = math.max(6, math.floor(run.toSpawn * 0.6)); run.waveHaste = 1.7 end },   -- fewer but very fast
    { id = "horde",    label = "HORDE",           weight = 12, minWave = 3,
      apply = function(run) run.toSpawn = math.floor(run.toSpawn * 1.7); run.vehToSpawn, run.heliToSpawn = 0, 0 end },   -- swarm (cap + stagger pace it)
    { id = "armor",    label = "ARMORED COLUMN",  weight = 12, minWave = 4, req = function(run) return run.arena ~= nil end,
      apply = function(run) run.vehToSpawn = math.max(run.vehToSpawn, 4) + 2; run.toSpawn = math.max(6, math.floor(run.toSpawn * 0.55)) end },   -- vehicle push
    { id = "siege",    label = "SIEGE",           weight = 10, minWave = 4,
      apply = function(run) run.strikesLeft = math.max(run.strikesLeft or 0, 6); run.toSpawn = math.max(6, math.floor(run.toSpawn * 0.7)) end },   -- continuous shelling
    { id = "airborne", label = "AIRBORNE ASSAULT", weight = 16, minWave = 3, req = function(run) return airborneTemplate(run) ~= nil end,
      apply = function(run) run.airborne = airborneTemplate(run); run.airborneAlt = AIRBORNE_ALT
                            run.vehToSpawn, run.heliToSpawn = 0, 0
                            run.toSpawn = math.max(8, math.floor(run.toSpawn * 0.9)); run.preBarrage = true end },   -- barrage + paratrooper drop (Allied/China)
}
-- the "Special Waves" modifier scales the NORMAL (plain-wave) weight: rare -> more normals, chaos -> 0 normals
-- (every eligible non-boss wave becomes a special archetype). Special weights are untouched.
local ARCH_NORMAL_MUL = { rare = 3, normal = 1, frequent = 0.25, chaos = 0 }
local function pickArchetype(run)              -- weighted roll among the eligible archetypes for this wave
    local nmul = ARCH_NORMAL_MUL[(run.mods and run.mods.mArch) or "normal"] or 1
    local elig, tot = {}, 0
    for _, a in ipairs(WAVE_ARCHETYPES) do
        if run.wave >= (a.minWave or 0) and (not a.req or a.req(run)) then
            local w = (a.id == "normal") and (a.weight * nmul) or a.weight
            if w > 0 then elig[#elig + 1] = { a = a, w = w }; tot = tot + w end   -- 0-weight normal (chaos) drops out
        end
    end
    if tot <= 0 then return nil end            -- nothing eligible (e.g. chaos before any special unlocks) -> plain wave
    local r = rnd() * tot
    for _, e in ipairs(elig) do r = r - e.w; if r <= 0 then return e.a end end
    return elig[#elig].a
end
local VEH_START, HELI_START = 3, 5   -- waves at which enemy vehicles / helis start appearing
local function spawnWave(run)
    local cx, cy, cz = hostPose()
    local arena = run.arena
    local center = arena and { x = arena.center[1], y = arena.center[2], z = arena.center[3] } or (cx and { x = cx, y = cy, z = cz })
    if not center then return end                                -- host not ready; retry next tick
    run.wave = run.wave + 1
    local cfg = run.cfg
    run.center = center
    run.spawnPts = arena and idealPoints(arena.inf, (cx or center.x), (cz or center.z)) or nil
    run.enemies = {}
    run.toSpawn = math.floor(((cfg.baseCount or 12) + (run.wave - 1) * (cfg.perWave or 6)) * (run.mods and run.mods.mSize or 1))
    run.spawned = 0; run.waveKills = 0
    run.airborne, run.airborneAlt, run.preBarrage, run.waveHaste = nil, nil, nil, nil   -- clear last wave's archetype flags
    local vs, hs = early(run, VEH_START), early(run, HELI_START)
    run.vehToSpawn  = (run.wave >= vs) and math.min(1 + math.floor((run.wave - vs) / 2), 8) or 0
    run.heliToSpawn = (run.wave >= hs) and math.min(1 + math.floor((run.wave - hs) / 3), 4) or 0
    run.vehSpawned, run.heliSpawned = 0, 0
    run.strikesLeft = strikeCount(run); run.strikeTick = 0
    run.boss = nil
    local bossEvery = (run.mods and run.mods.mEarly) and 1 or ((run.mods and run.mods.mBoss) and 3 or BOSS_EVERY)
    if run.wave % bossEvery == 0 then spawnBoss(run) end
    local arch                                                    -- WAVE ARCHETYPE (non-boss waves): reshape the spawn + announce it
    if not run.boss then arch = pickArchetype(run); if arch and arch.apply then safe(arch.apply, run) end end
    run.total = run.toSpawn + run.vehToSpawn + run.heliToSpawn; run.left = run.total   -- AFTER the archetype mutates the counts
    if run.preBarrage then startAirborne(run) end                -- airborne: softening strikes now, paratroopers chute in via the budget
    if arch and arch.label ~= "" then toast(">> " .. arch.label) end   -- host-only wave banner
    -- (scripted reinforcement heli retired -- it floated/hovered; native reporting + adoptStrays now handle backup)
    run.state = "active"
    Loader.Printf("[WaveDef] wave " .. run.wave .. " [" .. (arch and arch.id or "normal") .. "]: " .. run.toSpawn .. " inf + " .. run.vehToSpawn .. " veh + " .. run.heliToSpawn .. " heli [" .. tostring(run.factionsLabel) .. "]" .. (run.boss and (" + BOSS " .. run.boss.def.name) or "") .. (run.strikesLeft > 0 and (" + " .. run.strikesLeft .. " strikes") or ""))
end

-- ===== end run: terminal state -> complete/fail the contract (native fanfare) -> clear HUD =====
local function endRun(run, won)
    run.state = won and "won" or "lost"
    if won then awardXP(XP_WIN) end
    clearEnemies(run)                                            -- despawn survivors + pull their blips
    restoreEconomy()                                            -- restore the wallet NOW (beats the death->medevac savegame)
    restoreRelations()                                          -- un-hostile the factions on contract end
    publish(run)
    safe(function() Contract._finish(W.inst or Contract.active, won) end)
    W.inst = nil
    -- linger on the results card; CONTINUE (or this fallback timeout) tears the run down.
    if Event and Event.Create then Event.Create(Event.TimerRelative, { 14 }, function() if W.run == run then W.stop() end end) end
end

-- ===== ready-gate: the authority starts the next wave when both players ready (or the host forces) =====
local function enterShop(run)                                    -- authority: open the intermission before a wave
    run.state = "shop"; W.hostReady = false; W.clientReady = false
    publish(run)
end
local function proceed()                                         -- authority: leave the shop, spawn the wave
    if not ModNet.IsAuthority() then return end
    local run = W.run; if not run or run.state ~= "shop" then return end
    spawnWave(run); publish(run)
end
local function checkProceed()
    if not ModNet.IsAuthority() then return end
    if W.hostReady and (not ModNet.IsCoop() or W.clientReady) then proceed() end
end
ModNet.On("wd_ready", function() if not ModNet.IsAuthority() then return end W.clientReady = true; checkProceed() end)
local function doReady()
    W.iReady = true                                              -- for the local READY label
    if ModNet.IsAuthority() then W.hostReady = true; checkProceed()
    else ModNet.Send("wd_ready", 1) end
end
local function doForce() if ModNet.IsAuthority() then W.hostReady = true; proceed() end end

-- ===== engine tick (authority only) =====
local function engineTick()
    local run = W.run
    if not run or run.state == "won" or run.state == "lost" then return end
    local _, _, _, hch = hostPose()
    if hch then local hp = safe(Object.GetHealth, hch); if hp and hp <= 0 then endRun(run, false); return end end
    if run.state == "shop" then
        -- idle: the wave starts via the ready-gate (doReady / doForce -> proceed). Nothing timed here.
    elseif run.state == "active" then
        if stillSpawning(run) then spawnBatch(run) end            -- pace the wave in (infantry + vehicles + helis)
        W._aggroN = (W._aggroN or 0) + 1
        -- NO periodic re-issue of the Attack goal: re-forcing it every couple seconds RESET each enemy's
        -- pathing and froze them at their spawn. The one-shot Attack goal from spawnOne/spawnVeh is enough.
        if W._aggroN % REGEN_EVERY == 0 then regenPass(run) end   -- heal tanky enemies/boss (regen = the tank mechanic)
        -- (native-reinforcement adoption retired: we now suppress the engine reinforcement + do our own copter-drop)
        updateAcquisition(run)                                    -- Target Acquisition: track how long the player holds still
        if (run.strikesLeft or 0) > 0 then                        -- enemy bombardment: escalating conflict
            run.strikeTick = (run.strikeTick or 0) + 1
            if run.strikeTick >= STRIKE_EVERY then run.strikeTick = 0; run.strikesLeft = run.strikesLeft - 1; fireEnemyStrike(run) end
        end
        if run.mods and run.mods.mShell then                      -- Sustained Shelling: a strike near the player every ~10s
            run.shellTick = (run.shellTick or 0) + 1
            if run.shellTick >= 20 then run.shellTick = 0; fireEnemyStrike(run) end
        end
        local bossAlive = false
        if run.boss then
            local hp = safe(Object.GetHealth, run.boss.u)
            if hp and hp > 0 then
                bossAlive = true; run.boss.tick = run.boss.tick + 1
                local bmx = run.boss.maxHp or safe(Object.GetMaxHealth, run.boss.u) or hp   -- boss HP bar (both machines)
                put("bossName", run.boss.def.name); put("bossHPpct", math.max(0, math.min(100, math.floor(hp / math.max(1, bmx) * 100))))
                local def = run.boss.def
                if def.add and run.boss.tick % (def.addEvery or 3) == 0 then           -- summoner: adds while it lives
                    local bx, by, bz = safe(Object.GetPosition, run.boss.u)
                    local _, _, _, hch3 = hostPose()
                    local p = bx and nearBossPoint(run, bx, bz)                        -- adds spawn at a nearby AUTHORED point
                    if p then                                                          -- (geometry-safe) -- Solano near a wall used
                        spawnOne(run, hch3, p, 800000 + run.boss.tick)                 -- to clip his followers into it
                    elseif bx then                                                     -- no arena points -> old ring-around-boss fallback
                        local ang = run.boss.tick * 2.399963
                        local ax, az = bx + 6 * math.cos(ang), bz + 6 * math.sin(ang)
                        local au = safe(Pg.Spawn, pickUnit(run.pool), ax, by, az)
                        if au then
                            if hch3 then safe(function() Ai.Goal({ AIGuid = au, Goal = "Attack", Target = hch3, Priority = "HiPri", Force = true }) end) end
                            run.enemies[#run.enemies + 1] = { u = au, blip = addEnemyBlip(au, 800000 + run.boss.tick), sx = ax, sy = by, sz = az }
                        end
                    end
                end
            else
                removeEnemyBlip(run.boss.blip); put("bossName", nil)
                local bonus = math.floor(10000 * (W.rewardMult or 1)); run.cash = (run.cash or 0) + bonus
                safe(function() MrxPmc.AddCashQty(bonus) end); if ModNet.IsCoop() then ModNet.Send("wd_reward", bonus) end
                awardXP(300); toast("BOSS DOWN: " .. run.boss.def.name)
                run.boss = nil
            end
        elseif S.bossName then put("bossName", nil) end          -- no boss this wave -> clear the HP bar
        local alive = countAlive(run)
        local unspawned = math.max(0, (run.toSpawn or 0) - (run.spawned or 0)) + math.max(0, (run.vehToSpawn or 0) - (run.vehSpawned or 0)) + math.max(0, (run.heliToSpawn or 0) - (run.heliSpawned or 0))
        run.left = alive + unspawned + (bossAlive and 1 or 0)
        if not stillSpawning(run) and alive <= 0 and not run.boss then   -- wave fully cleared
            local reward = math.floor((1000 * (run.waveKills or 0) + 5000) * (W.rewardMult or 1))
            run.cash = (run.cash or 0) + reward
            safe(function() MrxPmc.AddCashQty(reward) end)       -- pay host player
            if ModNet.IsCoop() then ModNet.Send("wd_reward", reward) end  -- pay the co-op partner
            awardXP(XP_PER_WAVE)
            if run.cfg.mode == "fixed" and run.wave >= (run.cfg.waves or 0) then endRun(run, true); return
            else
                if run.wave > (run.best or 0) then run.best = run.wave; run.newBest = true; saveBest(run.best) end
                enterShop(run)                                   -- -> intermission (ready-gated)
            end
        end
    end
    publish(run)
end

-- ===== intermission BOARD (BOTH machines): buy (cash) + unlock (xp) + READY / FORCE =====
local openBoard, closeBoard, startPlacement          -- forward decls (buyItem + placement cross-reference the board)
local function boardRows()
    local rows = {}
    rows[#rows + 1] = { label = (W.iReady and "READY  -  waiting for the wave..." or ">  READY  -  START NEXT WAVE"), ready = true }
    if ModNet.IsAuthority() and ModNet.IsCoop() then rows[#rows + 1] = { label = ">> FORCE NEXT WAVE (host)", force = true } end
    if not S.noStore then
    rows[#rows + 1] = { header = "BUY   (CASH " .. fmtCash() .. ")" }
    for _, cat in ipairs(CAT_ORDER) do
        for _, it in ipairs(CATALOG) do
            if it.cat == cat and isUnlocked(it) then rows[#rows + 1] = { label = it.name .. "   " .. fmtCash(it.cost), buy = it } end
        end
    end
    local hdr = false
    for _, cat in ipairs(CAT_ORDER) do
        for _, it in ipairs(CATALOG) do
            if it.cat == cat and (it.xp or 0) > 0 then
                if not hdr then rows[#rows + 1] = { header = "UNLOCK   (XP: " .. getXP() .. ")" }; hdr = true end
                rows[#rows + 1] = { label = it.name .. "   [" .. (isUnlocked(it) and "OWNED" or (it.xp .. " XP")) .. "]", unlock = it }
            end
        end
    end
    end   -- store hidden by the "No Store" modifier
    return rows
end
local function boardDetail(row)
    if not row then return { category = "INTERMISSION", rewards = { "Ready up to start the wave" } } end
    if row.ready then return { category = "READY", rewards = { "Start the next wave" }, objectives = { "Waits for BOTH players", "(host can FORCE)" } } end
    if row.force then return { category = "HOST", rewards = { "Start now" }, objectives = { "Skip waiting for the partner" } } end
    local o = row.buy or row.unlock; if not o then return { category = "INTERMISSION" } end
    local body = (UI.wrap and UI.wrap(o.desc, 34)) or { o.desc }
    if row.buy then
        local cash = getCash(); local aff = cash >= o.cost and "AFFORDABLE" or ("NEED " .. fmtCash(o.cost - cash))
        return { category = o.cat .. "  (BUY)", rewards = { "COST  " .. fmtCash(o.cost), aff }, objectives = body }
    end
    return { category = o.cat .. "  (UNLOCK)", rewards = { isUnlocked(o) and "OWNED" or ("COST  " .. o.xp .. " XP") }, objectives = body }
end
local function boardRefresh()
    if not W.board then return end
    W.board:items(boardRows())
    W.board:hint("O/L move   K select   J ready    CASH " .. fmtCash())
    local s = W.board:selected(); if s then W.board:detail(boardDetail(s)) end
end
local PLACEABLE = { VEHICLE = true, EMPLACEMENT = true, PROP = true }
local function buyItem(o)
    if getCash() < (o.cost or 0) then toast("NOT ENOUGH CASH (" .. fmtCash(o.cost) .. ")"); return end
    addCash(-(o.cost or 0))
    if PLACEABLE[o.cat] then startPlacement(o)                   -- close menu -> walk -> ENTER drops it at your feet
    else safe(o.effect, buyerCtx()); toast("BOUGHT " .. o.name) end
end
local function unlockItem(o)
    if isUnlocked(o) then toast(o.name .. " already unlocked"); return end
    if spendXP(o.xp) then doUnlock(o); toast("UNLOCKED " .. o.name) else toast("NEED " .. (o.xp - getXP()) .. " MORE XP") end
end
local function boardChoose(row)
    if not row then return end
    if row.ready then doReady()
    elseif row.force then doForce()
    elseif row.buy then buyItem(row.buy)
    elseif row.unlock then unlockItem(row.unlock) end
    boardRefresh()
end
openBoard = function()
    if W.board then safe(function() W.board:destroy() end); W.board = nil end
    W.board = UI.Board{
        title    = "WAVE DEFENSE  -  INTERMISSION",
        hint     = "O/L move   K select   J ready    CASH " .. fmtCash(),
        items    = boardRows(),
        onSelect = function(row) if W.board then W.board:detail(boardDetail(row)) end end,
        onChoose = function(row) boardChoose(row) end,
        onBack   = function() doReady(); boardRefresh() end,     -- J = "I'm ready"
    }
    safe(function() W.board:focus() end)
    local s = W.board and W.board:selected(); if s then W.board:detail(boardDetail(s)) end
end
closeBoard = function() if W.board then safe(function() W.board:destroy() end); W.board = nil end end
local function setBoard(open)
    if W._suppressBoard then return end                          -- held closed during placement mode
    if open and not W._boardShown then W._boardShown = true; W.iReady = false; openBoard()
    elseif (not open) and W._boardShown then W._boardShown = false; closeBoard() end
end

-- ===== placement mode: buy a placeable -> close menu -> walk -> ENTER drops it at your feet -> reopen =====
local PLACE_RGB = { 80, 220, 120 }
local function placeCtx() local c = buyerCtx(); c.fx, c.fz = c.x or c.fx, c.z or c.fz; return c end   -- at feet
local function ghostOn()
    local ch = safe(UI.hero) or safe(Player and Player.GetLocalCharacter)
    if W._ghost then pcall(Marker.Remove, W._ghost); W._ghost = nil end
    if ch then local ok, d = pcall(Marker.AddDisc, ch, 3, PLACE_RGB[1], PLACE_RGB[2], PLACE_RGB[3], 0.35); if ok then W._ghost = d end end
end
local function endPlacement()
    if W._ghost then pcall(Marker.Remove, W._ghost); W._ghost = nil end
    if W.placePanel then safe(function() W.placePanel:destroy() end); W.placePanel = nil end
    W.placing = nil; W._suppressBoard = false; W.placeGen = (W.placeGen or 0) + 1
    openBoard(); W._boardShown = true                            -- reopen the intermission
end
local function doPlace()  local o = W.placing; if o then safe(o.effect, placeCtx()); toast("PLACED " .. o.name) end; endPlacement() end
local function doCancel() local o = W.placing; if o then addCash(o.cost or 0); toast("CANCELLED (refunded)") end; endPlacement() end
local function placeTick(gen)
    if W.placeGen ~= gen or not W.placing then return end
    if S.state ~= "shop" then endPlacement(); return end          -- wave started mid-placement -> abort
    local ks = Loader.GetKeyboardState and Loader.GetKeyboardState()
    local function down(vk) return ks and (string.byte(ks, vk + 1) or 0) >= 128 end
    local e, b = down(0x0D), down(0x08)                           -- Enter = place, Backspace = cancel
    if e and not W._pE then W._pE = true; doPlace(); return end
    if not e then W._pE = false end
    if b and not W._pB then W._pB = true; doCancel(); return end
    if not b then W._pB = false end
    W._ghostN = (W._ghostN or 0) + 1
    if W._ghostN % 8 == 0 then ghostOn() end                      -- re-snapshot the foot ring ~0.5s
    Event.Create(Event.TimerRelative, { 0.06 }, function() placeTick(gen) end)
end
startPlacement = function(o)
    W.placing = o; W._suppressBoard = true
    W._boardShown = false; closeBoard()
    ghostOn()
    W.placePanel = UI.Panel{ x = 224, y = 8, w = 250, title = "PLACING" }
    safe(function() W.placePanel:line(0, o.name); W.placePanel:line(1, "MOVE to position"); W.placePanel:line(2, "ENTER = place"); W.placePanel:line(3, "BACKSPACE = cancel"); W.placePanel:show() end)
    W._pE, W._pB = true, true                                     -- ignore the buy keypress still held down
    W.placeGen = (W.placeGen or 0) + 1
    local g = W.placeGen; Event.Create(Event.TimerRelative, { 0.06 }, function() placeTick(g) end)
end

-- ===== results screen (BOTH machines): a win/fail summary card when a run ends =====
-- Rendered off the same big board movie as the intermission, so a finished run reads as a "mission
-- complete" screen. It reads the SYNCED run stats (S.*) plus this machine's own per-run XP/clock, so the
-- host and the co-op partner show the same card. On the authority, CONTINUE ends the run for BOTH (W.stop
-- nils the shared state -> both cards close); on the client, CONTINUE just closes its own card (a local
-- guard stops the still-terminal shared state from re-opening it).
local openResults, closeResults, resultsContinue
local function fmtTime(s)
    if UI.fmt_time then local ok, r = pcall(UI.fmt_time, s); if ok and type(r) == "string" then return r end end
    s = math.max(0, math.floor(tonumber(s) or 0)); return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
local function runXPStr() local n = W.runXP or 0; return UI.comma and UI.comma(n) or tostring(n) end
local function resultsSummary(won)                              -- the detail pane (outcome banner + headline numbers)
    local cfg = S.cfg or {}; local mode = cfg.mode or "endless"; local wave = S.wave or 0
    local rmx = (S.rewardPct and S.rewardPct / 100) or (W.rewardMult or 1)
    local obj = {}
    obj[#obj + 1] = "Mode:  " .. (mode == "fixed" and ("Fixed " .. (cfg.waves or "?") .. " waves") or "Endless")
    if S.factions and S.factions ~= "" then obj[#obj + 1] = "Factions:  " .. tostring(S.factions) end
    obj[#obj + 1] = "Difficulty reward:  x" .. string.format("%.2f", rmx)
    obj[#obj + 1] = " "
    obj[#obj + 1] = won and "The arena holds. Outstanding work." or "The line broke. Regroup and retry."
    return {
        category = won and "VICTORY" or "DEFEATED",
        rewards = {
            "WAVE " .. wave .. (mode == "fixed" and ("  /  " .. (cfg.waves or "?")) or ""),
            (S.kills or 0) .. "  KILLS",
            "+" .. runXPStr() .. "  XP",
            fmtCash(S.cash or 0) .. "  EARNED",
        },
        objectives = obj,
        progress = (mode == "fixed" and (cfg.waves or 0) > 0) and math.min(1, wave / cfg.waves) or (won and 1 or 0),
        progressText = won and "COMPLETE" or "OVERRUN",
    }
end
local function resultsRows(won)                                 -- the scoreboard list (CONTINUE is the only selectable row)
    local cfg = S.cfg or {}; local mode = cfg.mode or "endless"
    local rows = { { header = won and "VICTORY  -  SUMMARY" or "DEFEATED  -  SUMMARY" } }
    rows[#rows + 1] = { label = "Waves " .. (mode == "fixed" and "cleared" or "reached") .. ":    " .. (S.wave or 0) }
    rows[#rows + 1] = { label = "Kills:    " .. (S.kills or 0) }
    rows[#rows + 1] = { label = "Cash earned:    " .. fmtCash(S.cash or 0) }
    rows[#rows + 1] = { label = "XP gained:    " .. runXPStr() }
    rows[#rows + 1] = { label = "Time survived:    " .. fmtTime(rtime() - (W.runStartT or rtime())) }
    if mode ~= "fixed" then
        rows[#rows + 1] = { header = "ENDLESS" }
        rows[#rows + 1] = { label = "Best wave:    " .. (S.best or 0) .. (S.newBest and "     -  NEW BEST!" or "") }
    end
    rows[#rows + 1] = { header = " " }
    rows[#rows + 1] = { label = ">  CONTINUE", cont = true }
    return rows
end
openResults = function(won)
    if W.results then safe(function() W.results:destroy() end); W.results = nil end
    W.results = UI.Board{
        title    = "WAVE DEFENSE  -  " .. (won and "VICTORY" or "DEFEATED"),
        hint     = "K / J   -   continue",
        items    = resultsRows(won),
        detail   = resultsSummary(won),
        onSelect = function() if W.results then W.results:detail(resultsSummary(won)) end end,
        onChoose = function(row) if row and row.cont then resultsContinue() end end,
        onBack   = function() resultsContinue() end,
    }
    safe(function() W.results:focus() end)
end
closeResults = function() if W.results then safe(function() W.results:destroy() end); W.results = nil end end
resultsContinue = function()
    if ModNet.IsAuthority() then W.stop()                        -- ends the run for both machines (shared state -> nil)
    else W._resultsDismissed = true; closeResults() end          -- client: close locally; guard blocks a resync reopen
end
local function setResults(show, won)
    if show and not W._resultsShown and not W._resultsDismissed then
        W._resultsShown = true; openResults(won)
    elseif (not show) and W._resultsShown then
        W._resultsShown = false; closeResults()
    end
end

-- ===== HUD (BOTH machines) -- pure read of the synced state =====
local STATE_TXT = { shop = "INTERMISSION", active = "FIGHT!", won = "VICTORY", lost = "DEFEATED" }
local function updateHud()
    local state = S.state
    if state and not W._runInit then W._runInit = true; isolateSupports()          -- once per run (both machines): wipe outside supports
        W.savedCash = getCash()                                                    -- ISOLATE the economy: bank the campaign wallet,
        safe(function() Loader.SaveVar("WaveDef_savedCash", W.savedCash) end)       -- persist it for crash-recovery,
        addCash(-(W.savedCash or 0)); if S.rich then addCash(25000) end             -- and start the run at $0 (+25k if Rich Start)
        W._lastHP = nil
        W.runXP = 0; W.runStartT = rtime()                                         -- per-run stats for the results card
        W._resultsShown = false; W._resultsDismissed = false
        W._lastWaveSeen = 0                                                         -- for the wave-incoming banner
    end
    if not state then
        W._runInit = false
        restoreEconomy()                                                            -- fallback wallet restore (idempotent)
        setBoard(false); setResults(false); clearDrops(); restoreSupports()    -- restore the player's own supports
        W._resultsDismissed = false
        if W.panel then W.panel:hide() end
        if W.bar then W.bar:hide() end; if W.bossBar then W.bossBar:hide() end
        return
    end
    setBoard(state == "shop")
    if state == "shop" then                                     -- the intermission board owns the corner: hide the wave panel
        if W.panel then W.panel:hide() end
        if W.bar then W.bar:hide() end; if W.bossBar then W.bossBar:hide() end
        return
    end
    if state == "won" or state == "lost" then                   -- terminal: the results card owns the screen
        restoreEconomy()                                        -- BOTH machines: wallet back the instant the run ends (pre-medevac)
        if W.panel then W.panel:hide() end
        if W.bar then W.bar:hide() end; if W.bossBar then W.bossBar:hide() end
        setResults(true, state == "won")
        return
    end
    if S.wave and S.wave ~= W._lastWaveSeen then                -- wave-incoming banner (both machines; no extra ModNet traffic)
        W._lastWaveSeen = S.wave
        if (S.wave or 0) > 0 then toast("-  WAVE " .. S.wave .. "  INCOMING  -") end
    end
    if S.glass then                                             -- Glass Cannon: amplify damage taken (~2x) via HP-delta polling
        local ch = Player.GetLocalCharacter()
        if ch then local cur = safe(Object.GetHealth, ch)
            if cur and W._lastHP and cur < W._lastHP then safe(function() Object.SetHealth(ch, math.max(1, cur - (W._lastHP - cur))) end) end
            W._lastHP = safe(Object.GetHealth, ch)
        end
    end
    if not W.panel then W.panel = UI.Panel{ x = 8, y = 8, w = 210, title = "WAVE DEFENSE" } end
    if not W.bar   then W.bar   = UI.Bar{ x = 8, y = 130, w = 210, label = "" } end
    local wave, left, total = S.wave or 0, S.enemiesLeft or 0, S.enemiesTotal or 0
    local cfg = S.cfg or {}
    if cfg.mode == "fixed" then W.panel:line(0, "Wave " .. wave .. " / " .. (cfg.waves or "?"))
    else W.panel:line(0, "Wave " .. wave .. "     Best " .. (S.best or 0)) end
    W.panel:line(1, "Enemies " .. left .. " / " .. total)
    W.panel:line(2, "Kills " .. (S.kills or 0) .. "     " .. fmtCash(S.cash or 0))
    W.panel:line(3, STATE_TXT[state] or tostring(state))
    W.panel:show()
    local frac = (total > 0) and ((total - left) / total) or 0
    W.bar:set(frac); W.bar:label((state == "shop") and "Ready up" or ("Cleared " .. math.floor(frac * 100) .. "%")); W.bar:show()
    if S.bossName then                                          -- boss HP bar (top, right of the panel) while a boss is alive
        if not W.bossBar then W.bossBar = UI.Bar{ x = 224, y = 8, w = 250, label = "" } end
        W.bossBar:set((S.bossHPpct or 100) / 100); W.bossBar:label("BOSS  -  " .. tostring(S.bossName)); W.bossBar:show()
    elseif W.bossBar then W.bossBar:hide() end
end

-- ===== lifecycle (authority sets up the run; client just displays synced state) =====
function W.begin(cfg)
    if not ModNet.IsAuthority() then return end
    cfg = cfg or defaultCfg()
    W.mods = W.loadMods()                                         -- refresh the modifiers + derive the reward multiplier
    W.rewardMult = modRewardMult(W.mods)
    local arena = (cfg.arena and cfg.arena ~= "none") and ARENAS[cfg.arena] or nil
    local n = W.mods.mAll and #FACTION_ORDER or (tonumber(cfg.factions) or 1)   -- Force-All overrides the combo
    if n < 1 then n = 1 elseif n > #FACTION_ORDER then n = #FACTION_ORDER end
    local active = {}; for i = 1, n do active[i] = FACTION_ORDER[i] end
    setupRelations(active)                                        -- all active factions hostile to Pmc, friendly to each other
    W.run = { cfg = cfg, arena = arena, mods = W.mods, wave = 0, state = "shop", enemies = {}, total = 0, left = 0,
              kills = 0, cash = 0, waveKills = 0, best = loadBest(), newBest = false,
              factions = active, factionsLabel = table.concat(active, "+"),
              pool = buildPool(active, "inf"), vehPool = buildPool(active, "veh"), heliPool = buildPool(active, "heli"),
              toSpawn = 0, spawned = 0, vehToSpawn = 0, vehSpawned = 0, heliToSpawn = 0, heliSpawned = 0, boss = nil }
    W.hostReady, W.clientReady, W.iReady = false, false, false
    clearDrops()
    put("noStore", W.mods.mStore and true or false)              -- both machines: hide the store rows
    put("glass", W.mods.mGlass and true or false)                -- both machines: glass cannon (2x damage taken)
    put("rich", W.mods.mRich and true or false)                  -- both machines: +$25k at run start (isolated economy)
    S.cfg = cfg
    publish(W.run)
    Loader.Printf("[WaveDef] begin: " .. tostring(cfg.mode) .. ", " .. n .. " faction(s), rewardMult x" .. string.format("%.2f", W.rewardMult) .. ", arena " .. tostring(cfg.arena))
end
function W.stop()
    if not ModNet.IsAuthority() then return end
    if W.run then clearEnemies(W.run) end
    clearDrops(); restoreRelations(); restoreEconomy()          -- fallbacks (idempotent) if endRun was skipped -- BEFORE W.run=nil
    W.run = nil; put("state", nil)                              -- clears the save-suppression guard
    Loader.Printf("[WaveDef] stop")
end

-- ===== heartbeat (BOTH machines; gen-guarded so a reload doesn't stack) =====
-- CLIENT-side enemy blips: the host's blips anchor to HOST guids that don't resolve on the client (and the
-- Net.IsServer()-gated radar netsync doesn't reach us in this co-op). Native enemies blip because EACH
-- machine blips its OWN local copy of the networked unit -- so the CLIENT sweeps for hostile humans near
-- itself and blips them with ITS OWN guids. Host/SP already blip via addEnemyBlip; this runs on the client.
W.cblips = W.cblips or {}
local function clientClearBlips()
    for _, nm in pairs(W.cblips) do
        pcall(function() Hud.Radar:RemoveObjective({ sName = nm, bDontNetSync = true }) end)
        pcall(function() Pda.Map:RemoveBlip({ sName = nm }) end)
    end
    W.cblips = {}
end
local function clientBlipSweep()
    if ModNet.IsAuthority() then return end                     -- host/SP already blip locally in addEnemyBlip
    if not S.state then if next(W.cblips) then clientClearBlips() end return end   -- run ended -> pull all
    local ch = Player.GetLocalCharacter(); if not ch then return end
    local px, py, pz = safe(Object.GetPosition, ch); if not px then return end
    local seen = {}
    for f in string.gmatch(S.factions or "", "[^+]+") do
        local tag = COLLECT_TAG[f]
        local list = tag and safe(function() return Pg.FastCollectHumans(px, py, pz, 130, tag .. " && Human") end)
        if type(list) == "table" then
            for _, u in ipairs(list) do
                seen[u] = true
                if not W.cblips[u] then
                    local nm = "wd_cb" .. tostring(u)
                    pcall(function() Hud.Radar:AddObjective({ sName = nm, uGuid = u, sTexture = "objective_action", nR = ENEMY_RGB[1], nG = ENEMY_RGB[2], nB = ENEMY_RGB[3], nWidth = 10.666667, nHeight = 10.666667, nSortOrder = 5, bDontNetSync = true }) end)
                    pcall(function() Pda.Map:AddBlip({ sName = nm, uGuid = u, sTexture = "icon_yellow_mc", nSortOrder = 2 }) end)
                    W.cblips[u] = nm
                end
            end
        end
    end
    for u, nm in pairs(W.cblips) do                             -- drop blips for units no longer around
        if not seen[u] then
            pcall(function() Hud.Radar:RemoveObjective({ sName = nm, bDontNetSync = true }) end)
            pcall(function() Pda.Map:RemoveBlip({ sName = nm }) end)
            W.cblips[u] = nil
        end
    end
end
local function loop(gen)
    if W.gen ~= gen then return end
    if ModNet.IsAuthority() then pcall(engineTick) end
    pcall(pollDrops)                                             -- both machines: collect drops near the local player
    pcall(updateHud)
    if not ModNet.IsAuthority() then                            -- client re-blips enemies near itself ~every 1s
        W._cbN = (W._cbN or 0) + 1
        if W._cbN % 2 == 0 then pcall(clientBlipSweep) end
    end
    Event.Create(Event.TimerRelative, { TICK }, function() loop(gen) end)
end
W.gen = (W.gen or 0) + 1
do local g = W.gen; Event.Create(Event.TimerRelative, { TICK }, function() loop(g) end) end

-- ===== setup UI (config; opened on accept for a seamless accept -> configure -> start) =====
local function cyclerEntry(m, item)
    m:entry(function() return item.label .. ":  " .. tostring(W.cfg[item.key]) end,
        function(_)
            local cur, idx = W.cfg[item.key], 1
            for i, x in ipairs(item.values) do if x == cur then idx = i; break end end
            local nv = item.values[(idx % #item.values) + 1]
            W.cfg[item.key] = nv; W.saveVal(item.key, nv)
        end)
end
W.cfg = W.loadCfg()
W.mods = W.loadMods()
-- a modifier menu entry: toggle, or cycle through the values, saving immediately (mirrors cyclerEntry).
local function modEntry(m, mod)
    if mod.kind == "toggle" then
        m:entry(function() return mod.label .. ":  " .. (W.mods[mod.key] and "ON" or "OFF") end,
            function(_) W.mods[mod.key] = not W.mods[mod.key]; W.saveVal(mod.key, W.mods[mod.key]) end)
    else
        m:entry(function() return mod.label .. ":  " .. ((mod.kind == "mult") and ("x" .. tostring(W.mods[mod.key])) or tostring(W.mods[mod.key])) end,
            function(_)
                local cur, idx = W.mods[mod.key], 1
                for i, x in ipairs(mod.vals) do if x == cur then idx = i; break end end
                local nv = mod.vals[(idx % #mod.vals) + 1]; W.mods[mod.key] = nv; W.saveVal(mod.key, nv)
            end)
    end
end
W.menu = UI.Menu{ title = "WAVE DEFENSE SETUP" }
W.menu:header("OPTIONS")
for _, item in ipairs(W.CONFIG) do cyclerEntry(W.menu, item) end
W.menu:category("MODIFIERS  (difficulty + rewards) >", function(c)
    c:entry(function() return "REWARD MULTIPLIER:  x" .. string.format("%.2f", modRewardMult(W.mods)) end,
        function(ctx) ctx:hint("Harder levers earn more XP/cash; assists earn less") end)
    for _, mod in ipairs(W.MODIFIERS) do modEntry(c, mod) end
    c:entry("Reset modifiers", function(ctx)
        for _, mod in ipairs(W.MODIFIERS) do local d; if mod.kind == "toggle" then d = false else d = mod.vals[2] end; W.mods[mod.key] = d; W.saveVal(mod.key, d) end
        ctx:hint("Modifiers reset")
    end)
end)
W.menu:header("LAUNCH")
W.menu:entry("START WAVE DEFENSE", function(ctx) ctx:close(); W.begin(W.cfg) end)
W.menu:entry("Reset to defaults", function(ctx)
    for _, c in ipairs(W.CONFIG) do W.cfg[c.key] = c.default; W.saveVal(c.key, c.default) end
    ctx:hint("Reset to defaults")
end)
function W.openSetup()
    if not ModNet.IsAuthority() then return end
    W.cfg = W.loadCfg(); W.mods = W.loadMods()
    if Event and Event.Create then Event.Create(Event.TimerRelative, { 0.2 }, function() if W.menu then W.menu:open() end end)
    elseif W.menu then W.menu:open() end
end

-- ===== the contract = the launcher =====
Contract.Register{
    id = "wavedef", title = "Wave Defense",
    desc = "Hold a fortified arena against escalating enemy waves. Buy and upgrade between waves.",
    hideTracker = true,
    start = { { x = ARENAS.arena_a.center[1], y = ARENAS.arena_a.center[2], z = ARENAS.arena_a.center[3] },
              { x = ARENAS.arena_a.center[1] + 5, y = ARENAS.arena_a.center[2], z = ARENAS.arena_a.center[3] + 5 } },
    onBegin = function(inst) W.inst = inst; W.openSetup() end,
    objectives = { Contract.Survive{ desc = "Survive the waves", time = 3600 } },
}

Loader.Printf("[WaveDef] ready (engine + store + arena, one file). Accept 'Wave Defense' on the F5 board.")
