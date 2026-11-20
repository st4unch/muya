#!/usr/bin/env bash
#
# e2e-self-update.sh — synthetic-user end-to-end run of Muya Native's SELF-UPDATE (beta_update_check / beta_update_install).
#
#   native/scripts/e2e-self-update.sh <happy|badsha|wrongsigner|readonly>
#
# Inputs (env):
#   NATIVE_ZIP            notarized Native zip (the "new" build the test server offers)            [required]
#   E2E_KEY / E2E_PUB     test minisign key file / its Tauri-style base64 public key (file or literal) [required]
#   TAURI_CLI_DIR         a dir where `npx tauri signer sign` works (signs the manifest)           [required]
#   SIGN_IDENTITY         "Developer ID Application: …" (signs the rpc client + the e2e muyad)      [required]
#   WORK                  short work dir (unix sockets hold 104 bytes)    [default /private/tmp/mce2e/selfupdate]
#   E2E_MUYAD             prebuilt muyad (cargo build -p muyad --features e2e); built here when unset
#   APP_FOLDER / APP_NAME  folder (under the work dir) and file name the OLD copy runs from [Applications / Muya Native.app]
#   OLD_VERSION           version the installed copy is patched to          [default: zip version minus one patch]
#
# What it does: throwaway HOME with seeded ~/.claude/muya-*.json, the zip installed into <work>/Applications, ITS
# Info.plist patched to an older version (only the installed copy), the app launched like Finder does, ptyd + the e2e
# muyad started by hand, then rpc beta_update_check + beta_update_install. The script plays launchd: when muyad
# exits it starts it again from the INSTALLED bundle (what the LaunchAgent plist's KeepAlive does). Test tool, not shipped.
# Side effect: NSFileManager trashes into the REAL ~/.Trash even with a fake HOME (it ignores $HOME).
set -uo pipefail

SCEN=${1:?scenario: happy|badsha|wrongsigner|readonly}
: "${NATIVE_ZIP:?}" "${E2E_KEY:?}" "${E2E_PUB:?}" "${TAURI_CLI_DIR:?}" "${SIGN_IDENTITY:?}"
W=${WORK:-/private/tmp/mce2e/selfupdate}
HERE=$(cd "$(dirname "$0")" && pwd)
FAKE="$W/$SCEN"; H="$FAKE/home"; APPS="$FAKE/${APP_FOLDER:-Applications}"; SRV="$FAKE/srv"
PORT=$((20000 + RANDOM % 20000))
PUB=$E2E_PUB; [ -f "$PUB" ] && PUB=$(tr -d '\n' < "$PUB")
FINDER_PATH=/usr/bin:/bin:/usr/sbin:/sbin
SD="$H/Library/Application Support/Muya"
APP="$APPS/${APP_NAME:-Muya Native.app}"   # APP_FOLDER / APP_NAME: run the installed copy from e.g. "Desktop" as "Muya Native Yeni.app"
NAT="$APP/Contents/MacOS"
FAILS=0
say() { printf '\n== [%s] %s\n' "$SCEN" "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null; }
app_pid() { pgrep -f "$APP/Contents/MacOS/MuyaNative" | head -1; }
# *.status.json is rewritten every ~15 s by whatever real Muya runs on the host (scheduler heartbeat), not by this test.
real_stamp() { for f in "$HOME"/.claude/muya-*; do case "$f" in *.status.json) continue;; esac; [ -e "$f" ] && stat -f '%N %m %z' "$f"; done 2>/dev/null | sort; }

cleanup() {
  chmod -R u+w "$APPS" 2>/dev/null
  touch "$FAKE/stop-launchd" 2>/dev/null
  pkill -f "$FAKE/" 2>/dev/null; pkill -f "$W/$SCEN/" 2>/dev/null
  [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null
  true
}
trap cleanup EXIT

mkdir -p "$W"; real_stamp > "$W/real-home-before.$SCEN"
chmod -R u+w "$FAKE" 2>/dev/null; rm -rf "$FAKE"; mkdir -p "$H/.claude" "$APPS" "$SRV" "$SD" "$W"

# --- tools: signed rpc client, signed e2e muyad --------------------------------------------------------
CALL="$W/muyad_call"
if [ ! -x "$CALL" ]; then
  swiftc -O "$HERE/e2e/muyad_call.swift" -o "$CALL" || { echo "swiftc failed"; exit 2; }
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" --identifier com.staunch.muya.native "$CALL" || exit 2
fi
E2E_MUYAD_BIN=${E2E_MUYAD:-}
if [ -z "$E2E_MUYAD_BIN" ]; then
  ( cd "$HERE/.." && eval "$(bash scripts/ghostty-env.sh)" && CARGO_TARGET_DIR="$W/target" cargo build --release -p muyad --features e2e ) >/dev/null 2>&1 || { echo "e2e muyad build failed"; exit 2; }
  E2E_MUYAD_BIN="$W/target/release/muyad"
fi
SIGNED_MUYAD="$W/muyad-e2e"; cp "$E2E_MUYAD_BIN" "$SIGNED_MUYAD"
codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" --identifier com.staunch.muya.muyad "$SIGNED_MUYAD" || exit 2

# --- seed the user's data -------------------------------------------------------------------------------
cat > "$H/.claude/muya-ssh-config.json" <<'EOF'
{"version":1,"servers":[{"id":"s1","label":"build box","host":"10.0.0.5","port":22,"username":"ops","connectionType":"direct"}],"psmpProfiles":[]}
EOF
cat > "$H/.claude/muya-schedules.json" <<EOF
{"version":1,"jobs":[{"id":"j1","name":"nightly","prompt":"summarise","folder":"$H","schedule":{"kind":"interval","minutes":30},"enabled":true,"timeoutMin":5,"bypass":false,"chrome":false,"created":1,"updated":1}]}
EOF
echo '{"debugLog":true}' > "$H/.claude/muya-settings.json"
( cd "$H/.claude" && shasum -a 256 muya-*.json > "$FAKE/shared-before.sha" )

# --- install the "old" Native -----------------------------------------------------------------------------
T="$FAKE/unz"; mkdir -p "$T"; ditto -x -k "$NATIVE_ZIP" "$T"
NEWV=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$T/Muya Native.app/Contents/Info.plist")
OLDV=${OLD_VERSION:-$(python3 -c "import sys;a=sys.argv[1].split('.');a[-1]=str(int(a[-1])-1);print('.'.join(a))" "$NEWV")}
ditto "$T/Muya Native.app" "$APP"; rm -rf "$T"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OLDV" "$APP/Contents/Info.plist"   # only the installed copy
# The patch breaks the seal and macOS then refuses to launch it: re-sign the installed copy with the same Developer ID
# (a real older release is validly signed too). Not notarized; fine without quarantine. The served zip is untouched.
codesign --force --deep --options runtime --timestamp --preserve-metadata=entitlements -s "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 || { echo "re-signing the old copy failed"; exit 2; }
INFO_SHA_BEFORE=$(shasum -a 256 "$APP/Contents/Info.plist" | cut -d' ' -f1)

# --- what the server serves -------------------------------------------------------------------------------
SERVE_ZIP="$SRV/Muya-Native-beta.zip"
case "$SCEN" in
  wrongsigner)  # a valid zip (its own sha is published) whose app is re-signed ad-hoc: right sha, wrong signer
    T=$(mktemp -d); ditto -x -k "$NATIVE_ZIP" "$T"
    codesign --force --deep -s - "$T/Muya Native.app" >/dev/null 2>&1
    ditto -c -k --keepParent "$T/Muya Native.app" "$SERVE_ZIP"; rm -rf "$T" ;;
  *) cp "$NATIVE_ZIP" "$SERVE_ZIP" ;;
esac
SHA=$(shasum -a 256 "$SERVE_ZIP" | awk '{print $1}')
[ "$SCEN" = badsha ] && SHA=$(printf '0%.0s' $(seq 64))
cat > "$SRV/native-beta.json" <<EOF
{"schema":1,"channel":"beta","version":"$NEWV","url":"http://127.0.0.1:$PORT/Muya-Native-beta.zip","sha256":"$SHA","minClassicVersion":"4.1.21","notes":"e2e self-update"}
EOF
( cd "$TAURI_CLI_DIR" && npx tauri signer sign -f "$E2E_KEY" -p "" "$SRV/native-beta.json" ) >/dev/null 2>&1 || { echo "signing the manifest failed"; exit 2; }
mv "$SRV/native-beta.json.sig" "$SRV/native-beta.json.minisig"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" > "$FAKE/server.log" 2>&1 &
SPID=$!; sleep 1

# --- daemons: ptyd, and muyad under a launchd stand-in -----------------------------------------------------
say "installed version $OLDV (zip is $NEWV); starting daemons and the app as a synthetic user"
( HOME="$H" PATH=$FINDER_PATH nohup "$NAT/muya-ptyd" --socket "$SD/ptyd.sock" > "$FAKE/ptyd.log" 2>&1 & )
sleep 1
cat > "$FAKE/launchd.sh" <<EOF
#!/bin/bash
# Stand-in for launchd + KeepAlive: first run is the e2e muyad, every restart is the INSTALLED bundle's muyad.
export HOME="$H" PATH=$FINDER_PATH MUYA_SWITCHOVER_PASS_ENV=1
export MUYA_SWITCHOVER_E2E_MANIFEST_URL="http://127.0.0.1:$PORT/native-beta.json" MUYA_SWITCHOVER_E2E_PUBKEY="$PUB" MUYA_SWITCHOVER_E2E_URL_PREFIX="http://127.0.0.1:$PORT/"
bin="$SIGNED_MUYAD"
while [ ! -e "$FAKE/stop-launchd" ]; do
  "\$bin" --socket "$SD/muyad.sock" --ptyd "$SD/ptyd.sock" >> "$FAKE/muyad.log" 2>&1 &
  pid=\$!; echo "\$(date +%s) start pid=\$pid bin=\$bin" >> "$FAKE/launchd.log"
  wait \$pid; echo "\$(date +%s) exit pid=\$pid code=\$?" >> "$FAKE/launchd.log"
  bin="$NAT/muyad"; sleep 1
done
EOF
chmod +x "$FAKE/launchd.sh"; ( nohup "$FAKE/launchd.sh" > /dev/null 2>&1 & )
for i in $(seq 1 20); do [ -S "$SD/muyad.sock" ] && break; sleep 0.5; done
MUYAD0=$(awk '/start/{sub("pid=","",$3);print $3;exit}' "$FAKE/launchd.log")
open -n --env "HOME=$H" --env "PATH=$FINDER_PATH" --env "MUYA_SWITCHOVER_PASS_ENV=1" "$APP"
for i in $(seq 1 30); do [ -n "$(app_pid)" ] && break; sleep 0.5; done
sleep 4
APP0=$(app_pid)
check "old app running (pid $APP0) and muyad up (pid $MUYAD0)" test -n "$APP0" -a -n "$MUYAD0"
kill -0 "$MUYAD0" 2>/dev/null || bad "e2e muyad not alive"

# --- 1. check ------------------------------------------------------------------------------------------------
say "beta_update_check"
OUT=$("$CALL" "$SD/muyad.sock" beta_update_check "{\"appPath\":\"$APP\"}"); echo "$OUT"
case "$OUT" in *"\"available\":1"*|*"\"available\":true"*) ok "check: update available";; *) bad "check: update not available";; esac
case "$OUT" in *"\"version\":\"$NEWV\""*) ok "check: offers $NEWV";; *) bad "check: wrong version";; esac

# --- 2. install ----------------------------------------------------------------------------------------------
say "beta_update_install (listening for events)"
( while [ ! -e "$FAKE/stop-sampler" ]; do echo "$(date +%s) $(pgrep -f "$APP/Contents/MacOS/MuyaNative" | tr '\n' ' ')" >> "$FAKE/app-pids.log"; sleep 0.5; done ) &
SAMPLER=$!
# readonly: the folder that holds the app is not writable for this user — the update must say so, before touching anything.
[ "$SCEN" = readonly ] && chmod 555 "$APPS"
LISTEN=$([ "$SCEN" = happy ] && echo 120 || echo 30)
MUYAD_CALL_EVENTS_SECS=$LISTEN "$CALL" "$SD/muyad.sock" beta_update_install "{\"appPath\":\"$APP\"}" | tee "$FAKE/install.out"
# Sample the app for 12 s after the daemon hung up: the new MuyaNative must appear and STAY (it also receives the "done"
# event from the old daemon; a build without the initiatedHere fix quits 1.5 s later, together with the old app).
sleep 12
touch "$FAKE/stop-sampler"; wait $SAMPLER 2>/dev/null
# pgrep lists the OLD pid first for as long as it lives, so judge from the sampler log: pids not in the first sample are
# "new"; one of them must still be in the LAST sample (12 s after the daemon hung up).
SEEN_NEW=$(awk 'NR==1{for(i=2;i<=NF;i++)init[$i]=1} {for(i=2;i<=NF;i++) if(!($i in init)) n[$i]=1} END{for(k in n) printf "%s ", k}' "$FAKE/app-pids.log")
APP1=""; for q in $SEEN_NEW; do case " $(tail -1 "$FAKE/app-pids.log" | cut -d' ' -f2-) " in *" $q "*) APP1=$q;; esac; done
echo "--- launchd.log"; cat "$FAKE/launchd.log"
echo "--- MuyaNative pids over time (unix secs; deduped)"; uniq -f1 "$FAKE/app-pids.log" | sed -n '1,12p'
echo "--- app/daemon trace"; grep -h "" "$FAKE/muyad.log" | tail -5

STATE="$H/Library/Application Support/com.staunch.muya/switchover/switch.json"
if [ "$SCEN" = happy ]; then
  check "events: reached phase done" grep -q '"phase":"done"' "$FAKE/install.out"
  check "events: the daemon hung up by itself after the final event" grep -q '^CLOSED' "$FAKE/install.out"
  check "installed app is now $NEWV (was $OLDV)" test "$(ver)" = "$NEWV"
  check "updated IN PLACE: ${APP_FOLDER:-Applications}/ holds only ${APP_NAME:-Muya Native.app} (nothing written elsewhere)" test "$(ls -A "$APPS")" = "${APP_NAME:-Muya Native.app}"
  check "codesign --verify --deep --strict on the installed app" codesign --verify --deep --strict "$APP"
  SPCTL=$(spctl -a -t exec -vv "$APP" 2>&1); echo "$SPCTL"
  case "$SPCTL" in *accepted*"Notarized Developer ID"*|*"accepted"*) ok "spctl accepts (notarized Developer ID)";; *) bad "spctl";; esac
  check "new MuyaNative appeared (old $APP0, new ${SEEN_NEW:-none})" test -n "$SEEN_NEW"
  check "new MuyaNative is STILL running 12 s after the update finished (pid ${APP1:-gone})" test -n "$APP1"
  # With no app having started the job (the harness plays the UI) nobody quits the old app; in the UI the initiating app
  # steps aside 1.5 s after "done" (initiatedHere). Informational only here.
  kill -0 $APP0 2>/dev/null && echo "INFO  old app (pid $APP0) still running: expected, nothing in this harness initiated the update from an app window"
  TR=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('trashedPreviousTarget') or '')" "$STATE" 2>/dev/null); echo "trashedPreviousTarget: ${TR:-<none>}"
  check "state says the old bundle went to the Trash ($TR)" test -n "$TR"
  case "$TR" in "$HOME/.Trash/"*) ok "...and it is the real ~/.Trash (NSFileManager ignores the fake HOME)";; *) bad "trash path not under the real ~/.Trash";; esac
  test -e "$TR/Contents/Info.plist" && echo "(trashed bundle readable: version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TR/Contents/Info.plist"))" || echo "(trashed bundle not inspectable: ~/.Trash is TCC-protected)"
  # launchd stand-in: the first muyad exited on its own, the next one runs from the installed bundle
  check "first muyad exited by itself with code 0" grep -q "exit pid=$MUYAD0 code=0" "$FAKE/launchd.log"
  MUYAD1=$(awk '/start/{sub("pid=","",$3);p=$3}END{print p}' "$FAKE/launchd.log")
  EXE1=$(ps -p "$MUYAD1" -o comm= 2>/dev/null)
  check "second muyad (pid $MUYAD1) is a new pid" test "$MUYAD1" != "$MUYAD0"
  check "second muyad runs from the NEW bundle path ($EXE1)" test "$EXE1" = "$NAT/muyad"
  ST=$("$CALL" "$SD/muyad.sock" beta_update_status "{\"appPath\":\"$APP\"}"); echo "$ST"
  case "$ST" in *"\"installed\":\"$NEWV\""*) ok "new daemon answers and reports $NEWV";; *) bad "new daemon status";; esac
else
  case "$SCEN" in
    badsha)      PAT="damaged";;
    wrongsigner) PAT="not properly signed|signature|signed|Team";;
    readonly)    PAT="cannot write to.*Nothing was changed";;
  esac
  echo "--- error message:"; grep '"phase":"error"' "$FAKE/install.out" | cut -c1-400
  check "events: phase error with a clear message ($PAT)" bash -c "grep '\"phase\":\"error\"' '$FAKE/install.out' | grep -Eqi '$PAT'"
  check "installed app untouched: still $OLDV" test "$(ver)" = "$OLDV"
  check "installed Info.plist byte-identical" test "$(shasum -a 256 "$APP/Contents/Info.plist" | cut -d' ' -f1)" = "$INFO_SHA_BEFORE"
  check "old app still running with the same pid ($APP0)" test "$(app_pid)" = "$APP0"
  check "daemon not restarted (pid $MUYAD0 alive, launchd.log has one start)" bash -c "kill -0 $MUYAD0 && [ \$(grep -c start '$FAKE/launchd.log') = 1 ]"
  TR=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('trashedPreviousTarget') or '')" "$STATE" 2>/dev/null)
  check "nothing trashed (state has no trashedPreviousTarget)" test -z "$TR"
  check "stage dir cleaned" bash -c "! ls '$H/Library/Caches/com.staunch.muya/switchover/$NEWV' >/dev/null 2>&1"
fi
check "seeded ~/.claude/muya-*.json unchanged" bash -c "cd '$H/.claude' && shasum -a 256 -c '$FAKE/shared-before.sha'"
real_stamp > "$W/real-home-after.$SCEN"
check "real ~/.claude/muya-* untouched (name/mtime/size)" diff "$W/real-home-before.$SCEN" "$W/real-home-after.$SCEN"

say "RESULT: $([ $FAILS = 0 ] && echo PASS || echo "FAIL ($FAILS)")   work dir: $FAKE"
exit $FAILS
