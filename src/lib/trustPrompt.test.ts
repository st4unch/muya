import { describe, expect, it } from "vitest";
import { trustPromptKeys } from "./trustPrompt";

const head = ["Accessing workspace:", "", "/tmp/ws", "", "Quick safety check: Is this a project you created or one you trust? (Like your own code)", ""];

describe("trustPromptKeys", () => {
  it("2.1.3xx layout: 'No, exit' is pre-selected → Down then Enter", () => {
    expect(trustPromptKeys([...head, "❯ No, exit", "  Yes, I trust this folder", "", "Enter to confirm · Esc to cancel"])).toBe("\x1b[B\r");
  });
  it("older layout: 'Yes' is pre-selected → plain Enter", () => {
    expect(trustPromptKeys([...head, "❯ 1. Yes, proceed", "  2. No, exit"])).toBe("\r");
    expect(trustPromptKeys([...head, "❯ Yes, I trust this folder", "  No, exit"])).toBe("\r");
  });
  it("does nothing on other screens", () => {
    expect(trustPromptKeys([])).toBeNull();
    expect(trustPromptKeys(["staunch@mac ws % claude", "❯ hello"])).toBeNull();
    expect(trustPromptKeys(["Loading development channels", "❯ 1. I am using this for local development", "  2. Exit"])).toBeNull();
  });
  it("waits until the options are drawn", () => {
    expect(trustPromptKeys(head)).toBeNull();
    expect(trustPromptKeys([...head, "  Yes, I trust this folder"])).toBeNull(); // no selection marker yet
  });
});
