// When the strip under the terminal shows. Turn progress belongs to the chat box: with it closed the strip only echoed
// Claude's own spinner and, appearing/disappearing every turn, resized and redrew the terminal. The update notice shows either way.

import Foundation

public enum StripVisibility {
    public static func showsProgress(working: Bool, composerOpen: Bool) -> Bool { working && composerOpen }
    public static func shows(working: Bool, updateReady: Bool, composerOpen: Bool) -> Bool {
        showsProgress(working: working, composerOpen: composerOpen) || updateReady
    }
    public static func height(working: Bool, updateReady: Bool, composerOpen: Bool, full: CGFloat) -> CGFloat {
        shows(working: working, updateReady: updateReady, composerOpen: composerOpen) ? full : 0
    }

    /// The inline Allow / Deny bar duplicates Claude's own prompt in the terminal. It belongs to the chat box: with the chat closed
    /// the user answers in the terminal, and the bar must not appear (it resized the terminal and offered Y/N keys twice).
    public static func showsApproval(waiting: Bool, composerOpen: Bool) -> Bool { waiting && composerOpen }
    public static func approvalHeight(waiting: Bool, composerOpen: Bool, full: CGFloat) -> CGFloat {
        showsApproval(waiting: waiting, composerOpen: composerOpen) ? full : 0
    }
}
