-- MazeGenerator (ModuleScript, Server)
-- Generates a solvable Backrooms-style maze using recursive backtracking
-- plus opens up some rooms/corridors for that repetitive office feel.
local Config = require(game.ReplicatedStorage.Shared.GameConfig)
local MazeGenerator = {}

-- Directions: 1=North,2=East,3=South,4=West
local DIRS = {
	[1] = {dx = 0, dy = -1, wall = "N", opposite = "S"},
	[2] = {dx = 1, dy = 0, wall = "E", opposite = "W"},
	[3] = {dx = 0, dy = 1, wall = "S", opposite = "N"},
	[4] = {dx = -1, dy = 0, wall = "W", opposite = "E"},
}

-- Returns {grid, width, height}
-- grid[y][x] = {N,E,S,W} boolean walls (true = wall present)
-- also includes a "visited" flag used during generation
local function createEmptyGrid(w, h)
	local grid = {}
	for y = 1, h do
		grid[y] = {}
		for x = 1, w do
			grid[y][x] = { N = true, E = true, S = true, W = true, visited = false, isRoom = false }
		end
	end
	return grid
end

-- Recursive backtracking to carve a perfect maze (always solvable)
local function carveMaze(grid, w, h)
	local stack = {}
	local startX, startY = math.random(1, w), math.random(1, h)
	grid[startY][startX].visited = true
	table.insert(stack, {x = startX, y = startY})

	while #stack > 0 do
		local current = stack[#stack]
		local x, y = current.x, current.y

		-- Gather unvisited neighbors
		local neighbors = {}
		for i = 1, 4 do
			local d = DIRS[i]
			local nx, ny = x + d.dx, y + d.dy
			if nx >= 1 and nx <= w and ny >= 1 and ny <= h and not grid[ny][nx].visited then
				table.insert(neighbors, {dir = d, nx = nx, ny = ny})
			end
		end

		if #neighbors > 0 then
			local pick = neighbors[math.random(1, #neighbors)]
			-- Knock down wall between current and neighbor
			local cell = grid[y][x]
			local ncell = grid[pick.ny][pick.nx]
			cell[pick.dir.wall] = false
			ncell[pick.dir.opposite] = false
			ncell.visited = true
			table.insert(stack, {x = pick.nx, y = pick.ny})
		else
			table.remove(stack)
		end
	end

	-- Reset visited for later use
	for y = 1, h do
		for x = 1, w do
			grid[y][x].visited = false
		end
	end
end

-- Open up some 2x2 and 3x3 "rooms" to break up the pure-corridor look
-- while preserving solvability (extra openings don't break a perfect maze)
local function addRooms(grid, w, h)
	local numRooms = math.floor((w * h) / 25)
	for _ = 1, numRooms do
		local rw = math.random(2, 3)
		local rh = math.random(2, 3)
		local rx = math.random(1, math.max(1, w - rw))
		local ry = math.random(1, math.max(1, h - rh))

		-- Knock down all internal walls
		for yy = ry, ry + rh - 1 do
			for xx = rx, rx + rw - 1 do
				grid[yy][xx].isRoom = true
				-- Open N wall if not on room top edge
				if yy > ry then
					grid[yy][xx].N = false
					grid[yy - 1][xx].S = false
				end
				-- Open W wall if not on room left edge
				if xx > rx then
					grid[yy][xx].W = false
					grid[yy][xx - 1].E = false
				end
			end
		end
	end
end

-- Build physical Part instances into a parent model.
-- Returns:
--   model (with Floor, Walls, Lights, Ceiling, SpawnPoints)
--   spawnPoints: list of Vector3 positions (center of cells)
--   exitCandidateCells: list of {x,y,pos} cells that are open, far from spawn
local function buildMazeModel(grid, w, h, parent)
	local cell = Config.CellSize
	local wallH = Config.WallHeight
	local half = cell / 2
	local center = Config.MazeCenterOffset

	-- Origin of the maze in world space (lower-left corner of grid)
	-- Center the maze around (center.x, center.z)
	local ox = center.x - (w * cell) / 2
	local oy = Config.FloorY
	local oz = center.z - (h * cell) / 2

	local model = Instance.new("Model")
	model.Name = "Maze"

	local wallFolder = Instance.new("Folder")
	wallFolder.Name = "Walls"
	wallFolder.Parent = model

	local lightFolder = Instance.new("Folder")
	lightFolder.Name = "Lights"
	lightFolder.Parent = model

	-- Floor
	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Size = Vector3.new(w * cell, 1, h * cell)
	floor.Anchored = true
	floor.CanCollide = true
	floor.Position = Vector3.new(ox + w * cell / 2, oy - 0.5, oz + h * cell / 2)
	floor.Material = Enum.Material.Fabric -- simulates carpet
	floor.Color = Config.FloorColor
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.BottomSurface = Enum.SurfaceType.Smooth
	floor.Parent = model

	-- Ceiling
	local ceiling = Instance.new("Part")
	ceiling.Name = "Ceiling"
	ceiling.Size = Vector3.new(w * cell, 1, h * cell)
	ceiling.Anchored = true
	ceiling.CanCollide = false
	ceiling.Position = Vector3.new(floor.Position.X, oy + wallH + 0.5, floor.Position.Z)
	ceiling.Material = Enum.Material.SmoothPlastic
	ceiling.Color = Config.CeilingColor
	ceiling.TopSurface = Enum.SurfaceType.Smooth
	ceiling.BottomSurface = Enum.SurfaceType.Smooth
	ceiling.Parent = model

	-- Material for walls
	local function makeWall(size, cframe)
		local p = Instance.new("Part")
		p.Size = size
		p.CFrame = cframe
		p.Anchored = true
		p.CanCollide = true
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Config.WallColor
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = wallFolder
		return p
	end

	local wallT = Config.WallThickness

	-- Build walls based on the grid. To avoid duplicates we only draw
	-- the North and East wall per cell, plus the outer South/West edges.
	for gy = 1, h do
		for gx = 1, w do
			local c = grid[gy][gx]
			local worldX = ox + (gx - 1) * cell + half
			local worldZ = oz + (gy - 1) * cell + half

			-- North wall (top edge of cell)
			if c.N then
				makeWall(
					Vector3.new(cell + wallT, wallH, wallT),
					CFrame.new(worldX, oy + wallH / 2, worldZ - half)
				)
			end
			-- East wall
			if c.E then
				makeWall(
					Vector3.new(wallT, wallH, cell + wallT),
					CFrame.new(worldX + half, oy + wallH / 2, worldZ)
				)
			end
		end
	end
	-- South edge of maze
	local southZ = oz + h * cell
	for gx = 1, w do
		local worldX = ox + (gx - 1) * cell + half
		makeWall(
			Vector3.new(cell + wallT, wallH, wallT),
			CFrame.new(worldX, oy + wallH / 2, southZ)
		)
	end
	-- West edge of maze
	local westX = ox
	for gy = 1, h do
		local worldZ = oz + (gy - 1) * cell + half
		makeWall(
			Vector3.new(wallT, wallH, cell + wallT),
			CFrame.new(westX, oy + wallH / 2, worldZ)
		)
	end

	-- Fluorescent lights: one per cell, on the ceiling, flickering occasionally
	for gy = 1, h do
		for gx = 1, w do
			local worldX = ox + (gx - 1) * cell + half
			local worldZ = oz + (gy - 1) * cell + half

			local lightPart = Instance.new("Part")
			lightPart.Name = "Fluorescent"
			lightPart.Size = Vector3.new(8, 0.3, 1.5)
			lightPart.Anchored = true
			lightPart.CanCollide = false
			lightPart.Material = Enum.Material.Neon
			lightPart.Color = Color3.fromRGB(255, 250, 220)
			lightPart.Position = Vector3.new(worldX, oy + wallH + 0.3, worldZ)
			lightPart.Parent = lightFolder

			local pl = Instance.new("PointLight")
			pl.Brightness = 1.2
			pl.Range = 18
			pl.Color = Color3.fromRGB(255, 250, 220)
			pl.Parent = lightPart
		end
	end

	model.Parent = parent

	-- Build list of open cells (centers) for spawn/exit placement
	local openCells = {}
	for gy = 1, h do
		for gx = 1, w do
			local worldX = ox + (gx - 1) * cell + half
			local worldZ = oz + (gy - 1) * cell + half
			table.insert(openCells, {
				x = gx, y = gy,
				pos = Vector3.new(worldX, oy, worldZ)
			})
		end
	end

	return model, openCells, ox, oy, oz
end

-- BFS from a start cell, returning a 2D array of distances (nil = unreachable).
-- Used to pick exit (farthest cell from spawn) and professor spawn (farthest
-- cell from spawn that isn't the exit or player start).
local function bfsAllDistances(grid, w, h, sx, sy)
	local dist = {}
	for y = 1, h do
		dist[y] = {}
		for x = 1, w do dist[y][x] = nil end
	end
	local queue = {{x = sx, y = sy, d = 0}}
	dist[sy][sx] = 0
	while #queue > 0 do
		local cur = table.remove(queue, 1)
		for i = 1, 4 do
			local d = DIRS[i]
			local cell = grid[cur.y][cur.x]
			if not cell[d.wall] then
				local nx, ny = cur.x + d.dx, cur.y + d.dy
				if nx >= 1 and nx <= w and ny >= 1 and ny <= h and dist[ny][nx] == nil then
					dist[ny][nx] = cur.d + 1
					table.insert(queue, {x = nx, y = ny, d = cur.d + 1})
				end
			end
		end
	end
	return dist
end

-- BFS to find shortest path length between two cells (convenience for verifying
-- solvability; used mainly during testing).
local function bfsDistance(grid, w, h, sx, sy, tx, ty)
	if sx == tx and sy == ty then return 0 end
	local dist = bfsAllDistances(grid, w, h, sx, sy)
	return dist[ty][tx]
end

-- Generate a fresh maze and build it in Workspace.ActiveMap.
-- Returns:
--   model, spawnCandidates (list of Vector3), exitPos (Vector3)
function MazeGenerator.Generate(parent)
	local w = Config.MazeWidth
	local h = Config.MazeHeight

	-- Clean previous
	if parent:FindFirstChild("Maze") then
		parent.Maze:Destroy()
	end

	local grid = createEmptyGrid(w, h)
	carveMaze(grid, w, h)
	addRooms(grid, w, h)

	local model, openCells, ox, oy, oz = buildMazeModel(grid, w, h, parent)

	-- Pick a spawn cell near the center for players' initial drop point
	local spawnGridX = math.floor(w / 2) + math.random(-2, 2)
	local spawnGridY = math.floor(h / 2) + math.random(-2, 2)
	spawnGridX = math.clamp(spawnGridX, 1, w)
	spawnGridY = math.clamp(spawnGridY, 1, h)

	-- Single BFS from spawn gives us the distance to every reachable cell.
	local distFromSpawn = bfsAllDistances(grid, w, h, spawnGridX, spawnGridY)

	-- Find exit cell: the farthest reachable cell from spawn.
	local exitGX, exitGY = spawnGridX, spawnGridY
	local bestDist = -1
	for y = 1, h do
		for x = 1, w do
			local d = distFromSpawn[y][x]
			if d and d > bestDist then
				bestDist = d
				exitGX, exitGY = x, y
			end
		end
	end

	-- Spawn candidates: a cluster of open cells near spawn for multiple players
	local spawnCandidates = {}
	-- First the main spawn cell
	local function cellWorld(gx, gy)
		local worldX = ox + (gx - 1) * Config.CellSize + Config.CellSize / 2
		local worldZ = oz + (gy - 1) * Config.CellSize + Config.CellSize / 2
		return Vector3.new(worldX, oy, worldZ)
	end

	-- BFS from spawn to get a set of nearby open cells
	local visited = {}
	for yy = 1, h do visited[yy] = {}; for xx = 1, w do visited[yy][xx] = false end end
	local q = {{x = spawnGridX, y = spawnGridY, d = 0}}
	visited[spawnGridY][spawnGridX] = true
	while #q > 0 do
		local cur = table.remove(q, 1)
		table.insert(spawnCandidates, cellWorld(cur.x, cur.y))
		if cur.d >= 3 then -- gather enough cells around spawn
			if #spawnCandidates >= 16 then break end
		end
		for i = 1, 4 do
			local d = DIRS[i]
			local cell = grid[cur.y][cur.x]
			if not cell[d.wall] then
				local nx, ny = cur.x + d.dx, cur.y + d.dy
				if nx >= 1 and nx <= w and ny >= 1 and ny <= h and not visited[ny][nx] then
					visited[ny][nx] = true
					table.insert(q, {x = nx, y = ny, d = cur.d + 1})
				end
			end
		end
	end

	-- Professor spawn: farthest cell from spawn that is NOT the exit or the player spawn itself
	local profGX, profGY = spawnGridX, spawnGridY
	local profBestDist = -1
	for y = 1, h do
		for x = 1, w do
			local d = distFromSpawn[y][x]
			local bad = (x == exitGX and y == exitGY) or (x == spawnGridX and y == spawnGridY)
			if d and d > profBestDist and not bad then
				profBestDist = d
				profGX, profGY = x, y
			end
		end
	end

	return {
		Model = model,
		SpawnCandidates = spawnCandidates,
		ProfessorSpawn = cellWorld(profGX, profGY),
		-- Exit is at floor level (Y=oy). The exit pad is built at Y=0.5 on top of the floor.
		ExitPos = cellWorld(exitGX, exitGY),
		Grid = grid,
		Width = w,
		Height = h,
		OriginX = ox,
		OriginY = oy,
		OriginZ = oz,
	}
end

return MazeGenerator
