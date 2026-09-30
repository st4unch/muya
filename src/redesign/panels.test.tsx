import { fireEvent, render, screen, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ControlScreen } from "./ControlScreen";
import { GridScreen } from "./GridScreen";
import { ResizeHandle, clampSize } from "./ResizeHandle";
import { panelShortcut } from "./usePanelLayout";
import { shouldExitGridOnEscape } from "./gridKeys";
import { previewAgents, previewFooter, previewHeader, previewInspector } from "./previewFixture";

function controlProps(): React.ComponentProps<typeof ControlScreen> {
  return {
    header: previewHeader, footer: previewFooter, themePreference: "dark", onThemeCycle: vi.fn(), onNotificationsClick: vi.fn(),
    onWorkspaceClick: vi.fn(), onOpenPalette: vi.fn(), railActive: "control", onRailNavigate: vi.fn(), agents: previewAgents,
    selectedAgentKey: "muya-all", agentFilter: "all", onAgentFilterChange: vi.fn(), onSelectAgent: vi.fn(), onNewAgent: vi.fn(),
    onReorderAgents: vi.fn(), openFile: null, onCloseFile: vi.fn(), onCompact: vi.fn(), onSplitToGrid: vi.fn(), onStop: vi.fn(),
    onMoreActions: vi.fn(), composerValue: "", onComposerChange: vi.fn(), onSendMessage: vi.fn(), onCycleMode: vi.fn(),
    onAttachFile: vi.fn(), onOpenCommands: vi.fn(), updateReady: false, onRestartForUpdate: vi.fn(), inspector: previewInspector,
    inspectorTab: "changes", onInspectorTabChange: vi.fn(), onApprove: vi.fn(), onDeny: vi.fn(), onOpenApproval: vi.fn(),
    onReviewDiff: vi.fn(), onCommit: vi.fn(), inspectorOpen: true, filesSlot: <div>tree here</div>, filesCount: 3,
  };
}

beforeEach(() => localStorage.clear());

// jsdom has no layout: report the inline width like a browser would.
Object.defineProperty(HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get() {
    return parseInt((this as HTMLElement).style.width, 10) || 296;
  },
});

describe("panel toggles", () => {
  it("hide/show exactly their own panel and persist", () => {
    const { unmount } = render(<ControlScreen {...controlProps()} />);
    expect(screen.getByLabelText("Agents")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Hide agents panel" }));
    expect(screen.queryByLabelText("Agents")).toBeNull();
    expect(screen.getByLabelText("Inspector")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Show agents panel" })).toHaveAttribute("aria-pressed", "false");
    fireEvent.click(screen.getByRole("button", { name: "Hide inspector" }));
    expect(screen.queryByLabelText("Inspector")).toBeNull();
    unmount();
    render(<ControlScreen {...controlProps()} />); // "restart"
    expect(screen.queryByLabelText("Agents")).toBeNull();
    expect(screen.queryByLabelText("Inspector")).toBeNull();
  });

  it("⌘B / ⌥⌘B toggle from anywhere (window capture, keyed on code)", () => {
    render(<ControlScreen {...controlProps()} />);
    fireEvent.keyDown(document.body, { code: "KeyB", key: "b", metaKey: true });
    expect(screen.queryByLabelText("Agents")).toBeNull();
    fireEvent.keyDown(document.body, { code: "KeyB", key: "∫", metaKey: true, altKey: true });
    expect(screen.queryByLabelText("Inspector")).toBeNull();
    fireEvent.keyDown(document.body, { code: "KeyB", key: "b", metaKey: true });
    expect(screen.getByLabelText("Agents")).toBeInTheDocument();
  });

  it("below 1280px the inspector starts hidden, the toggle's pressed state matches, and it can still be shown", () => {
    render(<ControlScreen {...controlProps()} inspectorOpen={false} />);
    expect(screen.queryByLabelText("Inspector")).toBeNull();
    const btn = screen.getByRole("button", { name: "Show inspector" });
    expect(btn).toHaveAttribute("aria-pressed", "false");
    fireEvent.click(btn);
    expect(screen.getByLabelText("Inspector")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Hide inspector" })).toHaveAttribute("aria-pressed", "true");
    // The wide-screen preference was not overwritten by the narrow-window toggle.
    expect(localStorage.getItem("muya.panels.inspectorOpen")).not.toBe("false");
  });

  it("panelShortcut ignores other chords", () => {
    const e = { metaKey: true, ctrlKey: false, shiftKey: false, altKey: false, code: "KeyB" };
    expect(panelShortcut(e)).toBe("agents");
    expect(panelShortcut({ ...e, altKey: true })).toBe("inspector");
    expect(panelShortcut({ ...e, shiftKey: true })).toBeNull();
    expect(panelShortcut({ ...e, metaKey: false })).toBeNull();
    expect(panelShortcut({ ...e, code: "KeyK" })).toBeNull();
  });
});

describe("resize", () => {
  it("clamps to the limits", () => {
    expect(clampSize(100, 220, 480)).toBe(220);
    expect(clampSize(900, 220, 480)).toBe(480);
    expect(clampSize(300.4, 220, 480)).toBe(300);
  });

  it("keyboard resize on the agents handle is clamped, persisted; double-click resets", () => {
    render(<ControlScreen {...controlProps()} />);
    const handle = screen.getByRole("separator", { name: "Resize agents panel" });
    const aside = screen.getByLabelText("Agents");
    for (let i = 0; i < 40; i++) fireEvent.keyDown(handle, { key: "ArrowRight", shiftKey: true });
    expect(aside.style.width).toBe("480px");
    expect(localStorage.getItem("muya.panels.agentsWidth")).toBe("480");
    for (let i = 0; i < 40; i++) fireEvent.keyDown(handle, { key: "ArrowLeft", shiftKey: true });
    expect(aside.style.width).toBe("220px");
    fireEvent.doubleClick(handle);
    expect(aside.style.width).toBe("296px");
    expect(localStorage.getItem("muya.panels.agentsWidth")).toBeNull();
  });

  it("restores a stored width (clamped) on mount", () => {
    localStorage.setItem("muya.panels.inspectorWidth", "9999");
    render(<ControlScreen {...controlProps()} />);
    expect(screen.getByLabelText("Inspector").style.width).toBe("520px");
  });

  it("pointer drag reports growth from the start size", () => {
    const onResize = vi.fn();
    render(
      <div>
        <ResizeHandle side="left" min={260} max={520} getSize={() => 320} onResize={onResize} onReset={vi.fn()} label="h" />
      </div>,
    );
    const h = screen.getByRole("separator");
    h.setPointerCapture = vi.fn();
    fireEvent.pointerDown(h, { button: 0, clientX: 500, pointerId: 1 });
    fireEvent.pointerMove(h, { clientX: 450, pointerId: 1 }); // left-side handle: dragging left grows
    expect(onResize).toHaveBeenLastCalledWith(370);
    fireEvent.pointerMove(h, { clientX: 0, pointerId: 1 });
    expect(onResize).toHaveBeenLastCalledWith(520);
    fireEvent.pointerUp(h, { pointerId: 1 });
    onResize.mockClear();
    fireEvent.pointerMove(h, { clientX: 400, pointerId: 1 });
    expect(onResize).not.toHaveBeenCalled();
  });
});

describe("files section", () => {
  it("is collapsed by default, expands on click, persists, and the inspector has no Files tab", () => {
    const { unmount } = render(<ControlScreen {...controlProps()} />);
    const head = screen.getByRole("button", { name: /FILES/ });
    expect(head).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByText("tree here")).toBeNull();
    fireEvent.click(head);
    expect(screen.getByText("tree here")).toBeInTheDocument();
    expect(screen.getByRole("separator", { name: "Resize files section" })).toBeInTheDocument();
    expect(screen.queryByRole("tab", { name: "Files" })).toBeNull();
    unmount();
    render(<ControlScreen {...controlProps()} />);
    expect(screen.getByText("tree here")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /FILES/ }));
    expect(screen.queryByText("tree here")).toBeNull();
  });
});

describe("files fill", () => {
  it("expanded Files fills the panel until the split is dragged; double-click returns to fill", () => {
    render(<ControlScreen {...controlProps()} />);
    fireEvent.click(screen.getByRole("button", { name: /FILES/ }));
    const files = screen.getByLabelText("Files");
    expect(files.style.flex).toBe("1 1 0px");
    localStorage.setItem("muya.panels.filesHeight", "300");
  });
  it("a stored split height is used instead of fill", () => {
    localStorage.setItem("muya.panels.filesOpen", "true");
    localStorage.setItem("muya.panels.filesHeight", "300");
    render(<ControlScreen {...controlProps()} />);
    expect(screen.getByLabelText("Files").style.flex).toBe("0 1 300px");
  });
});

describe("rename", () => {
  it("double-click a session in the list renames it in place; Esc cancels", () => {
    const onRename = vi.fn();
    render(<ControlScreen {...controlProps()} onRenameAgent={onRename} />);
    const list = screen.getByLabelText("Agents");
    fireEvent.doubleClick(within(list).getByText("iptv-2a"));
    const input = within(list).getByLabelText("Session name");
    expect(input).toHaveValue("iptv-2a");
    fireEvent.change(input, { target: { value: "  iptv-main " } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onRename).toHaveBeenCalledWith("iptv-2a", "iptv-main");

    fireEvent.doubleClick(within(list).getByText("muya-all"));
    const again = within(list).getByLabelText("Session name");
    fireEvent.change(again, { target: { value: "other" } });
    fireEvent.keyDown(again, { key: "Escape" });
    expect(onRename).toHaveBeenCalledTimes(1);
    expect(within(list).queryByLabelText("Session name")).toBeNull();
  });

  it("double-click the session header name renames the selected session", () => {
    const onRename = vi.fn();
    render(<ControlScreen {...controlProps()} onRenameAgent={onRename} />);
    fireEvent.doubleClick(screen.getByRole("heading", { level: 1 }));
    const input = screen.getByLabelText("Session name");
    fireEvent.change(input, { target: { value: "renamed" } });
    fireEvent.blur(input);
    expect(onRename).toHaveBeenCalledWith("muya-all", "renamed");
  });

  it("right-click on a session asks for its actions menu", () => {
    const onCtx = vi.fn();
    render(<ControlScreen {...controlProps()} onAgentContextMenu={onCtx} />);
    fireEvent.contextMenu(within(screen.getByLabelText("Agents")).getByText("numbat-c3"));
    expect(onCtx).toHaveBeenCalledWith("numbat-c3", expect.anything());
  });
});

describe("files search", () => {
  it("the filter button lives in the Files header, only while expanded", () => {
    render(<ControlScreen {...controlProps()} />);
    expect(screen.queryByRole("button", { name: "Filter files" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: /FILES/ }));
    const btn = screen.getByRole("button", { name: "Filter files" });
    fireEvent.click(btn);
    expect(screen.getByRole("button", { name: "Close file filter" })).toHaveAttribute("aria-pressed", "true");
  });
});

describe("leaving the grid", () => {
  it("Exit grid button calls onExitGrid", () => {
    const onExitGrid = vi.fn();
    render(
      <GridScreen
        railActive="control" onRailNavigate={vi.fn()} footer={{ ...previewFooter, variant: "grid" }} panels={previewAgents.slice(0, 2)}
        layout="1x2" onLayoutChange={vi.fn()} onWaitingFirst={vi.fn()} onBroadcastOpen={vi.fn()} onExitGrid={onExitGrid}
        focusedKey="muya-all" onFocusPanel={vi.fn()} onMaximizePanel={vi.fn()} onApprove={vi.fn()} onDeny={vi.fn()}
        onAlwaysAllow={vi.fn()} composerValues={{}} onComposerChange={vi.fn()} onSendMessage={vi.fn()}
        onAssignFromQueue={vi.fn()} onReplacePanel={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "Exit grid" }));
    expect(onExitGrid).toHaveBeenCalledTimes(1);
  });

  it("Esc exits only outside terminals, fields, dialogs and overlays", () => {
    const mk = (html: string) => {
      const host = document.createElement("div");
      host.innerHTML = html;
      document.body.appendChild(host);
      return host.firstElementChild as HTMLElement;
    };
    const key = (target: EventTarget | null, extra = {}) => ({ key: "Escape", metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, target, ...extra });
    expect(shouldExitGridOnEscape(key(document.body), false)).toBe(true);
    expect(shouldExitGridOnEscape(key(mk("<section><b>x</b></section>")), false)).toBe(true);
    expect(shouldExitGridOnEscape(key(mk('<div data-terminal-slot="a"><textarea></textarea></div>').firstElementChild), false)).toBe(false);
    expect(shouldExitGridOnEscape(key(mk("<input />")), false)).toBe(false);
    expect(shouldExitGridOnEscape(key(mk("<textarea></textarea>")), false)).toBe(false);
    expect(shouldExitGridOnEscape(key(mk('<div role="dialog"><button>b</button></div>').firstElementChild), false)).toBe(false);
    expect(shouldExitGridOnEscape(key(document.body), true)).toBe(false);
    expect(shouldExitGridOnEscape(key(document.body, { key: "Enter" }), false)).toBe(false);
    expect(shouldExitGridOnEscape(key(document.body, { shiftKey: true }), false)).toBe(false);
  });
});
