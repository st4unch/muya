import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ControlScreen } from "./ControlScreen";
import { previewAgents, previewFooter, previewHeader, previewInspector } from "./previewFixture";

function baseProps(): React.ComponentProps<typeof ControlScreen> {
  return {
    header: previewHeader,
    footer: previewFooter,
    themePreference: "dark",
    onThemeCycle: vi.fn(),
    onNotificationsClick: vi.fn(),
    onWorkspaceClick: vi.fn(),
    onOpenPalette: vi.fn(),
    railActive: "control",
    onRailNavigate: vi.fn(),
    agents: previewAgents,
    selectedAgentKey: "muya-all",
    agentFilter: "all",
    onAgentFilterChange: vi.fn(),
    onSelectAgent: vi.fn(),
    onNewAgent: vi.fn(),
    onReorderAgents: vi.fn(),
    openFile: null,
    onCloseFile: vi.fn(),
    onCompact: vi.fn(),
    onSplitToGrid: vi.fn(),
    onStop: vi.fn(),
    onMoreActions: vi.fn(),
    composerValue: "",
    onComposerChange: vi.fn(),
    onSendMessage: vi.fn(),
    onCycleMode: vi.fn(),
    onAttachFile: vi.fn(),
    onOpenCommands: vi.fn(),
    updateReady: false,
    onRestartForUpdate: vi.fn(),
    inspector: previewInspector,
    inspectorTab: "changes",
    onInspectorTabChange: vi.fn(),
    onApprove: vi.fn(),
    onDeny: vi.fn(),
    onOpenApproval: vi.fn(),
    onReviewDiff: vi.fn(),
    onCommit: vi.fn(),
    inspectorOpen: true,
  };
}

describe("ControlScreen", () => {
  it("renders the session header for the selected agent and the terminal slot", () => {
    render(<ControlScreen {...baseProps()} />);
    expect(screen.getByRole("heading", { name: "muya-all" })).toBeInTheDocument();
    expect(screen.getByText("Bypass permissions on")).toBeInTheDocument();
    expect(document.querySelector('[data-terminal-slot="muya-all"]')).toBeInTheDocument();
  });

  it("shows FileHeader instead of SessionHeader when a file is open", () => {
    render(<ControlScreen {...baseProps()} openFile={{ name: "pty.rs", path: "src-tauri/src/pty.rs" }} />);
    expect(screen.getByRole("heading", { name: "pty.rs" })).toBeInTheDocument();
    expect(screen.getByText("Close")).toBeInTheDocument();
    expect(screen.queryByText("Bypass permissions on")).not.toBeInTheDocument();
  });

  it("hides the inspector when inspectorOpen is false", () => {
    render(<ControlScreen {...baseProps()} inspectorOpen={false} />);
    expect(screen.queryByLabelText("Inspector")).not.toBeInTheDocument();
  });

  // Live: with the chat box closed the strip duplicated Claude's own spinner line, and
  // appearing/disappearing with every turn resized the terminal so it kept jumping.
  it("hides the progress strip while the chat box is closed", () => {
    const { rerender } = render(<ControlScreen {...baseProps()} composerOpen={false} />);
    expect(screen.queryByText("Unfurling…")).not.toBeInTheDocument();
    rerender(<ControlScreen {...baseProps()} composerOpen />);
    expect(screen.getByText("Unfurling…")).toBeInTheDocument();
  });

  it("still shows the update notice with the chat box closed", () => {
    render(<ControlScreen {...baseProps()} composerOpen={false} updateReady />);
    expect(screen.queryByText("Unfurling…")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /restart/i })).toBeInTheDocument();
  });

  // Live: a first launch showed a blank main pane that read as broken.
  it("guides the user when there are no agents", () => {
    const onNewTerminal = vi.fn();
    const onNewAgent = vi.fn();
    render(<ControlScreen {...baseProps()} agents={[]} selectedAgentKey={null} onNewTerminal={onNewTerminal} onNewAgent={onNewAgent} />);
    expect(screen.getByText("No agents yet")).toBeInTheDocument();
    screen.getByRole("button", { name: /New terminal/ }).click();
    expect(onNewTerminal).toHaveBeenCalled();
    expect(document.querySelector("[data-terminal-slot]")).toBeNull();
  });
});
