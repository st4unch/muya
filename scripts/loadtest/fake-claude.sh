#!/bin/sh
# Stand-in `claude` for the real-app load test. Answers the capability probe and the
# session list like the real CLI, and otherwise streams Claude-like ANSI output at
# LOADTEST_BPS bytes per second (default 64000) until it is killed.
case "$1" in
  agents) echo '[]'; exit 0 ;;
  --version|-v) echo '2.1.999 (Claude Code)'; exit 0 ;;
esac
exec /usr/bin/python3 -u -c '
import os, sys, time
bps = int(os.environ.get("LOADTEST_BPS", "64000"))
out = sys.stdout
i = 0
tick = 0.02
while True:
    t0 = time.time()
    buf = []
    size = 0
    while size < bps * tick:
        i += 1
        if i % 7 == 0:
            s = "\r\x1b[2K\x1b[38;5;214m*\x1b[0m Thinking... \x1b[2m(%ds)\x1b[0m" % i
        else:
            s = "\r\n\x1b[38;5;%dm*\x1b[0m Read \x1b[1msrc/File%d.tsx\x1b[0m \x1b[2m(%d lines)\x1b[0m  %s" % (16 + i % 200, i, i * 37 % 900, "lorem ipsum dolor sit amet " * (1 + i % 4))
        buf.append(s)
        size += len(s)
    out.write("".join(buf))
    out.flush()
    time.sleep(max(0, tick - (time.time() - t0)))
' muya-loadtest-flood
