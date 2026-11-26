// Unit tests of Sources/Logic/WorkspaceScope.swift (ported from src/lib/workspaceScope.test.ts) and the scoped menu rows.

import Foundation

func runWorkspaceScopeTests() {
    let A = "/home/u/projects/muya", B = "/home/u/projects/padas"
    test("workspace scope: a session belongs to the folder it was opened in and everything below it") {
        check(WorkspaceScope.belongsTo(cwd: A, root: A), "the folder itself")
        check(WorkspaceScope.belongsTo(cwd: A + "/src", root: A), "a subfolder")
        check(WorkspaceScope.belongsTo(cwd: A + "/", root: A + "/"), "trailing slash on both")
        check(WorkspaceScope.belongsTo(cwd: "/x/y", root: "/"), "root / holds everything")
    }
    test("workspace scope: a sibling with the same prefix is not inside") {
        check(!WorkspaceScope.belongsTo(cwd: A + "-old", root: A), "muya-old")
        check(!WorkspaceScope.belongsTo(cwd: B, root: A), "other folder")
    }
    test("workspace scope: worktrees next to the repo count as the repo's") {
        check(WorkspaceScope.belongsTo(cwd: "/home/u/projects/muya-worktrees/feat-x", root: A), "own worktree")
        check(!WorkspaceScope.belongsTo(cwd: "/home/u/projects/padas-worktrees/feat-x", root: A), "another repo's worktree")
        check(WorkspaceScope.worktreeDir(A) == "/home/u/projects/muya-worktrees", "worktreeDir")
        check(WorkspaceScope.worktreeDir("/") == nil && WorkspaceScope.worktreeDir("/top") == nil, "no worktree dir for / and a top-level folder")
    }
    test("workspace scope: SSH shows in every scope; a session without a folder only under All") {
        check(WorkspaceScope.inScope(cwd: "", ssh: true, scope: A), "ssh in a scope")
        check(!WorkspaceScope.inScope(cwd: "", scope: A), "no folder, scoped")
        check(WorkspaceScope.inScope(cwd: "", scope: nil), "no folder, all")
        check(WorkspaceScope.inScope(cwd: B, scope: nil), "nil admits everything")
        check(!WorkspaceScope.inScope(cwd: B, scope: A), "other folder, scoped")
        check(WorkspaceScope.inScope(cwd: A + "/src", scope: A), "subfolder, scoped")
    }
    test("workspace scope: the longest root names the session's workspace; no match = nil") {
        let roots = ["/home/u/projects", A, B]
        check(WorkspaceScope.workspaceOf(cwd: A + "/src", roots: roots) == A, "most specific")
        check(WorkspaceScope.workspaceOf(cwd: "/home/u/projects/other", roots: roots) == "/home/u/projects", "parent")
        check(WorkspaceScope.workspaceOf(cwd: "/tmp", roots: roots) == nil, "none")
        check(WorkspaceScope.workspaceOf(cwd: "", roots: roots) == nil, "no folder")
    }
    test("workspace scope: shortcut pick (1-9 = Nth row, 0 = all, none past the list)") {
        let rows = ["/w/a", "/w/b", "/w/c"]
        check(WorkspaceScope.pick(digit: 1, rows: rows) == .root("/w/a") && WorkspaceScope.pick(digit: 3, rows: rows) == .root("/w/c"), "Nth")
        check(WorkspaceScope.pick(digit: nil, rows: rows) == .all && WorkspaceScope.pick(digit: nil, rows: []) == .none, "all needs a workspace")
        check(WorkspaceScope.pick(digit: 4, rows: rows) == .none && WorkspaceScope.pick(digit: 0, rows: rows) == .none, "past the list")
    }
    test("workspace scope: chip label") {
        check(WorkspaceScope.chipLabel(scope: nil, hasSessions: true) == "All workspaces", "all")
        check(WorkspaceScope.chipLabel(scope: nil, hasSessions: false) == "No workspace", "none")
        check(WorkspaceScope.chipLabel(scope: A + "/", hasSessions: false) == "muya", "folder name, even with no session")
    }
    test("workspace menu rows: count = sessions in the root's scope; the chosen root stays listed") {
        let cwds = [A, A + "/src", "/home/u/projects/muya-worktrees/f", B]
        let r = WorkspaceMenuLogic.rows(cwds: cwds)
        check(r.map(\.path) == [A, A + "/src", "/home/u/projects/muya-worktrees/f", B], "one row per distinct cwd")
        check(r[0].count == 3 && r[1].count == 1 && r[3].count == 1, "scope counts: \(r.map(\.count))")
        let ssh = WorkspaceMenuLogic.rows(cwds: [A, ""], ssh: [false, true])
        check(ssh.count == 1 && ssh[0].count == 2, "ssh counts in every row")
        let kept = WorkspaceMenuLogic.rows(cwds: [B], keep: A)
        check(kept.map(\.path) == [B, A] && kept[1].count == 0 && kept[1].title == "muya", "kept root with 0 agents")
        check(WorkspaceMenuLogic.rows(cwds: [B], keep: B).count == 1, "kept root already listed once")
    }
}
