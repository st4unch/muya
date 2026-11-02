import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { SplitArea } from "./SplitArea";
import { previewAgents } from "./previewFixture";

const [a, b, c] = previewAgents;
const panes = [a, b, c].map((agent) => ({ key: agent.key, agent }));

describe("SplitArea focus", () => {
  it("each pane has a focus button that calls onToggleZoom(key)", () => {
    const onToggleZoom = vi.fn();
    render(<SplitArea panes={panes} focusedKey={a.key} onFocusPane={vi.fn()} onClosePane={vi.fn()} onToggleZoom={onToggleZoom} />);
    expect(document.querySelectorAll("[data-split-pane]")).toHaveLength(3);
    fireEvent.click(screen.getByRole("button", { name: `Focus pane ${b.name}` }));
    expect(onToggleZoom).toHaveBeenCalledWith(b.key);
  });

  it("a zoomed pane is shown alone with a Restore button; the others' slots are gone", () => {
    const onToggleZoom = vi.fn();
    render(<SplitArea panes={panes} focusedKey={b.key} zoomedKey={b.key} onFocusPane={vi.fn()} onClosePane={vi.fn()} onToggleZoom={onToggleZoom} />);
    const shown = document.querySelectorAll<HTMLElement>("[data-split-pane]");
    expect(shown).toHaveLength(1);
    expect(shown[0].dataset.splitPane).toBe(b.key);
    expect(document.querySelector(`[data-terminal-slot="${a.key}"]`)).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Restore split" }));
    expect(onToggleZoom).toHaveBeenCalledWith(b.key);
  });

  it("a zoomed key that is not a pane shows the whole split", () => {
    render(<SplitArea panes={panes} focusedKey={a.key} zoomedKey="gone" onFocusPane={vi.fn()} onClosePane={vi.fn()} onToggleZoom={vi.fn()} />);
    expect(document.querySelectorAll("[data-split-pane]")).toHaveLength(3);
  });
});
