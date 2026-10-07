import { describe, expect, it } from "vitest";
import { isMuyaChannelWarning } from "./channelPrompt";

// Captured from Claude Code 2.1.292 (spike, 2026-10-07).
const screen = (channels: string, cursorOn = 1) => [
  "  WARNING: Loading development channels",
  "",
  "  --dangerously-load-development-channels is for local channel development only. Do not use this option to run channels you have",
  "  downloaded off the internet.",
  "",
  "  Please use --channels to run a list of approved channels.",
  "",
  `  Channels: ${channels}`,
  "",
  `  ${cursorOn === 1 ? "❯" : " "} 1. I am using this for local development`,
  `  ${cursorOn === 2 ? "❯" : " "} 2. Exit`,
  "",
  "  Enter to confirm · Esc to cancel",
];

describe("isMuyaChannelWarning", () => {
  it("matches the warning for Muya's own channel", () => {
    expect(isMuyaChannelWarning(screen("server:muya-mcp"))).toBe(true);
  });

  it("leaves a warning that names any other channel to the operator", () => {
    expect(isMuyaChannelWarning(screen("server:other"))).toBe(false);
    expect(isMuyaChannelWarning(screen("server:muya-mcp, server:other"))).toBe(false);
    expect(isMuyaChannelWarning(screen("server:muya-mcp-evil"))).toBe(false);
  });

  it("only when option 1 is the selected one", () => {
    expect(isMuyaChannelWarning(screen("server:muya-mcp", 2))).toBe(false);
  });

  it("ignores ordinary screens", () => {
    expect(isMuyaChannelWarning(["❯ 1. I am using this for local development"])).toBe(false);
    expect(isMuyaChannelWarning([])).toBe(false);
  });
});
