#!/usr/bin/env bash
# Fails on a dependency whose licence is unknown/unlisted; prints copyleft (GPL/AGPL/LGPL) ones so the
# operator can decide (ADR: Muya may move to GPL-3.0 if STTextView is chosen).
set -euo pipefail
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/licences.py" check
