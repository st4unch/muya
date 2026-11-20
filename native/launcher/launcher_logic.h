// The launcher's only decision, pure so it is unit-tested (native/launcher/test.sh).
#ifndef MUYA_LAUNCHER_LOGIC_H
#define MUYA_LAUNCHER_LOGIC_H
#include <stdlib.h>

/// The oldest macOS major version the Muya 5 app supports (LSMinimumSystemVersion, -target in app/build.sh).
#define MUYA_MIN_MAJOR 14

typedef enum { MUYA_RUN_APP = 0, MUYA_RESTORE_CLASSIC = 1 } muya_action;

static inline muya_action muya_decide(int major) { return major >= MUYA_MIN_MAJOR ? MUYA_RUN_APP : MUYA_RESTORE_CLASSIC; }

/// "14.2.1" -> 14, "10.15.7" -> 10, junk -> 0.
static inline int muya_major_from_product(const char *s) {
    if (!s || *s < '0' || *s > '9') return 0;
    return atoi(s);
}

/// kern.osrelease ("23.4.0" = macOS 14): Darwin 20 = macOS 11, so macOS = Darwin - 9; Darwin 19 and older is macOS 10.x.
static inline int muya_major_from_darwin(const char *s) {
    int d = muya_major_from_product(s);
    if (d <= 0) return 0;
    return d >= 20 ? d - 9 : 10;
}
#endif
