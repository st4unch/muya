// Permission-prompt notification words and the once-per-prompt rule (NotifyLogic.swift).

import Foundation

func runNotifyTests() {
    test("notification text: tool and the first 80 characters of the target, same as the daemon's") {
        check(PromptNotice.title == "Muya: permission needed", "title")
        check(PromptNotice.body(tool: "Bash", target: "rm -rf build") == "Claude is asking permission to use Bash: rm -rf build", "bash")
        check(PromptNotice.body(tool: "Tool use", target: "") == "Claude is asking permission to use a tool", "generic tool, no target")
        check(PromptNotice.body(tool: "", target: "x") == "Claude is asking permission to use a tool: x", "unknown tool")
        let long = PromptNotice.body(tool: "Write", target: String(repeating: "a", count: 200))
        check(long == "Claude is asking permission to use Write: " + String(repeating: "a", count: 80), "target cut at 80")
    }

    test("a banner is skipped only while the operator looks at that session in the active window") {
        check(!PromptNotice.shouldPost(appActive: true, windowVisible: true, isSelected: true), "looking at it")
        check(PromptNotice.shouldPost(appActive: false, windowVisible: true, isSelected: true), "another app in front")
        check(PromptNotice.shouldPost(appActive: true, windowVisible: true, isSelected: false), "another session selected")
        check(PromptNotice.shouldPost(appActive: true, windowVisible: false, isSelected: true), "window hidden")
    }

    test("a banner click link round-trips the session id; other links are ignored") {
        check(PromptNotice.sessionURL(42).absoluteString == "muya://session/42", "url")
        check(PromptNotice.sessionId(from: PromptNotice.sessionURL(42)) == 42, "round trip")
        check(PromptNotice.sessionId(from: URL(string: "muya://session/x")!) == nil, "not a number")
        check(PromptNotice.sessionId(from: URL(string: "https://session/1")!) == nil, "other scheme")
        check(PromptNotice.sessionId(from: URL(fileURLWithPath: "/tmp/a")) == nil, "file url")
    }

    test("tracker: one notice per prompt, again for a new prompt, again after the prompt went away") {
        var t = PromptNoticeTracker()
        check(t.fresh(prompting: [1: "Bash|ls|Do you want?"]) == [1], "first sight")
        check(t.fresh(prompting: [1: "Bash|ls|Do you want?"]).isEmpty, "same prompt")
        check(t.fresh(prompting: [1: "Bash|rm|Do you want?", 2: "Edit|a|q"]) == [1, 2], "new prompt on 1, first on 2")
        check(t.fresh(prompting: [:]).isEmpty, "none left")
        check(t.fresh(prompting: [1: "Bash|rm|Do you want?"]) == [1], "the same text after it went away is a new prompt")
    }
}
