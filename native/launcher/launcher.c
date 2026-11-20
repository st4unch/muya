// Muya's main executable (Contents/MacOS/muya): a tiny launcher, plain C, no runtime beyond libSystem.
//
// The real app (MuyaNative) needs macOS 14. On macOS 14 or later this launcher replaces itself with the app (execv: same pid,
// same environment and arguments, so LaunchServices' idea of who is responsible for the process, which muyad's peer gate
// relies on, is unchanged). On an older macOS it restores Muya Classic 4.1.22 in place, through muyad's pinned and verified
// return (`muyad --return-classic`: sha256 + Team ID + notarization), and says so in one line.
//
// Why it exists: classic's Tauri updater cannot gate an update by macOS version. A Mac below 14 gets this bundle in place of
// classic anyway; without this launcher macOS would only say "can't be opened" and classic would be gone.
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include "launcher_logic.h"

static int os_major(void) {
#ifdef MUYA_LAUNCHER_TEST
    // Test builds only (the e2e bundle); the shipping launcher has neither this variable nor the string.
    const char *fake = getenv("MUYA_LAUNCHER_FAKE_MAJOR");
    if (fake && *fake) return atoi(fake);
#endif
    char buf[64];
    size_t n = sizeof buf;
    if (sysctlbyname("kern.osproductversion", buf, &n, NULL, 0) == 0) {
        int m = muya_major_from_product(buf);
        if (m > 0) return m;
    }
    n = sizeof buf;
    if (sysctlbyname("kern.osrelease", buf, &n, NULL, 0) == 0) return muya_major_from_darwin(buf);
    return 0;
}

static void notice(const char *text) {
#ifdef MUYA_LAUNCHER_TEST
    if (getenv("MUYA_LAUNCHER_NO_DIALOG")) { fprintf(stderr, "muya launcher: %s\n", text); return; }
#endif
    char script[512];
    snprintf(script, sizeof script, "display dialog \"%s\" with title \"Muya\" buttons {\"OK\"} default button 1 with icon caution", text);
    pid_t p = fork();
    if (p == 0) { execl("/usr/bin/osascript", "osascript", "-e", script, (char *)NULL); _exit(127); }
    if (p > 0) { int st; waitpid(p, &st, 0); }
}

int main(int argc, char **argv) {
    (void)argc;
    char self[PATH_MAX];
    uint32_t sz = sizeof self;
    if (_NSGetExecutablePath(self, &sz) != 0) return 70;
    char dirbuf[PATH_MAX];
    strlcpy(dirbuf, self, sizeof dirbuf);
    const char *dir = dirname(dirbuf);                       // .../Muya.app/Contents/MacOS

    if (muya_decide(os_major()) == MUYA_RUN_APP) {
        char real[PATH_MAX];
        snprintf(real, sizeof real, "%s/MuyaNative", dir);
        execv(real, argv);                                    // argv[0] stays as LaunchServices / the updater started us
        perror("muya launcher: cannot start the app");
        return 71;
    }

    // Too old for Muya 5: put Muya Classic 4.1.22 back where this app is.
    char bundle[PATH_MAX], muyad[PATH_MAX];
    snprintf(bundle, sizeof bundle, "%s/../..", dir);
    snprintf(muyad, sizeof muyad, "%s/muyad", dir);
    char resolved[PATH_MAX];
    if (!realpath(bundle, resolved)) strlcpy(resolved, bundle, sizeof resolved);
    pid_t p = fork();
    if (p == 0) { execl(muyad, "muyad", "--return-classic", resolved, (char *)NULL); _exit(127); }
    int st = -1;
    if (p > 0) waitpid(p, &st, 0);
    if (p > 0 && WIFEXITED(st) && WEXITSTATUS(st) == 0)
        notice("Muya 5 needs macOS 14 or later. Muya Classic 4.1.22 has been restored and is opening.");
    else
        notice("Muya 5 needs macOS 14 or later, and Muya Classic could not be restored automatically. Download Muya Classic 4.1.22 from the Muya releases page on GitHub.");
    return st == 0 ? 0 : 1;
}
