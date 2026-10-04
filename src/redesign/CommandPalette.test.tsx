import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { CommandPalette } from "./CommandPalette";

// cmdk (Radix dialog + list sizing) needs these browser APIs jsdom lacks.
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} } as unknown as typeof ResizeObserver;
Element.prototype.scrollIntoView ??= () => {};

const base = {
  open: true,
  onOpenChange: () => {},
  agents: [],
  files: [],
  commands: [],
  onSelectAgent: () => {},
  onRunCommand: () => {},
};

describe("CommandPalette — On this Mac", () => {
  it("reports the typed query so the Mac can be searched", () => {
    const onQueryChange = vi.fn();
    render(<CommandPalette {...base} onOpenFile={() => {}} onQueryChange={onQueryChange} />);
    fireEvent.change(screen.getByPlaceholderText(/files on this Mac/), { target: { value: "notes" } });
    expect(onQueryChange).toHaveBeenLastCalledWith("notes");
  });

  it("lists Spotlight results with their folder and opens the chosen one", () => {
    const onOpenFile = vi.fn();
    render(
      <CommandPalette
        {...base}
        onOpenFile={onOpenFile}
        macFiles={[{ path: "/Users/u/docs/notes.md", name: "notes.md", dir: "~/docs" }]}
      />,
    );
    expect(screen.getByText("On this Mac")).toBeInTheDocument();
    expect(screen.getByText("~/docs")).toBeInTheDocument();
    fireEvent.click(screen.getByText("notes.md"));
    expect(onOpenFile).toHaveBeenCalledWith("/Users/u/docs/notes.md");
  });

  it("shows no On this Mac heading without results", () => {
    render(<CommandPalette {...base} onOpenFile={() => {}} />);
    expect(screen.queryByText("On this Mac")).toBeNull();
  });
});
