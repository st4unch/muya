#!/usr/bin/env bash
# Unit test of the launcher's version decision, plus a build of the launcher with its deployment target and a gate check:
#   native/launcher/test.sh
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
cat > "$T/t.c" <<'EOF'
#include <assert.h>
#include <stdio.h>
#include "launcher_logic.h"
int main(void) {
    assert(muya_decide(26) == MUYA_RUN_APP && muya_decide(15) == MUYA_RUN_APP && muya_decide(14) == MUYA_RUN_APP);
    assert(muya_decide(13) == MUYA_RESTORE_CLASSIC && muya_decide(12) == MUYA_RESTORE_CLASSIC && muya_decide(11) == MUYA_RESTORE_CLASSIC);
    assert(muya_decide(10) == MUYA_RESTORE_CLASSIC && muya_decide(0) == MUYA_RESTORE_CLASSIC);
    assert(muya_major_from_product("14.2.1") == 14 && muya_major_from_product("26.0") == 26 && muya_major_from_product("10.15.7") == 10);
    assert(muya_major_from_product("") == 0 && muya_major_from_product("x") == 0 && muya_major_from_product(NULL) == 0);
    assert(muya_major_from_darwin("23.4.0") == 14 && muya_major_from_darwin("25.6.0") == 16 && muya_major_from_darwin("22.1.0") == 13);
    assert(muya_major_from_darwin("20.6.0") == 11 && muya_major_from_darwin("19.6.0") == 10 && muya_major_from_darwin("") == 0);
    puts("launcher decision: all assertions hold");
    return 0;
}
EOF
clang -I. -Wall -Werror -o "$T/t" "$T/t.c" && "$T/t"
# shipping build: arm64, deployment target 11.0 (the floor of an arm64 Mac; classic itself is arm64-only), no test strings
clang -arch arm64 -mmacosx-version-min=11.0 -O2 -Wall -Werror -o "$T/launcher" launcher.c
vtool -show-build "$T/launcher" | grep -E "minos"
if strings "$T/launcher" | grep -qE "MUYA_LAUNCHER_FAKE_MAJOR|MUYA_LAUNCHER_NO_DIALOG"; then echo "FAIL: the shipping launcher contains test overrides"; exit 1; fi
echo "shipping launcher has no test override strings"
clang -arch arm64 -mmacosx-version-min=11.0 -DMUYA_LAUNCHER_TEST -O2 -Wall -Werror -o "$T/launcher-test" launcher.c
strings "$T/launcher-test" | grep -q MUYA_LAUNCHER_FAKE_MAJOR && echo "test build has the override (as intended)"
rm -rf "$T"
