"""Simulation of GameManager's round state machine for testing."""

WAITING = "WAITING"
STARTING = "STARTING"
PLAYING = "PLAYING"
ROUND_END = "ROUND_END"


class RoundStateMachine:
    def __init__(self):
        self.state = WAITING
        self.time_in_state = 0
        self.alive_players = {}   # name -> True
        self.spectators = set()
        self.escaped = set()
        self.winner = None
        self.end_reason = None
        self.maze_generated = False
        self.professor_spawned = False

    def alive_count(self):
        return len(self.alive_players)

    def tick(self, dt, players=None):
        if players is not None:
            # Player join/leave reconciliation
            joined = set(players) - set(self.alive_players.keys()) - self.spectators - self.escaped
            for p in joined:
                self.player_join(p)
            left = (set(self.alive_players.keys()) | self.spectators | self.escaped) - set(players)
            for p in list(left):
                self.player_leave(p)

        self.time_in_state += dt

        if self.state == WAITING:
            if self.alive_count() == 0:
                self.time_in_state = 0
            elif self.time_in_state >= Config.WaitingTime:
                self._begin_starting()
        elif self.state == STARTING:
            if self.time_in_state >= Config.StartingTime:
                self._begin_playing()
        elif self.state == PLAYING:
            if self.time_in_state >= Config.RoundTimeMax:
                self._end_round("TimeUp", None)
        elif self.state == ROUND_END:
            if self.time_in_state >= Config.RoundEndTime:
                self._begin_waiting()

    def _begin_starting(self):
        self.state = STARTING
        self.time_in_state = 0

    def _begin_playing(self):
        self.state = PLAYING
        self.time_in_state = 0
        self.maze_generated = True
        self.professor_spawned = True
        # All connected players are considered alive at start of round
        # (players joining mid-round are handled via player_join)
        # Simulate: anyone currently not a spectator is alive
        for p in list(self.spectators):
            pass  # keep spectators (e.g., someone joined mid-waiting? rare)
        # Already set in player_join

    def _end_round(self, reason, winner):
        self.state = ROUND_END
        self.time_in_state = 0
        self.end_reason = reason
        self.winner = winner

    def _begin_waiting(self):
        self.state = WAITING
        self.time_in_state = 0
        self.alive_players = {}
        self.spectators = set()
        self.escaped = set()
        self.winner = None
        self.end_reason = None
        self.maze_generated = False
        self.professor_spawned = False

    def player_join(self, name):
        if self.state == PLAYING:
            self.spectators.add(name)
        elif self.state in (WAITING, STARTING):
            self.alive_players[name] = True

    def player_leave(self, name):
        self.alive_players.pop(name, None)
        self.spectators.discard(name)
        self.escaped.discard(name)
        if self.state == PLAYING and self.alive_count() == 0 and not self.escaped:
            self._end_round("AllCaught", None)

    def player_caught(self, name):
        if name not in self.alive_players:
            return
        self.alive_players.pop(name, None)
        self.spectators.add(name)
        if self.alive_count() == 0:
            self._end_round("AllCaught", None)

    def player_escape(self, name):
        if name not in self.alive_players:
            return
        self.alive_players.pop(name, None)
        self.escaped.add(name)
        self.spectators.add(name)
        self._end_round("Escape", name)


# Config pulled in from run_all_tests
try:
    Config
except NameError:
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
