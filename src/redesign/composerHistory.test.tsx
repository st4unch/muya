// Created by Claude — Classification: INTERNAL
import { useState } from "react";
import { render, screen, fireEvent } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(() => Promise.resolve([])) }));
import { Composer } from "./Composer";
import { HISTORY_MAX, loadHistory, pushHistory, stepHistory } from "./composerHistory";

describe("pushHistory", () => {
  it("appends, skips a repeat of the newest, caps the length", () => {
    expect(pushHistory([], "a")).toEqual(["a"]);
    expect(pushHistory(["a"], "a")).toEqual(["a"]);
    expect(pushHistory(["a", "b"], "a")).toEqual(["a", "b", "a"]);
    const full = Array.from({ length: HISTORY_MAX }, (_, i) => `p${i}`);
    const next = pushHistory(full, "new");
    expect(next).toHaveLength(HISTORY_MAX);
    expect(next[0]).toBe("p1");
    expect(next[next.length - 1]).toBe("new");
  });
});

describe("stepHistory", () => {
  const list = ["one", "two"];
  it("walks up, stops at the oldest, walks down to the draft", () => {
    let c = { index: null as number | null, draft: "" };
    const s1 = stepHistory(list, c, "up", "typing")!;
    expect(s1.text).toBe("two");
    c = s1.cursor;
    const s2 = stepHistory(list, c, "up", s1.text)!;
    expect(s2.text).toBe("one");
    expect(stepHistory(list, s2.cursor, "up", "one")).toBeNull();
    const s3 = stepHistory(list, s2.cursor, "down", "one")!;
    expect(s3.text).toBe("two");
    const s4 = stepHistory(list, s3.cursor, "down", "two")!;
    expect(s4.text).toBe("typing");
    expect(s4.cursor.index).toBeNull();
  });
  it("does nothing with an empty list or ↓ when not browsing", () => {
    expect(stepHistory([], { index: null, draft: "" }, "up", "")).toBeNull();
    expect(stepHistory(list, { index: null, draft: "" }, "down", "")).toBeNull();
  });
});

function Harness({ target = "agent" as "agent" | "shell", onSend = vi.fn() }) {
  const [value, setValue] = useState("");
  return (
    <Composer
      agentName="muya-all"
      target={target}
      value={value}
      onChange={setValue}
      onSend={(t) => { onSend(t); setValue(""); }}
      mode="bypass"
      onCycleMode={vi.fn()}
      onAttachFile={vi.fn()}
      onCommands={vi.fn()}
    />
  );
}

describe("Composer history", () => {
  beforeEach(() => localStorage.clear());
  const box = () => screen.getByRole("textbox") as HTMLTextAreaElement;
  const type = (text: string) => fireEvent.change(box(), { target: { value: text } });
  const key = (k: string) => fireEvent.keyDown(box(), { key: k });

  it("↑ recalls sent prompts, ↓ returns to the draft", () => {
    render(<Harness />);
    type("first");
    key("Enter");
    type("second");
    key("Enter");
    expect(loadHistory("agent")).toEqual(["first", "second"]);
    type("draft");
    box().setSelectionRange(0, 0);
    key("ArrowUp");
    expect(box().value).toBe("second");
    box().setSelectionRange(0, 0);
    key("ArrowUp");
    expect(box().value).toBe("first");
    key("ArrowDown");
    expect(box().value).toBe("second");
    key("ArrowDown");
    expect(box().value).toBe("draft");
  });

  it("↑ below the first line moves the caret instead", () => {
    localStorage.setItem("apex.composerHistory.agent", JSON.stringify(["old"]));
    render(<Harness />);
    type("line1\nline2");
    box().setSelectionRange(9, 9);
    key("ArrowUp");
    expect(box().value).toBe("line1\nline2");
  });

  it("shell commands and agent prompts are kept apart", () => {
    render(<Harness target="shell" />);
    type("ls -la");
    key("Enter");
    expect(loadHistory("shell")).toEqual(["ls -la"]);
    expect(loadHistory("agent")).toEqual([]);
  });
});
