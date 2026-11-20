"""S4 load: session 0 sets input modes then floods 12 MB (so the mode bytes leave the 1 MB ring);
session 1 streams 1 MB/s; the rest 64 KB/s of Claude-like colored lines."""
import sys, time
i = int(sys.argv[1]); out = sys.stdout.buffer
line = lambda n: ("\x1b[38;5;%dm*\x1b[0m Read \x1b[1msrc/File%d.tsx\x1b[0m şğüİı 日本語 lorem ipsum %d\r\n" % (16 + n % 200, n, n)).encode()
if i == 0:
    out.write(b"\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[>1u"); out.flush()
    blob = b"".join(line(n) for n in range(1000)); sent = 0
    while sent < 12_000_000:
        out.write(blob); sent += len(blob)
    out.flush()
    while True: time.sleep(60)
if i == 2:
    # TUI with a fixed header and a scroll region: the header is drawn once and again only on
    # SIGWINCH. After >1 MB of scrolled output the header bytes are no longer in the ring.
    import signal
    def header(*_):
        out.write(b"\x1b7\x1b[1;1H\x1b[44;97m HEADER drawn once \x1b[K\x1b[0m\x1b[2;1H\x1b[33mstatus: streaming\x1b[K\x1b[0m\x1b8"); out.flush()
    signal.signal(signal.SIGWINCH, header)
    time.sleep(3)  # start after both muyads attached, so the reference sees the header being drawn
    out.write(b"\x1b[2J\x1b[3;30r\x1b[30;1H"); header()
    blob = b"".join(line(n) for n in range(1000)); sent = 0
    while sent < 3_000_000:
        out.write(blob); sent += len(blob)
    out.flush()
    while True: time.sleep(60)
rate = 1_000_000 if i == 1 else 65_536
blob = b"".join(line(n) for n in range(400)); pos = 0; t = time.monotonic(); step = rate // 100
while True:
    chunk = (blob + blob)[pos:pos + step]; pos = (pos + step) % len(blob)
    out.write(chunk); out.flush()
    t += 0.01; d = t - time.monotonic()
    time.sleep(d) if d > 0 else None
