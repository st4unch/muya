#!/usr/bin/env bash
# Builds ImeLab as a bundle and runs its self test. Activated runs wait until the operator has
# been idle for 120 s; the input sources are restored afterwards whatever happens to ImeLab.
#   ./run.sh [--activate] [--ime-ja] [--out FILE]
set -u
cd "$(dirname "$0")"
mkdir -p build/ImeLab.app/Contents/MacOS
swiftc -O -swift-version 6 -target arm64-apple-macos26.0 main.swift -o build/ImeLab.app/Contents/MacOS/ImeLab || exit 1
swiftc -O restore-input.swift -o build/restore-input || exit 1
cp Info.plist build/ImeLab.app/Contents/
codesign --force -s - build/ImeLab.app 2>/dev/null
if [[ " $* " == *" --activate "* ]]; then
  for _ in $(seq 120); do
    idle=$(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/{print $NF; exit}') / 1000000000 ))
    [ "$idle" -ge 120 ] && break
    sleep 10
  done
fi
build/ImeLab.app/Contents/MacOS/ImeLab --selftest "$@" &
pid=$!
for _ in $(seq 90); do kill -0 $pid 2>/dev/null || break; sleep 1; done
kill -0 $pid 2>/dev/null && { echo "run.sh: ImeLab hung, killing it" >&2; kill -9 $pid; }
[[ " $* " == *" --ime-ja "* ]] && build/restore-input >&2
