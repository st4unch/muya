// Pure logic of the Queue / Branches / Kanban views: ahead-behind parsing, the push/merge queue rows, the
// commit-graph lane assignment and the kanban board. Foundation only, no I/O, so it is unit-tested directly.

import Foundation

// MARK: Ahead / behind

struct AheadBehind: Equatable {
    var ahead = 0
    var behind = 0
    var gone = false

    /// `git rev-list --left-right --count base...branch` prints "<only in base>\t<only in branch>": behind, then ahead.
    static func parseCount(_ s: String) -> AheadBehind? {
        let p = s.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard p.count == 2, let behind = Int(p[0]), let ahead = Int(p[1]), behind >= 0, ahead >= 0 else { return nil }
        return AheadBehind(ahead: ahead, behind: behind)
    }

    /// `%(upstream:track)` of for-each-ref: "", "[ahead 2]", "[behind 1]", "[ahead 2, behind 1]" or "[gone]".
    static func parseTrack(_ s: String) -> AheadBehind {
        var r = AheadBehind()
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n"))
        if t == "gone" { r.gone = true; return r }
        for part in t.split(separator: ",") {
            let w = part.split(separator: " ")
            guard w.count == 2, let n = Int(w[1]) else { continue }
            if w[0] == "ahead" { r.ahead = n } else if w[0] == "behind" { r.behind = n }
        }
        return r
    }
}

// MARK: Queue

enum QueueStatus: String, Equatable {
    case readyToMerge = "Ready to merge"
    case needsRebase = "Needs rebase"
    case pushNeeded = "Push needed"
    case dirty = "Uncommitted changes"
    case noUpstream = "No upstream"
    case merged = "Merged"
    case upToDate = "Up to date"
}

struct QueueCheck: Equatable {
    var name: String
    var pass: Bool
}

struct QueueEntry: Equatable, Identifiable {
    var branch: String
    var worktree: String?          // path of the worktree that has it checked out
    var upstream: String?
    var vsUpstream = AheadBehind()
    var vsBase = AheadBehind()     // ahead/behind of the base branch (main)
    var dirty = false
    var subject = ""
    var base = "main"
    var isBase = false
    var id: String { branch }

    var status: QueueStatus {
        if dirty { return .dirty }
        if isBase { return vsUpstream.ahead > 0 ? .pushNeeded : .upToDate }
        if vsBase.ahead == 0 { return .merged }
        if vsBase.behind > 0 { return .needsRebase }
        if upstream == nil || vsUpstream.gone { return .noUpstream }
        if vsUpstream.ahead > 0 { return .pushNeeded }
        return .readyToMerge
    }

    /// CI-less checks: what git itself can say without a server.
    var checks: [QueueCheck] {
        var c = [QueueCheck(name: "clean tree", pass: !dirty)]
        if !isBase {
            c.append(QueueCheck(name: "up to date with \(base)", pass: vsBase.behind == 0))
            c.append(QueueCheck(name: "pushed", pass: upstream != nil && !vsUpstream.gone && vsUpstream.ahead == 0))
        } else {
            c.append(QueueCheck(name: "pushed", pass: vsUpstream.ahead == 0))
        }
        return c
    }

    var checksSummary: String {
        let c = checks
        return "\(c.filter(\.pass).count)/\(c.count)"
    }

    /// Which actions make sense for this row.
    var canPush: Bool { !dirty && (isBase || vsBase.ahead > 0) && (upstream == nil || vsUpstream.gone || vsUpstream.ahead > 0) }
    var canMerge: Bool { !isBase && !dirty && vsBase.ahead > 0 }
    var canDelete: Bool { !isBase && vsBase.ahead == 0 && worktree == nil }

    var aheadBehindText: String {
        let u = upstream == nil ? "–" : (vsUpstream.gone ? "gone" : "↑\(vsUpstream.ahead) ↓\(vsUpstream.behind)")
        return isBase ? u : "\(u)  ·  \(base) ↑\(vsBase.ahead) ↓\(vsBase.behind)"
    }
}

/// What a destructive button WOULD run. In this build nothing is executed: the handler only logs it.
enum QueueAction: Equatable {
    case push(branch: String, remote: String, setUpstream: Bool)
    case merge(branch: String, into: String)
    case deleteBranch(String)

    var commandLine: String {
        switch self {
        case let .push(b, r, up): return up ? "git push -u \(r) \(b)" : "git push \(r) \(b)"
        case let .merge(b, into): return "git checkout \(into) && git merge --no-ff \(b)"
        case let .deleteBranch(b): return "git branch -d \(b)"
        }
    }

    var title: String {
        switch self {
        case let .push(b, _, _): return "Push \(b)?"
        case let .merge(b, into): return "Merge \(b) into \(into)?"
        case let .deleteBranch(b): return "Delete branch \(b)?"
        }
    }

    var verb: String {
        switch self {
        case .push: return "Push"
        case .merge: return "Merge"
        case .deleteBranch: return "Delete"
        }
    }
}

extension QueueEntry {
    func pushAction(remote: String = "origin") -> QueueAction { .push(branch: branch, remote: remote, setUpstream: upstream == nil) }
    func mergeAction() -> QueueAction { .merge(branch: branch, into: base) }
    func deleteAction() -> QueueAction { .deleteBranch(branch) }

    /// Queue order: what can be merged first, then what needs work, merged branches last.
    static func order(_ a: QueueEntry, _ b: QueueEntry) -> Bool {
        func rank(_ e: QueueEntry) -> Int {
            switch e.status {
            case .readyToMerge: return 0
            case .pushNeeded: return 1
            case .needsRebase: return 2
            case .noUpstream: return 3
            case .dirty: return 4
            case .upToDate: return 5
            case .merged: return 6
            }
        }
        let (ra, rb) = (rank(a), rank(b))
        return ra != rb ? ra < rb : a.branch < b.branch
    }
}

enum QueueParser {
    /// `for-each-ref --format=%(refname:short)\t%(upstream:short)\t%(upstream:track)\t%(HEAD)\t%(subject) refs/heads`
    static func branches(_ text: String) -> [(branch: String, upstream: String?, track: AheadBehind, head: Bool, subject: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty else { return nil }
            return (f[0], f[1].isEmpty ? nil : f[1], AheadBehind.parseTrack(f[2]), f[3] == "*", f.count > 4 ? f[4] : "")
        }
    }
}

// MARK: Commit graph

struct CommitNode: Equatable {
    var sha: String
    var parents: [String]
    var refs: [String] = []
    var author = ""
    var time: TimeInterval = 0
    var subject = ""
    var short: String { String(sha.prefix(7)) }
}

/// One drawn row of the graph. Lanes are columns; every number is a lane index.
struct DagRow: Equatable {
    var lane: Int                 // where this commit's dot sits
    var incoming: [Int]           // lanes that end at this commit from above (several = a merge point below)
    var through: [Int]            // lanes passing straight through this row
    var outgoing: [Int]           // lanes the commit continues into below (one per parent)
    var laneCount: Int            // widest point of this row
}

enum DagLayout {
    /// `git log --all --topo-order --format=%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%s` with records separated by 0x1E.
    static func parse(_ text: String) -> [CommitNode] {
        text.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { rec in
            let f = rec.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, f[0].count >= 7 else { return nil }
            let refs = f[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0.hasPrefix("HEAD -> ") ? String($0.dropFirst(8)) : $0 }.filter { !$0.isEmpty && $0 != "HEAD" }
            return CommitNode(sha: f[0], parents: f[1].split(separator: " ").map(String.init), refs: refs, author: f[3], time: TimeInterval(f[4]) ?? 0, subject: f[5])
        }
    }

    /// Lane assignment for commits in topological order (children before parents).
    /// `lanes[i]` is the sha lane i is waiting for (nil = free). A commit takes the first lane waiting for it;
    /// its first parent continues in that lane, further parents take a waiting lane or a free one.
    static func layout(_ commits: [CommitNode]) -> [DagRow] {
        var lanes: [String?] = []
        var rows: [DagRow] = []
        rows.reserveCapacity(commits.count)
        for c in commits {
            let waiting = lanes.indices.filter { lanes[$0] == c.sha }
            let lane: Int
            if let f = waiting.first { lane = f } else if let free = lanes.firstIndex(where: { $0 == nil }) { lane = free } else { lanes.append(nil); lane = lanes.count - 1 }
            let widthBefore = lanes.count
            // lanes that just pass through: waiting for something else
            let through = lanes.indices.filter { lanes[$0] != nil && lanes[$0] != c.sha && $0 != lane }
            for i in waiting { lanes[i] = nil }
            var outgoing: [Int] = []
            for (n, p) in c.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0 == p }) { outgoing.append(existing); continue }
                if n == 0 { lanes[lane] = p; outgoing.append(lane); continue }
                if let free = lanes.firstIndex(where: { $0 == nil }) { lanes[free] = p; outgoing.append(free) } else { lanes.append(p); outgoing.append(lanes.count - 1) }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            let width = max(widthBefore, lanes.count, lane + 1, (outgoing.max() ?? 0) + 1)
            rows.append(DagRow(lane: lane, incoming: waiting, through: through, outgoing: outgoing, laneCount: width))
        }
        return rows
    }

    static let palette: [UInt32] = [0x82C0F5, 0x7FC27A, 0xF0A04B, 0xC792EA, 0x4DD0E1, 0xE0626B, 0xE6C84F, 0xA0A8B3]
}

// MARK: Kanban

enum KanbanColumn: String, CaseIterable, Equatable {
    case draft, active, review, done

    var title: String {
        switch self {
        case .draft: return "Draft"
        case .active: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }

    /// The status word written back to the progress file when a card is moved here.
    var statusWord: String { rawValue }

    /// Same keyword mapping as today's board (src/components/PrdBoard.tsx classifyStatus).
    static func classify(_ status: String) -> KanbanColumn {
        let s = status.lowercased()
        if ["done", "completed", "shipped"].contains(where: s.contains) { return .done }
        if ["active", "in progress", "in-progress", "implementing"].contains(where: s.contains) { return .active }
        if ["review", "pending", "awaiting"].contains(where: s.contains) { return .review }
        return .draft
    }
}

struct KanbanCard: Equatable, Identifiable {
    var slug: String
    var title: String
    var status: String
    var file: String               // progress file name, e.g. prd-foo.progress.md
    var id: String { slug }
    var column: KanbanColumn { KanbanColumn.classify(status) }
}

enum KanbanFile {
    /// `status:` of the front matter, "" if there is none.
    static func status(of text: String) -> String {
        for line in frontMatter(text) where line.lowercased().hasPrefix("status:") {
            return line.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        return ""
    }

    static func frontMatter(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        var out: [String] = []
        for l in lines.dropFirst() {
            if l.trimmingCharacters(in: .whitespaces) == "---" { return out }
            out.append(l)
        }
        return []
    }

    /// First "# Heading" of a document, else nil.
    static func title(of text: String) -> String? {
        for l in text.components(separatedBy: "\n") where l.hasPrefix("# ") { return String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    /// The same text with `status:` set to `word` (added to the front matter if it was missing).
    static func settingStatus(_ word: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            if let i = lines[1..<end].firstIndex(where: { $0.lowercased().hasPrefix("status:") }) { lines[i] = "status: \(word)" } else { lines.insert("status: \(word)", at: end) }
            return lines.joined(separator: "\n")
        }
        return "---\nstatus: \(word)\n---\n" + text
    }
}

struct KanbanBoard: Equatable {
    var cards: [KanbanCard]

    func cards(in column: KanbanColumn) -> [KanbanCard] { cards.filter { $0.column == column } }

    /// Moves a card to `column` (at the end of it); false if the slug is unknown or it is already there.
    @discardableResult
    mutating func move(slug: String, to column: KanbanColumn) -> Bool {
        guard let i = cards.firstIndex(where: { $0.slug == slug }), cards[i].column != column else { return false }
        var c = cards.remove(at: i)
        c.status = column.statusWord
        cards.append(c)
        return true
    }

    /// The neighbouring column in `step` direction (-1 / +1), clamped.
    static func neighbour(of column: KanbanColumn, step: Int) -> KanbanColumn {
        let all = KanbanColumn.allCases
        let i = all.firstIndex(of: column) ?? 0
        return all[max(0, min(all.count - 1, i + step))]
    }
}
