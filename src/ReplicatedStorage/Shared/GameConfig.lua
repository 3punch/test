-- GameConfig (ModuleScript)
-- Central tuning constants for Professor Escape
local Config = {}

-- ========== ROUND TIMINGS ==========
Config.WaitingTime = 10        -- seconds in lobby before round starts
Config.StartingTime = 5        -- countdown before teleporting in
Config.RoundTimeMax = 300      -- 5 minutes max per round
Config.RoundEndTime = 5        -- pause after round ends

-- ========== MAZE ==========
Config.MazeWidth = 25          -- cells wide (odd numbers produce nicer layouts)
Config.MazeHeight = 25         -- cells tall
Config.CellSize = 16           -- studs per cell
Config.WallHeight = 8          -- wall height in studs
Config.WallThickness = 1
Config.FloorY = 0              -- floor Y position
Config.WallColor = Color3.fromRGB(215, 195, 120)   -- mustard / cream yellow
Config.FloorColor = Color3.fromRGB(180, 150, 90)   -- old yellow carpet
Config.CeilingColor = Color3.fromRGB(225, 220, 200)
Config.LobbySize = Vector3.new(80, 16, 80)
Config.MazeCenterOffset = Vector3.new(0, 0, -150)  -- where to place the maze relative to lobby

-- ========== PLAYER / STAMINA ==========
Config.WalkSpeed = 14
Config.SprintSpeed = 22
Config.MaxStamina = 100
Config.StaminaDrainPerSecond = 25    -- sprint drains 25/sec -> 4 seconds max sprint
Config.StaminaRegenPerSecond = 15    -- regen 15/sec -> ~6.6 seconds to full
Config.StaminaCooldown = 0.5         -- wait this long after sprinting before regen

-- ========== PROFESSOR ==========
Config.ProfessorWalkSpeed = 12       -- slightly slower than walk, so sprint lets you escape
Config.ProfessorChaseSpeed = 16      -- slightly faster than walk, slower than sprint
Config.ProfessorBurstSpeed = 24      -- faster than sprint
Config.ProfessorDetectionRange = 28  -- studs
Config.ProfessorCatchRange = 3       -- studs to catch
Config.ProfessorPathUpdateRate = 0.6 -- seconds between path recomputes
Config.ProfessorPatrolWaypointRange = 40
Config.BurstCooldown = 15            -- seconds between speed bursts
Config.BurstDuration = 3             -- how long burst lasts
Config.BurstWarningTime = 0.8        -- warning before burst kicks in
Config.ProfessorHealth = 1000

-- ========== EXIT ==========
Config.ExitPadSize = Vector3.new(8, 0.5, 8)
Config.ExitColor = Color3.fromRGB(80, 220, 100)
Config.ExitLightColor = Color3.fromRGB(80, 255, 120)

return Config
