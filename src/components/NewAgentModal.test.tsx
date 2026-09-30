import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

// The modal imports the dialog plugin at module load; stub it.
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

import NewAgentModal, { baseCommand } from "./NewAgentModal";

const setup = (props: Partial<React.ComponentProps<typeof NewAgentModal>> = {}) => {
  const onLaunch = vi.fn().mockResolvedValue(undefined);
  const onClose = vi.fn();
  render(<NewAgentModal open onClose={onClose} workspaces={["/w/proj", "/w/other"]} onLaunch={onLaunch} {...props} />);
  return { onLaunch, onClose };
};

describe("NewAgentModal", () => {
  beforeEach(() => vi.clearAllMocks());

  it("does not render when closed", () => {
    const { container } = render(<NewAgentModal open={false} onClose={() => {}} workspaces={[]} onLaunch={vi.fn()} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("defaults to Claude bypass and forwards the spec on Launch", async () => {
    const user = userEvent.setup();
    const { onLaunch } = setup();
    expect(screen.getByRole("tab", { name: "Claude Code" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByLabelText("Permission mode")).toHaveDisplayValue("Bypass permissions");
    expect(screen.getByPlaceholderText("/path/to/project")).toHaveValue("/w/proj");

    await user.type(screen.getByPlaceholderText("feature/my-task"), "feature/x");
    await user.click(screen.getByRole("button", { name: "Launch agent" }));

    expect(onLaunch).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "claude",
        workspace: "/w/proj",
        branch: "feature/x",
        command: "claude --dangerously-skip-permissions",
        prompt: "",
        files: [],
      }),
    );
  });

  it("can still launch Claude's agents manager (the old `claude agents` preset)", async () => {
    const user = userEvent.setup();
    const { onLaunch } = setup();
    await user.type(screen.getByPlaceholderText("Sent to the agent as soon as it starts"), "hi");
    await user.click(screen.getByRole("checkbox", { name: /agents manager/i }));
    expect(screen.getByLabelText("Permission mode")).toBeDisabled();
    expect(screen.queryByPlaceholderText("Sent to the agent as soon as it starts")).toBeNull();
    await user.click(screen.getByRole("button", { name: "Launch agent" }));
    expect(onLaunch).toHaveBeenCalledWith(
      expect.objectContaining({ type: "claude", command: "claude agents", prompt: "", files: [] }),
    );
  });

  it("accepts a manually typed workspace path", async () => {
    const user = userEvent.setup();
    const { onLaunch } = setup();
    fireEvent.change(screen.getByPlaceholderText("/path/to/project"), { target: { value: "/Users/x/other/path" } });
    await user.click(screen.getByRole("button", { name: "Launch agent" }));
    expect(onLaunch).toHaveBeenCalledWith(expect.objectContaining({ workspace: "/Users/x/other/path" }));
  });

  it("picks a workspace from the dropdown", async () => {
    const user = userEvent.setup();
    setup();
    await user.click(screen.getByRole("button", { name: "Known workspaces" }));
    await user.click(screen.getByRole("option", { name: "/w/other" }));
    expect(screen.getByPlaceholderText("/path/to/project")).toHaveValue("/w/other");
  });

  it("maps every Claude permission mode to its real flag", async () => {
    expect(baseCommand("claude", "manual", true)).toBe("claude --permission-mode manual");
    expect(baseCommand("claude", "acceptEdits", true)).toBe("claude --permission-mode acceptEdits");
    expect(baseCommand("claude", "plan", true)).toBe("claude --permission-mode plan");
    expect(baseCommand("claude", "auto", true)).toBe("claude --permission-mode auto");
    expect(baseCommand("claude", "bypass", true)).toBe("claude --dangerously-skip-permissions");

    const user = userEvent.setup();
    const { onLaunch } = setup();
    await user.selectOptions(screen.getByLabelText("Permission mode"), "plan");
    await user.click(screen.getByRole("button", { name: "Launch agent" }));
    expect(onLaunch).toHaveBeenCalledWith(expect.objectContaining({ command: "claude --permission-mode plan" }));
  });

  it("switches type: opencode auto toggle, terminal has no mode and its own title", async () => {
    const user = userEvent.setup();
    const { onLaunch } = setup();
    await user.click(screen.getByRole("tab", { name: "opencode" }));
    expect(screen.queryByLabelText("Permission mode")).toBeNull();
    await user.click(screen.getByRole("button", { name: "Launch agent" }));
    expect(onLaunch).toHaveBeenLastCalledWith(expect.objectContaining({ type: "opencode", command: "opencode --auto" }));

    await user.click(screen.getByRole("tab", { name: "opencode" }));
    await user.click(screen.getByLabelText("Auto-approve"));
    await user.click(screen.getByRole("button", { name: "Launch agent" }));
    expect(onLaunch).toHaveBeenLastCalledWith(expect.objectContaining({ command: "opencode" }));

    await user.click(screen.getByRole("tab", { name: "Terminal" }));
    expect(screen.getByRole("dialog", { name: "New terminal" })).toBeInTheDocument();
    expect(screen.queryByPlaceholderText("feature/my-task")).toBeNull();
    await user.click(screen.getByRole("button", { name: "Open terminal" }));
    expect(onLaunch).toHaveBeenLastCalledWith(expect.objectContaining({ type: "terminal", command: "", branch: "" }));
  });

  it("shows an inline error and does not launch an agent without a workspace", async () => {
    const user = userEvent.setup();
    const { onLaunch } = setup({ workspaces: [] });
    await user.click(screen.getByRole("button", { name: "Launch agent" }));
    expect(onLaunch).not.toHaveBeenCalled();
    expect(screen.getByRole("alert")).toHaveTextContent(/workspace/i);
  });

  it("Advanced shows the exact command and an edit overrides it", async () => {
    const user = userEvent.setup();
    const { onLaunch } = setup();
    await user.type(screen.getByLabelText("Initial prompt (optional)"), "fix it");
    await user.click(screen.getByRole("button", { name: /Advanced/ }));
    const cmd = screen.getByLabelText("Command that will run");
    expect(cmd).toHaveValue("claude --dangerously-skip-permissions 'fix it'");
    fireEvent.change(cmd, { target: { value: "claude agents" } });
    await user.click(screen.getByRole("button", { name: "Launch agent" }));
    expect(onLaunch).toHaveBeenCalledWith(expect.objectContaining({ command: "claude agents", prompt: "", files: [] }));
  });

  it("Cmd+Enter launches", async () => {
    const { onLaunch } = setup();
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Enter", metaKey: true });
    await vi.waitFor(() => expect(onLaunch).toHaveBeenCalledTimes(1));
  });

  it("focuses the workspace field on open", async () => {
    setup();
    await vi.waitFor(() => expect(screen.getByPlaceholderText("/path/to/project")).toHaveFocus());
  });

  // BUG REGRESSION: Esc did nothing, but a stray click outside closed the modal.
  it("Escape closes the modal", () => {
    const { onClose } = setup();
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("clicking the backdrop does NOT close the modal", async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const { container } = render(<NewAgentModal open onClose={onClose} workspaces={["/w/proj"]} onLaunch={vi.fn()} />);
    await user.click(container.firstElementChild as HTMLElement);
    expect(onClose).not.toHaveBeenCalled();
  });

  it("is titled New agent by default", () => {
    setup();
    expect(screen.getByRole("dialog", { name: "New agent" })).toBeInTheDocument();
  });
});
