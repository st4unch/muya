#!/usr/bin/env bash
#
# e2e-v5.sh - synthetic-user end-to-end runs of Muya 5 (docs/prd-muya-v5-replace.md). A test tool, not shipped.
#
#   native/scripts/e2e-v5.sh <classic-update|orphan-control|return|bridge-move>
#
#   classic-update  a classic 4.1.22 copy runs the REAL Tauri updater path (check -> download_and_install -> restart) against a
#                   local feed; it must end as Muya 5 at the same path, start itself through LaunchServices, be accepted by
#                   muyad and carry the data
#   orphan-control  a signed client started as an orphan (what classic's relaunch alone gives the new app) is REFUSED by muyad
#                   while the same client started normally is accepted: the reason the start-up re-launch exists
#   return          Muya 5 -> "Return to Muya Classic": the pinned build lands in place, verified, the Muya 5 launchd jobs are
#                   booted out; classic's own updater then offers 5.0.0 again but never installs it by itself
#   bridge-move     the beta/bridge app (id <e2e>.native) becomes Muya.app in the same folder, old app in the Trash, old jobs gone
#
# Every app is a throwaway copy under the id com.staunch.muya.e2e[.native]; the real id, the real apps, the real LaunchAgents,
# Login Items and TCC are never touched. launchd jobs use the labels com.staunch.muya.e2e.{muyad,ptyd}, started from plists under
# the work dir with launchctl bootstrap (not SMAppService / BTM), and removed on exit.
#
# Inputs (env):
#   CLASSIC_E2E        classic 4.1.22 .app built from source with --features e2e + tauri.e2e.conf.json (id e2e, updater -> 127.0.0.1:38717)
#   V5_E2E             notarized + stapled Muya.app of the release flavour built with MUYA_E2E_ID (version 5.0.0)
#   BRIDGE_E2E         signed "Muya Native.app" of the bridge flavour built with MUYA_E2E_ID (version 4.1.27)
#   CLASSIC_E2E_ZIP    notarized zip of CLASSIC_E2E (the pinned build "Return" installs in the e2e world)
#   SIGN_IDENTITY      "Developer ID Application: ..." (signs the rpc client)
#   TAURI_CLI_DIR      a dir where `npx tauri signer sign` works
#   UPDATE_KEY         the updater private key (default ~/.tauri/muya-update.key)
#   WORK               short work dir (unix sockets hold 104 bytes)   [default /private/tmp/mv5]
# Keep running from a shell that stays alive: muyad refuses an orphaned client.
set -uo pipefail

SCEN=${1:?scenario: classic-update|orphan-control|return|bridge-move|scheduler-headless|launcher-old-os|release-update}
: "${CLASSIC_E2E:?}" "${V5_E2E:?}" "${BRIDGE_E2E:?}" "${CLASSIC_E2E_ZIP:?}" "${SIGN_IDENTITY:?}" "${TAURI_CLI_DIR:?}"
UPDATE_KEY=${UPDATE_KEY:-$HOME/.tauri/muya-update.key}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-/private/tmp/mv5}
FAKE="$W/$SCEN"; H="$FAKE/home"; APPS="$FAKE/Applications"; SRV="$FAKE/srv"
SD="$H/Library/Application Support/Muya"
PORT=38717   # compiled into the classic e2e build (tauri.e2e.conf.json)
FINDER_PATH=/usr/bin:/bin:/usr/sbin:/sbin
RELEASE_ID=com.staunch.muya.e2e; LEGACY_ID=com.staunch.muya.e2e.native
LABELS="com.staunch.muya.e2e.muyad com.staunch.muya.e2e.ptyd"
UIDN=$(id -u)
FAILS=0
say()  { printf '\n== [%s] %s\n' "$SCEN" "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
job_loaded() { launchctl print "gui/$UIDN/$1" >/dev/null 2>&1; }
real_stamp() { for f in "$HOME"/.claude/muya-*; do case "$f" in *.status.json) continue;; esac; [ -e "$f" ] && stat -f '%N %m %z' "$f"; done 2>/dev/null | sort; }

cleanup() {
  for l in $LABELS; do launchctl bootout "gui/$UIDN/$l" >/dev/null 2>&1; done
  [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null
  pkill -f "$FAKE/" 2>/dev/null
  chmod -R u+w "$APPS" 2>/dev/null
  true
}
trap cleanup EXIT

mkdir -p "$W"; real_stamp > "$W/real-home-before.$SCEN"
chmod -R u+w "$FAKE" 2>/dev/null; rm -rf "$FAKE"; mkdir -p "$H/.claude" "$APPS" "$SRV" "$SD" "$H/Library/Application Support/com.staunch.muya" "$H/.Trash"

# --- the rpc client (signed with an id muyad accepts) ----------------------------------------------------------------
CALL="$W/muyad_call"
if [ ! -x "$CALL" ]; then
  swiftc -O "$HERE/e2e/muyad_call.swift" -o "$CALL" || { echo "swiftc failed"; exit 2; }
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" --identifier com.staunch.muya.native "$CALL" || exit 2
fi

# --- the user's data ---------------------------------------------------------------------------------------------------
cat > "$H/.claude/muya-ssh-config.json" <<'EOF'
{"version":1,"servers":[{"id":"s1","label":"build box","host":"10.0.0.5","port":22,"username":"ops","connectionType":"direct"}],"psmpProfiles":[]}
EOF
cat > "$H/.claude/muya-schedules.json" <<EOF
{"version":1,"jobs":[{"id":"j1","name":"nightly","prompt":"summarise","folder":"$H","schedule":{"kind":"interval","minutes":30},"enabled":true,"timeoutMin":5,"bypass":false,"chrome":false,"created":1,"updated":1}]}
EOF
echo '{"debugLog":true}' > "$H/.claude/muya-settings.json"
( cd "$H/.claude" && shasum -a 256 muya-*.json > "$FAKE/shared-before.sha" )
# Classic's webview storage (workspaces, layout): the file the first-launch migration reads. The path is classic's real id.
LS="$H/Library/WebKit/com.staunch.muya/WebsiteData/Default/aaaa/bbbb/LocalStorage"; mkdir -p "$LS"
python3 - "$LS/localstorage.sqlite3" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); db.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)")
for k, v in {"apex.workspaces": '[{"path":"/work/demo","name":"demo"}]', "muya.gridLayout": '{"cols":2,"rows":1}'}.items():
    db.execute("INSERT INTO ItemTable VALUES (?,?)", (k, v.encode("utf-16-le")))
db.commit()
PY

# --- what the server serves --------------------------------------------------------------------------------------------
sign_file() { ( cd "$TAURI_CLI_DIR" && TAURI_SIGNING_PRIVATE_KEY_PATH="$UPDATE_KEY" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" npx tauri signer sign "$1" ) >/dev/null 2>&1; }
V5TGZ="$SRV/Muya-5.0.0-arm64.app.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$V5TGZ" -C "$(dirname "$V5_E2E")" "$(basename "$V5_E2E")"
BAD=$(python3 - "$V5TGZ" "$(basename "$V5_E2E")" <<'PY'
import sys, tarfile, pathlib
bad = [m.name for m in tarfile.open(sys.argv[1]).getmembers() if not pathlib.PurePath(m.name).parts or pathlib.PurePath(m.name).parts[0] != sys.argv[2] or any(p.startswith("._") for p in pathlib.PurePath(m.name).parts)]
print("\n".join(bad))
PY
)
[ -z "$BAD" ] && ok "updater archive has a single Muya.app root and no AppleDouble entries" || bad "stray entries: $BAD"
sign_file "$V5TGZ" || { echo "signing the tarball failed"; exit 2; }
SIG=$(cat "$V5TGZ.sig")
cat > "$SRV/latest.json" <<EOF
{"version":"5.0.0","notes":"e2e","pub_date":"2026-11-19T00:00:00Z","platforms":{"darwin-aarch64":{"signature":"$SIG","url":"http://127.0.0.1:$PORT/Muya-5.0.0-arm64.app.tar.gz"}}}
EOF
cp "$CLASSIC_E2E_ZIP" "$SRV/Muya-4.1.22-e2e.zip"; RETURN_SHA=$(shasum -a 256 "$SRV/Muya-4.1.22-e2e.zip" | awk '{print $1}')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" > "$FAKE/server.log" 2>&1 &
SPID=$!; sleep 1

# --- launchd stand-in: REAL launchd, e2e labels, jobs from plists under the work dir ------------------------------------
job_env() {
  cat <<EOF
    <key>HOME</key><string>$H</string><key>PATH</key><string>$FINDER_PATH</string><key>MUYA_SWITCHOVER_PASS_ENV</key><string>1</string>
    <key>MUYA_SWITCHOVER_E2E_LATEST_URL</key><string>http://127.0.0.1:$PORT/latest.json</string>
    <key>MUYA_SWITCHOVER_E2E_URL_PREFIX</key><string>http://127.0.0.1:$PORT/</string>
    <key>MUYA_SWITCHOVER_E2E_RELEASE_ID</key><string>$RELEASE_ID</string><key>MUYA_SWITCHOVER_E2E_LEGACY_ID</key><string>$LEGACY_ID</string>
    <key>MUYA_SWITCHOVER_E2E_LABELS</key><string>com.staunch.muya.e2e.muyad,com.staunch.muya.e2e.ptyd</string>
    <key>MUYA_SWITCHOVER_E2E_RETURN_URL</key><string>http://127.0.0.1:$PORT/Muya-4.1.22-e2e.zip</string><key>MUYA_SWITCHOVER_E2E_RETURN_SHA</key><string>$RETURN_SHA</string>
EOF
}
write_job() {   # label, executable, args...
  local label=$1 exe=$2; shift 2
  local f="$FAKE/$label.plist"
  { echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
    echo "<key>Label</key><string>$label</string><key>ProgramArguments</key><array><string>$exe</string>"
    for a in "$@"; do echo "<string>$a</string>"; done
    echo "</array><key>EnvironmentVariables</key><dict>"; job_env; echo "</dict>"
    echo "<key>KeepAlive</key><true/><key>RunAtLoad</key><true/><key>ThrottleInterval</key><integer>1</integer>"
    echo "<key>StandardErrorPath</key><string>$FAKE/$label.log</string><key>StandardOutPath</key><string>$FAKE/$label.log</string></dict></plist>"; } > "$f"
  launchctl bootstrap "gui/$UIDN" "$f"
}
start_services() {   # from the bundle at $1: ptyd, then muyad
  local nat="$1/Contents/MacOS"
  write_job com.staunch.muya.e2e.ptyd "$nat/muya-ptyd" --socket "$SD/ptyd.sock"
  sleep 1
  write_job com.staunch.muya.e2e.muyad "$nat/muyad" --socket "$SD/muyad.sock" --ptyd "$SD/ptyd.sock" --broker --scheduler   # = the shipping LaunchAgent plist
  for i in $(seq 1 30); do [ -S "$SD/muyad.sock" ] && break; sleep 0.5; done
}
launch_app() { open -n --env "HOME=$H" --env "PATH=$FINDER_PATH" --env "MUYA_SWITCHOVER_PASS_ENV=1" "$1"; }
# The launcher (Contents/MacOS/muya) execs the app and keeps argv[0], so the command line says ".../MacOS/muya" while the process image is MuyaNative.
app_pids() { pgrep -f "$1/Contents/MacOS/muya( |\$)" | tr '\n' ' '; }
# The executable image of a pid (the first "txt" mapping): ps shows argv[0], which the launcher keeps, so ask lsof.
image_of() { lsof -p "$1" 2>/dev/null | awk '$4=="txt"{ $1=$2=$3=$4=$5=$6=$7=$8=""; sub(/^ +/,""); print; exit }'; }
classic_pids() { local p; for p in $(pgrep -f "$1/Contents/MacOS/muya( |\$)"); do case "$(image_of "$p")" in */MacOS/muya) echo "$p";; esac; done | tr '\n' ' '; }

say "environment: work dir $FAKE, ids $RELEASE_ID / $LEGACY_ID, launchd labels: $LABELS"
case "$SCEN" in
# ======================================================================================================================
classic-update)
  ditto "$CLASSIC_E2E" "$APPS/Muya.app"
  say "classic copy installed at $APPS/Muya.app ($(plist "$APPS/Muya.app" CFBundleIdentifier) $(plist "$APPS/Muya.app" CFBundleShortVersionString), exe $(plist "$APPS/Muya.app" CFBundleExecutable))"
  HOME="$H" PATH="$FINDER_PATH" MUYA_E2E_AUTOUPDATE=1 MUYA_SWITCHOVER_PASS_ENV=1 "$APPS/Muya.app/Contents/MacOS/muya" > "$FAKE/classic.log" 2>&1 &
  CPID=$!
  say "classic running (pid $CPID); waiting for the updater to install and restart"
  for i in $(seq 1 90); do grep -q "installed; restarting" "$H/e2e-update.log" 2>/dev/null && break; sleep 1; done
  cat "$H/e2e-update.log" 2>/dev/null
  check "the classic updater found 5.0.0 and installed it" grep -q "installed; restarting" "$H/e2e-update.log"
  for i in $(seq 1 40); do [ -n "$(app_pids "$APPS/Muya.app")" ] && break; sleep 0.5; done
  sleep 3
  check "classic (pid $CPID) exited by itself after the restart" bash -c "! kill -0 $CPID"
  NEWP=$(app_pids "$APPS/Muya.app"); say "Muya 5 process(es): ${NEWP:-none}"
  ls -A "$APPS"
  check "the folder holds only Muya.app (same path, same name)" test "$(ls -A "$APPS")" = "Muya.app"
  check "bundle id is the (e2e) release id" test "$(plist "$APPS/Muya.app" CFBundleIdentifier)" = "$RELEASE_ID"
  check "version is 5.0.0" test "$(plist "$APPS/Muya.app" CFBundleShortVersionString)" = "5.0.0"
  check "the bundle executable is the launcher `muya` (the updater spawns it from the new Info.plist)" test "$(plist "$APPS/Muya.app" CFBundleExecutable)" = "muya"
  check "codesign --verify --deep --strict on the installed bundle" codesign --verify --deep --strict "$APPS/Muya.app"
  SP=$(spctl -a -t exec -vv "$APPS/Muya.app" 2>&1); echo "$SP"
  case "$SP" in *accepted*"Notarized Developer ID"*) ok "spctl: accepted, Notarized Developer ID (the unpacked tarball kept the stapled ticket)";; *) bad "spctl: $SP";; esac
  # The relaunch: the process that runs now was started by LaunchServices (parent 1), not by the dead classic.
  APID=$(echo "$NEWP" | awk '{print $NF}')
  if [ -n "$APID" ]; then
    echo "ps: $(ps -o pid=,ppid=,command= -p "$APID" | cut -c1-200)"
    check "the running Muya 5 was started through LaunchServices (ppid 1, --relaunched-by-launchservices)" bash -c "[ \$(ps -o ppid= -p $APID | tr -d ' ') = 1 ] && ps -o command= -p $APID | grep -q -- --relaunched-by-launchservices"
    check "...and the process image is the real app (the launcher exec'd MuyaNative: its executable image is MuyaNative)" bash -c "lsof -p $APID | awk '\$4==\"txt\"' | head -1 | grep -q /MuyaNative"
  else bad "no Muya 5 process"; fi
  say "services: launchd (e2e labels) starts ptyd + muyad from the NEW bundle"
  start_services "$APPS/Muya.app"
  sleep 8
  MP=$(pgrep -f "$APPS/Muya.app/Contents/MacOS/muyad" | head -1)
  check "muyad runs from the new bundle (pid ${MP:-none})" test -n "$MP"
  check "the app is still running after muyad came up" test -n "$(app_pids "$APPS/Muya.app")"
  echo "--- muyad log"; tail -5 "$FAKE/com.staunch.muya.e2e.muyad.log" 2>/dev/null | cut -c1-200
  check "muyad did not refuse the app" bash -c "! grep -qi 'refus' '$FAKE/com.staunch.muya.e2e.muyad.log'"
  PREFS="$H/Library/Application Support/com.staunch.muya/native/ui-prefs.json"
  for i in $(seq 1 20); do [ -s "$PREFS" ] && break; sleep 0.5; done
  check "classic's workspaces were migrated (ui-prefs.json has apex.workspaces)" grep -q "apex.workspaces" "$PREFS"
  ST=$("$CALL" "$SD/muyad.sock" update_status "{\"appPath\":\"$APPS/Muya.app\"}"); echo "$ST"
  case "$ST" in *'"installed":"5.0.0"'*'"kind":"release"'*|*'"kind":"release"'*'"installed":"5.0.0"'*) ok "muyad: installed 5.0.0, kind release (the update feed is already current)";; *) bad "update_status";; esac
  ;;
# ======================================================================================================================
orphan-control)
  ditto "$V5_E2E" "$APPS/Muya.app"
  start_services "$APPS/Muya.app"
  say "the same signed client, once started normally (a child of this shell) and once as an orphan that the system attributes to another process"
  "$CALL" "$SD/muyad.sock" update_status "{\"appPath\":\"$APPS/Muya.app\"}" > "$FAKE/normal-call.out" 2>&1; cat "$FAKE/normal-call.out"
  check "a normal child of a live shell is accepted by muyad" grep -q '"ok":1' "$FAKE/normal-call.out"
  bash -c "'$CALL' '$SD/muyad.sock' update_status '{}' > '$FAKE/orphan-call.out' 2>&1 &"
  sleep 4; cat "$FAKE/orphan-call.out"
  check "the orphan (parent launchd, attributed to another process) is REFUSED by muyad: this is what classic's relaunch alone would give the new app" grep -q "refused: .*launchd-parented" "$FAKE/orphan-call.out"
  ;;
# ======================================================================================================================
return)
  ditto "$V5_E2E" "$APPS/Muya.app"
  start_services "$APPS/Muya.app"
  launch_app "$APPS/Muya.app"
  for i in $(seq 1 30); do [ -n "$(app_pids "$APPS/Muya.app")" ] && break; sleep 0.5; done; sleep 5
  APP0=$(app_pids "$APPS/Muya.app"); check "Muya 5 running (pid ${APP0:-none}) and services up" test -n "$APP0"
  check "both e2e launchd jobs loaded before the return" bash -c "launchctl print gui/$UIDN/com.staunch.muya.e2e.muyad >/dev/null && launchctl print gui/$UIDN/com.staunch.muya.e2e.ptyd >/dev/null"
  ST=$("$CALL" "$SD/muyad.sock" update_status "{\"appPath\":\"$APPS/Muya.app\"}"); echo "$ST"
  case "$ST" in *'"returnVersion":"4.1.22"'*) ok "muyad says the return target is 4.1.22";; *) bad "status: $ST";; esac
  say "return_classic_start (listening for events)"
  MUYAD_CALL_EVENTS_SECS=120 "$CALL" "$SD/muyad.sock" return_classic_start "{\"appPath\":\"$APPS/Muya.app\"}" | tee "$FAKE/return.out"
  sleep 8
  check "events reached phase done" grep -q '"phase":"done"' "$FAKE/return.out"
  ls -A "$APPS"
  check "the folder holds only Muya.app (same path, same name)" test "$(ls -A "$APPS")" = "Muya.app"
  check "it is classic now: bundle id still the (e2e) release id" test "$(plist "$APPS/Muya.app" CFBundleIdentifier)" = "$RELEASE_ID"
  check "it is classic 4.1.22 (executable muya, version 4.1.22)" bash -c "[ \"$(plist "$APPS/Muya.app" CFBundleExecutable)\" = muya ] && [ \"$(plist "$APPS/Muya.app" CFBundleShortVersionString)\" = 4.1.22 ]"
  check "codesign --verify --deep --strict" codesign --verify --deep --strict "$APPS/Muya.app"
  SP=$(spctl -a -t exec -vv "$APPS/Muya.app" 2>&1); echo "$SP"
  case "$SP" in *accepted*"Notarized Developer ID"*) ok "spctl: accepted, Notarized Developer ID";; *) bad "spctl: $SP";; esac
  TR=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('trashedPreviousTarget') or '')" "$H/Library/Application Support/com.staunch.muya/switchover/switch.json" 2>/dev/null)
  echo "trashed Muya 5: ${TR:-none}"; check "the Muya 5 bundle is in the Trash" test -d "$TR"
  check "classic is running from the same path (process image .../muya)" test -n "$(classic_pids "$APPS/Muya.app")"
  sleep 6
  say "login items: no job may point at the Trash or a missing program"
  check "e2e muyad job is gone from launchd" bash -c "! launchctl print gui/$UIDN/com.staunch.muya.e2e.muyad >/dev/null 2>&1"
  check "e2e ptyd job is gone from launchd" bash -c "! launchctl print gui/$UIDN/com.staunch.muya.e2e.ptyd >/dev/null 2>&1"
  check "no daemon process of Muya 5 left (muyad / muya-ptyd under $APPS or the Trash)" bash -c "! pgrep -f 'Muya.app/Contents/MacOS/(muyad|muya-ptyd)' | xargs -I{} ps -o command= -p {} | grep -q \"$FAKE\\|.Trash\""
  say "classic 4.1.22's own updater offers 5.0.0 again, and does not install it by itself"
  V0=$(plist "$APPS/Muya.app" CFBundleShortVersionString)
  HOME="$H" PATH="$FINDER_PATH" MUYA_E2E_AUTOUPDATE=check "$APPS/Muya.app/Contents/MacOS/muya" > "$FAKE/classic-check.log" 2>&1 &
  CK=$!; for i in $(seq 1 40); do grep -q "update available" "$H/e2e-update.log" 2>/dev/null && break; sleep 1; done; sleep 15
  cat "$H/e2e-update.log" 2>/dev/null
  check "classic offers 5.0.0 (update available: 5.0.0)" grep -q "update available: 5.0.0" "$H/e2e-update.log"
  check "...but nothing was installed: version still $V0" test "$(plist "$APPS/Muya.app" CFBundleShortVersionString)" = "$V0"
  check "...and the folder is unchanged" test "$(ls -A "$APPS")" = "Muya.app"
  kill "$CK" 2>/dev/null
  ;;
# ======================================================================================================================
bridge-move)
  ditto "$BRIDGE_E2E" "$APPS/Muya Native.app"
  OLD="$APPS/Muya Native.app"
  start_services "$OLD"
  launch_app "$OLD"
  for i in $(seq 1 30); do [ -n "$(app_pids "$OLD")" ] && break; sleep 0.5; done; sleep 5
  APP0=$(app_pids "$OLD"); check "the bridge app is running (pid ${APP0:-none}), id $(plist "$OLD" CFBundleIdentifier), version $(plist "$OLD" CFBundleShortVersionString)" test -n "$APP0"
  ST=$("$CALL" "$SD/muyad.sock" update_status "{\"appPath\":\"$OLD\"}"); echo "$ST"
  case "$ST" in *'"kind":"legacy"'*) ok "muyad classifies it as legacy";; *) bad "status: $ST";; esac
  CK=$("$CALL" "$SD/muyad.sock" update_check "{\"appPath\":\"$OLD\"}"); echo "$CK"
  case "$CK" in *'"version":"5.0.0"'*) ok "update_check offers 5.0.0";; *) bad "check: $CK";; esac
  say "update_install (listening for events)"
  MUYAD_CALL_EVENTS_SECS=120 "$CALL" "$SD/muyad.sock" update_install "{\"appPath\":\"$OLD\"}" | tee "$FAKE/move.out"
  sleep 10
  check "events reached phase done" grep -q '"phase":"done"' "$FAKE/move.out"
  ls -A "$APPS"
  check "the folder holds only Muya.app (landed as Muya.app, same folder)" test "$(ls -A "$APPS")" = "Muya.app"
  check "new bundle id is the (e2e) release id" test "$(plist "$APPS/Muya.app" CFBundleIdentifier)" = "$RELEASE_ID"
  check "new version is 5.0.0" test "$(plist "$APPS/Muya.app" CFBundleShortVersionString)" = "5.0.0"
  check "codesign --verify --deep --strict" codesign --verify --deep --strict "$APPS/Muya.app"
  SP=$(spctl -a -t exec -vv "$APPS/Muya.app" 2>&1); echo "$SP"
  case "$SP" in *accepted*"Notarized Developer ID"*) ok "spctl: accepted, Notarized Developer ID";; *) bad "spctl: $SP";; esac
  NEW=$(app_pids "$APPS/Muya.app"); check "Muya 5 is running (pid ${NEW:-none})" test -n "$NEW"
  TR=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('trashedSource') or '')" "$H/Library/Application Support/com.staunch.muya/switchover/switch.json" 2>/dev/null)
  echo "trashed bridge app: ${TR:-none}"; check "the old Muya Native.app is in the Trash" test -d "$TR"
  sleep 6
  say "login items: the old jobs must be gone, nothing may run from the Trash"
  check "e2e muyad job is gone from launchd" bash -c "! launchctl print gui/$UIDN/com.staunch.muya.e2e.muyad >/dev/null 2>&1"
  check "e2e ptyd job is gone from launchd" bash -c "! launchctl print gui/$UIDN/com.staunch.muya.e2e.ptyd >/dev/null 2>&1"
  echo "processes still running from the old path (the old APP stays until its own window steps aside; only daemons matter):"; pgrep -fl 'Muya Native.app/Contents/MacOS' | cut -c1-160 || true
  check "no daemon (muyad / muya-ptyd) runs from the old path or the Trash" bash -c "! pgrep -f 'Muya Native.app/Contents/MacOS/(muyad|muya-ptyd)' >/dev/null"
  check "the only thing left from the old path is the old app itself (nothing in the Trash runs)" bash -c "! pgrep -f '.Trash/' >/dev/null"
  ;;
scheduler-headless)
  # Parity with classic's background scheduler agent: muyad (started with the shipping plist's arguments) fires a schedule while
  # NO app window runs. `claude` is a stub in the synthetic home that records how it was called.
  ditto "$V5_E2E" "$APPS/Muya.app"
  mkdir -p "$H/.local/bin"
  cat > "$H/.local/bin/claude" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo 2.1.245 ;;
  agents) echo '[]' ;;
  *) echo "$@" > "$HOME/schedule-fired.txt"; echo '{"type":"result","result":"scheduled run ok","total_cost_usd":0}' ;;
esac
EOF
  chmod +x "$H/.local/bin/claude"
  FIRE=$(date -v+2M +%H:%M)
  cat > "$H/.claude/muya-schedules.json" <<EOF
{"version":1,"jobs":[{"id":"j9","name":"headless","prompt":"say hi","folder":"$H","schedule":{"kind":"daily","time":"$FIRE"},"enabled":true,"timeoutMin":5,"bypass":false,"chrome":false,"created":1,"updated":1}]}
EOF
  ( cd "$H/.claude" && shasum -a 256 muya-ssh-config.json muya-settings.json > "$FAKE/shared-before.sha" )
  start_services "$APPS/Muya.app"
  check "no Muya app window is running" test -z "$(app_pids "$APPS/Muya.app")"
  say "schedule 'headless' is due at $FIRE (local); waiting for muyad to fire it"
  for i in $(seq 1 200); do [ -s "$H/schedule-fired.txt" ] && break; sleep 1; done
  echo "claude was called with: $(cat "$H/schedule-fired.txt" 2>/dev/null)"
  check "the schedule fired with no app window running (stub claude ran with the prompt)" grep -q "say hi" "$H/schedule-fired.txt"
  check "still no app window" test -z "$(app_pids "$APPS/Muya.app")"
  ;;
# ======================================================================================================================
launcher-old-os)
  # The launcher on a Mac that is too old for Muya 5 (simulated with the fake-OS override of the e2e launcher build, which the
  # shipping launcher does not contain): classic 4.1.22 is restored in place through the pinned, verified return, no app starts.
  ditto "$V5_E2E" "$APPS/Muya.app"
  say "Muya 5 bundle at $APPS/Muya.app, launcher says the OS is 13"
  ( export HOME="$H" PATH="$FINDER_PATH" MUYA_SWITCHOVER_PASS_ENV=1 MUYA_LAUNCHER_FAKE_MAJOR=13 MUYA_LAUNCHER_NO_DIALOG=1 \
      MUYA_SWITCHOVER_E2E_URL_PREFIX="http://127.0.0.1:$PORT/" MUYA_SWITCHOVER_E2E_RELEASE_ID="$RELEASE_ID" MUYA_SWITCHOVER_E2E_LEGACY_ID="$LEGACY_ID" \
      MUYA_SWITCHOVER_E2E_RETURN_URL="http://127.0.0.1:$PORT/Muya-4.1.22-e2e.zip" MUYA_SWITCHOVER_E2E_RETURN_SHA="$RETURN_SHA"
    "$APPS/Muya.app/Contents/MacOS/muya" > "$FAKE/launcher.out" 2>&1; echo "exit=$?" >> "$FAKE/launcher.out" )
  cat "$FAKE/launcher.out" | cut -c1-220
  check "the launcher exited 0 after restoring" grep -q "exit=0" "$FAKE/launcher.out"
  check "the one-line notice was given" grep -q "Muya 5 needs macOS 14 or later" "$FAKE/launcher.out"
  ls -A "$APPS"
  check "the folder holds only Muya.app (same path, same name)" test "$(ls -A "$APPS")" = "Muya.app"
  check "it is classic 4.1.22 (executable muya, version 4.1.22, e2e id)" bash -c "[ \"$(plist "$APPS/Muya.app" CFBundleShortVersionString)\" = 4.1.22 ] && [ \"$(plist "$APPS/Muya.app" CFBundleIdentifier)\" = $RELEASE_ID ] && [ -x \"$APPS/Muya.app/Contents/MacOS/muya\" ] && [ ! -e \"$APPS/Muya.app/Contents/MacOS/MuyaNative\" ]"
  check "codesign --verify --deep --strict" codesign --verify --deep --strict "$APPS/Muya.app"
  SP=$(spctl -a -t exec -vv "$APPS/Muya.app" 2>&1); echo "$SP"
  case "$SP" in *accepted*"Notarized Developer ID"*) ok "spctl: accepted, Notarized Developer ID";; *) bad "spctl: $SP";; esac
  sleep 4
  check "classic is opened and running from that path" test -n "$(classic_pids "$APPS/Muya.app")"
  check "no Muya 5 app process was ever left running" bash -c "! pgrep -f 'MuyaNative' | xargs -I{} ps -o command= -p {} | grep -q '$FAKE'"
  TR=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('trashedPreviousTarget') or '')" "$H/Library/Application Support/com.staunch.muya/switchover/switch.json" 2>/dev/null)
  check "the Muya 5 bundle is in the Trash ($TR)" test -d "$TR"
  ;;
release-update)
  # The ordinary update of an installed Muya 5: Check for Updates (update_check) offers a newer latest.json, Install & Restart
  # (update_install) replaces the app in place, launchd (real, e2e labels) restarts muyad from the new bundle, the new version runs.
  ditto "$V5_E2E" "$APPS/Muya.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 4.9.0" "$APPS/Muya.app/Contents/Info.plist"   # the INSTALLED copy is "older"
  MUYA_SIGN_IDENTITY="$SIGN_IDENTITY" bash "$HERE/sign.sh" "$APPS/Muya.app" >/dev/null 2>&1 || { echo "re-signing the older copy failed"; exit 2; }
  start_services "$APPS/Muya.app"
  launch_app "$APPS/Muya.app"
  for i in $(seq 1 30); do [ -n "$(app_pids "$APPS/Muya.app")" ] && break; sleep 0.5; done; sleep 5
  APP0=$(app_pids "$APPS/Muya.app"); MUYAD0=$(pgrep -f "$APPS/Muya.app/Contents/MacOS/muyad" | head -1)
  check "Muya 4.9.0 (the older copy) is running (pid ${APP0:-none}) with muyad pid ${MUYAD0:-none}" test -n "$APP0" -a -n "$MUYAD0"
  CK=$("$CALL" "$SD/muyad.sock" update_check "{\"appPath\":\"$APPS/Muya.app\"}"); echo "$CK"
  case "$CK" in *'"available":true'*'"version":"5.0.0"'*) ok "Check for Updates: 5.0.0 is available (installed 4.9.0)";; *) bad "check: $CK";; esac
  ST=$("$CALL" "$SD/muyad.sock" update_status "{\"appPath\":\"$APPS/Muya.app\"}"); echo "$ST"
  case "$ST" in *'"pending":{"version":"5.0.0"}'*|*'"pending":{'*'5.0.0'*) ok "the pending update is remembered (the footer notice reads it)";; *) bad "status has no pending update: $ST";; esac
  MUYAD_CALL_EVENTS_SECS=120 "$CALL" "$SD/muyad.sock" update_install "{\"appPath\":\"$APPS/Muya.app\"}" | tee "$FAKE/update.out"
  sleep 10
  check "events reached phase done" grep -q '"phase":"done"' "$FAKE/update.out"
  check "same path, same name: only Muya.app" test "$(ls -A "$APPS")" = "Muya.app"
  check "the new version is 5.0.0" test "$(plist "$APPS/Muya.app" CFBundleShortVersionString)" = "5.0.0"
  check "codesign --verify --deep --strict" codesign --verify --deep --strict "$APPS/Muya.app"
  SP=$(spctl -a -t exec -vv "$APPS/Muya.app" 2>&1); case "$SP" in *accepted*"Notarized Developer ID"*) ok "spctl: accepted, Notarized Developer ID";; *) bad "spctl: $SP";; esac
  NEW=$(app_pids "$APPS/Muya.app"); check "Muya 5.0.0 is running (pid ${NEW:-none})" test -n "$NEW"
  MUYAD1=$(pgrep -f "$APPS/Muya.app/Contents/MacOS/muyad" | head -1)
  check "launchd restarted muyad from the new bundle (pid $MUYAD0 -> ${MUYAD1:-none})" test -n "$MUYAD1" -a "$MUYAD1" != "$MUYAD0"
  ST=$("$CALL" "$SD/muyad.sock" update_status "{\"appPath\":\"$APPS/Muya.app\"}"); echo "$ST"
  case "$ST" in *'"installed":"5.0.0"'*) ok "the new muyad reports 5.0.0";; *) bad "status after: $ST";; esac
  ;;
esac

check "seeded ~/.claude/muya-*.json unchanged" bash -c "cd '$H/.claude' && shasum -a 256 -c '$FAKE/shared-before.sha'"
real_stamp > "$W/real-home-after.$SCEN"
check "real ~/.claude/muya-* untouched (name/mtime/size)" diff "$W/real-home-before.$SCEN" "$W/real-home-after.$SCEN"
say "RESULT: $([ $FAILS = 0 ] && echo PASS || echo "FAIL ($FAILS)")   work dir: $FAKE"
exit $FAILS
