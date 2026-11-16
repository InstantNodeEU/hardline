#!/usr/bin/env python3
"""Answer interactive prompts of a command running in a pty.

    drive.py 'REGEX=ANSWER' ... -- COMMAND ARGS...

Rules are checked in order against new output. ANSWER is typed followed by
Enter, "@3 y" waits three seconds first. The answer KILL kills the command instead, which for `ssh -tt` looks
like a dropped connection to the remote side. Exits with the command's exit
code, 124 on timeout. With DRIVE_CAST=FILE the session is also written as an
asciicast (v2) for the README recording.
"""
import fcntl, json, os, pty, re, select, signal, struct, sys, termios, time

sep = sys.argv.index("--")
rules = [r.split("=", 1) for r in sys.argv[1:sep]]
cmd = sys.argv[sep + 1:]
timeout = float(os.environ.get("DRIVE_TIMEOUT", "900"))

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))

buf, pos, start = "", 0, time.time()
cast = None
if os.environ.get("DRIVE_CAST"):
    cast = open(os.environ["DRIVE_CAST"], "w")
    cast.write(json.dumps({"version": 2, "width": 100, "height": 32}) + "\n")
while True:
    if time.time() - start > timeout:
        os.kill(pid, signal.SIGKILL)
        sys.exit(124)
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            data = os.read(fd, 4096).decode(errors="replace")
        except OSError:
            break
        if not data:
            break
        sys.stdout.write(data)
        sys.stdout.flush()
        if cast:
            cast.write(json.dumps([round(time.time() - start, 3), "o", data]) + "\n")
        buf += data
    # the earliest prompt in the new output gets answered first
    hits = [(m, a) for rx, a in rules for m in [re.search(rx, buf[pos:])] if m]
    if hits:
        m, answer = min(hits, key=lambda h: h[0].start())
        pos += m.end()
        if answer == "KILL":
            print("\n[drive] killing the connection", flush=True)
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            sys.exit(0)
        if answer.startswith("@"):
            delay, _, answer = answer[1:].partition(" ")
            time.sleep(float(delay))
        os.write(fd, (answer + "\n").encode())

_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
