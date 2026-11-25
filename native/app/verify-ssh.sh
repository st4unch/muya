#!/usr/bin/env bash
# SSH & Passwords page: builds tools/ssh-shots.swift against the page's own sources and the in-memory fake
# daemon (synthetic data), runs its assertions on the real views and writes dark + light screenshots to
# screenshots/ssh-* and screenshots/vault-*. No daemon, no app process, no real secrets.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
GHOSTTY=$(bash "$HERE/../scripts/ghostty-env.sh" | sed -n 's|^export PKG_CONFIG_PATH="\(.*\)/share/pkgconfig"|\1|p')
OUT=$HERE/build
mkdir -p "$OUT" screenshots
swiftc -swift-version 5 -target arm64-apple-macos26.0 -warnings-as-errors -parse-as-library -O \
  -I CGhostty -Xcc -I"$GHOSTTY/include" -L "$GHOSTTY/lib" \
  Sources/Client/*.swift Sources/Logic/ServiceIdentity.swift Sources/Theme/*.swift Sources/App/Theme.swift Sources/App/Kit.swift Sources/App/ModalParts.swift Sources/App/FindIconButton.swift Sources/App/AccessibilityAudit.swift \
  Sources/SSH/SSHLogic.swift Sources/SSH/SSHService.swift Sources/SSH/SSHForm.swift Sources/SSH/PasswordStoreCards.swift Sources/SSH/ServerCards.swift Sources/SSH/SSHPage.swift \
  tools/ssh-shots.swift -o "$OUT/ssh-shots"
"$OUT/ssh-shots" "$HERE/screenshots"
