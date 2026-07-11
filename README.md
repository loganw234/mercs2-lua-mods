# Mercenaries 2 Lua Mods

The **Lua Bridge** runtime for **Mercenaries 2: World in Flames** (PC), plus content designed to be driven by scripts running on top of it. This is the stable release channel for the Lua Bridge — active development happens in the [Merc2-Mods-Exp](https://github.com/loganw234/Merc2-Mods-Exp) DEV repo; when a version proves stable there it lands here as a release.

## Current catalog

| Mod | What it is |
|---|---|
| **Lua Bridge** | The runtime. Live Lua REPL, script loader (OnBoot / OnLoad / OnKey), keyboard/focus API, math stdlib parity, persistent SaveVar/LoadVar, self-healing watchdog. Every `[LUA]` mod in this catalog depends on this. |
| **[LUA] Menu Widgets** | Five reusable menu movie assets (`forge`, `cbar`, `cpanel`, `contracts`, `chat`) that Lua scripts drive via `SetSwfFile()`. Additive-only — does not override any base-game asset. |

The `[LUA]` prefix on a mod's catalog name signals that it requires the Lua Bridge to be installed and enabled. The Lua Bridge itself has no `[LUA]` prefix — it's the runtime, not a dependent.

## Installing via the modkit

Add this repository as a mod source in the [mercs2-modkit](https://github.com/Mercenaries-Fan-Build/mercs2-modkit), then browse the catalog and install what you want. Install the Lua Bridge first; anything `[LUA]`-prefixed after that.

## Documentation

Full script-writing docs, API reference for the Lua Bridge, and sample scripts live on the wiki: **[wiki.mercs2.tools](https://wiki.mercs2.tools)**.

## Building from source

Requires a 32-bit MinGW cross-compiler (the game is a 32-bit process):

```sh
# Windows: MSYS2 + mingw-w64-i686-gcc
# Linux:   apt install gcc-mingw-w64-i686
# macOS:   brew install mingw-w64

make                       # build every ASI mod
make -C mods/lua-bridge    # build just the Lua Bridge
```

## License

MIT — see [LICENSE](LICENSE).
