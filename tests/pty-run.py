#!/usr/bin/env python3
"""Run a command with its stdin bound to a real, never-closing PTY.

Used by the --exec anti-hang regression test. It reproduces the exact
condition that triggered the original bug: an interactive terminal on the
launcher's stdin whose pipe never sends EOF. `opencode run` (emulated by the
fake docker) drains that stdin, so without the fix the launcher blocks forever.

The command's stdout/stderr stay wired to ours (so bats still captures the
launcher's output and the fake-docker log is written as usual); only stdin is
replaced with the PTY slave. The exit code is the child's, except that a child
still running after <timeout-seconds> is SIGKILLed and reported as 124 —
mirroring coreutils `timeout` — so the test can assert "did not hang".

Usage: pty-run.py <timeout-seconds> <command> [args...]
"""
import os
import pty
import signal
import sys
import time


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: pty-run.py <timeout-seconds> <command> [args...]\n")
        return 2
    timeout = float(sys.argv[1])
    argv = sys.argv[2:]

    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        # Child: its own session so the slave becomes a controlling TTY, then
        # bind stdin to it. stdout/stderr are left inherited.
        os.setsid()
        os.dup2(slave, 0)
        os.close(slave)
        os.close(master)
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)

    # Parent: hold `master` open (never write, never close) so the child's TTY
    # never sees EOF — exactly the interactive-terminal condition. Reap with a
    # deadline so a genuine hang can't wedge the suite.
    os.close(slave)
    deadline = time.monotonic() + timeout
    while True:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            if os.WIFEXITED(status):
                return os.WEXITSTATUS(status)
            if os.WIFSIGNALED(status):
                return 128 + os.WTERMSIG(status)
            return 1
        if time.monotonic() >= deadline:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            return 124
        time.sleep(0.05)


if __name__ == "__main__":
    sys.exit(main())
