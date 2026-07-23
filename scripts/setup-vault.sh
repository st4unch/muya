#!/usr/bin/env bash
#
# setup-vault.sh — one-command setup for Muya's Vault Context (semantic search
# over an Obsidian vault via the smart-connections MCP server).
#
# What it does (idempotent — safe to re-run):
#   1. Copies the bundled MCP server (vendor/smart-connections-mcp) into the
#      target dir (default: ~/smart-connections-mcp; override with VAULT_MCP_DIR).
#   2. Creates a Python venv there and installs the deps (torch, sentence-
#      transformers, mcp). Uses `uv` if present (fast), else `python3 -m venv`.
#   3. VERIFIES the venv can import sentence_transformers — the exact check Muya
#      makes before it will use the venv.
#   4. Prints the remaining manual steps (set the vault path in the app; make
#      sure Obsidian's Smart Connections plugin has indexed the vault).
#
# Muya's Rust side (vault.rs `resolve_python`) auto-selects this venv once it has
# the deps, so no env var is needed after this runs. You can still force a
# specific interpreter with VAULT_PYTHON, or a different server dir with
# VAULT_MCP_DIR (both read by the app at runtime too).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/vendor/smart-connections-mcp"
DEST="${VAULT_MCP_DIR:-$HOME/smart-connections-mcp}"

say()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$SRC" ] || die "bundled source not found at $SRC (run from the Muya repo)"

say "1/4  Installing MCP server → $DEST"
mkdir -p "$DEST"
# Copy source files (never clobber a user-modified server with an older one is
# not a concern here — the repo copy is the source of truth for setup).
cp "$SRC/server.py"        "$DEST/server.py"
cp "$SRC/requirements.txt" "$DEST/requirements.txt"
[ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$DEST/README.md"
ok "server.py + requirements.txt in place"

say "2/4  Creating Python environment + installing deps (this can take a few minutes — torch is large)"
cd "$DEST"
if command -v uv >/dev/null 2>&1; then
  uv venv --python 3.11 .venv 2>/dev/null || uv venv .venv
  uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt
else
  # Prefer a real 3.11 if available; fall back to whatever python3 is.
  PYBIN="$(command -v python3.11 || command -v python3 || true)"
  [ -n "$PYBIN" ] || die "no python3 found — install Python 3.11 (brew install python@3.11) and re-run"
  "$PYBIN" -m venv .venv
  ./.venv/bin/python -m pip install --upgrade pip
  ./.venv/bin/python -m pip install -r requirements.txt
fi
ok "venv created at $DEST/.venv"

say "3/4  Verifying the venv (Muya makes this exact check before using it)"
if ./.venv/bin/python -c "import sentence_transformers" 2>/dev/null; then
  ok "sentence_transformers imports — Muya will auto-select this venv"
else
  die "venv is missing deps — 'import sentence_transformers' failed. Re-run, or install manually:
     cd $DEST && ./.venv/bin/python -m pip install -r requirements.txt"
fi

say "4/4  Manual steps that only YOU can do"
cat <<EOF

  In Obsidian:
    • Install/enable the "Smart Connections" community plugin.
    • Let it index the vault — this writes a .smart-env/ folder inside the vault.
      Muya reads that; without it, search returns nothing even with the venv ready.

  In Muya:
    • Open Chat/Control → the Vault Source panel.
    • Set the vault path (the folder that contains .obsidian/ and .smart-env/),
      or let auto-detect find it, then Restart the vault connection.

  Done. If it still says "not installed", confirm $DEST/server.py exists and the
  step-3 check above passed.
EOF
ok "Setup complete."
