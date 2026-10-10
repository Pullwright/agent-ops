#!/usr/bin/env python3
#
# deploy/docker/grok-subreaper.py — contains a Grok Build run (issue #2134,
# docs/reviews/2026-10-06-grok-build-evaluation.md's "Beyond the ten
# questions" section, "Containing them"), installed root-owned, outside
# /app, at /usr/local/libexec/agent-ops/grok-subreaper.
#
# Grok runs every `run_terminal_command` in its own session, so
# lib/stage-run.sh's own process-group kill (`kill -TERM -$pid`, requirement
# 9c) ends Grok but leaves its last command running, reparented to PID 1;
# Grok's own handling of the signal cannot be relied on to end it either.
# Walking /proc for Grok's descendants and signalling each group — this
# wrapper's first design — races a command started between the walk and the
# signal, and misses anything that has already left Grok's own tree.
#
# A child subreaper closes both gaps. `prctl(PR_SET_CHILD_SUBREAPER)` needs
# no privilege the scheduler's container lacks (unlike a PID namespace or a
# cgroup of its own, neither available to it): once set, a process that
# loses its parent reparents to the nearest living ancestor that has set
# this flag, rather than to PID 1, whatever session or process group it has
# since put itself in. This wrapper sets the flag, forks Grok as its only
# direct child, forwards SIGTERM/SIGINT/SIGHUP to it, and — once Grok has
# exited, or two seconds after a forwarded signal, whichever comes first —
# repeatedly kills every process now reparented to it until one pass finds
# none. That whole sweep fits inside lib/stage-run.sh's own five-second
# grace between its TERM and its KILL.
#
# Usage: grok-subreaper.py [--cleanup PATH] [--] <command> [args...]
# Execs <command> [args...] (ordinarily `grok` and its own arguments) as a
# forked child; exits with that child's own exit status (128+signal if the
# child died of a signal this wrapper did not itself forward and SIGKILL).
#
# `--cleanup PATH`, when given, removes PATH once the child has exited (the
# prompt file lib/substrate-grok-build.sh's own `_exec` writes, since Grok's
# own `--prompt-file` cannot read the launcher's inherited stdin by path
# across the uid change `grok` itself runs under — see that function's own
# header for why). This wrapper is the only thing in the chain with a
# definite "the run that needed it is over" moment: its caller `exec`s
# straight into it and so never returns to clean up after itself.

import ctypes
import os
import signal
import sys
import time

PR_SET_CHILD_SUBREAPER = 36
FORWARDED_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
SIGNAL_TO_KILL_GRACE_SECONDS = 2
POLL_INTERVAL_SECONDS = 0.1
SWEEP_PASSES = 20


def set_subreaper():
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        err = ctypes.get_errno()
        sys.stderr.write(
            "grok-subreaper: prctl(PR_SET_CHILD_SUBREAPER) failed: %s\n"
            % os.strerror(err)
        )
        sys.exit(1)


def descendants_of(root_pid):
    """Every live pid in /proc whose PPid chain leads back to root_pid,
    found by one pass over /proc rather than a repeated query per pid."""
    ppid_of = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            with open("/proc/%d/status" % pid) as f:
                for line in f:
                    if line.startswith("PPid:"):
                        ppid_of[pid] = int(line.split()[1])
                        break
        except (FileNotFoundError, ProcessLookupError):
            continue
    found = set()
    frontier = {root_pid}
    while frontier:
        nxt = {pid for pid, ppid in ppid_of.items() if ppid in frontier} - found
        if not nxt:
            break
        found |= nxt
        frontier = nxt
    return found


def reap_zombies():
    """Collect the exit status of whatever has already reparented to us and
    died, so it does not stay a zombie between sweep passes."""
    while True:
        try:
            pid, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if pid == 0:
            break


def sweep(my_pid):
    """Kill every process this wrapper's subreaper flag has caught, as it
    catches them: a command still starting when the first pass runs is
    caught by a later one, which is why this repeats until a pass finds
    nothing left, not just once."""
    for _ in range(SWEEP_PASSES):
        reap_zombies()
        victims = descendants_of(my_pid)
        if not victims:
            return
        for pid in victims:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(POLL_INTERVAL_SECONDS)
    reap_zombies()


def main(argv):
    args = argv[1:]
    cleanup_path = None
    if args[:1] == ["--cleanup"]:
        if len(args) < 2:
            sys.stderr.write("usage: %s [--cleanup PATH] [--] <command> [args...]\n" % argv[0])
            return 2
        cleanup_path = args[1]
        args = args[2:]
    if args[:1] == ["--"]:
        args = args[1:]
    if not args:
        sys.stderr.write("usage: %s [--cleanup PATH] [--] <command> [args...]\n" % argv[0])
        return 2

    set_subreaper()
    my_pid = os.getpid()

    child_pid = os.fork()
    if child_pid == 0:
        try:
            os.execvp(args[0], args)
        except OSError as exc:
            sys.stderr.write("grok-subreaper: %s: %s\n" % (args[0], exc))
        os._exit(127)

    state = {"signalled_at": None}

    def forward(signum, _frame):
        if state["signalled_at"] is None:
            state["signalled_at"] = time.monotonic()
        try:
            os.kill(child_pid, signum)
        except ProcessLookupError:
            pass

    for sig in FORWARDED_SIGNALS:
        signal.signal(sig, forward)

    child_status = None
    child_killed = False
    while True:
        try:
            pid, status = os.waitpid(child_pid, os.WNOHANG)
        except ChildProcessError:
            pid, status = child_pid, 0
        if pid == child_pid:
            child_status = status
            break
        if (
            state["signalled_at"] is not None
            and not child_killed
            and time.monotonic() - state["signalled_at"] >= SIGNAL_TO_KILL_GRACE_SECONDS
        ):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child_killed = True
        time.sleep(POLL_INTERVAL_SECONDS)

    sweep(my_pid)

    if cleanup_path is not None:
        try:
            os.unlink(cleanup_path)
        except OSError:
            pass

    if os.WIFSIGNALED(child_status):
        return 128 + os.WTERMSIG(child_status)
    return os.WEXITSTATUS(child_status)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
