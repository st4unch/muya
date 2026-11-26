// Where the parts of the left column sit (src/redesign/FilesSection.tsx + AgentList.tsx footer): the agents list (or the open files in
// Files mode), the FILES header row and the tree under it. Pure geometry in a flipped (top-down) space so it is unit-tested
// (Tests/SidebarTests.swift); SidebarView only applies it. A collapsed section is the header alone: the tree gets zero height.

import Foundation

public struct SidebarGeometry: Equatable, Sendable {
    public static let barHeight: CGFloat = 35
    /// The two hint lines under the Files row (AgentList.tsx footer).
    public static let hintHeight: CGFloat = 57

    public var agents: CGRect?       // nil in Files mode (the open-files list takes its place)
    public var openFiles: CGRect?    // Files mode: on top of the column. Control mode: only when files are open, just above the FILES header
    public var header: CGRect        // the "FILES N" row: the click target that toggles the tree
    public var tree: CGRect

    public static func layout(width: CGFloat, height: CGFloat, expanded: Bool, filesMode: Bool, openFilesWanted: CGFloat, agentsWanted: CGFloat = 0, filesHeight: CGFloat? = nil, controlFilesWanted: CGFloat = 0) -> SidebarGeometry {
        let bar = barHeight
        if filesMode {
            // Classic's Files screen: the open files on top, the FILES section at the bottom of the column. Collapsed it is the
            // header alone, flush with the bottom edge; open it takes the rest under the open files (the tree grows upward).
            if !expanded {
                let oh = min(openFilesWanted, max(height - bar, 0))
                return SidebarGeometry(agents: nil, openFiles: CGRect(x: 0, y: 0, width: width - 1, height: oh),
                                       header: CGRect(x: 0, y: height - (bar - 1), width: width, height: bar - 1),
                                       tree: CGRect(x: 0, y: height, width: width - 1, height: 0))
            }
            let oh = min(openFilesWanted, max(height * 0.5, 99))   // classic: the list keeps what its rows need, at most half the column
            return SidebarGeometry(agents: nil, openFiles: CGRect(x: 0, y: 0, width: width - 1, height: oh),
                                   header: CGRect(x: 0, y: oh, width: width, height: bar - 1),
                                   tree: CGRect(x: 0, y: oh + bar - 1, width: width - 1, height: max(height - oh - bar + 1, 0)))
        }
        // Classic (AgentList.tsx filesFill): open, the agents list takes only the height its rows need (at most half the
        // column) and the tree gets everything else; the tree never drops below 120 px.
        let agentsH = min(agentsWanted, height * 0.5, height - hintHeight - bar - 120)
        var section = expanded ? max(height - hintHeight - max(agentsH, 0), bar) : bar
        if expanded, let fh = filesHeight { section = max(FilesHeightLogic.clamp(fh, available: height - hintHeight), bar) }   // dragged: the operator's height (classic filesH)
        let header = CGRect(x: 0, y: height - hintHeight - section, width: width, height: bar)
        // Control mode with files open: their cards sit between the agents and the FILES header, at most 40% of what the agents
        // area has and never so much that the agents list drops under 120 px; the list scrolls inside whatever it gets.
        let above = max(height - hintHeight - section, 0)
        let cf = controlFilesWanted > 0 ? max(min(controlFilesWanted, above * 0.4, above - 120), 0) : 0
        return SidebarGeometry(agents: CGRect(x: 0, y: 0, width: width - 1, height: above - cf),
                               openFiles: cf > 0 ? CGRect(x: 0, y: above - cf, width: width - 1, height: cf) : nil, header: header,
                               tree: CGRect(x: 0, y: header.maxY, width: width - 1, height: expanded ? section - bar : 0))
    }
}
