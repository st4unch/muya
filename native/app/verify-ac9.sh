#!/usr/bin/env bash
# AC9: kill -9 the app with 25 sessions -> the relaunched app lists all 25 within 500 ms of process start,
# every session's screen text hashes the same as before the kill, and no shell PID is lost.
# Own throwaway stack (private TMPDIR, fake HOME, own sockets); kills only PIDs it started. Needs a GUI session.
#   verify-ac9.sh [runs=5]    records "ac9" in measurements.json, exit 1 on FAIL
set -euo pipefail
cd "$(dirname "$0")"
RUNS=${1:-5}
N=25
WORK=$(mktemp -d /tmp/muya-ac9.XXXXXX)  # short path: unix socket paths are limited to 104 bytes
export TMPDIR=$WORK # run-dev.sh keeps its state file and dev dir under TMPDIR: isolated from other stacks
STATE=$WORK/muya-native-dev.state
RES=$WORK/results.jsonl
: > "$RES"
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped

./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 5 "$DEV/app-debug.sock"; }
wait_sock() { for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && return 0; sleep 0.1; done; echo "app debug socket never came up" >&2; exit 1; }
hash_of() { dbg text | shasum -a 256 | cut -c1-16; }
wait_sock

# 25 sessions, each with its own marker text and a few lines of output.
for i in $(seq $N); do
  mkdir -p "$DEV/home/p$i"
  dbg "new $DEV/home/p$i" >/dev/null
done
sleep 1.5
IDS=($(dbg sessions | cut -f1))
[ "${#IDS[@]}" = "$N" ] || { echo "FAIL: expected $N sessions, have ${#IDS[@]}" >&2; exit 1; }
i=0
for id in "${IDS[@]}"; do
  i=$((i + 1))
  dbg "select $id" >/dev/null
  dbg "type \"echo AC9-$i-marker; seq 1 $((i % 7 + 2))\\n\"" >/dev/null
done
sleep 1.5
# Pre-kill hash of every session's screen (selecting attaches it, the snapshot may take a moment).
BF=$WORK/before.txt; : > "$BF"
before() { awk -v k="$1" '$1==k{print $2}' "$BF"; }
for id in "${IDS[@]}"; do dbg "select $id" >/dev/null; sleep 0.25; echo "$id $(hash_of)" >> "$BF"; done
shells() { pgrep -P "$PTYD_PID" | sort -n | tr '\n' ' '; }
PIDS_BEFORE=$(shells)
echo "sessions=$N shells=$(echo $PIDS_BEFORE | wc -w) distinct screens=$(cut -d" " -f2 "$BF" | sort -u | wc -l | tr -d " ")"

fail=0
for run in $(seq "$RUNS"); do
  . "$STATE"
  kill -9 "$APP_PID"
  for _ in $(seq 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
  sleep 0.4
  ./run-dev.sh app >/dev/null; . "$STATE"
  wait_sock
  # The app records its own timings relative to the kernel's process start time.
  L=""; for _ in $(seq 40); do L=$(dbg launch | head -1); case "$L" in *"snapshots=0"*|*"shown_ms=-1"*) sleep 0.05 ;; *) break ;; esac; done
  # Settle: the selected session's screen has arrived. Then hash every session after relaunch.
  mism=0; slow=0
  for id in "${IDS[@]}"; do
    dbg "select $id" >/dev/null
    ok=0
    for _ in $(seq 40); do [ "$(hash_of)" = "$(before "$id")" ] && { ok=1; break; }; sleep 0.05; done
    [ $ok = 1 ] || { mism=$((mism + 1)); echo "  run $run: session $id screen differs after relaunch" >&2; }
  done
  # L (read before the hashing loop, which attaches every session) holds the launch figures.
  PIDS_AFTER=$(shells)
  lost=0; for p in $PIDS_BEFORE; do case " $PIDS_AFTER " in *" $p "*) ;; *) lost=$((lost + 1)) ;; esac; done
  count=$(dbg sessions | wc -l | tr -d ' ')
  echo "run $run: $L mismatches=$mism pids_lost=$lost sessions_after=$count"
  printf '%s\n' "$L|$mism|$lost|$count" >> "$RES"
  [ "$mism" = 0 ] && [ "$lost" = 0 ] && [ "$count" = "$N" ] || fail=1
done

python3 -I - "$RES" "$N" "$RUNS" "$fail" <<'E'
import json, re, statistics, sys, os
res, n, runs, fail = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rows = []
for line in open(res):
    l, mism, lost, count = line.strip().rsplit("|", 3)
    m = dict(kv.split("=", 1) for kv in l.split() if "=" in kv)
    per = dict(p.split("=") for p in m.get("per", "").split(",") if p)
    rows.append({"shown_ms": int(m["shown_ms"]), "first_snapshot_ms": min(map(int, per.values())) if per else -1,
                 "mismatches": int(mism), "pids_lost": int(lost), "sessions_after": int(count)})
shown = [r["shown_ms"] for r in rows]
snap = [r["first_snapshot_ms"] for r in rows]
out = {"sessions": n, "runs": runs,
       "shown_ms": {"p50": statistics.median(shown), "max": max(shown), "all": shown},
       "first_screen_ms": {"p50": statistics.median(snap), "max": max(snap), "all": snap},
       "screen_hash_mismatches": sum(r["mismatches"] for r in rows), "pids_lost": sum(r["pids_lost"] for r in rows),
       "target_ms": 500}
out["pass"] = (not fail) and out["shown_ms"]["max"] <= 500 and out["first_screen_ms"]["max"] <= 500 and min(snap) >= 0
path = os.path.join(os.getcwd(), "measurements.json")
d = json.load(open(path)); d["ac9"] = out
json.dump(d, open(path, "w"), indent=1); open(path, "a").write("\n")
print("AC9", "PASS" if out["pass"] else "FAIL", json.dumps({k: out[k] for k in ("shown_ms", "first_screen_ms", "screen_hash_mismatches", "pids_lost")}))
sys.exit(0 if out["pass"] else 1)
E
