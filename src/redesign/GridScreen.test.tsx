import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { GridScreen } from "./GridScreen";
import { previewAgents, previewFooter } from "./previewFixture";

function baseProps(): React.ComponentProps<typeof GridScreen> {
  return {
    railActive: "control",
    onRailNavigate: vi.fn(),
    footer: { ...previewFooter, variant: "grid" },
    panels: previewAgents.slice(0, 4),
    layout: "2x2",
    onLayoutChange: vi.fn(),
    onWaitingFirst: vi.fn(),
    onBroadcastOpen: vi.fn(),
    focusedKey: "documents-44",
    onFocusPanel: vi.fn(),
    onMaximizePanel: vi.fn(),
    onApprove: vi.fn(),
    onDeny: vi.fn(),
    onAlwaysAllow: vi.fn(),
    composerValues: {},
    onComposerChange: vi.fn(),
    onSendMessage: vi.fn(),
    onAssignFromQueue: vi.fn(),
    onReplacePanel: vi.fn(),
  };
}

describe("GridScreen", () => {
  it("renders one panel per agent, the rail (incl. Settings) and the grid footer hint", () => {
    render(<GridScreen {...baseProps()} />);
    expect(screen.getByRole("region", { name: "documents-44" })).toBeInTheDocument();
    expect(screen.getByRole("region", { name: "muya-all" })).toBeInTheDocument();
    expect(screen.getByLabelText("Settings")).toBeInTheDocument();
    expect(screen.getByText("Tab to switch panels · ⌘⏎ maximize")).toBeInTheDocument();
  });

  it("renders the layout segment and panel count", () => {
    render(<GridScreen {...baseProps()} />);
    expect(screen.getByText("4 panels")).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "2×2" })).toBeInTheDocument();
  });

  it("fills unused cells of the layout with empty panels whose pick adds an agent", async () => {
    const props = { ...baseProps(), panels: previewAgents.slice(0, 2), layout: "2x2" as const };
    render(<GridScreen {...props} />);
    const empties = screen.getAllByRole("region", { name: "Empty panel" });
    expect(empties).toHaveLength(2);
    screen.getAllByRole("button", { name: "Swap panel" })[0].click();
    expect(props.onReplacePanel).toHaveBeenCalledWith("empty:0");
  });
});
