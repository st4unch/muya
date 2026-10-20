#!/bin/bash
# Rebuild every panda scene and copy the .riv files into the app (src/assets/panda/rive).
# Needs the Rive CLI (https://rive.app/docs/cli/getting-started) at ~/.rive/bin/rive or on PATH.
set -euo pipefail
cd "$(dirname "$0")"
RIVE=$(command -v rive || echo "$HOME/.rive/bin/rive")
OUT=../../src/assets/panda/rive
python3 scenes2.py                                      # wave sleep gaming ... business
python3 gen_panda.py bamboo - scene_bamboo 1000 654      # the bamboo splits
python3 gen_panda.py cookie - scene_cookie 1100 0 cam    # the cookie run (the view follows the panda)
mkdir -p "$OUT"
for d in scene_*; do
  name=${d#scene_}
  "$RIVE" "$d" --once
  cp "$d/build/$name.riv" "$OUT/$name.riv"
done
echo "copied $(ls "$OUT"/*.riv | wc -l | tr -d ' ') scenes to $OUT"
