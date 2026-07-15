# Changelog

All notable changes to the Mercenaries 2 Lua Mods stable channel will be documented in this file.

## [v1.0.1] - 2026-07-15

Only `lua-bridge` bumped (1.0.0 → 1.0.1). Watchdog reliability patch — no user-facing API changes.

### Fixed

- **Watchdog now detects "hung inside a native call from Lua."** Previously the watchdog's `since_detour > 2000` guard — meant to distinguish a genuine stall from a legitimate pause — silently misfired in the very case it existed to catch. When a queued script called into native code that never returned (e.g. `SetSwfFile()` on a wedged D3D device, an infinite `while true do end`), the game thread was blocked, so no more of our hooked detours could fire. After 2 seconds the watchdog treated the hang as "game paused" and bailed. This is the specific pattern users reported as "bridge queue stops draining, only PC restart fixes it."
- **New detection path.** A separate `g_bridgeExecStartTick` tracks when the pump entered `LuaDoString`. If it stays set for longer than the stuck threshold, the watchdog fires regardless of detour activity — because being inside exec proves the pump was active. Logged as `pattern: in-bridge-exec-not-returning (native call from Lua hung)` with `exec_elapsed=Xms` for post-mortem.
- **Boot-time timestamp seeding.** `g_lastDetourFireTick`, `g_lastPumpAttemptTick`, and `g_lastPumpProgressTick` are now initialized to `GetTickCount()` before the watchdog thread starts, instead of BSS-zero. Prevents `since_progress = GetTickCount()` (a huge number) on the first wake, which could produce incoherent diagnostics in edge cases.
- **What this fixes and doesn't fix.** When the game thread eventually recovers (driver unblocks, native call completes late), the reset means the next pump entry finds a clean bridge state — fresh `g_LuaState`, cleared `g_seenL`, `t_inBridgeExec` force-cleared — instead of a permanently jammed queue. The bridge cannot forcibly unstick a hung native call from a different thread; if the game process is genuinely dead, only a restart helps. But the failure mode is now recoverable rather than fatal, and the diagnostic log clearly identifies which of three stuck patterns fired.

## [v1.0.0] - 2026-07-10

Initial stable-channel release. Contents mirror `lua-bridge-DEV` v0.3.0 from the [experimental repo](https://github.com/loganw234/Merc2-Mods-Exp), with the `_DEV` filename suffix stripped for the stable artifact.
