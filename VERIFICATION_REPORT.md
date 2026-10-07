# Professor Escape — Final Verification Report

Generated after the final fix + audit pass. **No Roblox Studio play test was performed** — this
environment is Linux-only and cannot run Roblox Studio or the Luau VM inside the Roblox engine.
Everything below is either (a) an automated test that runs here, or (b) a static audit of the
source. The two are separated explicitly, and the Studio procedure at the end is the remaining
step needed to call the MVP "runtime verified".

---

## 1. Final status

| Item | Result | Basis |
|---|---|---|
| Automated tests | **22/22 PASS** | `tests/run_all_tests.py` (Python ports of the maze, round state machine, stamina math, path follower, speed balance) |
| Maze | **PASS** | 200 seeds: every cell reachable from spawn, exit reachable, professor spawn reachable + far, wall data consistent, small mazes solvable |
| Professor | **PASS** | Static verification of the NPC rig (canonical R6 sizes/layout, Humanoid, Motor6D joints, PrimaryPart) — not executed in Studio |
| Pathfinding | **PASS** | Static verification of `PathfindingService` usage + sequential waypoint following + repath triggers — navmesh execution not run |
| Catch | **PASS** | Logic tests (catch once, no double catch, all-caught ends round) + static verification of the server-side catch path |
| Exit | **PASS** | Static verification of pad `Touched` → `escapePlayer` wiring (with guards) + distance-based backup check; trigger itself not executed |
| Spectator | **PASS** | Logic tests (caught/escaped joins, spectator seats, cannot re-trigger) |
| Round restart | **PASS** | Logic simulation of many consecutive rounds with no state leakage |
| Cleanup | **PASS** | Static audit of every teardown path (AI connections, maze, NPC, exit, seats, per-player listeners) |
| Static audit | **PASS** | Block-balance check **and** a real Luau parse (tree-sitter Luau grammar) incl. accidental-global / infinite-loop / non-integer-literal checks |

All automated suites were re-run **after** the last modification: 22/22 tests, 7/7 files balanced,
7/7 files parsed by the Luau grammar.

---

## 2. The 10 audit points

1. **`.project.json` / Rojo structure consistent — FIXED.**
   The project file previously set properties as bare keys (Rojo 6 style) and mapped folders that
   should not be mapped; the three scripts that must be `Script`/`LocalScript` were plain `.lua`
   files, which Rojo turns into `ModuleScript`s. Now:
   - `GameManager.server.lua` → `Script`, `ClientMain.client.lua` / `AmbientEffects.client.lua` →
     `LocalScript`s, remaining `.lua` files → `ModuleScript`s (verified against the Rojo v7
     "Sync Details" documentation).
   - `default.project.json` rewritten as a pure structure map (services + `$path` + the
     `Remotes`/`ProfessorModels` folders with `$ignoreUnknownInstances`). No properties in the file
     at all — every property (Lighting, Teams, walk speed, respawn) is applied at runtime by
     `GameManager`, so the project file and the scripts cannot disagree.
   - Removed the `$path` mappings for `Workspace`, `SoundService` and `StarterGui`: Rojo prunes
     "unknown" children of `$path` nodes, which would have deleted runtime content (maze/NPC/pads
     in Workspace, client `Sound` objects in SoundService) during a live-sync.
   - No `.gitkeep` files remain (they would be synced as unknown files); the folders Rojo needs
     exist as declared instances instead.
   *Caveat:* the Rojo binary could not be downloaded in this sandbox (the release-asset host is
   blocked), so `rojo build` was **not** executed. The file was validated against the documented
   Rojo v7 format and is valid JSON.

2. **Scripts reference the correct services and module paths — PASS.**
   `Players`, `ReplicatedStorage`, `ServerStorage`, `Workspace`, `Teams`, `Lighting`,
   `SoundService`, `Debris`, `RunService`, `PathfindingService`, `UserInputService`, `StarterGui`,
   `StarterPlayer` are all fetched via `GetService`. Every `require` resolves to a file that exists:
   `ReplicatedStorage.Shared.GameConfig` (server ×3, client ×1), `script.Parent.MazeGenerator`,
   `.ProfessorBuilder`, `.ProfessorAI`. Note `MazeGenerator`/`ProfessorAI` reference
   `game.ReplicatedStorage.Shared.GameConfig`.

3. **No script depends on an object that is never created — PASS.**
   Every container the code reads is either mapped by Rojo or created defensively at load:
   `ReplicatedStorage/Remotes`, `Workspace/{Lobby,ActiveMap,Exit,Professors}`, `Teams/{Players,
   Spectators}` are all created by `GameManager` with `FindFirstChild(...) or Instance.new(...)`
   (idempotent, so a pre-existing Rojo-created instance is reused). Lighting/SoundService/
   StarterPlayer settings are applied by the server at load, so an empty baseplate works.
   Client-side lookups of runtime objects (`Workspace.ActiveMap`, `Maze/Floor`, other players'
   characters) are all nil-guarded or behind `WaitForChild`.

4. **No client assumes a RemoteEvent exists — PASS.**
   `ClientMain` does `ReplicatedStorage:WaitForChild("Remotes")` then `:WaitForChild("GameEvent")`
   / `:WaitForChild("SprintEvent")`; `AmbientEffects` touches no remotes. The server creates
   `Remotes` + both `RemoteEvent`s as the very first thing in `GameManager` (before any code that
   can yield), so the client wait always resolves.

5. **ProfessorBuilder produces a valid Humanoid character — PASS (static).**
   The rig is now built from the canonical R6 layout: parts `HumanoidRootPart`/`Torso` (2×2×1),
   `Head` (2×2×2), arms/legs (1×2×1); parts are positioned at the canonical offsets
   (head +2 on Y, arms ±1.5 on X, legs ±0.5 X / −2 Y relative to the torso) and the six Motor6D
   joints (`RootJoint`, `Neck`, `Left/Right Shoulder`, `Left/Right Hip`) are created with the
   canonical Part0→Part1 directions and `C0 = Part0.CFrame:ToObjectSpace(Part1.CFrame)`,
   `C1 = identity` — i.e. the joint transform is *derived from real part positions* instead of
   hand-typed offsets, so the assembled rig cannot be geometrically inconsistent. The model has a
   `Humanoid` (WalkSpeed 12, JumpPower/JumpHeight 0, MaxHealth 100000, AutoRotate true), a
   `PrimaryPart`, unanchored body parts (required for physics), non-colliding decorations, a
   `ForceField`, and a `Sounds` folder with empty-id placeholder `Sound`s.
   The parts collide like a real character (Torso collides, root/head/limbs do not).

6. **Pathfinding follows waypoints correctly — PASS (static).**
   `ComputePathTo` → `CreatePath{AgentRadius=2, AgentHeight=6, AgentCanJump=false,
   AgentCanClimb=false, WaypointSpacing=4}` → `ComputeAsync` (pcall-wrapped) → status check →
   `GetWaypoints()` → `MoveToNextWaypoint()` walks the list sequentially (skipping waypoints
   already within 1.5 studs) → `Humanoid.MoveToFinished` advances the index → end of list clears
   the path so the next update recomputes. Repathing is triggered by: `path.Blocked`, a failed
   reach, the per-state update rate (0.4 s chasing / 1.2 s patrolling), and a 3-second
   stuck-detector. Movement is done exclusively with `Humanoid:MoveTo`, so the engine enforces
   collisions — the NPC cannot clip through walls. The `Blocked` connection is disconnected before
   each new path, so connections do not accumulate.

7. **Maze / spawn / exit positions still valid — PASS.**
   200-seed automated sweep after the changes: every cell reachable from the spawn, exit always
   reachable, professor spawn always reachable and far from the player spawn, spawn candidates
   always open cells. `MazeGenerator.Generate` returns `ExitPos` at floor level (Y = `FloorY`),
   which is what `buildExit` assumes when it places the 0.5-thick pad at Y = 0.4.

8. **Round cleanup leaves nothing behind — PASS.**
   `startWaiting()` (i.e. every round transition) stops the AI (`Stop()` disconnects the heartbeat,
   `MoveToFinished` and `Blocked` connections, silences sounds, clears the burst light, stops the
   Humanoid), drops the `Game.Professor` handle, then `ClearAllChildren()` on
   `Workspace/Professors`, `Workspace/Exit`, `Workspace/ActiveMap`, and destroys every
   `SpectatorSeat_*` part. Per-player connections are attached once in `PlayerAdded` (removed with
   the player) and the `Died` handler uses `task.delay` (non-yielding). Global connections
   (`Heartbeat` main loop, `SprintEvent.OnServerEvent`, `PlayerAdded`, `PlayerRemoving`) are
   created once at script load and are *not* re-created per round. Verified by both static reading
   and the multi-round simulation test.

9. **Complete automated suite re-run — PASS.** 22/22 (see §1, §4).

10. **Final static audit of all Lua/Luau files — PASS.**
    Two independent checkers: `tests/syntax_check.py` (block balance, string/comment aware) and
    `tests/luau_parse.py` (real tree-sitter **Luau** parse tree; also flags accidental globals,
    `while true`/`repeat` loops with no yield and no break/return, and non-integer
    `math.random` bounds). All 7 files clean.

### Bugs found and fixed in this final pass

| File | Issue | Fix |
|---|---|---|
| `GameManager.lua` → `GameManager.server.lua` | Rojo would have created it as a **ModuleScript**, so the whole game would never run | renamed to `.server.lua` |
| `ClientMain.lua`, `AmbientEffects.lua` → `*.client.lua` | Rojo would have created them as **ModuleScripts** → no client UI/input | renamed to `.client.lua` |
| `default.project.json` | bare-key properties (Rojo 6 syntax), `$path` on Workspace/SoundService/StarterGui (Rojo would prune runtime content), `.gitkeep` files inside mapped folders | rewritten; offending mappings and `.gitkeep` files removed |
| `ProfessorBuilder.lua` | joints used hand-typed `C0` values with `C1` left at identity, which assembled the rig 0.5–1 stud out of place (head sunk into the torso, legs half swallowed); header comment described an approach that was no longer used | rig parts are now placed at canonical positions and every joint transform is derived from them; body parts collide like a real R6 character; decorations welded + massless; comment corrected |
| `ProfessorAI.lua` | `math.random(minX, maxX)` used non-integer patrol bounds derived from part positions (Luau coerces/truncates these — fragile and config-dependent) | bounds snapped with `math.floor` + degenerate-small-maze guard |
| `GameManager.server.lua` | `SoundService.AmbientReverb = Enum.ReverbType.Hallway` would hard-error on a Roblox version without that enum item, aborting the rest of the server setup block | wrapped in `pcall` |

(Fixes from the earlier hardening pass — `task.spawn` around the yielding `PlayerAdded` body,
sprint state release on respawn/death, server-side Lighting/Teams/StarterPlayer setup, the
distance-based backup exit trigger, `Players.RespawnTime`, tighter pathfinding agent parameters,
professor HRP spawn height, empty `SoundId` placeholders — are all still in place.)

---

## 3. VERIFIED WITHOUT ROBLOX STUDIO

These are backed by executed checks **in this environment**:

- **Luau syntax of all 7 files** — parsed successfully by a real Luau grammar (tree-sitter-luau),
  no `ERROR`/`MISSING` nodes; independently confirmed by the block-balance checker.
- **No accidental globals** — every assignment target is a local or a known Roblox global reachable
  in that context.
- **No infinite loop without a yield** in any `while true` / `repeat` body.
- **No non-integer literal passed to `math.random`.**
- **Maze generation logic** — Python port of `MazeGenerator.lua`, 200 random seeds: full
  connectivity from the player spawn, reachable exit, reachable + distant professor spawn, valid
  spawn candidates, correct wall/door data, small-maze edge cases.
- **Round state machine** — Python port of `round_state.py` model driven by `GameConfig` values:
  WAITING → STARTING → PLAYING → ROUND_END → WAITING, single player, all-caught, time-out,
  empty-server waiting extension, joining mid-round as spectator, leaving mid-round.
- **Catch / escape / spectator bookkeeping** — a caught or escaped player becomes a spectator, can
  never be caught or escape twice, and the round ends exactly once.
- **No state leakage across rounds** — 50-round simulation: alive/escaped/spectator sets,
  spectators and winners are fully reset each round.
- **Stamina math** — drain 25/s, regen 15/s after a 0.5 s cooldown, clamped to
  [0, MaxStamina]; sprint speed > walk speed > professor walk speed; burst speed > sprint speed
  (so a burst can close a gap but a corner + sprint can break it).
- **Path-follower logic** — the sequential waypoint follower used by the AI reaches a target in a
  simulated grid maze, including skipping already-reached waypoints.
- **Static wiring audit** — remotes created before use, all `require` targets exist, the exit pad's
  `Touched` handler is connected and guarded (`Humanoid` check → player lookup → not-a-spectator →
  `PLAYING` state → not-already-escaped → `escapePlayer`), all teardown paths clear their
  containers and disconnect their connections, Rojo file→instance-type mapping matches the Rojo v7
  rules.
- **`default.project.json` validity** — valid JSON, all `$path` targets exist, no dotfiles inside
  mapped folders, structure matches the documented Rojo v7 project format.

---

## 4. REQUIRES REAL ROBLOX STUDIO PLAYTEST

Nothing in this list has been tested. Do not treat these as verified:

- **Rojo actually building/syncing the place** (`rojo build` / `rojo serve` + plugin connect) —
  the Rojo binary could not be downloaded here.
- **The scripts loading without runtime errors** (Luau executed by Roblox: service access,
  `Instance` construction, property names/overnight renames, `Enum` items, `task.*` scheduling).
- **Physics of the professor rig** — that the assembled R6 rig stands up, walks, falls cleanly onto
  the maze floor, doesn't jitter/ragdoll, and rotates with `AutoRotate`.
- **`Humanoid:MoveTo` + `PathfindingService` actually working in this maze** — navmesh generation
  across a 25×25 × 16-stud maze of individual wall parts, `ComputeAsync` returning `Success`,
  first-path latency, path quality through 16-stud corridors with `AgentRadius=2`, `Blocked`
  behaviour, and the stuck-detector's real-world behaviour.
- **Real catch timing** (3-stud range vs. server heartbeat rates) and whether the professor feels
  "threatening but beatable" in practice.
- **Collision correctness** — that players cannot clip through walls, cannot fall through the
  floor/ceiling, can walk through every doorway, and that the exit pad is not blocked.
- **`Touched` actually firing** on the exit pad (the distance-based backup path is code-reviewed but
  also unexecuted).
- **Client UI, sprint input latency, stamina bar, spectator camera** and the "You escaped" /
  "You were caught" flows.
- **Multiplayer behaviour with 2+ real clients** — shared maze, one professor, team assignment,
  spectator seats, per-client state broadcasts.
- **Round loop stability over time** (repeated mazes, no leftover instances, no FPS decay, no
  memory growth) and the profiler numbers for the maze/lighting (25×25 maze + per-cell lights is
  the main performance unknown).
- **Audio** — every `SoundId` is intentionally empty (placeholders), so there is no sound at all
  until asset ids are filled in. The professor also has no walk animation (`Animator`/animation
  assets were deliberately not added): expect it to slide, not walk.
- **Studio-only tooling** — `View → Script Analysis` (lint) results, and any Type/`--!strict`
  diagnostics.

---

## 5. Exact Roblox Studio play-test steps

### A. Get the project into Studio

**Option A — Rojo (recommended)**
1. Install the Rojo CLI (https://rojo.space — `rokit`, `aftman`, `cargo install rojo`, or a release
   binary) and the **Rojo** plugin in Studio (Toolbox/Creator Store).
2. In a terminal in the project root:
   ```
   rojo build default.project.json -o ProfessorEscape.rbxlx
   ```
3. Studio → **File → Open from File** → `ProfessorEscape.rbxlx`.
   *(Live-sync alternative: `rojo serve`, then Studio → **Plugins → Rojo → Connect**.)*

**Option B — no tools:** follow `README.md` → "Option B — Manual setup". Note the file→instance
types: `GameManager` = **Script**, `MazeGenerator`/`ProfessorAI`/`ProfessorBuilder`/`GameConfig` =
**ModuleScripts**, `ClientMain`/`AmbientEffects` = **LocalScripts**.

### B. Pre-flight (before pressing Play)

4. **Explorer** check:
   - `ReplicatedStorage` → `Shared` (Folder) → `GameConfig` (ModuleScript); `Remotes` (Folder,
     empty is correct — the server fills it).
   - `ServerScriptService` → `GameManager` **Script**; `MazeGenerator`, `ProfessorAI`,
     `ProfessorBuilder` **ModuleScripts**.
   - `StarterPlayer → StarterPlayerScripts` → `ClientMain`, `AmbientEffects` **LocalScripts**.
5. Delete the template's `Baseplate` part and any `SpawnLocation` in `Workspace`, plus any leftover
   template `Script`. The server builds the lobby, maze and spawns itself.
6. Open **View → Output** and clear it. Leave it visible for the whole test.

### C. Round 1 — lobby, countdown, maze

7. Press **F5** (solo play) or **Test → Start**.
   **Expected:** Output has no red errors. You spawn in a lit lobby box. UI shows `WAITING` with a
   countdown (≤10 s). Teams `Players` / `Spectators` appear.
8. When the countdown goes `STARTING` (5 s) you are teleported into the maze.
   **Check:** yellow carpet floor, mustard walls, ceiling with fluorescent light panels, fog; you
   are standing on the floor, not inside a wall.
9. **Movement:** WASD walks (14 studs/s). Hold **Shift** → sprint (22) and the stamina bar drains
   (~25/s, so ~4 s of sprint). Release → bar refills after ~0.5 s.
   **Check:** you cannot walk through walls; doorways in the walls are passable.

### D. The Professor

10. Find it — dark humanoid, white shirt panel, red tie, dark eyes.
    **Expected:** it patrols corridors (12 studs/s), turns to face where it walks, and starts
    chasing (16) when it sees you within 28 studs with line of sight.
11. **Check no wall clipping:** step around a corner and watch it take the corridor route.
12. **Speed Burst:** every ~15 s while chasing, a red glow appears above its head for ~0.8 s, then it
    runs at 24 for 3 s. Sprinting (22) plus corners should let you break away.
13. **Catch:** let it touch you (≤3 studs).
    **Expected:** "You were caught" message, you switch to the **Spectators** team, your camera
    switches to spectate mode, and you can no longer be caught or counted as alive.

### E. Exit and round end

14. In the next round, find the **green glowing EXIT pad** and step on it.
    **Expected:** "You escaped" message, the round ends immediately (5 s `ROUND_END`), and you are
    listed as the winner. *(Design note: the **first** escape ends the round for everyone.)*
15. Watch a full cycle with no input: `PLAYING` → 5-minute timer expires → `ROUND_END` → `WAITING`
    → new maze. Confirm the new maze is a **different** layout.

### F. Cleanup / leak checks (Explorer, mid-session)

16. During `WAITING`: `Workspace/ActiveMap`, `Workspace/Exit`, `Workspace/Professors` must be
    **empty**, and no `SpectatorSeat_*` parts may remain from the previous round.
17. During `PLAYING`: exactly **one** `Maze` inside `Workspace/ActiveMap`, **one** `Professor` in
    `Workspace/Professors`, **one** exit pad in `Workspace/Exit`.
18. Run **3+ full rounds** and confirm Output stays clean and that the instance count
    (`View → Explorer` eyeball, or a command-bar count) returns to roughly the same value each
    `WAITING` phase.
19. Optional command-bar sanity checks (server context, while playing):
    ```lua
    print(#game.Workspace.ActiveMap:GetChildren(), #game.Workspace.Professors:GetChildren())
    print(game.ReplicatedStorage.Remotes:GetChildren())  -- GameEvent, SprintEvent
    ```
20. Open **View → Performance Stats** and watch FPS/render time with the maze loaded — this is the
    main unmeasured risk (400×400-stud maze with many wall parts and lights).

### G. Multiplayer

21. **Test → Clients and Servers → Players: 2 → Start.**
    **Expected:** both players get their own window, both are placed in the *same* maze at
    different spawn points, both see the same professor, the first to touch the exit wins and ends
    the round for both, and a caught player in one window becomes a spectator while the other keeps
    playing.

### H. If something goes wrong

- Copy the **entire Output log** (red lines especially) — that is the only way to diagnose
  runtime-only issues.
- Watch specifically for: `attempt to index nil` (an object assumed before creation),
  `Unknown global` / script analysis warnings, `ComputeAsync` errors or paths never becoming
  `Success` (professor stands still), and the professor spinning or falling over (rig/physics).
- The professor self-recovers from being stuck (it repaths every ~3 s), so a single freeze is
  usually transient — a *permanent* freeze points at navmesh generation in the maze.

---

## 6. How to re-run everything here

```bash
python3 tests/run_all_tests.py     # 22 logic tests (maze 200 seeds, rounds, stamina, follower)
python3 tests/syntax_check.py      # Luau block-balance check (no dependencies)

# stronger static check (optional dependency):
pip install tree-sitter tree-sitter-luau
python3 tests/luau_parse.py        # real Luau parse + globals/loops/literals audit
```

## 7. File map (current)

```
default.project.json                                  Rojo project (structure only)
README.md                                             setup + play instructions
src/ReplicatedStorage/Shared/GameConfig.lua            ModuleScript — tuning constants
src/ServerScriptService/GameManager.server.lua         Script — lobby, rounds, teams, remotes, stamina, exit
src/ServerScriptService/MazeGenerator.lua              ModuleScript — maze + spawn/exit/professor placement
src/ServerScriptService/ProfessorBuilder.lua           ModuleScript — canonical R6 NPC rig + placeholders
src/ServerScriptService/ProfessorAI.lua                ModuleScript — patrol/chase/burst + pathfinding
src/StarterPlayer/StarterPlayerScripts/ClientMain.client.lua      LocalScript — UI, sprint, spectator camera
src/StarterPlayer/StarterPlayerScripts/AmbientEffects.client.lua  LocalScript — hum, heartbeat, flicker
tests/                                                22-test suite + 2 static checkers
```
