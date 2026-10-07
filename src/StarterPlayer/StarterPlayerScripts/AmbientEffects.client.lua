-- AmbientEffects (LocalScript)
-- Adds client-side atmosphere: distant fluorescent hum, subtle flicker,
-- and heartbeat/chase music when the professor is nearby.
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")

local localPlayer = Players.LocalPlayer

-- === Ambient hum (placed in SoundService so it follows the listener) ===
local hum = SoundService:FindFirstChild("FluorescentHum")
if not hum then
	hum = Instance.new("Sound")
	hum.Name = "FluorescentHum"
	hum.Looped = true
	hum.Volume = 0.15
	-- Placeholder empty sound. Replace SoundId with an asset id for polish.
	hum.SoundId = ""
	hum.Parent = SoundService
end
hum:Play()

-- === Proximity heartbeat when professor is near ===
local heartbeat = Instance.new("Sound")
heartbeat.Name = "Heartbeat"
heartbeat.Looped = true
heartbeat.Volume = 0
heartbeat.SoundId = ""
heartbeat.Parent = SoundService
heartbeat:Play()

-- Track nearest professor distance every 0.25 seconds
local lastCheck = 0
RunService.Heartbeat:Connect(function(dt)
	local now = tick()
	if now - lastCheck < 0.25 then return end
	lastCheck = now

	local char = localPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then heartbeat.Volume = 0 return end
	if char:GetAttribute("Spectating") then heartbeat.Volume = 0 return end

	local profs = Workspace:FindFirstChild("Professors")
	local minDist = math.huge
	if profs then
		for _, model in ipairs(profs:GetChildren()) do
			local pr = model:FindFirstChild("HumanoidRootPart")
			if pr then
				local d = (pr.Position - root.Position).Magnitude
				if d < minDist then minDist = d end
			end
		end
	end
	if minDist < 40 then
		-- Ramp up heartbeat volume the closer the professor is
		local vol = math.clamp((40 - minDist) / 40, 0, 1) * 0.5
		heartbeat.Volume = vol
	else
		heartbeat.Volume = 0
	end
end)

-- === Occasional random light flicker handled client-side for atmosphere ===
-- (Server also does a few, but client-side adds extra unpredictability with no network cost)
task.spawn(function()
	while true do
		task.wait(math.random(6, 15))
		local map = Workspace:FindFirstChild("ActiveMap")
		local maze = map and map:FindFirstChild("Maze")
		local lights = maze and maze:FindFirstChild("Lights")
		if lights then
			local list = lights:GetChildren()
			if #list > 0 then
				local pick = list[math.random(1, #list)]
				if pick:IsA("BasePart") then
					local pl = pick:FindFirstChildOfClass("PointLight")
					if pl then
						local orig = pl.Brightness
						pl.Brightness = 0
						task.wait(0.08 + math.random() * 0.15)
						if pl then pl.Brightness = orig end
					end
				end
			end
		end
	end
end)
