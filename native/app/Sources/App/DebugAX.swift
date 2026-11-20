#if MUYA_TEST_HOOKS
// Test hook (debug socket only): `ax-tree [dump]` audits every visible window and sheet of this process.

import AppKit

extension DebugServer {
    func axTree(dump: Bool) -> String {
        accessibilityAudit(windows: NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }, dump: dump)
    }
}
#endif
