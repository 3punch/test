-- GameManager (Script, Server)
-- Root game loop. Manages rounds, players, lobby, maze, professor, exit.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Teams = game:GetService("Teams")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

-- ========== REMOTES ==========
-- Create remotes FIRST so clients waiting on PlayerAdded can immediately find them.
local Remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
Remotes.Name = "Remotes"
Remotes.Parent = ReplicatedStorage

local function ensureRemote(name)
	local r = Remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = Remotes
	end
	return r
end

local GameEvent = ensureRemote("GameEvent")    -- Server->Client game state broadcasts
local SprintEvent = ensureRemote("SprintEvent") -- Client->Server: sprinting bool

-- Wait for shared module to exist before requiring it (defensive: server always
-- starts after ReplicatedStorage is populated, but belt-and-suspenders).
if not ReplicatedStorage:FindFirstChild("Shared", true) then
	-- Should never happen if Rojo/Manual setup put it in place, but fail gracefully
	task.wait(1)
end
local Config = require(ReplicatedStorage.Shared.GameConfig)
local MazeGenerator = require(script.Parent.MazeGenerator)
local ProfessorBuilder = require(script.Parent.ProfessorBuilder)
local ProfessorAI = require(script.Parent.ProfessorAI)

-- ========== WORKSPACE FOLDERS ==========
local function ensureFolder(parent, name)
	local f = parent:FindFirstChild(name) or Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local Lobby = ensureFolder(Workspace, "Lobby")
local ActiveMap = ensureFolder(Workspace, "ActiveMap")
local ExitFolder = ensureFolder(Workspace, "Exit")
local ProfessorsFolder = ensureFolder(Workspace, "Professors")

-- ========== BUILD LOBBY ==========
local function buildLobby()
	Lobby:ClearAllChildren()

	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Size = Config.LobbySize
	floor.Anchored = true
	floor.Position = Vector3.new(0, Config.FloorY - 0.5, 0)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Color = Color3.fromRGB(120, 120, 140)
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.BottomSurface = Enum.SurfaceType.Smooth
	floor.Parent = Lobby

	-- Walls
	local wallT = 2
	local size = Config.LobbySize
	local function wall(name, wpos, wsize)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = wsize
		p.Anchored = true
		p.Position = wpos
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(90, 90, 110)
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = Lobby
		return p
	end
	wall("WallN", Vector3.new(0, 8, -size.Z/2), Vector3.new(size.X, 16, wallT))
	wall("WallS", Vector3.new(0, 8,  size.Z/2), Vector3.new(size.X, 16, wallT))
	wall("WallW", Vector3.new(-size.X/2, 8, 0), Vector3.new(wallT, 16, size.Z))
	wall("WallE", Vector3.new( size.X/2, 8, 0), Vector3.new(wallT, 16, size.Z))

	-- Ceiling light
	local ceil = Instance.new("Part")
	ceil.Size = Vector3.new(size.X, 1, size.Z)
	ceil.Anchored = true
	ceil.Position = Vector3.new(0, 15.5, 0)
	ceil.Material = Enum.Material.SmoothPlastic
	ceil.Color = Color3.fromRGB(200, 200, 210)
	ceil.CanCollide = false
	ceil.Parent = Lobby

	local lightPart = Instance.new("Part")
	lightPart.Size = Vector3.new(20, 0.5, 4)
	lightPart.Anchored = true
	lightPart.Position = Vector3.new(0, 15, 0)
	lightPart.Material = Enum.Material.Neon
	lightPart.Color = Color3.fromRGB(255, 255, 255)
	lightPart.Parent = Lobby
	local pl = Instance.new("PointLight")
	pl.Brightness = 2
	pl.Range = 40
	pl.Color = Color3.fromRGB(255, 255, 255)
	pl.Parent = lightPart

	-- Spawn location for lobby (players teleport here between rounds)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, Config.FloorY, 0)
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Neutral = true
	spawn.Color = Color3.fromRGB(80, 180, 255)
	spawn.Material = Enum.Material.Neon
	spawn.Parent = Lobby

	-- Sign
	local sign = Instance.new("Part")
	sign.Size = Vector3.new(30, 4, 1)
	sign.Anchored = true
	sign.Position = Vector3.new(0, 10, -size.Z/2 + 3)
	sign.Material = Enum.Material.SmoothPlastic
	sign.Color = Color3.fromRGB(40, 40, 50)
	sign.Parent = Lobby
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 20
	sg.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "PROFESSOR ESCAPE\nWaiting for players..."
	label.TextColor3 = Color3.fromRGB(255, 220, 100)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Parent = sg
end

buildLobby()

-- ========== ROUND STATE ==========
local WAITING = "WAITING"
local STARTING = "STARTING"
local PLAYING = "PLAYING"
local ROUND_END = "ROUND_END"

local Game = {
	State = WAITING,
	StateEndTime = tick() + Config.WaitingTime,
	MazeData = nil,
	Professor = nil, -- {Model, AI}
	ExitPart = nil,
	AlivePlayers = {}, -- [player] = true
	EscapedPlayers = {},
	SpectatorSet = {},
	RoundStartTime = 0,
	WinnerName = nil,
	EndReason = nil,
}

-- ========== PLAYER SETUP ==========
local function safeLoadCharacter(player)
	player:LoadCharacter()
	task.wait(0.3)
	local char = player.Character
	if not char then return end
	local hum = char:WaitForChild("Humanoid", 5)
	if hum then
		hum.WalkSpeed = Config.WalkSpeed
		hum.JumpPower = 50 -- keep simple jumping enabled, but jumping over walls is impossible due to wall height
	end
end

local function teleportToLobby(player)
	local spawn = Lobby:FindFirstChild("LobbySpawn", true)
	if not spawn then return end
	local char = player.Character
	if char and char:FindFirstChild("HumanoidRootPart") then
		char:MoveTo(spawn.Position + Vector3.new(math.random(-2,2), 3, math.random(-2,2)))
		char:SetAttribute("Spectating", false)
		char:SetAttribute("InMaze", false)
	end
end

local function resetPlayerForRound(player)
	safeLoadCharacter(player)
	player.Team = Teams.Players
	player.Neutral = false
	task.wait(0.3)
	local char = player.Character
	if char then
		char:SetAttribute("Spectating", false)
		char:SetAttribute("Sprinting", false)
		char:SetAttribute("InMaze", false)
		char:SetAttribute("Stamina", Config.MaxStamina)
		-- Re-enable collisions (we turn them off for spectators)
		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = true
			end
		end
		local hum = char:FindFirstChild("Humanoid")
		if hum then
			hum.WalkSpeed = Config.WalkSpeed
			hum:ChangeState(Enum.HumanoidStateType.RunningNoPhysics)
		end
	end
	teleportToLobby(player)
end

local function makeSpectator(player)
	player.Team = Teams.Spectators
	local char = player.Character
	if char then
		char:SetAttribute("Spectating", true)
		char:SetAttribute("Sprinting", false)
		local hum = char:FindFirstChild("Humanoid")
		local root = char:FindFirstChild("HumanoidRootPart")
		-- Sit the player to immobilize them, disable collisions so they don't
		-- block other players or the professor.
		if hum then
			hum.WalkSpeed = 0
			hum.JumpPower = 0
			hum.Sit = true
		end
		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
		-- Anchor them high above the maze so they're out of the way.
		if root and Game.MazeData then
			-- Sit causes the root to be positioned about 2 studs above the seat;
			-- we compensate by placing a seat part they sit on.
			local seat = Instance.new("Seat")
			seat.Size = Vector3.new(4, 1, 4)
			seat.Anchored = true
			seat.CanCollide = true
			seat.Transparency = 1
			seat.Position = Vector3.new(
				Game.MazeData.ExitPos.X,
				Config.WallHeight + 40,
				Game.MazeData.ExitPos.Z
			)
			seat.Parent = Workspace
			-- Teleport the humanoid directly into the seat
			root.CFrame = CFrame.new(seat.Position + Vector3.new(0, 3, 0))
			if hum then
				hum.Sit = true
				seat:Sit(hum)
			end
			-- Clean up seat when next round starts (we clear ActiveMap next round but
			-- seat is in Workspace; tag it for cleanup)
			seat.Name = "SpectatorSeat_" .. player.UserId
			Debris:AddItem(seat, Config.RoundEndTime + Config.StartingTime + Config.WaitingTime + 2)
		end
	end
	GameEvent:FireClient(player, "Spectate")
end

-- Handle sprint toggle sent by client. Rate-limited and validated server-side.
local sprintCooldowns = {}
SprintEvent.OnServerEvent:Connect(function(player, state)
	if typeof(state) ~= "boolean" then return end
	local now = tick()
	local last = sprintCooldowns[player] or 0
	if now - last < 0.05 then return end -- 20hz max
	sprintCooldowns[player] = now

	local char = player.Character
	if not char then return end
	if char:GetAttribute("Spectating") then return end
	local hum = char:FindFirstChild("Humanoid")
	if not hum then return end
	if Game.State ~= PLAYING then
		char:SetAttribute("Sprinting", false)
		return
	end
	if not char:GetAttribute("InMaze") then
		char:SetAttribute("Sprinting", false)
		return
	end
	local stam = char:GetAttribute("Stamina")
	if stam == nil then
		stam = Config.MaxStamina
		char:SetAttribute("Stamina", stam)
	end
	if state and stam > 3 then
		char:SetAttribute("Sprinting", true)
	else
		char:SetAttribute("Sprinting", false)
	end
end)

-- ========== EXIT DETECTION ==========
local function buildExit(pos)
	ExitFolder:ClearAllChildren()
	local pad = Instance.new("Part")
	pad.Name = "ExitPad"
	pad.Size = Config.ExitPadSize
	pad.Anchored = true
	pad.CanCollide = false
	pad.Position = Vector3.new(pos.X, 0.4, pos.Z)
	pad.Material = Enum.Material.Neon
	pad.Color = Config.ExitColor
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.BottomSurface = Enum.SurfaceType.Smooth
	pad.Transparency = 0.2
	pad.Parent = ExitFolder

	local light = Instance.new("PointLight")
	light.Brightness = 3
	light.Range = 30
	light.Color = Config.ExitLightColor
	light.Parent = pad

	local labelPart = Instance.new("Part")
	labelPart.Size = Vector3.new(6, 3, 0.5)
	labelPart.Anchored = true
	labelPart.CanCollide = false
	labelPart.Position = pos + Vector3.new(0, 3, 0)
	labelPart.Material = Enum.Material.SmoothPlastic
	labelPart.Color = Color3.fromRGB(20, 20, 20)
	labelPart.Parent = ExitFolder
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 30
	sg.Parent = labelPart
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = "EXIT"
	tl.TextColor3 = Color3.fromRGB(80, 255, 120)
	tl.TextScaled = true
	tl.Font = Enum.Font.SourceSansBold
	tl.Parent = sg

	pad.Touched:Connect(function(hit)
		local hum = hit.Parent:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if not player then return end
		if player.Team == Teams.Spectators then return end
		if Game.State ~= PLAYING then return end
		if Game.EscapedPlayers[player] then return end
		escapePlayer(player)
	end)

	Game.ExitPart = pad
end

function escapePlayer(player)
	Game.EscapedPlayers[player] = true
	Game.AlivePlayers[player] = nil
	GameEvent:FireClient(player, "YouEscaped")
	GameEvent:FireAllClients("PlayerEscaped", player.Name)
	-- Make them a winner/spectator so they can watch
	makeSpectator(player)
	Game.WinnerName = player.Name
	Game.EndReason = "Escape"
	endRound()
end

function catchPlayer(player)
	if Game.SpectatorSet[player] or Game.EscapedPlayers[player] then return end
	Game.AlivePlayers[player] = nil
	Game.SpectatorSet[player] = true
	GameEvent:FireClient(player, "YouCaught")
	GameEvent:FireAllClients("PlayerCaught", player.Name)
	makeSpectator(player)
	-- Check if all alive players are gone
	local aliveCount = 0
	for _ in pairs(Game.AlivePlayers) do aliveCount = aliveCount + 1 end
	if aliveCount == 0 then
		Game.EndReason = "AllCaught"
		Game.WinnerName = nil
		endRound()
	end
end

-- ========== ROUND LIFECYCLE ==========
local function broadcastState()
	local timeLeft = math.max(0, Game.StateEndTime - tick())
	GameEvent:FireAllClients("State", Game.State, timeLeft, {
		alive = countAlive(),
		winner = Game.WinnerName,
		reason = Game.EndReason,
	})
end

function countAlive()
	local n = 0
	for _ in pairs(Game.AlivePlayers) do n = n + 1 end
	return n
end

local function startWaiting()
	Game.State = WAITING
	Game.StateEndTime = tick() + Config.WaitingTime
	Game.WinnerName = nil
	Game.EndReason = nil
	Game.AlivePlayers = {}
	Game.EscapedPlayers = {}
	Game.SpectatorSet = {}

	-- Stop any existing professor AI (disconnects its heartbeat connection) before
	-- we destroy its model. This prevents leaked connections / stale AI loops.
	if Game.Professor and Game.Professor.AI then
		Game.Professor.AI:Stop()
		Game.Professor = nil
	end

	-- Clear previous round
	ProfessorsFolder:ClearAllChildren()
	ExitFolder:ClearAllChildren()
	ActiveMap:ClearAllChildren()

	-- Clear spectator seats from last round
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Seat") and child.Name:sub(1, 14) == "SpectatorSeat_" then
			child:Destroy()
		end
	end

	-- Reset all players
	for _, p in ipairs(Players:GetPlayers()) do
		resetPlayerForRound(p)
		teleportToLobby(p)
	end

	broadcastState()
end

local function startCountdown()
	Game.State = STARTING
	Game.StateEndTime = tick() + Config.StartingTime
	broadcastState()
end

local function startPlaying()
	-- Generate maze
	Game.MazeData = MazeGenerator.Generate(ActiveMap)
	buildExit(Game.MazeData.ExitPos)

	-- Teleport players to spawn points in maze
	local spawns = Game.MazeData.SpawnCandidates
	local playerList = Players:GetPlayers()
	for i, p in ipairs(playerList) do
		safeLoadCharacter(p)
		p.Team = Teams.Players
		Game.AlivePlayers[p] = true
		Game.EscapedPlayers[p] = false
		Game.SpectatorSet[p] = false
		local spawnPos = spawns[((i - 1) % #spawns) + 1]
		-- Slight jitter to avoid overlapping characters
		local jitter = Vector3.new(math.random(-2,2), 0, math.random(-2,2))
		task.wait(0.05)
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChild("Humanoid")
		if char and root and hum then
			char:MoveTo(spawnPos + jitter)
			char:SetAttribute("Spectating", false)
			char:SetAttribute("InMaze", true)
			char:SetAttribute("Stamina", Config.MaxStamina)
			char:SetAttribute("Sprinting", false)
			hum.WalkSpeed = Config.WalkSpeed
		end
	end

	-- Spawn professor
	local profModel = ProfessorBuilder.Build()
	profModel.Parent = ProfessorsFolder
	local profAI = ProfessorAI.new(profModel)
	profAI.OnCatchPlayer = catchPlayer
	profAI:Start(Game.MazeData.ProfessorSpawn)
	Game.Professor = {Model = profModel, AI = profAI}

	Game.State = PLAYING
	Game.RoundStartTime = tick()
	Game.StateEndTime = tick() + Config.RoundTimeMax
	broadcastState()
end

function endRound()
	if Game.State == ROUND_END then return end
	-- Stop professor
	if Game.Professor and Game.Professor.AI then
		Game.Professor.AI:Stop()
	end
	Game.State = ROUND_END
	Game.StateEndTime = tick() + Config.RoundEndTime
	GameEvent:FireAllClients("RoundEnd", Game.EndReason, Game.WinnerName)
end

-- ========== MAIN LOOP ==========
local lastBroadcast = 0
local mainLoopConn
mainLoopConn = RunService.Heartbeat:Connect(function(dt)
	local now = tick()

	if Game.State == WAITING then
		-- Need at least 1 player to start. Wait for min waiting time and at least 1 player.
		local playerCount = #Players:GetPlayers()
		if playerCount == 0 then
			-- keep extending timer until someone joins
			Game.StateEndTime = now + Config.WaitingTime
		elseif now >= Game.StateEndTime then
			startCountdown()
		end
	elseif Game.State == STARTING then
		if now >= Game.StateEndTime then
			startPlaying()
		end
	elseif Game.State == PLAYING then
		if now >= Game.StateEndTime then
			-- time up -> everyone loses
			Game.EndReason = "TimeUp"
			endRound()
		end

		-- Server-side stamina update
		for player in pairs(Game.AlivePlayers) do
			local char = player.Character
			if char then
				local hum = char:FindFirstChild("Humanoid")
				local root = char:FindFirstChild("HumanoidRootPart")
				if hum and root then
					local stam = char:GetAttribute("Stamina") or Config.MaxStamina
					local sprinting = char:GetAttribute("Sprinting") == true
					-- Only actually sprint if moving forward
					local moving = hum.MoveDirection.Magnitude > 0.2
					if sprinting and moving and stam > 0 then
						stam = math.max(0, stam - Config.StaminaDrainPerSecond * dt)
						hum.WalkSpeed = Config.SprintSpeed
						if stam <= 0 then
							char:SetAttribute("Sprinting", false)
						end
						char:SetAttribute("LastSprintTime", now)
					else
						-- Short delay before regen kicks in
						local lastSprint = char:GetAttribute("LastSprintTime") or 0
						if now - lastSprint > Config.StaminaCooldown then
							stam = math.min(Config.MaxStamina, stam + Config.StaminaRegenPerSecond * dt)
						end
						hum.WalkSpeed = Config.WalkSpeed
					end
					char:SetAttribute("Stamina", stam)
				end
			end
		end

		-- Backup exit check: distance-based (so even if Touched misses due to
		-- high speed / spawn geometry, stepping onto the pad always works)
		if Game.ExitPart then
			local exitPos = Game.ExitPart.Position
			local checkRadius = 5  -- studs; same size as half the pad
			for player in pairs(Game.AlivePlayers) do
				local char = player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if root then
					local dx = root.Position.X - exitPos.X
					local dz = root.Position.Z - exitPos.Z
					local dist2 = dx*dx + dz*dz
					if dist2 < checkRadius*checkRadius and math.abs(root.Position.Y - exitPos.Y) < 4 then
						escapePlayer(player)
						break
					end
				end
			end
		end

		-- Flickering lights occasionally (atmosphere)
		local maze = ActiveMap:FindFirstChild("Maze")
		if maze then
			local lights = maze:FindFirstChild("Lights")
			if lights and math.random() < 0.004 then
				local light = lights:GetChildren()[math.random(1, #lights:GetChildren())]
				if light and light:IsA("BasePart") then
					local pl = light:FindFirstChildOfClass("PointLight")
					if pl then
						local oldBright = pl.Brightness
						pl.Brightness = 0
						task.delay(0.15, function()
							if pl then pl.Brightness = oldBright end
						end)
					end
				end
			end
		end
	elseif Game.State == ROUND_END then
		if now >= Game.StateEndTime then
			startWaiting()
		end
	end

	-- Broadcast state at ~10hz
	if now - lastBroadcast > 0.1 then
		lastBroadcast = now
		broadcastState()
		-- also send stamina per alive player (targeted)
		for player in pairs(Game.AlivePlayers) do
			local char = player.Character
			if char then
				local stam = char:GetAttribute("Stamina") or Config.MaxStamina
				GameEvent:FireClient(player, "Stamina", stam)
			end
		end
	end
end)

-- ========== PLAYER JOIN/LEAVE ==========
Players.PlayerAdded:Connect(function(player)
	-- Attach CharacterAdded listener immediately (synchronous)
	player.Team = Teams.Players
	player.CharacterAdded:Connect(function(char)
		local hum = char:WaitForChild("Humanoid")
		char:SetAttribute("Stamina", Config.MaxStamina)
		char:SetAttribute("Sprinting", false)
		char:SetAttribute("Spectating", false)
		char:SetAttribute("InMaze", false)
		hum.Died:Connect(function()
			-- If they die during the round for any reason, treat as caught
			if Game.State == PLAYING and Game.AlivePlayers[player] then
				task.delay(1.5, function()
					if Game.AlivePlayers[player] then
						catchPlayer(player)
					end
				end)
			end
		end)
	end)
	-- Do remaining setup (which may yield) in a separate thread so we don't block
	-- future PlayerAdded events.
	task.spawn(function()
		task.wait(1)
		if not player:IsDescendantOf(game) then return end
		if player.Character then
			teleportToLobby(player)
		else
			safeLoadCharacter(player)
			task.wait(0.3)
			if player.Character then
				teleportToLobby(player)
			end
		end
		-- If we're mid-round, respawn and make them a spectator
		if Game.State == PLAYING then
			Game.SpectatorSet[player] = true
			if not player.Character then safeLoadCharacter(player); task.wait(0.5) end
			makeSpectator(player)
		elseif Game.State == WAITING then
			-- If we had 0 players and now >=1, give some time before starting
			if #Players:GetPlayers() >= 1 then
				local timeLeft = Game.StateEndTime - tick()
				if timeLeft < 2 then
					Game.StateEndTime = tick() + 4
				end
			end
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	Game.AlivePlayers[player] = nil
	Game.EscapedPlayers[player] = nil
	Game.SpectatorSet[player] = nil
	-- If it was playing and everyone left, go back to waiting
	if Game.State == PLAYING and countAlive() == 0 and next(Game.EscapedPlayers) == nil then
		endRound()
	end
end)

-- ========== CONFIGURE ATMOSPHERE ==========
Lighting.Brightness = 1.5
Lighting.Ambient = Color3.fromRGB(90, 82, 72)
Lighting.OutdoorAmbient = Color3.fromRGB(90, 82, 72)
Lighting.FogEnd = 180
Lighting.FogStart = 40
Lighting.FogColor = Color3.fromRGB(180, 165, 140)
Lighting.GlobalShadows = true
Lighting.ClockTime = 12
-- Set ambient reverb for an eerie hallway feel (ignore if enum name differs across Roblox versions)
pcall(function() SoundService.AmbientReverb = Enum.ReverbType.Hallway end)

-- Configure starter player settings (server-authoritative fallback)
local StarterPlayer = game:GetService("StarterPlayer")
StarterPlayer.CharacterWalkSpeed = Config.WalkSpeed
StarterPlayer.CharacterJumpPower = 50
StarterPlayer.EnableMouseLockOption = true

-- Ensure Teams exist
local function ensureTeam(name, colorName, auto)
	local t = Teams:FindFirstChild(name)
	if not t then
		t = Instance.new("Team")
		t.Name = name
		t.TeamColor = BrickColor.new(colorName)
		t.AutoAssignable = auto
		t.Parent = Teams
	end
	return t
end
ensureTeam("Players", "Bright blue", true)
ensureTeam("Spectators", "Bright red", false)

-- Configure respawn
Players.CharacterAutoLoads = true
Players.RespawnTime = 1

-- Set up initial state
startWaiting()
