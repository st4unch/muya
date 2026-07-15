import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

// The modal imports the dialog plugin at module load; stub it.
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

import NewAgentModal from "./NewAgentModal";

describe("NewAgentModal", () => {
  beforeEach(() => vi.clearAllMocks());

  it("does not render when closed", () => {
    const { container } = render(
      <NewAgentModal open={false} onClose={() => {}} workspaces={[]} onLaunch={vi.fn()} />
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("defaults the command and forwards the spec on Launch", async () => {
    const user = userEvent.setup();
    const onLaunch = vi.fn().mockResolvedValue(undefined);
    const onClose = vi.fn();
    render(
      <NewAgentModal open onClose={onClose} workspaces={["/w/proj"]} onLaunch={onLaunch} />
    );

    // default command is the dangerous-skip one (command preset select shows it).
    // Note: an <input list=…> (workspace, datalist-backed) also reports role
    // "combobox" per HTML5 semantics, alongside the actual <select> — filter
    // to the real <select> element rather than assuming array order/length.
    const commandSelect = screen.getAllByRole("combobox").find((el) => el.tagName === "SELECT");
    expect(commandSelect).toHaveDisplayValue("claude --dangerously-skip-permissions");

    // Workspace input is pre-filled with the first known workspace.
    expect(screen.getByPlaceholderText("/path/to/project")).toHaveValue("/w/proj");

    await user.type(screen.getByPlaceholderText("feature/my-task"), "feature/x");
    await user.click(screen.getByRole("button", { name: /launch/i }));

    expect(onLaunch).toHaveBeenCalledTimes(1);
    expect(onLaunch).toHaveBeenCalledWith(
      expect.objectContaining({
        workspace: "/w/proj",
        branch: "feature/x",
        command: "claude --dangerously-skip-permissions",
        prompt: "",
        files: [],
      })
    );
  });

  it("accepts a manually typed workspace path not in the known list", async () => {
    const user = userEvent.setup();
    const onLaunch = vi.fn().mockResolvedValue(undefined);
    render(
      <NewAgentModal open onClose={() => {}} workspaces={["/w/proj"]} onLaunch={onLaunch} />
    );

    const input = screen.getByPlaceholderText("/path/to/project");
    fireEvent.change(input, { target: { value: "/Users/staunch/some/other/path" } });
    await user.click(screen.getByRole("button", { name: /launch/i }));

    expect(onLaunch).toHaveBeenCalledWith(
      expect.objectContaining({ workspace: "/Users/staunch/some/other/path" })
    );
  });

  // BUG REGRESSION: reported behavior was inverted — Esc did nothing, but a
  // stray click outside the modal closed it (and lost the filled-out form).
  it("BUG REGRESSION: Escape closes the modal", () => {
    const onClose = vi.fn();
    render(
      <NewAgentModal open onClose={onClose} workspaces={["/w/proj"]} onLaunch={vi.fn()} />
    );
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("BUG REGRESSION: clicking the backdrop does NOT close the modal", async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const { container } = render(
      <NewAgentModal open onClose={onClose} workspaces={["/w/proj"]} onLaunch={vi.fn()} />
    );
    // The backdrop is the outermost fixed-inset overlay div.
    const backdrop = container.firstElementChild as HTMLElement;
    await user.click(backdrop);
    expect(onClose).not.toHaveBeenCalled();
  });
});
