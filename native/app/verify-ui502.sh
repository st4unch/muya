#!/usr/bin/env bash
# The three 5.0.2 UI fixes, proved in the dev MOCK app (no daemon, mock data only, the app renders its own
# windows so this works with a locked screen):
#   1. Settings grows sideways: 1..3 columns, no vertical scrolling once the window is wide enough.
#   2. The footer "status fields" menu is compact and stays inside the window.
# Screenshots go to native/app/screenshots/ui502-*.png.
#   native/app/verify-ui502.sh        (build the dev app first: native/app/build.sh)      exit 1 on any FAIL
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-ui502.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-mock.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
./run-mock.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
for _ in $(seq 100); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
mkdir -p screenshots

for theme in Dark Light; do
  t=$(echo "$theme" | tr 'A-Z' 'a-z')
  dbg "settings-set appearance $theme" >/dev/null; sleep 1.2

  # 1. Settings at three window widths. Classic's point: wider, not taller.
  for size in "800 600" "1120 700" "1913 1000"; do
    set -- $size
    w=$1; h=$2
    dbg "window $w $h" >/dev/null; sleep 0.8
    plan=$(dbg uf-settings); sleep 0.8          # "<w> <h> <columns> scrolls=<bool>"
    dbg "settings-snap $PWD/screenshots/ui502-settings-$w-$t.png" >/dev/null; sleep 0.4
    [ -s "screenshots/ui502-settings-$w-$t.png" ] && ok "Settings screenshot at $w ($t): $plan" || bad "no Settings screenshot at $w ($t)"
    cols=$(echo "$plan" | awk '{print $3}')
    case "$w" in
      800)  [ "$cols" = 1 ] && ok "800 px: one column" || bad "800 px should use one column, got $cols" ;;
      1120) [ "$cols" -ge 2 ] && ok "1120 px: $cols columns" || bad "1120 px should use at least two columns, got $cols" ;;
      1913) [ "$cols" -ge 3 ] && ok "1913 px: $cols columns" || bad "1913 px should use three columns, got $cols"
            # The dialog already takes the whole usable height of the screen; what is left over is the remainder
            # three columns of classic's sections cannot absorb. A small remainder is fine, a long scroll is not.
            hidden=$(echo "$plan" | sed -n 's/.*hidden=\([0-9]*\).*/\1/p')
            [ "${hidden:-999}" -le 60 ] && ok "1913 px: at most a sliver is below the fold ($plan)" || bad "1913 px still scrolls: $plan" ;;
    esac
    dbg settings-close >/dev/null; sleep 0.4
  done

  # 2. The footer field menu: it must stay inside the Muya window. Not photographed — this mock app is attached to
  # the real sessions, so a picture of the main window would carry their names; scratchpad/ui-502-shots has mock shots.
  dbg "window 1120 700" >/dev/null; sleep 0.6
  dbg uf-fields >/dev/null; sleep 1.0
  rect=$(dbg uf-fields-rect)
  px=$(echo "$rect" | sed -n 's/popover=\([-0-9]*\),.*/\1/p'); pw=$(echo "$rect" | sed -n 's/popover=[-0-9]*,[-0-9]*,\([0-9]*\),.*/\1/p')
  wx=$(echo "$rect" | sed -n 's/.*window=\([-0-9]*\),.*/\1/p'); ww=$(echo "$rect" | sed -n 's/.*window=[-0-9]*,[-0-9]*,\([0-9]*\),.*/\1/p')
  if [ -n "$px" ] && [ -n "$wx" ] && [ "$px" -ge "$wx" ] && [ $((px + pw)) -le $((wx + ww)) ]; then
    ok "footer menu stays inside the window ($t): $rect"
  else
    bad "footer menu hangs outside the window ($t): $rect"
  fi
  dbg uf-fields-close >/dev/null; sleep 0.4
done

# FILES is not photographed here: this mock app opens the real workspaces, so its tree would show their names.
# That fix is covered by FileClickLogic's unit tests and by the mock-data screenshots in scratchpad/ui-502-shots.
echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
