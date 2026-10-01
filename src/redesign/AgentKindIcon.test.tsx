import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AgentKindIcon, agentGlyph } from "./AgentKindIcon";

describe("agentGlyph", () => {
  it("tells Claude, opencode, terminal and ssh apart", () => {
    expect(agentGlyph({ kind: "claude", agentRunning: true })).toBe("claude");
    expect(agentGlyph({ kind: "opencode", agentRunning: true })).toBe("opencode");
    expect(agentGlyph({ kind: "shell", agentRunning: false })).toBe("terminal");
    expect(agentGlyph({ kind: "ssh", agentRunning: false })).toBe("ssh");
    // claude typed by hand in a plain shell: the screen shows Claude's UI
    expect(agentGlyph({ kind: "shell", agentRunning: true })).toBe("claude");
  });
  it("renders a labelled glyph", () => {
    const { getByRole } = render(<AgentKindIcon agent={{ kind: "opencode", agentRunning: true }} />);
    expect(getByRole("img", { name: "opencode" })).toBeInTheDocument();
  });
});
