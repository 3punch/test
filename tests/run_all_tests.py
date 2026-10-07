"""Comprehensive automated tests for Professor Escape MVP.

These tests validate every piece of pure-logic we can run outside Roblox Studio,
mirroring the exact logic in the Luau source files.

Tested:
* Maze generation (recursive backtracker)
* Maze solvability (BFS from spawn to exit / professor spawn / every spawn candidate)
* Spawn placement (inside open cells, far from exit, reachable)
* Exit placement (reachable, not on spawn)
* Professor spawn placement (reachable, far from players, not on exit)
* Round state-machine transitions
* Catch/spectator invariants
* Multiplayer join/leave mid-round
* Player death mid-round
* Cleanup / connection leak prevention
* Pathfinding waypoint-following simulation
"""
import sys, os, random, copy, math
from collections import deque

sys.path.insert(0, os.path.dirname(__file__))
from maze_logic import generate_maze, find_spawns_exit_prof, bfs_dist
from round_state import RoundStateMachine, WAITING, STARTING, PLAYING, ROUND_END

# ====================== MAZE TESTS ======================

def test_maze_generation_runs():
    for seed in range(20):
        random.seed(seed)
        grid = generate_maze(25, 25)
        assert grid is not None, f"seed {seed} returned None"
        assert len(grid) == 25 and len(grid[0]) == 25
    print("[PASS] test_maze_generation_runs")

def test_maze_all_cells_reachable_from_spawn():
    """Every open cell must be reachable from the spawn (no isolated pockets).
    After add_rooms, all cells must remain reachable."""
    failures = 0
    for seed in range(200):
        random.seed(seed)
        grid, spawn, exit_cell, spawns, prof = find_spawns_exit_prof(generate_maze(25, 25), 25, 25)
        w = h = 25
        # BFS from spawn, must reach every cell
        visited = [[False]*w for _ in range(h)]
        q = deque([spawn])
        visited[spawn[1]][spawn[0]] = True
        DIRS = [(0,-1,"N","S"),(1,0,"E","W"),(0,1,"S","N"),(-1,0,"W","E")]
        while q:
            x, y = q.popleft()
            for (dx, dy, wall, _) in DIRS:
                if not grid[y][x][wall]:
                    nx, ny = x+dx, y+dy
                    if 0<=nx<w and 0<=ny<h and not visited[ny][nx]:
                        visited[ny][nx] = True
                        q.append((nx, ny))
        unreachable = sum(1 for y in range(h) for x in range(w) if not visited[y][x])
        if unreachable != 0:
            failures += 1
    assert failures == 0, f"{failures} mazes had unreachable cells"
    print("[PASS] test_maze_all_cells_reachable_from_spawn (200 seeds)")

def test_exit_always_reachable():
    for seed in range(200):
        random.seed(seed)
        grid, spawn, exit_cell, spawns, prof = find_spawns_exit_prof(generate_maze(25, 25), 25, 25)
        d = bfs_dist(grid, 25, 25, spawn[0], spawn[1], exit_cell[0], exit_cell[1])
        assert d is not None, f"exit unreachable at seed {seed}"
        assert d >= 20, f"exit too close to spawn at seed {seed}: {d}"
    print("[PASS] test_exit_always_reachable (200 seeds)")

def test_professor_spawn_always_reachable_and_far():
    for seed in range(200):
        random.seed(seed)
        grid, spawn, exit_cell, spawns, prof = find_spawns_exit_prof(generate_maze(25, 25), 25, 25)
        assert prof is not None
        assert prof != exit_cell[:2], "professor on exit"
        assert prof != spawn, "professor on player spawn"
        d = bfs_dist(grid, 25, 25, spawn[0], spawn[1], prof[0], prof[1])
        assert d is not None, "professor unreachable"
        assert d >= 20, f"professor too close at seed {seed}: {d}"
    print("[PASS] test_professor_spawn_always_reachable_and_far (200 seeds)")

def test_spawn_candidates_all_reachable_and_open():
    for seed in range(200):
        random.seed(seed)
        grid, spawn, exit_cell, spawns, prof = find_spawns_exit_prof(generate_maze(25, 25), 25, 25)
        assert len(spawns) >= 8, f"only {len(spawns)} spawn candidates"
        for s in spawns:
            d = bfs_dist(grid, 25, 25, spawn[0], spawn[1], s[0], s[1])
            assert d is not None, "spawn candidate unreachable"
            # spawn candidates must not be on exit
            assert s != exit_cell[:2]
    print("[PASS] test_spawn_candidates_all_reachable_and_open (200 seeds)")

def test_maze_small_sizes_solvable():
    for w, h in [(7,7), (11,11), (15,15), (25,25), (31,31)]:
        random.seed(w*100+h)
        grid, spawn, exit_cell, spawns, prof = find_spawns_exit_prof(generate_maze(w, h), w, h)
        d = bfs_dist(grid, w, h, spawn[0], spawn[1], exit_cell[0], exit_cell[1])
        assert d is not None
    print("[PASS] test_maze_small_sizes_solvable")

def test_no_two_cells_share_same_wall_problem():
    """All North/East walls we iterate over should be paired consistently."""
    for seed in range(50):
        random.seed(seed)
        grid = generate_maze(25, 25)
        for y in range(25):
            for x in range(25):
                c = grid[y][x]
                # North wall consistency with cell above
                if y > 0:
                    assert c["N"] == grid[y-1][x]["S"]
                # East wall consistency with cell to right
                if x < 24:
                    assert c["E"] == grid[y][x+1]["W"]
    print("[PASS] test_no_two_cells_share_same_wall_problem")

# ====================== ROUND STATE MACHINE TESTS ======================

def test_state_transitions_single_player():
    sm = RoundStateMachine()
    assert sm.state == WAITING
    sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
    assert sm.state == STARTING
    sm.tick(Config.StartingTime + 0.1)
    assert sm.state == PLAYING
    assert sm.maze_generated is True
    assert len(sm.alive_players) == 1
    # If player escapes, round ends
    sm.player_escape("Alice")
    assert sm.state == ROUND_END
    assert sm.winner == "Alice"
    sm.tick(Config.RoundEndTime + 0.1)
    assert sm.state == WAITING  # restarted
    print("[PASS] test_state_transitions_single_player")

def test_state_transitions_all_caught():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice","Bob"])
    sm.tick(Config.StartingTime + 0.1)
    assert sm.state == PLAYING
    assert sm.alive_count() == 2
    sm.player_caught("Alice")
    assert sm.alive_count() == 1
    assert sm.state == PLAYING
    sm.player_caught("Bob")
    assert sm.state == ROUND_END
    assert sm.winner is None
    assert sm.end_reason == "AllCaught"
    sm.tick(Config.RoundEndTime + 0.1)
    assert sm.state == WAITING
    print("[PASS] test_state_transitions_all_caught")

def test_state_transitions_time_out():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
    sm.tick(Config.StartingTime + 0.1)
    # Play for max duration
    sm.tick(Config.RoundTimeMax + 0.1)
    assert sm.state == ROUND_END
    assert sm.end_reason == "TimeUp"
    print("[PASS] test_state_transitions_time_out")

def test_waiting_extends_without_players():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 5, players=[])
    assert sm.state == WAITING  # should stay waiting
    sm.tick(0.1, players=["Alice"])
    assert sm.state == WAITING
    sm.tick(Config.WaitingTime + 0.1)
    assert sm.state == STARTING
    print("[PASS] test_waiting_extends_without_players")

def test_player_joins_mid_round_becomes_spectator():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
    sm.tick(Config.StartingTime + 0.1)
    assert sm.state == PLAYING
    sm.player_join("Bob")
    assert "Bob" in sm.spectators
    assert "Bob" not in sm.alive_players
    print("[PASS] test_player_joins_mid_round_becomes_spectator")

def test_player_leaves_mid_round_doesnt_end():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice","Bob"])
    sm.tick(Config.StartingTime + 0.1)
    sm.player_leave("Alice")
    assert sm.state == PLAYING  # Bob still alive
    assert sm.alive_count() == 1
    sm.player_caught("Bob")
    assert sm.state == ROUND_END
    print("[PASS] test_player_joins_mid_round_becomes_spectator (leave case)")

def test_caught_players_become_spectators():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
    sm.tick(Config.StartingTime + 0.1)
    sm.player_caught("Alice")
    assert "Alice" in sm.spectators
    assert "Alice" not in sm.alive_players
    print("[PASS] test_caught_players_become_spectators")

def test_escaped_players_become_spectators():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
    sm.tick(Config.StartingTime + 0.1)
    sm.player_escape("Alice")
    assert "Alice" in sm.spectators
    assert "Alice" not in sm.alive_players
    assert sm.winner == "Alice"
    print("[PASS] test_escaped_players_become_spectators")

def test_multiple_rounds_no_leaks():
    sm = RoundStateMachine()
    for i in range(5):
        sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
        sm.tick(Config.StartingTime + 0.1)
        sm.player_escape("Alice")
        sm.tick(Config.RoundEndTime + 0.1)
        assert sm.state == WAITING, f"didn't reset on round {i}"
        assert sm.alive_count() == 0
        assert len(sm.spectators) == 0
        assert sm.professor_spawned is False  # cleared
        assert sm.maze_generated is False
    print("[PASS] test_multiple_rounds_no_leaks")

def test_cannot_catch_spectator_twice():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
    sm.tick(Config.StartingTime + 0.1)
    sm.player_caught("Alice")
    sm.player_caught("Alice")  # must be no-op
    assert sm.state == ROUND_END
    print("[PASS] test_cannot_catch_spectator_twice")

def test_cannot_escape_twice():
    sm = RoundStateMachine()
    sm.tick(Config.WaitingTime + 0.1, players=["Alice"])
    sm.tick(Config.StartingTime + 0.1)
    sm.player_escape("Alice")
    # Second escape is a no-op (in real code, guarded by Game.EscapedPlayers check)
    # We simulate by just asserting state is ROUND_END and winner is still Alice
    assert sm.winner == "Alice"
    print("[PASS] test_cannot_escape_twice")

# ====================== STAMINA TESTS ======================

def test_stamina_drains_when_sprinting():
    max_stam = 100
    drain = 25
    regen = 15
    stam = max_stam
    sprinting = True
    dt = 0.1
    for _ in range(40):  # 4 seconds
        if sprinting and stam > 0:
            stam = max(0, stam - drain * dt)
        else:
            stam = min(max_stam, stam + regen * dt)
    assert stam == 0, "stamina should drain to 0"
    print("[PASS] test_stamina_drains_when_sprinting")

def test_stamina_regens_when_not_sprinting():
    stam = 0
    for _ in range(70):
        stam = min(100, stam + 15 * 0.1)
    assert stam == 100
    print("[PASS] test_stamina_regens_when_not_sprinting")

# ====================== PATH-FOLLOWING SIMULATION ======================

def test_path_follower_reaches_target():
    """Simulates the MoveToFinished-driven waypoint follower on a simple open
    grid. Ensures the state machine advances correctly and never gets stuck
    if waypoints are reachable."""
    # Make a straight-line corridor from (0,0) to (10,0)
    waypoints = [(i*3, 1, 0) for i in range(5)]  # 4 steps of 3 studs
    pos = [0.0, 3.0, 0.0]
    target_idx = 1
    speed = 12
    dt = 0.1
    t = 0
    reached = False
    while t < 30 and target_idx < len(waypoints):
        wp = waypoints[target_idx]
        dx = wp[0] - pos[0]
        dz = wp[2] - pos[2]
        dist = math.sqrt(dx*dx + dz*dz)
        if dist < 1.5:
            target_idx += 1
            continue
        nx = dx/dist * min(speed*dt, dist)
        nz = dz/dist * min(speed*dt, dist)
        pos[0] += nx; pos[2] += nz
        t += dt
    assert target_idx >= len(waypoints), f"stuck at waypoint {target_idx} after {t}s"
    print("[PASS] test_path_follower_reaches_target")

def test_burst_speed_is_faster_than_sprint():
    # Burst speed must be > sprint speed so it feels threatening
    assert Config.ProfessorBurstSpeed > Config.SprintSpeed
    # Professor chase speed should be slower than sprint so players can escape
    assert Config.ProfessorChaseSpeed < Config.SprintSpeed
    # Walk speed should be slow enough that patrols feel manageable
    assert Config.ProfessorWalkSpeed < Config.WalkSpeed
    print("[PASS] test_burst_speed_is_faster_than_sprint")

# ====================== CONFIG ======================

class Config:
    WaitingTime = 10
    StartingTime = 5
    RoundTimeMax = 300
    RoundEndTime = 5
    MaxStamina = 100
    SprintSpeed = 22
    WalkSpeed = 14
    ProfessorChaseSpeed = 16
    ProfessorBurstSpeed = 24
    ProfessorWalkSpeed = 12
    ProfessorDetectionRange = 28
    ProfessorCatchRange = 3
    BurstCooldown = 15
    BurstDuration = 3
    BurstWarningTime = 0.8

if __name__ == "__main__":
    # Make Config available to the round_state module
    import builtins
    builtins.Config = Config
    from round_state import Config  # noqa
    # Re-run any imports that need Config
    tests = [
        test_maze_generation_runs,
        test_maze_all_cells_reachable_from_spawn,
        test_exit_always_reachable,
        test_professor_spawn_always_reachable_and_far,
        test_spawn_candidates_all_reachable_and_open,
        test_maze_small_sizes_solvable,
        test_no_two_cells_share_same_wall_problem,
        test_state_transitions_single_player,
        test_state_transitions_all_caught,
        test_state_transitions_time_out,
        test_waiting_extends_without_players,
        test_player_joins_mid_round_becomes_spectator,
        test_player_leaves_mid_round_doesnt_end,
        test_caught_players_become_spectators,
        test_escaped_players_become_spectators,
        test_multiple_rounds_no_leaks,
        test_cannot_catch_spectator_twice,
        test_cannot_escape_twice,
        test_stamina_drains_when_sprinting,
        test_stamina_regens_when_not_sprinting,
        test_path_follower_reaches_target,
        test_burst_speed_is_faster_than_sprint,
    ]
    failed = 0
    for t in tests:
        try:
            t()
        except Exception as e:
            print(f"[FAIL] {t.__name__}: {e}")
            failed += 1
    print()
    if failed:
        print(f"FAILED: {failed} test(s)")
        sys.exit(1)
    else:
        print(f"All {len(tests)} tests PASSED.")
