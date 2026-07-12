-- ExampleContract.lua  -  a worked example of the Contract modder API.
--
-- DEPLOY: scripts/OnLoad/, with a HIGHER lua_loader.ini number than ContractFramework.lua so it
--   loads after the framework, e.g.:  ExampleContract.lua=15
--
-- This is the whole authoring surface a modder touches. Replace the coordinates below with ones
-- captured from the ForgeCam creator (or type them by hand). Templates must be exact Pg.Spawn
-- names - a typo just logs "DROP FAILED" and skips that spawn.

if not _G.Contract then
    Loader.Printf("ExampleContract: Contract framework not loaded - give ContractFramework.lua a LOWER [OnLoad] number")
    return
end

Contract.Register({
    id       = "example_ambush",
    title    = "Example: Jungle Ambush",
    category = "RAIDS",   -- groups it on the board (any string; auto-detected from what modders set)
    briefing = "Wipe out the guerilla patrol, hold the LZ, then extract.",
    reward   = { cash = 75000, fuel = 150 },
    -- start = { x = 0, y = 0, z = 0, yaw = 0 },   -- uncomment to teleport the player in on accept

    objectives = {
        Contract.Destroy({
            desc = "Eliminate the patrol",
            spawns = {                                -- { "Template", x, y, z, yaw }
                { "Guerilla Heavy (RPG)", 0, 0, 0 },
                { "Guerilla Soldier",     5, 0, 0 },
                { "Guerilla Soldier",    -5, 0, 0 },
                { "M151 (MG) (GR)",       0, 0, 8 },
            },
        }),
        Contract.Defend({ desc = "Hold the LZ", time = 60 }),
        Contract.Reach({  desc = "Reach extraction", at = { 40, 0, 0 }, radius = 15 }),
    },

    onComplete = function() Loader.Printf("[ExampleMod] ambush cleared - nice work") end,
    onFail     = function() Loader.Printf("[ExampleMod] the patrol got away") end,
})

-- A second contract showing the MODES (draft): parallel objectives, an optional bonus, a contract
-- time limit, and a background "stay in the area" fail-condition. Coords are player-relative via
-- fResolve so you can accept it anywhere to test.
Contract.Register({
    id       = "example_parallel",
    title    = "Example: Hold & Hunt (parallel)",
    category = "RAIDS",
    briefing = "Hold the plaza and wreck the escort at the same time. Don't stray too far.",
    reward   = { cash = 120000 },
    mode     = "parallel",
    timeLimit = 300,

    objectives = {
        Contract.Hold({    desc = "Hold the plaza (30s)", radius = 18, time = 30 }),
        Contract.Destroy({ desc = "Wreck the escort" }),
        Contract.Destroy({ desc = "Bonus: extra car", optional = true, bonus = 25000 }),
    },
    fail = { Contract.StayInArea({ radius = 220 }) },

    fResolve = function(def)
        local uc = Player.GetLocalCharacter(); if not uc then return end
        local x, y, z = Object.GetPosition(uc)
        def.objectives[1].tZone   = { x = x, y = y, z = z, r = 18 }
        def.objectives[2].tSpawns = { { "Guerilla Soldier", x + 12, y, z + 4 }, { "M151 (MG) (GR)", x + 14, y, z } }
        def.objectives[3].tSpawns = { { "Veyron", x + 10, y, z - 6 } }
        def.fail[1].tZone         = { x = x, y = y, z = z, r = 220 }
    end,
})

-- A third contract showcasing the DRAFT advanced pieces: nested phases (Group), a live-query target
-- (destroy any nearby vehicles), an interact, an HVT verify, and a heli extract. Player-relative.
Contract.Register({
    id       = "example_ops",
    title    = "Example: Black Ops (phased)",
    category = "OPS",
    briefing = "Two phases: soften the area, then grab the HVT and exfil.",
    reward   = { cash = 250000, fuel = 200 },

    objectives = {
        Contract.Group({ desc = "Phase 1: soften the area", mode = "parallel", objectives = {
            Contract.Destroy({ desc = "Wreck any vehicles nearby" }),      -- where= filled below
            Contract.Interact({ desc = "Plant charges (hold 3s)", time = 3 }),
        }}),
        Contract.Group({ desc = "Phase 2: grab & go", objectives = {       -- sequential
            Contract.Verify({ desc = "Neutralise the HVT", capture = true }),
            Contract.Extract({ desc = "Reach the LZ", boardTime = 3 }),
        }}),
    },

    fResolve = function(def)
        local uc = Player.GetLocalCharacter(); if not uc then return end
        local x, y, z = Object.GetPosition(uc)
        local p1 = def.objectives[1].tObjectives
        p1[1].tWhere = { area = { x = x, y = y, z = z, r = 120 }, kind = "vehicles" }
        p1[2].tZone  = { x = x + 6, y = y, z = z }
        local p2 = def.objectives[2].tObjectives
        p2[1].tSpawn = { "OC Boss", x + 15, y, z + 5 }
        p2[2].tZone  = { x = x - 20, y = y, z = z, r = 15 }
    end,
})

-- A quick Race example (checkpoints relative to the player).
Contract.Register({
    id       = "example_race",
    title    = "Example: Time Trial",
    category = "OPS",
    reward   = { cash = 40000 },
    objectives = { Contract.Race({ desc = "Hit all 4 checkpoints", radius = 12, time = 120 }) },
    fResolve = function(def)
        local uc = Player.GetLocalCharacter(); if not uc then return end
        local x, y, z = Object.GetPosition(uc)
        def.objectives[1].tCheckpoints = { { x + 30, y, z }, { x + 30, y, z + 40 }, { x - 20, y, z + 40 }, { x, y, z } }
    end,
})
