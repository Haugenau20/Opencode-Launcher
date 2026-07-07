#!/usr/bin/env python3
"""Run a command with stdin AND stdout/stderr all bound to a real PTY, and
echo everything the terminal received to our own stdout.

Companion to pty-run.py. Where that one only fakes an interactive stdin (to
reproduce the --exec hang), this fakes a fully interactive terminal so tests
can assert on what a human would actually SEE — used to verify the --exec
loading spinner draws and then gets out of the way, with the answer on its own
line rather than smooshed onto the spinner's.

The child's stdin/stdout/stderr are the PTY slave; the parent reads the master
and writes the bytes verbatim to fd 1 (so bats captures them in $output). The
child's exit code is returned, except that a child still running after
<timeout-seconds> is SIGKILLed and reported as 124 (like coreutils `timeout`),
so a hang can't wedge the suite.

Usage: pty-capture.py <timeout-seconds> <command> [args...]
"""
import os
import pty
import select
import signal
import sys
import time


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: pty-capture.py <timeout-seconds> <command> [args...]\n")
        return 2
    timeout = float(sys.argv[1])
    argv = sys.argv[2:]

    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        # Child: own session so the slave is its controlling TTY, then bind all
        # three standard streams to it.
        os.setsid()
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        os.close(slave)
        os.close(master)
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)

    os.close(slave)
    out = getattr(sys.stdout, "buffer", sys.stdout)
    deadline = time.monotonic() + timeout
    rc = None
    while True:
        r, _, _ = select.select([master], [], [], 0.1)
        if master in r:
            try:
                data = os.read(master, 4096)
            except OSError:
                data = b""
            if data:
                out.write(data)
                out.flush()
            else:
                break
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            if os.WIFEXITED(status):
                rc = os.WEXITSTATUS(status)
            elif os.WIFSIGNALED(status):
                rc = 128 + os.WTERMSIG(status)
            else:
                rc = 1
            # Drain any output still buffered in the PTY before returning.
            while True:
                r, _, _ = select.select([master], [], [], 0.05)
                if master not in r:
                    break
                try:
                    data = os.read(master, 4096)
                except OSError:
                    data = b""
                if not data:
                    break
                out.write(data)
                out.flush()
            return rc
        if time.monotonic() >= deadline:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            return 124


if __name__ == "__main__":
    sys.exit(main())
