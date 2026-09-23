import { describe, it, expect } from "vitest";
import { buildAgentCommand, singleQuote, detectAgent, buildResumeCommand, tabAgent, AGENT_BASE_COMMAND } from "./agent";

describe("buildAgentCommand", () => {
  it("defaults to claude --dangerously-skip-permissions", () => {
    expect(buildAgentCommand({ command: "", prompt: "", files: [] })).toBe(
      "claude --dangerously-skip-permissions"
    );
  });

  it("uses a custom command", () => {
    expect(buildAgentCommand({ command: "claude --foo", prompt: "", files: [] })).toBe(
      "claude --foo"
    );
  });

  it("appends a quoted prompt", () => {
    expect(buildAgentCommand({ command: "claude", prompt: "fix bug", files: [] })).toBe(
      "claude 'fix bug'"
    );
  });

  it("prepends files as @refs before the prompt", () => {
    expect(
      buildAgentCommand({ command: "claude", prompt: "do it", files: ["/a.ts", "/b.ts"] })
    ).toBe("claude '@/a.ts @/b.ts do it'");
  });

  it("escapes single quotes in the prompt", () => {
    expect(buildAgentCommand({ command: "claude", prompt: "it's broken", files: [] })).toBe(
      "claude 'it'\\''s broken'"
    );
  });
});

describe("singleQuote", () => {
  it("wraps and escapes", () => {
    expect(singleQuote("a'b")).toBe("'a'\\''b'");
  });
});

describe("detectAgent", () => {
  it("recognises each agent CLI and nothing else", () => {
    expect(detectAgent("claude --dangerously-skip-permissions")).toBe("claude");
    expect(detectAgent("opencode --auto")).toBe("opencode");
    expect(detectAgent("npm run dev")).toBeNull();
    expect(detectAgent("")).toBeNull();
    expect(detectAgent(undefined)).toBeNull();
  });

  it("matches the binary name, not a substring of some other word", () => {
    // 'opencoded' / 'my-claude' are different programs; matching them would put an
    // agent icon and resume behavior on a plain shell tab.
    expect(detectAgent("opencoded --auto")).toBeNull();
    expect(detectAgent("my-claude")).toBeNull();
    // A mention later in the line is not the program being run.
    expect(detectAgent("echo claude")).toBeNull();
  });

  it("recognises an absolute path, which is what the resolver actually hands us", () => {
    // On a machine where the bare name is not on PATH the backend resolves a full
    // path; failing to match it would silently drop the tab's agent identity.
    expect(detectAgent("/opt/homebrew/bin/opencode --auto")).toBe("opencode");
    expect(detectAgent("/Users/x/.local/bin/claude --resume abc")).toBe("claude");
  });
});

describe("buildResumeCommand", () => {
  it("uses each CLI's own resume flag", () => {
    // The flags are not interchangeable — each CLI rejects the other's.
    expect(buildResumeCommand("claude", "abc")).toBe(
      "claude --resume abc --dangerously-skip-permissions"
    );
    expect(buildResumeCommand("opencode", "ses_1")).toBe("opencode --session ses_1 --auto");
  });

  it("never puts one CLI's auto-approve flag on the other", () => {
    expect(AGENT_BASE_COMMAND.opencode).not.toContain("dangerously");
    expect(AGENT_BASE_COMMAND.claude).not.toContain("--auto");
    expect(buildResumeCommand("opencode", "x")).not.toContain("dangerously");
  });
});

describe("tabAgent", () => {
  it("keeps a tab persisted before opencode support working", () => {
    // Tabs saved by an older build carry only isClaude. Reading `agent` alone
    // would demote every restored Claude tab to a plain shell — no icon, no
    // resume — which is the quiet regression a stored boolean invites.
    expect(tabAgent({ isClaude: true })).toBe("claude");
    expect(tabAgent({ isClaude: false })).toBeNull();
    expect(tabAgent({})).toBeNull();
  });

  it("prefers the explicit agent when both are present", () => {
    expect(tabAgent({ agent: "opencode", isClaude: false })).toBe("opencode");
    expect(tabAgent({ agent: "claude", isClaude: true })).toBe("claude");
  });
});

describe("buildAgentCommand — per-agent prompt placement", () => {
  it("gives opencode its prompt by flag, never as a positional", () => {
    // `opencode [project]` — the positional is "path to start opencode in"
    // (verified against opencode 1.18.32 --help). A positional prompt would be
    // read as a directory path and the session would start in the wrong place,
    // silently.
    const cmd = buildAgentCommand({
      command: AGENT_BASE_COMMAND.opencode,
      prompt: "fix the migration",
      files: [],
    });
    expect(cmd).toBe("opencode --auto --prompt 'fix the migration'");
  });

  it("still gives claude its prompt as a positional", () => {
    const cmd = buildAgentCommand({
      command: AGENT_BASE_COMMAND.claude,
      prompt: "fix the migration",
      files: [],
    });
    expect(cmd).toBe("claude --dangerously-skip-permissions 'fix the migration'");
    expect(cmd).not.toContain("--prompt");
  });

  it("keeps file references with the prompt for both agents", () => {
    expect(
      buildAgentCommand({ command: AGENT_BASE_COMMAND.opencode, prompt: "go", files: ["/a.ts"] })
    ).toBe("opencode --auto --prompt '@/a.ts go'");
  });

  it("adds no prompt flag when there is no prompt", () => {
    expect(buildAgentCommand({ command: AGENT_BASE_COMMAND.opencode, prompt: "", files: [] })).toBe(
      "opencode --auto"
    );
  });
});
