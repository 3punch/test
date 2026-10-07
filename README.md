# Professor Escape — Backrooms Survival MVP

A multiplayer Roblox horror/funny survival game. Players spawn inside a procedurally generated yellow Backrooms maze. A Professor hunts them. Find the exit to escape; get caught and spectate.

## How to play (controls)

- **WASD** — walk
- **Shift** — sprint (uses stamina)
- **Touch the glowing green EXIT pad** to win the round
- If the Professor catches you, you become a spectator and can watch the remaining players

## How to open in Roblox Studio

### Option A — Rojo (recommended for code sync)
1. Install Rojo (https://rojo.space)
2. Open a Terminal / PowerShell in this folder
3. Run: `rojo build default.project.json -o ProfessorEscape.rbxlx`
4. Open `ProfessorEscape.rbxlx` in Roblox Studio
5. Press **Play** (F5) to test. Use **Start Server** + **Start Client** (in the Test tab) to test multiplayer.

To live-sync code while Studio is open, run `rojo serve` and connect with the Rojo Studio plugin.

Rojo file-type rules used by this project (important):

- `*.server.lua` -> `Script`   (`GameManager.server.lua`)
- `*.client.lua` -> `LocalScript` (`ClientMain.client.lua`, `AmbientEffects.client.lua`)
- `*.lua`        -> `ModuleScript` (`GameConfig`, `MazeGenerator`, `ProfessorAI`, `ProfessorBuilder`)

The project file only describes structure. Every property (Lighting, Teams, walk speed,
respawn time, atmosphere) is configured at runtime by `GameManager.server.lua`, so the
project file and the scripts can never disagree.

### Option B — Manual setup (no tools needed)
1. Open Roblox Studio → **Baseplate** template.
2. Delete the existing baseplate.
3. In **ReplicatedStorage**, create a Folder named `Shared`. Inside it create a ModuleScript named `GameConfig` and paste the contents of `src/ReplicatedStorage/Shared/GameConfig.lua` (remove the initial `--` comments at top are fine; replace the default template code).
4. In **ReplicatedStorage**, create a Folder named `Remotes`. Inside it create two `RemoteEvent` instances: `GameEvent` and `SprintEvent`.
5. In **ServerScriptService**, create:
   - A **Script** named `GameManager` → paste `src/ServerScriptService/GameManager.server.lua`
   - A **ModuleScript** named `MazeGenerator` → paste `src/ServerScriptService/MazeGenerator.lua`
   - A **ModuleScript** named `ProfessorAI` → paste `src/ServerScriptService/ProfessorAI.lua`
   - A **ModuleScript** named `ProfessorBuilder` → paste `src/ServerScriptService/ProfessorBuilder.lua`
6. In **StarterPlayer → StarterPlayerScripts**, create two **LocalScripts**:
   - `ClientMain` → paste `src/StarterPlayer/StarterPlayerScripts/ClientMain.client.lua`
   - `AmbientEffects` → paste `src/StarterPlayer/StarterPlayerScripts/AmbientEffects.client.lua`
7. Lighting, Teams and StarterPlayer settings below are **optional** — the server script
   configures them at runtime. Set them by hand only if you want them visible in Studio's editor.
   - **Lighting**: Brightness = 1.5, Ambient / OutdoorAmbient = dark cream, FogEnd = 180, FogStart = 40
8. In **Teams** (enable via Model → Service → Teams), create two Teams (also auto-created by the server):
   - `Players` (Bright blue, AutoAssignable)
   - `Spectators` (Bright red, not auto-assignable)
9. In **StarterPlayer**, set `CharacterWalkSpeed = 14` (the scripts will also enforce this).
10. Delete the default Baseplate, Script in Workspace, and any starter Sound/LocalScript.
11. Press Play.

### Option C — Using `rbxlx` included (if built)
Open `ProfessorEscape.rbxlx` directly.

## Code structure

Source file layout (see `default.project.json` for the mapping into Roblox services):

- `src/ReplicatedStorage/Shared/GameConfig.lua` (ModuleScript)
- `src/ServerScriptService/GameManager.server.lua` (Script)
- `src/ServerScriptService/MazeGenerator.lua`, `ProfessorBuilder.lua`, `ProfessorAI.lua` (ModuleScripts)
- `src/StarterPlayer/StarterPlayerScripts/ClientMain.client.lua`, `AmbientEffects.client.lua` (LocalScripts)

Runtime-created containers (do not need to exist in the place file; the server/tools make them):

- `Workspace/Lobby`, `Workspace/ActiveMap`, `Workspace/Exit`, `Workspace/Professors`
- `ReplicatedStorage/Remotes` (`GameEvent`, `SprintEvent`)
- `Teams/Players`, `Teams/Spectators`
- `ServerStorage/ProfessorModels` (empty staging folder for future `.rbxm` professor variants)

Modules and responsibilities:

- `ReplicatedStorage/Shared/GameConfig` — all tunable numbers (speed, maze size, timings)
- `ServerScriptService/GameManager` — round state machine, lobby, player/team/spectator management
- `ServerScriptService/MazeGenerator` — procedural maze (recursive backtracking, guaranteed solvable)
- `ServerScriptService/ProfessorBuilder` — procedural Professor NPC model
- `ServerScriptService/ProfessorAI` — patrol/chase/burst logic + Roblox Pathfinding
- `StarterPlayerScripts/ClientMain` — input, UI, sprinting, spectator camera
- `StarterPlayerScripts/AmbientEffects` — ambient hum, proximity heartbeat, light flicker

## Round flow

`WAITING` (10s min) → `STARTING` (5s countdown) → `PLAYING` (up to 5 min) → `ROUND_END` (5s) → `WAITING`

The round ends early if any player escapes or all players are caught.

## Network / security

- All gameplay decisions (winning, catching, round state, spawning) run on the server.
- The client only sends sprint-toggle input; stamina and speed are enforced server-side.
- RemoteEvents are rate-limited.

## Audio placeholders

Several `Sound` instances are created with empty `SoundId`. To add polish later, set the `SoundId` fields to uploaded audio asset IDs:

- Professor: `Footstep`, `Chase`, `BurstWarning`, `BurstActive`, `Catch` (on the Professor model → `Sounds`)
- Client: `Escape`, `Caught` (created in character Head on events)
- Ambient: `FluorescentHum`, `Heartbeat` (in SoundService)
