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

describe("Files rail", () => {
  const files = [
    { key: "edit:/r/a.ts", name: "a.ts", dir: "~/r", kind: "code" as const, dirty: true },
    { key: "pdf:/r/b.pdf", name: "b.pdf", dir: "~/r", kind: "pdf" as const, dirty: false },
  ];

  it("lists open files instead of agents; click selects, × closes, unsaved is marked", async () => {
    const { fireEvent, within } = await import("@testing-library/react");
    const onSelectFile = vi.fn();
    const onCloseOpenFile = vi.fn();
    render(
      <ControlScreen
        {...baseProps()}
        railActive="files"
        mode="files"
        openFiles={files}
        selectedFileKey="edit:/r/a.ts"
        onSelectFile={onSelectFile}
        onCloseOpenFile={onCloseOpenFile}
        openFile={{ name: "a.ts", path: "~/r/a.ts" }}
        fileSlot={<div data-testid="file-slot" />}
      />,
    );
    expect(screen.queryByLabelText("Agents")).toBeNull();
    const list = screen.getByRole("list", { name: "Open files" });
    expect(within(list).getAllByRole("listitem")).toHaveLength(2);
    expect(within(list).getByLabelText("Unsaved changes")).toBeInTheDocument();
    fireEvent.click(within(list).getByText("b.pdf"));
    expect(onSelectFile).toHaveBeenCalledWith("pdf:/r/b.pdf");
    fireEvent.click(within(list).getByRole("button", { name: "Close b.pdf" }));
    expect(onCloseOpenFile).toHaveBeenCalledWith("pdf:/r/b.pdf");
    // The main area shows the file, not the terminal or the message box.
    expect(screen.getByTestId("file-slot")).toBeInTheDocument();
    expect(document.querySelector("[data-terminal-slot]")).toBeNull();
  });

  it("with nothing open says how to open a file", () => {
    render(<ControlScreen {...baseProps()} railActive="files" mode="files" openFiles={[]} selectedFileKey={null} />);
    expect(screen.getByText("No file open")).toBeInTheDocument();
    expect(screen.getByText(/No open files/)).toBeInTheDocument();
  });

  it("agents mode keeps the terminal on screen even while a file is open", () => {
    render(<ControlScreen {...baseProps()} mode="agents" openFiles={files} openFile={{ name: "a.ts", path: "~/r/a.ts" }} fileSlot={<div data-testid="file-slot" />} />);
    expect(screen.queryByTestId("file-slot")).toBeNull();
    expect(document.querySelector('[data-terminal-slot="muya-all"]')).not.toBeNull();
    expect(screen.getByLabelText("Agents")).toBeInTheDocument();
  });
});
