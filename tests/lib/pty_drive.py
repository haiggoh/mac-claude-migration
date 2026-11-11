#!/usr/bin/env python3
"""Drive a child on a real pty, transcript to a file, key sent on a CONDITION.

Replaces the old `script` + timed-feeder pipeline whose early stdin EOF could
consume the queued key before the child reached its prompt (flake waypoint
mcm-e2e-run-2-pty-using). Here the master side is ours: we only ever write the
key AFTER the trigger text appeared in the output (condition-based, not
time-based), and we never close the master before the child exits, so EOF can
never preempt a prompt read.

Usage: pty_drive.py <transcript-out> <timeout-seconds> [--send <text> --when <substr>] -- <cmd> [args...]
       pty_drive.py --help
Exit status = the child's exit status; 124 on watchdog timeout (child killed).
"""
import os
import pty
import select
import sys
import time


def main(argv):
    if "--help" in argv or not argv:
        print((__doc__ or "").strip())
        return 0
    out_path, timeout = argv[0], float(argv[1])
    send = b"\n"
    when = b"carry on"  # default trigger: the startup menu's Enter option
    args = argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--send":
            send = args[i + 1].encode().decode("unicode_escape").encode()
            i += 2
        elif args[i] == "--when":
            when = args[i + 1].encode()
            i += 2
        elif args[i] == "--":
            args = args[i + 1:]
            break
        else:
            print("unexpected argument: %s" % args[i], file=sys.stderr)
            return 2
    if not args:
        print("no child command after --", file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(args[0], args)

    out = open(out_path, "wb")
    deadline = time.time() + timeout
    sent = False
    status = None
    try:
        while True:
            if time.time() > deadline:
                os.kill(pid, 9)
                os.waitpid(pid, 0)
                out.close()
                print("pty_drive: watchdog timeout after %ss — child killed" % timeout, file=sys.stderr)
                return 124
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    data = b""
                if data:
                    out.write(data)
                    out.flush()
                    if not sent and when in data:
                        os.write(fd, send)
                        sent = True
                elif data == b"":
                    pass
            wpid, st = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                status = st
                # drain whatever remains
                while True:
                    r, _, _ = select.select([fd], [], [], 0.2)
                    if not r:
                        break
                    try:
                        data = os.read(fd, 4096)
                    except OSError:
                        break
                    if not data:
                        break
                    out.write(data)
                break
    finally:
        out.close()
        try:
            os.close(fd)
        except OSError:
            pass
    if status is None:
        _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 128 + os.WTERMSIG(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
