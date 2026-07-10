# Mercenaries 2 Lua Mods

Lua-based mods for **Mercenaries 2: World in Flames** (PC). Each mod is a small Lua script that runs against the [Lua Bridge](https://github.com/loganw234/Merc2-Mods-Exp) runtime (`lua_bridge.asi`).

> [!IMPORTANT]
> **All mods in this catalog require the Lua Bridge mod to be installed and enabled first.** The `[LUA]` prefix on a mod's name in the modkit catalog signals this dependency. Without the runtime, the scripts have nowhere to run.

## Status: Probe phase

This repo is currently a **probe** — it exists to verify how the modkit's mod catalog handles different asset types before we start publishing real Lua-based mods here. The `[PROBE]` mods in the catalog are throwaway placeholders used to confirm modkit deployment behavior; they're safe to install then delete once the file path is confirmed.

Once the deployment path is understood, this catalog will grow to host individual Lua mods (menus, cheat tools, gameplay tweaks, etc.), each prefixed `[LUA]` to signal the runtime dependency.

## Documentation

Full script-writing docs, samples, and the API reference for the Lua Bridge runtime live on the wiki: **[wiki.mercs2.tools](https://wiki.mercs2.tools)**.

## License

MIT — see [LICENSE](LICENSE).
