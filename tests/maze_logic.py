"""Direct port of MazeGenerator.lua so we can test it in Python.
Uses exactly the same algorithm (recursive backtracking + room carving)."""
import random
from collections import deque

DIRS = [
    (0, -1, "N", "S"),
    (1, 0, "E", "W"),
    (0, 1, "S", "N"),
    (-1, 0, "W", "E"),
]


def generate_maze(w, h):
    def empty_grid():
        g = []
        for y in range(h):
            row = []
            for x in range(w):
                row.append({"N": True, "E": True, "S": True, "W": True,
                            "visited": False, "isRoom": False})
            g.append(row)
        return g

    grid = empty_grid()
    # Recursive backtracking
    sx, sy = random.randrange(w), random.randrange(h)
    grid[sy][sx]["visited"] = True
    stack = [(sx, sy)]
    while stack:
        x, y = stack[-1]
        neighbors = []
        for dx, dy, wall, opp in DIRS:
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not grid[ny][nx]["visited"]:
                neighbors.append((dx, dy, wall, opp, nx, ny))
        if neighbors:
            dx, dy, wall, opp, nx, ny = random.choice(neighbors)
            grid[y][x][wall] = False
            grid[ny][nx][opp] = False
            grid[ny][nx]["visited"] = True
            stack.append((nx, ny))
        else:
            stack.pop()

    # Reset visited
    for y in range(h):
        for x in range(w):
            grid[y][x]["visited"] = False

    # Add rooms
    num_rooms = (w * h) // 25
    for _ in range(num_rooms):
        rw = random.randint(2, 3)
        rh = random.randint(2, 3)
        rx = random.randrange(max(1, w - rw + 1))
        ry = random.randrange(max(1, h - rh + 1))
        for yy in range(ry, ry + rh):
            for xx in range(rx, rx + rw):
                grid[yy][xx]["isRoom"] = True
                if yy > ry:
                    grid[yy][xx]["N"] = False
                    grid[yy-1][xx]["S"] = False
                if xx > rx:
                    grid[yy][xx]["W"] = False
                    grid[yy][xx-1]["E"] = False
    return grid


def bfs_dist(grid, w, h, sx, sy, tx, ty):
    if sx == tx and sy == ty:
        return 0
    visited = [[False]*w for _ in range(h)]
    q = deque([(sx, sy, 0)])
    visited[sy][sx] = True
    while q:
        x, y, d = q.popleft()
        for dx, dy, wall, _ in DIRS:
            if not grid[y][x][wall]:
                nx, ny = x+dx, y+dy
                if 0 <= nx < w and 0 <= ny < h and not visited[ny][nx]:
                    if nx == tx and ny == ty:
                        return d + 1
                    visited[ny][nx] = True
                    q.append((nx, ny, d+1))
    return None


def _bfs_all_distances(grid, w, h, sx, sy):
    """Single BFS from (sx,sy) returning a 2D distance array (None=unreachable)."""
    dist = [[None]*w for _ in range(h)]
    q = deque([(sx, sy, 0)])
    dist[sy][sx] = 0
    while q:
        x, y, d = q.popleft()
        for dx, dy, wall, _ in DIRS:
            if not grid[y][x][wall]:
                nx, ny = x+dx, y+dy
                if 0 <= nx < w and 0 <= ny < h and dist[ny][nx] is None:
                    dist[ny][nx] = d + 1
                    q.append((nx, ny, d+1))
    return dist


def find_spawns_exit_prof(grid, w, h):
    spawn_x = w // 2 + random.randint(-2, 2)
    spawn_y = h // 2 + random.randint(-2, 2)
    spawn_x = max(0, min(w-1, spawn_x))
    spawn_y = max(0, min(h-1, spawn_y))

    # Single BFS from spawn gives us distance to every reachable cell.
    dist = _bfs_all_distances(grid, w, h, spawn_x, spawn_y)

    # Farthest = exit
    exit_cell = None
    best = -1
    for y in range(h):
        for x in range(w):
            d = dist[y][x]
            if d is not None and d > best:
                best = d
                exit_cell = (x, y, d)

    # Spawn candidates: BFS up to depth 3 from spawn
    spawns = []
    visited = [[False]*w for _ in range(h)]
    q = deque([(spawn_x, spawn_y, 0)])
    visited[spawn_y][spawn_x] = True
    while q:
        x, y, d = q.popleft()
        spawns.append((x, y))
        if d >= 3 and len(spawns) >= 16:
            break
        for dx, dy, wall, _ in DIRS:
            if not grid[y][x][wall]:
                nx, ny = x+dx, y+dy
                if 0 <= nx < w and 0 <= ny < h and not visited[ny][nx]:
                    visited[ny][nx] = True
                    q.append((nx, ny, d+1))

    # Prof spawn: farthest reachable cell that is not the exit or exact player spawn
    prof = None
    prof_best = -1
    for y in range(h):
        for x in range(w):
            d = dist[y][x]
            bad = (x, y) == exit_cell[:2] or (x, y) == (spawn_x, spawn_y)
            if d is not None and d > prof_best and not bad:
                prof_best = d
                prof = (x, y)

    return grid, (spawn_x, spawn_y), exit_cell, spawns, prof
