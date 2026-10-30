import os
import signal
import time


def wait_for_exit(run, target, seconds=15):
    deadline = time.monotonic() + seconds
    dead = status = death_signal = ""
    nudged = False
    while time.monotonic() < deadline:
        fields = run("display-message", "-p", "-t", target, "#{pane_dead}|#{pane_dead_status}|#{pane_dead_signal}").stdout.strip()
        dead, status, death_signal = fields.split("|")
        if dead == "1" and (status or death_signal):
            return status, death_signal
        if dead == "1" and not nudged:
            # Older tmux with libutempter can miss SIGCHLD during pane cleanup.
            server = int(run("display-message", "-p", "-t", target, "#{pid}").stdout.strip())
            os.kill(server, signal.SIGCHLD)
            nudged = True
        time.sleep(.05)
    raise AssertionError(f"terminal exit status unavailable; dead={dead!r}; status={status!r}; signal={death_signal!r}")
