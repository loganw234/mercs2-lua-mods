local KEYVAL = "f2"   -- must be in the first 10 lines (add "ModNet_CoopChat.lua=f2" under [OnKey])

-- ModNet_CoopChat.lua -- co-op text chat, refit onto the ModNet transport.
--
-- All the hard parts (hijack, pack/chunk, reassembly, sender id) now live in
-- ModNet. This file is just UI glue: send typed lines on the "chat" channel,
-- show received lines titled P1/P2, and freeze movement while typing. Compare
-- to coopchat.lua to see how much the library absorbs.
--
-- DEPLOY (both machines): OnLoad\uilib.lua AND OnLoad\ModNet.lua load first.
-- Then OnKey\ModNet_CoopChat.lua with  ModNet_CoopChat.lua=f2  under [OnKey].
-- NOTE: use this OR coopchat.lua, not both -- they'd both claim the wire.
----------------------------------------------------------------------------

if not (_G.UI and UI.Chat) then
  if Loader and Loader.Printf then Loader.Printf("[coopchat] load uilib.lua first") end
  return
end
if not _G.ModNet then
  if Loader and Loader.Printf then Loader.Printf("[coopchat] load ModNet.lua first") end
  return
end

local CH = "chat"

local function try(f, ...) if type(f) == "function" then local ok, v = pcall(f, ...); if ok then return v end end end
local function myId()
  return try(Player and Player.GetLocalPlayerId) or try(Player and Player.GetLocalId)
      or ((Net and Net.IsServer and Net.IsServer()) and 0 or 1)
end
local function label(id) return "P" .. (tonumber(id or 0) + 1) end   -- 0/1 -> P1/P2

-- freeze/unfreeze local player movement (game control gate; leaves chat input intact)
local function setMove(on)
  local p = try(Player and Player.GetLocalPlayer)
  if p and Player.SetInputEnabled then pcall(Player.SetInputEnabled, p, on) end
end

-- onSubmit: send over ModNet, then retitle prompt's bare local echo to "P<me>: text"
local function onSubmit(text)
  ModNet.Send(CH, text)
  local ui = _G.COOPCHAT2 and _G.COOPCHAT2.ui
  if ui then
    local wrap = UI.wrap and UI.wrap(text, 52)
    if type(wrap) == "table" and ui._log then
      for _ = 1, #wrap do table.remove(ui._log) end   -- drop the bare lines prompt just pushed
      ui:push(label(myId()) .. ": " .. text)           -- re-push titled
    end
  end
end

-- ===== build once: the UI.Chat window + movement wraps =====
if not _G.COOPCHAT2 then
  _G.COOPCHAT2 = {}
  local C = _G.COOPCHAT2
  C.ui = UI.Chat{ x = 20, y = 330, w = 384, title = "CO-OP CHAT", onSubmit = onSubmit }

  local basePrompt, baseEnd = C.ui.prompt, C.ui._endInput
  C.ui.prompt    = function(self, cb) setMove(false); return basePrompt(self, cb) end
  C.ui._endInput = function(self)     setMove(true);  return baseEnd(self)      end

  C.ui:push("[co-op chat ready -- press " .. KEYVAL .. " to type]")
  Loader.Printf("[coopchat] built on ModNet")
end

-- ===== each keypress: (re)register receiver (idempotent), then open the input line =====
ModNet.On(CH, function(sender, text)
  local ui = _G.COOPCHAT2 and _G.COOPCHAT2.ui
  if ui and type(text) == "string" then ui:push(label(sender) .. ": " .. text) end
end)

_G.COOPCHAT2.ui:prompt(onSubmit)
