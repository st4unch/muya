import { describe, it, expect, vi } from "vitest";
import { render, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));

import CreateWithClaudeModal from "./CreateWithClaudeModal";

describe("CreateWithClaudeModal", () => {
  it("does not render when closed", () => {
    const { container } = render(
      <CreateWithClaudeModal open={false} onClose={() => {}} onOpenTerminal={vi.fn()} />
    );
    expect(container).toBeEmptyDOMElement();
  });

  // BUG REGRESSION: same inverted Esc/backdrop behavior fixed across all
  // form modals in this session — Esc should close, a stray outside click
  // should not silently drop the form.
  it("BUG REGRESSION: Escape closes the modal", () => {
    const onClose = vi.fn();
    render(
      <CreateWithClaudeModal open onClose={onClose} onOpenTerminal={vi.fn()} />
    );
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("BUG REGRESSION: clicking the backdrop does NOT close the modal", async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const { container } = render(
      <CreateWithClaudeModal open onClose={onClose} onOpenTerminal={vi.fn()} />
    );
    const backdrop = container.firstElementChild as HTMLElement;
    await user.click(backdrop);
    expect(onClose).not.toHaveBeenCalled();
  });
});
