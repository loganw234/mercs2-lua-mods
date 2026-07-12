# Wave Defense — Feature Roadmap & Design Spec

A featured-quality, replayable co-op wave-defense mode for Mercenaries 2, leaning hard on the
game's native systems (economy, support call-ins, factions, vehicles, fanfare) with a
two-currency progression loop.

## Status (2026-07-11, end of session)

Nearly all systems M0-M9 are BUILT in one file (`WaveDefense.lua`, ~62KB, staged to the game).

- **Confirmed in-engine:** co-op connect (ModNet v1.2), base loop, drops, minimap blips, AI aggression,
  mixed-faction waves, airstrike->bombingrun.
- **Staged, NOT yet tested:** vehicle/heli waves, enemy airstrikes on the arena, the modifiers system,
  isolated run economy, regen-based tanky enemies/bosses, glass-cannon damage-amp, placement mode,
  the win/fail results card, and the 2026-07-11 CONTENT SWEEP (physical supply-crate drops, expanded
  store catalog, killstreak reward, boss HP bar, wave-incoming banner, physical-prop cover, +2 bosses,
  roster additions).
- **Shelved wall:** support auto-equip to quick-slots (Pda/PdaInterface unreachable from OnLoad). New
  untried lead: `MrxSupportManager.CurrentlyEquippedSupport:AddSupport(oSupport)`.
- **Engine facts learned:** no `Object.SetMaxHealth` (tanky = regen); `math.random` dead (Park-Miller rnd);
  airstrike key = `bombingrun`; faction abbrevs Vza/Gur/Chi/All/Oil/Pir; **`Cover (X)` templates are AI
  cover-hint markers, not physical props -- use `_global_sandbags…/barricade…/concretebarrier…/explosivebarrel`.**
- **Remaining (M9 polish):** local leaderboard, board art, wiki page; balance tuning; equip wall.

## Design pillars (locked)

- **Host-authoritative co-op.** Host runs the sim; partner = display + receives host-applied
  effects/supplies. (Done: ModNet marker fix + ready-gate + late-join reconcile.)
- **Two currencies.**
  - **XP** — persistent, **per-player** (each machine SaveVars its own; cheatable-OK). Spent in an
    **unlock tree** (`UI.Menu`) to *permanently* unlock content. Earned from kills/waves/wins.
  - **Cash** — in-match, native `MrxPmc` economy. Spent in the **store** to *buy* already-unlocked
    content during a match.
- **Native-first where clean.** Native cash (`MrxPmc.GetCashQty`/`AddCashQty`), support delivery
  (`AddSupportQty` -> the native 3-slot quick-call support menu), factions, vehicles, fanfare.
  Our own uilib UI where the native UI has baggage.
- **Arenas.** Fight in authored locations with known spawn-in points (reuse native outpost /
  landing-zone coords + ForgeCam/MissionForge authoring).
- **Juice.** Enemy drops, killstreak call-ins, VO/music/banners.

## Core loop

Accept contract -> pick arena + config -> waves spawn from the arena's directional points ->
kill for **cash + XP** -> between waves spend **cash** in the store on **unlocked** items
(supports / vehicles / emplacements / props / upgrades) and grab enemy **drops** mid-fight ->
survive N (fixed) or endless (high score) -> win/fail -> fanfare -> bank XP + best -> replay.
Between matches: spend **XP** in the unlock tree.

## Co-op economy model

- **Authority rule (KEY):** the client can run scripts and spawn/apply almost everything **locally** -
  props, empty vehicles, static emplacements, player buffs, effects, drops, cash. The **only**
  host-authoritative action is **spawning AI units** (enemies, AI-crewed vehicles/turrets, allied
  reinforcement soldiers). Keep ModNet on the critical path *only* for AI-unit spawns.
- **Cash**: awarded to both (host applies locally + broadcasts; joiner receives via ModNet). Each
  spends their own.
- **XP**: host counts kills/waves and signals "xp gained" to both; **each machine banks its own XP
  total to its own SaveVar**. Both progress independently.
- **Unlocks / store catalog**: per-machine-local (each player sees their own unlocked items + own cash).
- **Purchase effects run LOCALLY on the buyer's machine** (client or host), no round-trip - EXCEPT
  purchases that spawn **AI units** (reinforcements, AI-crewed emplacements), which send a request to
  the host to spawn. Cash debit is always local to the buyer.

## Store UI decision

Build on **uilib `UI.Board`** (list + detail pane = a natural shop) for control + co-op safety.
Native `MrxGuiSupportShop` is populatable (`Create`->`AddItemFull`->`SetCallback`->`Commence`) but
injects the player's equipped-support rows and has co-op sync + a HUD-hide bug. **Stretch:** swap in
the native `store` movie once a spike proves it's clean, if we want the exact native look.

---

## Milestones (the task list)

### M0 - Foundation (DONE)
- [x] Contract entry -> configure -> waves -> kills/cash -> win/fail -> replay (SP)
- [x] Co-op: host-auth sim, both-machine HUD, cash to both, ModNet ready-gate + late-join sync
- [x] Per-field SaveVar config, endless best score

### M1 - Arenas
- [x] Arena schema: `{x,y,z,radius}` spawn points, radius-tiered (<=5 inf / <=15 veh / >15 heli) + center
- [ ] Reuse native outpost / landing-zone coords as ready-made arenas (dump via existing tools)
- [x] MissionForge **ARENA branch** (Arena Center / Enemy Spawn Point / Defend Target) -> exports
      `arena = { center, spawns, defend }` inside MISSIONFORGE_EXPORT (2026-07-11)
- [x] Directional spawns: `spawnWave` cycles the arena's infantry points (golden-angle spread), not a ring
- [~] Authored: 1 (`arena_a`, 61 points, embedded); in-engine test pending; want 2-3 for launch
- [x] Arena select in config UI (`cfg.arena` = arena_a / none-ring)
- [ ] (opt) Defense-target object to protect; (opt) destructible hazards; (opt) soft arena leash

### M2 - Economy & XP
- [ ] Cash reward tuning (per kill, per wave-clear) via `MrxPmc.AddCashQty`
- [x] XP earn (kill 10 / wave 100 / win 500), per-machine SaveVar (`WaveDef_xp`), cheatable-OK
- [ ] XP + cash HUD readout (XP total shown in the tree for now; per-run HUD line = TODO)
- [x] Unlock storage: per-item flags via SaveVar (`WaveDef_unlock_<id>` = bool) [in WaveDefStore]
- [x] Co-op XP signal (`wd_xp`: host banks + signals; partner banks its own copy)

### M3 - Unlock tree (UI.Menu, out of match)
- [x] Tree UI: categories (only xp>0 items appear) -- `WaveDefStore.openTree()`
- [x] Each node shows XP cost + OWNED/locked; buy -> spend XP -> set unlock flag (dynamic labels)
- [x] Per-player (each machine's own XP + unlocks via SaveVar)
- [x] Surface it: folded into the between-wave INTERMISSION board (F8 + separate file removed) -- see M4

### M4 - Intermission (UI.Board, replaces timed prep)  [merged into WaveDefense.lua -- 1 file]
- [x] `UI.Board` intermission: BUY (cash, unlocked) + UNLOCK (xp) + READY row + host FORCE, detail pane
- [x] Purchase: `GetCashQty` gate -> `AddCashQty(-cost)` -> local effect
- [x] Auto-opens after every wave (and before wave 1); closes on wave spawn (both machines)
- [x] **Ready-gate**: wave starts when both ready (`wd_ready`) or host FORCE -- replaces the timer
- [x] Co-op: effects run LOCALLY on the buyer (authority rule); only AI spawns would host-route
- [x] Placement mode: placeable buys close the menu -> walk -> ENTER drop-at-feet -> reopen (ghost ring)
- [~] Support -> quick-select menu via `Hud.SupportMenu:AddItem{sName,sIcon,oSupport}` + `:RemoveItem` (the
      real freebie/PDA-equip API; `grantSupport` add-once tracked in `W._equipped`, pulled at run end) -- staged, untested

### M5 - Catalog (unlockable + purchasable content)
Each entry: `{ id, name, desc, xpCost, cashCost, category, unlock(), effect(ctx), icon }`
- [x] Supports: RPG resupply + 11 airstrikes (bombingrun..moab) -> native `AddSupportQty` (real keys)
- [x] Vehicles: softtop / armed HMMWV / LAVIII (Minigun) / M2A3 / M1A2 -> `Pg.Spawn` empty at feet
- [x] Emplacements: MG3 / GL / recoilless rifle / TOW (placeable)
- [x] Props: physical `_global_` sandbag / barricade / concrete / explosive-barrel (placeable)
- [~] Player upgrades: full-heal + 10s/25s invuln [max-health / revive / speed / multipliers still TODO]
- [x] Data-driven catalog table (single source; drives both the unlock tree and the store)

### M6 - Enemy drops
- [x] On enemy death: weighted chance (12%) to spawn a colored beacon at the death spot
- [x] Marker visual: colored `Marker.AddDisc`+blip on a TinyGeometry anchor (not native pickups)
- [x] Walk-over collect (`pollDrops`, DROP_R=6, both machines) -> apply effect
- [x] Color -> effect table: airstrike / artillery / 20s invincible / cash / nuke (weighted)
- [x] Co-op: host-auth spawn + `wd_drop` replicate; collect local + `wd_dropget` removes on both
- [x] Physical supply-crate drops: `Supply Drop (X)` / pickup props (weighted, rare = Treasure/Blueprints),
      `wd_crate` replicate, `MAX_LIVE_CRATES`=40 cap + run-end cleanup; `CRATE_SHARE`=60% of all drops
- [~] Tuning: added full-heal + carpet-bomb beacons + crates + rate 12->15%; wave-scaled rate still TODO

### M7 - Enemy & wave variety
- [x] Findability: per-enemy minimap blips + `Ai.SetHaste(1.6)` + ideal-distance spawns + re-aggro
- [x] Weighted per-faction ROSTERS (from the MissionForge catalog); `buildPool`/`pickUnit`
- [x] Elite/special units in the mix (weighted: soldiers common, heavies/snipers/elites rarer)
- [x] **Mixed-faction** waves (config `factions`=1-6): all hostile to Pmc + friendly to each other (`setupRelations`)
- [x] Boss waves (every 5): 7-entry `BOSSES` table (incl. **Solano** hp6 tanky-summoner + VZ Union Boss),
      tanky via regen, SUMMONER adds, **boss HP bar** on the HUD
- [x] Bigger + PACED waves (dozens; `SPAWN_BATCH`=6/tick, kill-count in `onEnemyDied`)
- [~] Vehicle/heli waves (arena veh/heli tiers wired: `spawnVeh`, VEH_START=3/HELI_START=5) -- staged, untested
- [ ] Custom boss weapons (no script `GiveWeapon` found) + per-unit weight tuning pass

### M8 - Native support & juice
- [x] Killstreak (every 25 kills) -> free random support grant for BOTH players (`wd_streak`)
- [x] Wave banners ("WAVE N INCOMING") via toast on `S.wave` change; boss intro toast; **boss HP bar** (top `UI.Bar`)
- [ ] VO / music / vfx cues (reuse contract framework `say`/music/vfx)
- [x] Results summary on win/fail (waves, kills, cash earned, XP gained, time, best + NEW BEST) on the
      board movie, both machines, CONTINUE-to-dismiss + 14s fallback + native fanfare

### M9 - Modes, meta, release polish
- [ ] Modes: fixed-N (win) / endless (high score) [done] + difficulty modifiers (2x enemies,
      no-store, iron-man) as XP/score multipliers
- [ ] Per-arena/config best + local leaderboard (SaveVar)
- [ ] Board entry with arena/config preview (gfxforge)
- [ ] Naming/theming, `KEYVAL` bindings, load order (`1_` frameworks)
- [ ] Update public `wiki/wave-defense.md`
- [ ] Package: FrameworkPack + mod, deploy both machines, co-op smoke test

---

## Decisions (resolved 2026-07-11)
1. **Store UI = uilib `UI.Board`.**
2. **XP per-player-local.** Addendum: the client may run scripts / spawn everything EXCEPT **AI units**
   (see Co-op economy model) - only AI-unit spawns are host-gated.
3. **Drops = custom colored beacons for "Special" drops** (rarer, more powerful). Mostly unique coded
   effects + special coded supports; 1-2 may be a native call-in. NOT native support-pickups.
4. **Placement = free-aim with an auto-updating ghost preview** in front of the player (confirm to
   place). Accept the small preview perf cost (limited event; key tracking already optimized).
5. **Build order:** (a) add arena-authoring options to **MissionForge** [DONE - ARENA branch + export],
   (b) Logan authors a baseline arena, (c) in parallel, Claude builds **store + catalog (M4/M5)**.

## Key native APIs (confirmed)
- Cash: `MrxPmc.GetCashQty()`, `MrxPmc.AddCashQty(±n)` (HUD-updating)
- Support: `MrxPmc.AddSupportQty(sId, n)`, `GetSupportQty(sId)`; catalog `MrxSupportData.tSupportData`
- Native store UI (if used): `MrxGuiSupportShop.Create/AddItemFull/SetCallback/Commence`
- Spawn: `Pg.Spawn(template,x,y,z)` (blank template hard-CTDs - validate first)
- AI: `Ai.Goal{ Goal="Attack", Target=... }`; blips: `enemyblippable`
- Persist: `Loader.SaveVar/LoadVar` (number/string/bool only - flatten to prefixed keys)
- Co-op: `_G.ModNet` (Shared / Send+On, host-auth via `IsAuthority()`, v1.2 ready-gate)
