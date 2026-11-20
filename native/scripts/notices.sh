#!/usr/bin/env bash
# Regenerates native/THIRD_PARTY_NOTICES.md (bundle.sh copies it into Contents/Resources).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
python3 -I "$HERE/licences.py" notices > "$HERE/../THIRD_PARTY_NOTICES.md"
echo "notices: $(grep -c '^| ' "$HERE/../THIRD_PARTY_NOTICES.md") rows -> native/THIRD_PARTY_NOTICES.md" >&2
