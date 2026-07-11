# Mercenaries 2 Lua Mods

Lua-driven mods for **Mercenaries 2: World in Flames** (PC). Menu widgets, script tools, and other content designed to be composed by scripts running on the [Lua Bridge](https://github.com/loganw234/Merc2-Mods-Exp) runtime.

> [!IMPORTANT]
> **Mods in this catalog require the Lua Bridge to be installed and enabled first** to be useful. The `[LUA]` prefix on every mod's catalog name signals this dependency. The assets themselves install without it (they're plain WAD-patch content), but nothing will drive them until a Lua script does.

## Current mods

| Mod | What it is |
|---|---|
| **[LUA] Menu Widgets** | Five reusable menu movie assets (`forge`, `cbar`, `cpanel`, `contracts`, `chat`) that Lua scripts drive via `SetSwfFile()`. Additive — does not override any base-game content. |

## Documentation

Full script-writing docs, samples for driving these menus, and the Lua Bridge API reference live on the wiki: **[wiki.mercs2.tools](https://wiki.mercs2.tools)**.

## License

MIT — see [LICENSE](LICENSE).
