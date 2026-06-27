import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
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

    // default command is the dangerous-skip one (command preset select shows it)
    const comboboxes = screen.getAllByRole("combobox");
    // comboboxes[0] = workspace select, comboboxes[1] = command preset select
    expect(comboboxes.length).toBe(2);
    expect(comboboxes[1]).toHaveDisplayValue("claude --dangerously-skip-permissions");

    await user.selectOptions(comboboxes[0], "/w/proj");
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
});
