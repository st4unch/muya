import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { SlashCommandsPopover, filterSlashItems } from "./SlashCommandsPopover";
import { mergeSlashItems } from "./useSlashCommands";
import { CLAUDE_BUILTINS, OPENCODE_BUILTINS } from "./slashBuiltins";
import type { SlashItem } from "./useSlashCommands";

const ITEMS: SlashItem[] = [
  { name: "clear", description: "Start a new session", source: "builtin" },
  { name: "compact", description: "Free up context", source: "builtin" },
  { name: "release", description: "Cut a release", source: "project" },
  { name: "kickoff", description: "Bootstrap a project", source: "skill" },
];
const ANCHOR = { left: 100, top: 500 } as DOMRect;

function setup() {
  const onPick = vi.fn();
  const onClose = vi.fn();
  render(<SlashCommandsPopover anchor={ANCHOR} items={ITEMS} onPick={onPick} onClose={onClose} />);
  return { onPick, onClose, input: screen.getByRole("combobox") };
}

describe("SlashCommandsPopover", () => {
  it("groups rows and focuses the filter input", () => {
    const { input } = setup();
    expect(document.activeElement).toBe(input);
    expect(screen.getAllByRole("option")).toHaveLength(4);
    for (const h of ["BUILT-IN", "PROJECT", "SKILLS"]) expect(screen.getByText(h)).toBeTruthy();
    expect(screen.queryByText("USER")).toBeNull();
  });

  it("filters by name and description", () => {
    const { input } = setup();
    fireEvent.change(input, { target: { value: "boot" } });
    expect(screen.getAllByRole("option").map((o) => o.textContent)).toEqual(["/kickoffBootstrap a project"]);
    fireEvent.change(input, { target: { value: "zzz" } });
    expect(screen.getByText("No matching commands")).toBeTruthy();
  });

  it("ArrowDown + Enter picks the second row", () => {
    const { input, onPick } = setup();
    fireEvent.keyDown(input, { key: "ArrowDown" });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onPick).toHaveBeenCalledWith("compact");
  });

  it("clicking a row picks it; Esc and outside click close", () => {
    const { onPick, onClose } = setup();
    fireEvent.mouseDown(screen.getByText("/release"));
    expect(onPick).toHaveBeenCalledWith("release");
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
    fireEvent.mouseDown(document.querySelector(".rd-root") as HTMLElement);
    expect(onClose).toHaveBeenCalledTimes(2);
  });
});

describe("slash helpers", () => {
  it("filterSlashItems ranks prefix matches first and ignores a leading slash", () => {
    const r = filterSlashItems(ITEMS, "/re");
    expect(r.map((i) => i.name)).toEqual(["release", "compact"]);
  });

  it("mergeSlashItems keeps built-ins, appends disk items, drops shadowing duplicates", () => {
    const merged = mergeSlashItems("claude", [
      { name: "clear", description: "shadow", source: "user" },
      { name: "mine", description: "d", source: "user" },
    ]);
    expect(merged.filter((i) => i.name === "clear")).toHaveLength(1);
    expect(merged[merged.length - 1]).toMatchObject({ name: "mine", source: "user" });
  });

  it("captured built-in lists are non-empty, unique and slash-free", () => {
    for (const list of [CLAUDE_BUILTINS, OPENCODE_BUILTINS]) {
      expect(list.length).toBeGreaterThan(10);
      expect(new Set(list.map((b) => b.name)).size).toBe(list.length);
      expect(list.every((b) => !b.name.startsWith("/") && b.description.length > 0)).toBe(true);
    }
  });
});
