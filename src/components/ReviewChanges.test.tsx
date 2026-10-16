// Created by Claude — Classification: INTERNAL
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

vi.mock("./ReviewDiffPane", () => ({
  default: ({ path, original, modified }: { path: string; original: string; modified: string }) => (
    <pre data-testid="pane">{`${path}|${original}|${modified}`}</pre>
  ),
}));
import { ReviewChanges, type ReviewSource } from "./ReviewChanges";

function source(): ReviewSource & { load: ReturnType<typeof vi.fn> } {
  const load = vi.fn(async (f: { path: string }) => ({ original: `old-${f.path}`, modified: `new-${f.path}` }));
  return {
    title: "Uncommitted changes · demo",
    files: [
      { code: "M", path: "a.ts", abs: "/r/a.ts" },
      { code: "?", path: "newdir/" },
      { code: "D", path: "c.ts", abs: "/r/c.ts" },
    ],
    load,
  };
}

describe("ReviewChanges", () => {
  it("lists every file and shows the picked file's diff", async () => {
    const src = source();
    render(<ReviewChanges source={src} theme="dark" onClose={vi.fn()} />);
    expect(screen.getAllByRole("option")).toHaveLength(3);
    expect(await screen.findByTestId("pane")).toHaveTextContent("a.ts|old-a.ts|new-a.ts");
    fireEvent.click(screen.getByRole("option", { name: /c\.ts/ }));
    await waitFor(() => expect(screen.getByTestId("pane")).toHaveTextContent("c.ts|old-c.ts|new-c.ts"));
  });

  it("Prev/Next and [ ] move, disabled at the ends; a folder has no diff", async () => {
    const src = source();
    render(<ReviewChanges source={src} theme="light" onClose={vi.fn()} />);
    const prev = screen.getByRole("button", { name: "← Prev" });
    const next = screen.getByRole("button", { name: "Next →" });
    expect(prev).toBeDisabled();
    fireEvent.click(next);
    expect(await screen.findByText(/A new folder/)).toBeInTheDocument();
    expect(src.load).toHaveBeenCalledTimes(1); // the folder is never loaded
    fireEvent.keyDown(window, { key: "]" });
    await waitFor(() => expect(screen.getByTestId("pane")).toHaveTextContent("c.ts"));
    expect(next).toBeDisabled();
    fireEvent.keyDown(window, { key: "[" });
    expect(await screen.findByText(/A new folder/)).toBeInTheDocument();
    expect(screen.getByText("File 2 of 3 · [ and ] to move")).toBeInTheDocument();
  });

  it("starts at startIndex and opens a working-tree file in the editor", async () => {
    const onOpenFile = vi.fn();
    const onClose = vi.fn();
    render(<ReviewChanges source={source()} startIndex={0} theme="dark" onClose={onClose} onOpenFile={onOpenFile} />);
    fireEvent.click(await screen.findByRole("button", { name: "Open in editor" }));
    expect(onOpenFile).toHaveBeenCalledWith("/r/a.ts");
    expect(onClose).toHaveBeenCalled();
  });
});
