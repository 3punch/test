-- ClientMain (LocalScript)
-- Handles client-side UI, sprint input, stamina bar, spectator camera, and audio.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")

local localPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameEvent = Remotes:WaitForChild("GameEvent")
local SprintEvent = Remotes:WaitForChild("SprintEvent")

-- Wait for game config to exist
local Config = require(ReplicatedStorage.Shared:WaitForChild("GameConfig"))

-- ========== BUILD UI ==========
local gui = script.Parent:FindFirstChild("GameUIGui") or Instance.new("ScreenGui")
gui.Name = "GameUIGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- Remove any old copy
if gui.Parent then gui.Parent = nil end
gui.Parent = localPlayer:WaitForChild("PlayerGui")

-- Top status bar
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 46)
topBar.Position = UDim2.new(0, 0, 0, 0)
topBar.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
topBar.BackgroundTransparency = 0.3
topBar.BorderSizePixel = 0
topBar.Parent = gui

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(0.6, 0, 1, 0)
statusLabel.Position = UDim2.new(0.2, 0, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
statusLabel.TextScaled = true
statusLabel.Font = Enum.Font.SourceSansBold
statusLabel.Text = "Waiting..."
statusLabel.Parent = topBar

local aliveLabel = Instance.new("TextLabel")
aliveLabel.Size = UDim2.new(0.2, 0, 1, 0)
aliveLabel.Position = UDim2.new(0.8, 0, 0, 0)
aliveLabel.BackgroundTransparency = 1
aliveLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
aliveLabel.TextScaled = true
aliveLabel.Font = Enum.Font.SourceSansSemibold
aliveLabel.Text = "Alive: 0"
aliveLabel.Parent = topBar

-- Bottom stamina bar
local staminaFrame = Instance.new("Frame")
staminaFrame.Name = "StaminaFrame"
staminaFrame.Size = UDim2.new(0, 260, 0, 18)
staminaFrame.Position = UDim2.new(0.5, -130, 1, -40)
staminaFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
staminaFrame.BorderSizePixel = 0
staminaFrame.BackgroundTransparency = 0.3
staminaFrame.Parent = gui

local staminaBar = Instance.new("Frame")
staminaBar.Size = UDim2.new(1, -6, 1, -6)
staminaBar.Position = UDim2.new(0, 3, 0, 3)
staminaBar.BackgroundColor3 = Color3.fromRGB(255, 220, 80)
staminaBar.BorderSizePixel = 0
staminaBar.Parent = staminaFrame

local staminaLabel = Instance.new("TextLabel")
staminaLabel.Size = UDim2.fromScale(1, 1)
staminaLabel.BackgroundTransparency = 1
staminaLabel.TextColor3 = Color3.fromRGB(0, 0, 0)
staminaLabel.Font = Enum.Font.SourceSansBold
staminaLabel.TextScaled = true
staminaLabel.Text = "STAMINA"
staminaLabel.Parent = staminaFrame

-- Center big message overlay
local centerMsg = Instance.new("TextLabel")
centerMsg.Name = "CenterMsg"
centerMsg.Size = UDim2.new(0.8, 0, 0, 120)
centerMsg.Position = UDim2.new(0.1, 0, 0.4, -60)
centerMsg.BackgroundTransparency = 1
centerMsg.TextColor3 = Color3.fromRGB(255, 80, 80)
centerMsg.TextScaled = true
centerMsg.Font = Enum.Font.SourceSansBold
centerMsg.Text = ""
centerMsg.TextStrokeTransparency = 0
centerMsg.Visible = false
centerMsg.Parent = gui

-- Helper function to flash center message
local function showCenter(text, color, seconds)
	centerMsg.Text = text
	centerMsg.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	centerMsg.Visible = true
	if seconds then
		task.delay(seconds, function()
			if centerMsg.Text == text then
				centerMsg.Visible = false
			end
		end)
	end
end

-- ========== SPRINT INPUT ==========
local isSprinting = false
local function setSprint(state)
	if isSprinting == state then return end
	isSprinting = state
	SprintEvent:FireServer(state)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		setSprint(true)
	end
end)

UserInputService.InputEnded:Connect(function(input, processed)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		setSprint(false)
	end
end)

-- Also stop sprint if chat / any reason
UserInputService.WindowFocusReleased:Connect(function() setSprint(false) end)

-- ========== SOUNDS ==========
local function playLocalSound(name, props)
	local char = localPlayer.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end
	local s = head:FindFirstChild(name)
	if not s then
		s = Instance.new("Sound")
		s.Name = name
		s.Parent = head
	end
	for k, v in pairs(props or {}) do s[k] = v end
	s:Play()
	return s
end

-- Footstep handling: simple client-side step sound while running
local lastFootstep = 0
RunService.Heartbeat:Connect(function()
	local char = localPlayer.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) then return end
	local moving = hum.MoveDirection.Magnitude > 0.2
	if moving and hum.Health > 0 then
		local speed = hum.WalkSpeed
		local interval = speed >= Config.SprintSpeed - 1 and 0.3 or 0.45
		local now = tick()
		if now - lastFootstep > interval then
			lastFootstep = now
			-- Footstep sound (placeholder): rely on Roblox default footstep by
			-- using no SoundId. Replace with a proper asset id for polish.
			local s = Instance.new("Sound")
			s.Volume = 0.2
			s.SoundId = ""
			s.Parent = root
			s:Play()
			game:GetService("Debris"):AddItem(s, 0.3)
		end
	end
end)

-- ========== SPECTATOR CAMERA ==========
local spectating = false
local spectateTarget = nil

local function pickSpectateTarget()
	local players = Players:GetPlayers()
	local candidates = {}
	for _, p in ipairs(players) do
		if p ~= localPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
			local attr = p.Character:GetAttribute("Spectating")
			if not attr then
				table.insert(candidates, p)
			end
		end
	end
	if #candidates == 0 then return nil end
	-- pick near previous if possible
	if spectateTarget and table.find(candidates, spectateTarget) then
		return spectateTarget
	end
	return candidates[math.random(1, #candidates)]
end

local camConn = nil
local function startSpectator()
	spectating = true
	if camConn then camConn:Disconnect() end
	local cam = Workspace.CurrentCamera
	camConn = RunService.RenderStepped:Connect(function()
		if not spectating then return end
		spectateTarget = pickSpectateTarget()
		if spectateTarget and spectateTarget.Character and spectateTarget.Character:FindFirstChild("HumanoidRootPart") then
			local root = spectateTarget.Character.HumanoidRootPart
			local offset = Vector3.new(0, 14, 22)
			cam.CameraType = Enum.CameraType.Scriptable
			local pos = root.Position + offset
			-- Look at the player but at eye height
			cam.CFrame = CFrame.new(pos, Vector3.new(root.Position.X, root.Position.Y + 2, root.Position.Z))
		else
			local activeMap = Workspace:FindFirstChild("ActiveMap")
			local maze = activeMap and activeMap:FindFirstChild("Maze")
			if maze and maze:FindFirstChild("Floor") then
				local f = maze.Floor
				local center = f.Position
				cam.CameraType = Enum.CameraType.Scriptable
				cam.CFrame = CFrame.new(center + Vector3.new(0, 120, 60), center)
			else
				-- fallback to lobby
				cam.CameraType = Enum.CameraType.Custom
			end
		end
	end)
end

local function stopSpectator()
	spectating = false
	if camConn then
		camConn:Disconnect()
		camConn = nil
	end
	local cam = Workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Custom
end

-- ========== SERVER EVENT HANDLING ==========
GameEvent.OnClientEvent:Connect(function(event, ...)
	local args = {...}
	if event == "State" then
		local state, timeLeft, info = args[1], args[2], args[3]
		local display = ""
		if state == "WAITING" then
			display = string.format("Waiting for players... %ds", math.ceil(timeLeft))
		elseif state == "STARTING" then
			display = string.format("Starting in %d...", math.ceil(timeLeft))
		elseif state == "PLAYING" then
			local mins = math.floor(timeLeft / 60)
			local secs = math.floor(timeLeft % 60)
			display = string.format("Escape the professor!  %d:%02d", mins, secs)
		elseif state == "ROUND_END" then
			display = "Round over..."
		end
		statusLabel.Text = display
		if info then
			aliveLabel.Text = "Alive: " .. tostring(info.alive or 0)
		end

		if state == "STARTING" then
			if math.ceil(timeLeft) <= 5 and math.ceil(timeLeft) > 0 then
				showCenter(tostring(math.ceil(timeLeft)), Color3.fromRGB(255, 200, 60), 0.8)
			end
		end

		-- Show stamina when playing
		staminaFrame.Visible = (state == "PLAYING")

	elseif event == "Stamina" then
		local stam = args[1]
		local ratio = math.clamp(stam / Config.MaxStamina, 0, 1)
		-- Bar inner is inset by 3px on each side; scale width proportionally
		staminaBar.Size = UDim2.new(ratio, -6 * ratio, 1, -6)
		if ratio < 0.2 then
			staminaBar.BackgroundColor3 = Color3.fromRGB(220, 60, 40)
		elseif ratio < 0.5 then
			staminaBar.BackgroundColor3 = Color3.fromRGB(220, 180, 60)
		else
			staminaBar.BackgroundColor3 = Color3.fromRGB(100, 220, 120)
		end

	elseif event == "Spectate" then
		startSpectator()
		staminaFrame.Visible = false
		showCenter("YOU WERE CAUGHT!\nSpectating...", Color3.fromRGB(255, 80, 80), 4)

	elseif event == "YouEscaped" then
		stopSpectator()
		showCenter("YOU ESCAPED!", Color3.fromRGB(100, 255, 120), 5)
		playLocalSound("Escape", { Volume = 0.7, SoundId = "" })

	elseif event == "YouCaught" then
		playLocalSound("Caught", { Volume = 0.7, SoundId = "" })
		showCenter("CAUGHT!", Color3.fromRGB(255, 60, 60), 2)

	elseif event == "PlayerEscaped" then
		local name = args[1]
		showCenter(name .. " ESCAPED!", Color3.fromRGB(100, 255, 120), 3)

	elseif event == "PlayerCaught" then
		local name = args[1]
		showCenter(name .. " was caught!", Color3.fromRGB(255, 100, 100), 2)

	elseif event == "RoundEnd" then
		local reason, winner = args[1], args[2]
		if reason == "Escape" then
			showCenter((winner or "Someone") .. " escaped!\nReturning to lobby...",
				Color3.fromRGB(100, 255, 120), 4)
		elseif reason == "AllCaught" then
			showCenter("The professor caught everyone!\nReturning to lobby...",
				Color3.fromRGB(255, 80, 80), 4)
		elseif reason == "TimeUp" then
			showCenter("Time ran out!\nReturning to lobby...",
				Color3.fromRGB(255, 160, 60), 4)
		end
	end
end)

-- Reset sprint state on respawn
localPlayer.CharacterAdded:Connect(function()
	isSprinting = false
	SprintEvent:FireServer(false)
	stopSpectator()
end)

-- Release sprint on death (Humanoid.Died) and on removal of character
localPlayer.CharacterRemoving:Connect(function()
	isSprinting = false
	stopSpectator()
end)

-- ========== AMBIENT SOUND ==========
-- Placeholder ambient hum (no SoundId = silent by default; set SoundId to a
-- real asset id for polish). SoundService.Parent = SoundService keeps it 2D.
local ambient = Instance.new("Sound")
ambient.Name = "AmbientHum"
ambient.Looped = true
ambient.Volume = 0.1
ambient.SoundId = ""
ambient.Parent = SoundService
ambient:Play()

-- Attempt to set startergui
pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true) end)
