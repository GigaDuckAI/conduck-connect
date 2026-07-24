#!/usr/bin/env python3
"""Run one command in a real PTY and feed it a fixed byte sequence.

Used only by the connector CLI regression suite. The PTY matters because a
successful check offers setup only to a real interactive terminal.

The timeout is a hard one. A wizard that is blocked on a prompt is the normal
failure this harness has to report, and such a child does not necessarily die on
SIGTERM: bash defers signals while it waits for a foreground child (a prompt read
inside a `$(...)` substitution), and a stuck grandchild -- curl, rclone -- holds
the PTY open regardless. So the deadline escalates SIGTERM -> SIGKILL against the
child's whole process group, with a bounded wait at each step, and whatever was
captured is written out no matter how the run ends: a timeout must produce a
diagnosable log, never an infinite CI hang with an empty one.
"""

from __future__ import annotations

import os
import pty
import select
import signal
import sys
import time

# Bounded waits after each escalation step. A PTY child that survives both has
# gone unkillable (uninterruptible sleep); the harness still returns.
TERM_GRACE = 3.0
KILL_GRACE = 3.0
# Exit status when the deadline fired, whatever signal ended the child.
TIMEOUT_STATUS = 124


def drain(fd: int, output: bytearray, budget: float) -> bool:
    """Read whatever is available for up to `budget` seconds. False once at EOF."""
    end = time.monotonic() + budget
    while True:
        remaining = end - time.monotonic()
        readable, _, _ = select.select([fd], [], [], max(0.0, min(0.1, remaining)))
        if readable:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            output.extend(chunk)
        if remaining <= 0:
            return True


def reap(pid: int, fd: int, fd_open: bool, output: bytearray, budget: float):
    """Poll for the child's exit for up to `budget` seconds, draining as we go.

    Returns (status, fd_open); status is None if the child is still alive. The
    drain matters: a child blocked writing into a full PTY buffer cannot reach
    its own exit, so waiting without reading would deadlock the wait itself.
    """
    end = time.monotonic() + budget
    while True:
        try:
            waited, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return 0, fd_open
        if waited == pid:
            return status, fd_open
        if time.monotonic() >= end:
            return None, fd_open
        if fd_open:
            fd_open = drain(fd, output, 0.05)
        else:
            time.sleep(0.05)


def signal_child(pid: int, sig: int) -> None:
    """Signal the child's process group, falling back to the bare pid.

    pty.fork() puts the child in its own session, so its process group holds the
    grandchildren too -- the command substitution or curl that is the actual
    thing still holding the terminal open.
    """
    for target in (lambda: os.killpg(pid, sig), lambda: os.kill(pid, sig)):
        try:
            target()
            return
        except (ProcessLookupError, PermissionError, OSError):
            continue


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: pty-run.py <timeout-seconds> <input> <command> [args...]", file=sys.stderr)
        return 2

    timeout = float(sys.argv[1])
    data = sys.argv[2].encode()
    command = sys.argv[3:]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(command[0], command, os.environ.copy())

    output = bytearray()
    status: int | None = None
    timed_out = False
    fd_open = True
    try:
        if data:
            try:
                os.write(fd, data)
            except OSError:
                output.extend(b"\nPTY WRITE FAILED\n")

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, fd_open = reap(pid, fd, fd_open, output, min(0.1, deadline - time.monotonic()))
            if status is not None:
                break

        if status is None:
            timed_out = True
            output.extend(b"\nPTY TIMEOUT\n")
            for sig, grace, label in (
                (signal.SIGTERM, TERM_GRACE, b"SIGTERM"),
                (signal.SIGKILL, KILL_GRACE, b"SIGKILL"),
            ):
                signal_child(pid, sig)
                status, fd_open = reap(pid, fd, fd_open, output, grace)
                if status is not None:
                    break
                output.extend(b"PTY child survived " + label + b"\n")
            if status is None:
                output.extend(b"PTY child could not be reaped; giving up and reporting the timeout\n")

        # Trailing output the child produced just before exiting.
        if fd_open:
            drain(fd, output, 0.2)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        # Unconditional: a timed-out or crashed run must still be diagnosable.
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()

    if timed_out:
        return TIMEOUT_STATUS
    if status is None:
        return 1
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
