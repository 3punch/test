-- ProfessorAI (ModuleScript, Server)
-- Drives the Professor NPC using Roblox Humanoid:MoveTo + PathfindingService.
-- Humanoid movement automatically handles collisions, so the professor cannot
-- walk through walls.
local Config = require(game.ReplicatedStorage.Shared.GameConfig)

local ProfessorAI = {}
ProfessorAI.__index = ProfessorAI

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local PATROL = "PATROL"
local CHASE = "CHASE"
local BURST_WARNING = "BURST_WARNING"
local BURST = "BURST"

function ProfessorAI.new(model)
	local self = setmetatable({}, ProfessorAI)
	self.Model = model
	self.Humanoid = model:WaitForChild("Humanoid")
	self.Humanoid.WalkSpeed = Config.ProfessorWalkSpeed
	self.Humanoid.JumpPower = 0
	self.Humanoid.JumpHeight = 0
	self.PrimaryPart = model.PrimaryPart
	self.Root = model:WaitForChild("HumanoidRootPart")

	self.State = PATROL
	self.TargetPlayer = nil
	self.LastPathCompute = 0
	self.CurrentWaypoints = nil
	self.CurrentWaypointIdx = 1
	self.CurrentPath = nil
	self.PatrolTarget = nil
	self.LastPatrolPick = 0

	self.BurstCooldownEnd = tick() + Config.BurstCooldown * math.random()
	self.BurstWarningEnd = 0
	self.BurstEnd = 0
	self.LastFootstep = 0

	self.Active = false
	self.OnCatchPlayer = nil
	self.Connection = nil
	self.MoveToConn = nil
	self.BlockedConn = nil
	self.StuckCheckTime = 0
	self.LastPosition = nil
	self.BurstLight = model:FindFirstChild("BurstLight", true)
	self.Sounds = model:FindFirstChild("Sounds")

	return self
end

function ProfessorAI:Start(spawnPos)
	self.Active = true
	self.State = PATROL
	self.Speed = Config.ProfessorWalkSpeed
	self.Humanoid.WalkSpeed = Config.ProfessorWalkSpeed

	-- Position the HumanoidRootPart high enough that the Humanoid lands cleanly on
	-- the floor. Humanoid physics will settle the model; giving it a 6-stud drop
	-- avoids clipping through walls/floor when the model is parented.
	self.Root.CFrame = CFrame.new(spawnPos.X, 6, spawnPos.Z)

	-- Listen for MoveToFinished so we can advance waypoints
	if self.MoveToConn then self.MoveToConn:Disconnect() end
	self.MoveToConn = self.Humanoid.MoveToFinished:Connect(function(reached)
		self:OnMoveToFinished(reached)
	end)

	-- Put NPC into running state so it doesn't ragdoll/fall
	self.Humanoid:ChangeState(Enum.HumanoidStateType.Running)

	self.Connection = RunService.Heartbeat:Connect(function(dt)
		if not self.Active then return end
		self:Update(dt)
	end)
end

function ProfessorAI:Stop()
	self.Active = false
	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end
	if self.MoveToConn then
		self.MoveToConn:Disconnect()
		self.MoveToConn = nil
	end
	if self.BlockedConn then
		self.BlockedConn:Disconnect()
		self.BlockedConn = nil
	end
	-- Stop chase/burst sounds
	if self.Sounds then
		local chase = self.Sounds:FindFirstChild("Chase")
		local burst = self.Sounds:FindFirstChild("BurstActive")
		if chase then chase:Stop() end
		if burst then burst:Stop() end
	end
	self:SetBurstLight(0)
	pcall(function() self.Humanoid:MoveTo(self.Root.Position) end)
end

function ProfessorAI:GetAlivePlayers()
	local alive = {}
	for _, p in ipairs(game.Players:GetPlayers()) do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChild("Humanoid")
		if root and hum and hum.Health > 0 and char:GetAttribute("Spectating") ~= true then
			table.insert(alive, p)
		end
	end
	return alive
end

function ProfessorAI:FindNearestVisiblePlayer()
	local myPos = self.Root.Position
	local best, bestDist = nil, Config.ProfessorDetectionRange

	for _, p in ipairs(self:GetAlivePlayers()) do
		local char = p.Character
		local pRoot = char and char:FindFirstChild("HumanoidRootPart")
		if pRoot then
			local offset = pRoot.Position - myPos
			local dist = offset.Magnitude
			if dist < bestDist then
				-- LoS check
				local params = RaycastParams.new()
				params.FilterDescendantsInstances = {self.Model, char}
				params.FilterType = Enum.RaycastFilterType.Blacklist
				local hit = workspace:Raycast(
					myPos + Vector3.new(0, 1.5, 0),
					offset.Unit * (dist + 0.5),
					params
				)
				local visible = (hit == nil)
				if visible or dist < Config.ProfessorDetectionRange * 0.4 then
					bestDist = dist
					best = p
				end
			end
		end
	end
	return best, bestDist
end

function ProfessorAI:PickPatrolTarget()
	local myPos = self.Root.Position
	local maze = workspace.ActiveMap and workspace.ActiveMap:FindFirstChild("Maze")
	if not maze then
		return myPos + Vector3.new(math.random(-30,30), 0, math.random(-30,30))
	end
	local floor = maze:FindFirstChild("Floor")
	if not floor then return myPos end
	local fp = floor.Position
	local half = floor.Size / 2
	-- math.random requires integer bounds, so snap the patrol area to whole studs.
	local minX, maxX = math.floor(fp.X - half.X + 6), math.floor(fp.X + half.X - 6)
	local minZ, maxZ = math.floor(fp.Z - half.Z + 6), math.floor(fp.Z + half.Z - 6)
	-- Degenerate (very small) maze: patrol around the floor center instead.
	if minX > maxX then minX, maxX = math.floor(fp.X), math.floor(fp.X) end
	if minZ > maxZ then minZ, maxZ = math.floor(fp.Z), math.floor(fp.Z) end
	-- Try a few times; if path compute fails just pick another
	for _ = 1, 8 do
		local tx = math.random(minX, maxX)
		local tz = math.random(minZ, maxZ)
		local target = Vector3.new(tx, 1, tz)
		if self:ComputePathTo(target) then
			return target
		end
	end
	return myPos
end

function ProfessorAI:ComputePathTo(targetPos)
	-- Disconnect previous blockage listener so we don't accumulate connections
	if self.BlockedConn then
		self.BlockedConn:Disconnect()
		self.BlockedConn = nil
	end
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 6,
		AgentCanJump = false,
		AgentCanClimb = false,
		WaypointSpacing = 4,
	})
	local ok, err = pcall(function()
		path:ComputeAsync(self.Root.Position, targetPos)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		self.CurrentPath = path
		self.CurrentWaypoints = path:GetWaypoints()
		self.CurrentWaypointIdx = 1
		-- Listen for blockages (one connection per path)
		self.BlockedConn = path.Blocked:Connect(function()
			if self.Active then
				self.CurrentPath = nil
				self.CurrentWaypoints = nil
				self.LastPathCompute = 0
			end
		end)
		self:MoveToNextWaypoint()
		return true
	end
	self.CurrentPath = nil
	self.CurrentWaypoints = nil
	return false
end

function ProfessorAI:MoveToNextWaypoint()
	if not self.CurrentWaypoints then return end
	-- Advance past any waypoint we've already reached
	while self.CurrentWaypointIdx <= #self.CurrentWaypoints do
		local wp = self.CurrentWaypoints[self.CurrentWaypointIdx]
		local here = self.Root.Position
		local dx = wp.Position.X - here.X
		local dz = wp.Position.Z - here.Z
		if math.sqrt(dx*dx + dz*dz) > 1.5 then
			self.Humanoid:MoveTo(wp.Position)
			return
		end
		self.CurrentWaypointIdx = self.CurrentWaypointIdx + 1
	end
	-- Reached end of path
	self.CurrentPath = nil
	self.CurrentWaypoints = nil
end

function ProfessorAI:OnMoveToFinished(reached)
	if not self.Active then return end
	if not self.CurrentWaypoints then return end
	if reached then
		self.CurrentWaypointIdx = self.CurrentWaypointIdx + 1
		self:MoveToNextWaypoint()
	else
		-- Didn't reach; force repath on next update
		self.CurrentPath = nil
		self.CurrentWaypoints = nil
		self.LastPathCompute = 0
	end
end

function ProfessorAI:PlayFootstep()
	local now = tick()
	local speed = self.Humanoid.WalkSpeed
	local interval = speed > 20 and 0.3 or (speed > 15 and 0.4 or 0.55)
	if now - self.LastFootstep < interval then return end
	if self.Humanoid.MoveDirection.Magnitude < 0.1 then return end
	self.LastFootstep = now
	local s = self.Sounds and self.Sounds:FindFirstChild("Footstep")
	if s then s:Play() end
end

function ProfessorAI:SetBurstLight(brightness)
	if not self.BurstLight then return end
	local pl = self.BurstLight:FindFirstChild("BurstPointLight")
	if pl then pl.Brightness = brightness end
	self.BurstLight.Transparency = brightness > 0 and 0 or 1
end

function ProfessorAI:Catch(player)
	local s = self.Sounds and self.Sounds:FindFirstChild("Catch")
	if s then s:Play() end
	if self.OnCatchPlayer then
		task.spawn(self.OnCatchPlayer, player)
	end
	-- Pause briefly after catching so the caught player's spectator transition can happen
	self.Humanoid:MoveTo(self.Root.Position)
	self.CurrentPath = nil
	self.CurrentWaypoints = nil
	self.LastPathCompute = tick() + 0.8
end

function ProfessorAI:Update(dt)
	local now = tick()

	-- Stuck detection: if we haven't moved meaningfully in 3s while supposed to be moving, repath.
	if self.State == CHASE or (self.State == PATROL and self.Speed > 1) then
		local moved = self.LastPosition and (self.Root.Position - self.LastPosition).Magnitude or 0
		if not self.LastPosition then
			self.LastPosition = self.Root.Position
			self.StuckCheckTime = now
		elseif moved < 0.3 and now - self.StuckCheckTime > 3 then
			-- Stuck! Force repath.
			self.CurrentPath = nil
			self.CurrentWaypoints = nil
			self.LastPathCompute = 0
			self.StuckCheckTime = now
			self.LastPosition = self.Root.Position
		elseif moved > 0.5 then
			self.StuckCheckTime = now
			self.LastPosition = self.Root.Position
		end
	else
		self.LastPosition = self.Root.Position
		self.StuckCheckTime = now
	end

	-- === Burst state machine ===
	if self.State ~= BURST and self.State ~= BURST_WARNING and now >= self.BurstCooldownEnd then
		if self.TargetPlayer then
			self.State = BURST_WARNING
			self.BurstWarningEnd = now + Config.BurstWarningTime
			self.Humanoid.WalkSpeed = Config.ProfessorChaseSpeed
			self.Speed = Config.ProfessorChaseSpeed
			self:SetBurstLight(3)
			local ws = self.Sounds and self.Sounds:FindFirstChild("BurstWarning")
			if ws then ws:Play() end
			-- Pause movement during warning
			self.Humanoid:MoveTo(self.Root.Position)
			self.CurrentPath = nil
		else
			self.BurstCooldownEnd = now + 5
		end
	end

	if self.State == BURST_WARNING then
		self.Humanoid:MoveTo(self.Root.Position)
		if now >= self.BurstWarningEnd then
			self.State = BURST
			self.BurstEnd = now + Config.BurstDuration
			self.Humanoid.WalkSpeed = Config.ProfessorBurstSpeed
			self.Speed = Config.ProfessorBurstSpeed
			local bs = self.Sounds and self.Sounds:FindFirstChild("BurstActive")
			if bs then bs:Play() end
			self.CurrentPath = nil
			self.LastPathCompute = 0
		end
	elseif self.State == BURST then
		if now >= self.BurstEnd then
			self.State = PATROL
			self.Humanoid.WalkSpeed = Config.ProfessorWalkSpeed
			self.Speed = Config.ProfessorWalkSpeed
			self.BurstCooldownEnd = now + Config.BurstCooldown
			self:SetBurstLight(0)
			local bs = self.Sounds and self.Sounds:FindFirstChild("BurstActive")
			if bs then bs:Stop() end
			self.TargetPlayer = nil
			self.CurrentPath = nil
			self.LastPathCompute = 0
		end
	end

	-- === Vision / targeting ===
	local seen, dist = self:FindNearestVisiblePlayer()
	if seen then
		local wasChasing = self.TargetPlayer
		self.TargetPlayer = seen
		if self.State ~= BURST and self.State ~= BURST_WARNING then
			self.State = CHASE
			self.Humanoid.WalkSpeed = Config.ProfessorChaseSpeed
			self.Speed = Config.ProfessorChaseSpeed
		end
		if not wasChasing then
			local cs = self.Sounds and self.Sounds:FindFirstChild("Chase")
			if cs then cs:Play() end
		end
		-- Force path update more frequently while chasing
		if self.CurrentPath and self.CurrentWaypoints then
			-- Check whether target has moved significantly since last compute
			-- We'll rely on the path update rate below; no need for per-frame recompute
		end

		if dist and dist <= Config.ProfessorCatchRange then
			self:Catch(seen)
			return
		end
	else
		if self.TargetPlayer then
			self.TargetPlayer = nil
			if self.State ~= BURST and self.State ~= BURST_WARNING then
				self.State = PATROL
				self.Humanoid.WalkSpeed = Config.ProfessorWalkSpeed
				self.Speed = Config.ProfessorWalkSpeed
				local cs = self.Sounds and self.Sounds:FindFirstChild("Chase")
				if cs then cs:Stop() end
				self.CurrentPath = nil
			end
		end
	end

	-- === Compute path as needed ===
	local targetPos = nil
	if self.TargetPlayer then
		local char = self.TargetPlayer.Character
		local pr = char and char:FindFirstChild("HumanoidRootPart")
		if pr then targetPos = pr.Position end
	else -- PATROL
		if not self.CurrentPath or (self.PatrolTarget and (self.PatrolTarget - self.Root.Position).Magnitude < 3)
		   or (not self.PatrolTarget) then
			if now - self.LastPatrolPick > 1 then
				self.LastPatrolPick = now
				self.PatrolTarget = self:PickPatrolTarget()
				targetPos = self.PatrolTarget
			end
		else
			targetPos = self.PatrolTarget
		end
	end

	-- Repath periodically while chasing to follow moving player
	local updateRate = self.TargetPlayer and 0.4 or 1.2
	if targetPos and (not self.CurrentPath or now - self.LastPathCompute > updateRate) then
		self.LastPathCompute = now
		self:ComputePathTo(targetPos)
	elseif self.CurrentPath and self.CurrentWaypoints and self.CurrentWaypointIdx <= #self.CurrentWaypoints then
		-- Make sure we're still moving toward current waypoint
		local wp = self.CurrentWaypoints[self.CurrentWaypointIdx]
		if wp and self.Humanoid.MoveDirection.Magnitude < 0.1 then
			self.Humanoid:MoveTo(wp.Position)
		end
	end

	self:PlayFootstep()
end

return ProfessorAI
