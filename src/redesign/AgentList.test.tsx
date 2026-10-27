import { render, screen, fireEvent, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AgentList, COMPACT_AFTER, dropModeAt } from "./AgentList";
import { previewAgents } from "./previewFixture";

describe("AgentList", () => {
  it("groups agents and hides empty groups", () => {
    render(
      <AgentList agents={previewAgents} selectedKey="muya-all" filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    expect(screen.getByText("WAITING FOR YOU")).toBeInTheDocument();
    expect(screen.getByText("WORKING")).toBeInTheDocument();
    expect(screen.getByText("IDLE")).toBeInTheDocument();
    expect(screen.getByText("documents-44")).toBeInTheDocument();
    expect(screen.getByText("serbest")).toBeInTheDocument();
  });

  it("filter=waiting shows only the waiting group", () => {
    const onFilterChange = vi.fn();
    const { rerender } = render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={onFilterChange} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    fireEvent.click(screen.getByRole("tab", { name: /Waiting/i }));
    expect(onFilterChange).toHaveBeenCalledWith("waiting");

    rerender(
      <AgentList agents={previewAgents} selectedKey={null} filter="waiting" onFilterChange={onFilterChange} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    expect(screen.getByText("WAITING FOR YOU")).toBeInTheDocument();
    expect(screen.queryByText("WORKING")).not.toBeInTheDocument();
    expect(screen.queryByText("IDLE")).not.toBeInTheDocument();
  });

  it("filter=recent shows only agents active in the last 6 hours", () => {
    const onFilterChange = vi.fn();
    const agents = previewAgents.map((a) => (a.status === "idle" ? a : { ...a, recent: true }));
    const { rerender } = render(
      <AgentList agents={agents} selectedKey={null} filter="all" onFilterChange={onFilterChange} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    const recentCount = agents.filter((a) => a.recent).length;
    fireEvent.click(screen.getByRole("tab", { name: `Recent ${recentCount}` }));
    expect(onFilterChange).toHaveBeenCalledWith("recent");

    rerender(
      <AgentList agents={agents} selectedKey={null} filter="recent" onFilterChange={onFilterChange} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    expect(screen.getByText("iptv-2a")).toBeInTheDocument();
    expect(screen.queryByText("serbest")).not.toBeInTheDocument();
    expect(screen.getByText("WORKING")).toBeInTheDocument();
  });

  it("selecting a card calls onSelectAgent with its key", () => {
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    fireEvent.click(screen.getByText("muya-all"));
    expect(onSelectAgent).toHaveBeenCalledWith("muya-all");
  });

  // The list drags with pointer events (Tauri's native layer swallows HTML5 drag-and-drop,
  // L80); the drop target is found with elementFromPoint, stubbed here.
  function pointerDrag(from: HTMLElement, over: HTMLElement, y = 20) {
    document.elementFromPoint = () => over;
    fireEvent.pointerDown(from, { button: 0, clientX: 0, clientY: 0 });
    window.dispatchEvent(new MouseEvent("pointermove", { clientX: 40, clientY: y }));
    window.dispatchEvent(new MouseEvent("pointerup", { clientX: 40, clientY: y }));
  }
  // A finished drag swallows the click that follows it until the next tick; let it lapse.
  afterEach(() => new Promise((r) => setTimeout(r, 0)));
  const rowRect = () => ({ top: 0, height: 40, bottom: 40, left: 0, right: 200, width: 200, x: 0, y: 0, toJSON: () => ({}) });

  it("dragging a row onto another calls onReorder(from, to) and does not select it", () => {
    const onReorder = vi.fn();
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={onReorder} />,
    );
    const from = screen.getByText("muya-all").closest("button")!;
    const to = screen.getByText("opencode-review").closest("button")!;
    pointerDrag(from, to);
    fireEvent.click(from);
    expect(onReorder).toHaveBeenCalledWith("muya-all", "opencode-review");
    expect(onSelectAgent).not.toHaveBeenCalled();
  });

  it("a press without movement is a plain click, not a drag", () => {
    const onReorder = vi.fn();
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={onReorder} />,
    );
    const from = screen.getByText("muya-all").closest("button")!;
    fireEvent.pointerDown(from, { button: 0 });
    window.dispatchEvent(new MouseEvent("pointerup", { clientX: 1, clientY: 1 }));
    fireEvent.click(from);
    expect(onReorder).not.toHaveBeenCalled();
    expect(onSelectAgent).toHaveBeenCalledWith("muya-all");
  });

  it("dropModeAt: the middle half groups, the edges reorder", () => {
    const rect = { top: 100, height: 40 };
    expect(dropModeAt(120, rect)).toBe("group");
    expect(dropModeAt(105, rect)).toBe("reorder");
    expect(dropModeAt(135, rect)).toBe("reorder");
  });

  it("a drop on the middle of a row groups instead of reordering; an edge drop still reorders", () => {
    const onReorder = vi.fn();
    const onGroup = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={onReorder} onGroup={onGroup} />,
    );
    const from = screen.getByText("muya-all").closest("button")!;
    const to = screen.getByText("opencode-review").closest("button")!;
    to.getBoundingClientRect = rowRect;
    pointerDrag(from, to, 20);
    expect(onGroup).toHaveBeenCalledWith("muya-all", "opencode-review");
    expect(onReorder).not.toHaveBeenCalled();
    pointerDrag(from, to, 2);
    expect(onReorder).toHaveBeenCalledWith("muya-all", "opencode-review");
  });

  it("a drop on a split's header joins that split; a member dropped on its own split does nothing", () => {
    const onGroupInto = vi.fn();
    const [a, b, c] = previewAgents;
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} onGroupInto={onGroupInto} splitGroups={[{ id: "g1", keys: [a.key, b.key], collapsed: false }]} />,
    );
    const header = screen.getByTitle("Show this split").parentElement!;
    pointerDrag(screen.getAllByText(c.name)[0].closest("button")!, header);
    expect(onGroupInto).toHaveBeenCalledWith(c.key, "g1");
    onGroupInto.mockClear();
    pointerDrag(screen.getAllByText(a.name)[0].closest("button")!, header);
    expect(onGroupInto).not.toHaveBeenCalled();
  });

  it("rows are not HTML5-draggable (the Tauri webview would show the file-drop hint)", () => {
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    expect(screen.getByText("muya-all").closest("button")!.getAttribute("draggable")).not.toBe("true");
  });

  it("⌘1 selects the first agent in list order", () => {
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    fireEvent.keyDown(window, { key: "1", metaKey: true });
    expect(onSelectAgent).toHaveBeenCalledWith(previewAgents[0].key);
  });

  it("lists a pinned agent under PINNED and not in its status group", () => {
    render(
      <AgentList agents={previewAgents} pinnedKeys={new Set(["iptv-2a"])} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    const pinned = screen.getByText("PINNED").parentElement!;
    const idle = screen.getByText("IDLE").parentElement!;
    expect(within(pinned).getByText("iptv-2a")).toBeInTheDocument();
    expect(within(idle).queryByText("iptv-2a")).not.toBeInTheDocument();
    expect(within(idle).getByText("numbat-c3")).toBeInTheDocument();
  });

  it("shows no PINNED group when nothing is pinned", () => {
    render(
      <AgentList agents={previewAgents} pinnedKeys={new Set()} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    expect(screen.queryByText("PINNED")).not.toBeInTheDocument();
  });

  it("⌘1 selects the pinned agent when it is first on screen", () => {
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} pinnedKeys={new Set(["numbat-c3"])} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    fireEvent.keyDown(window, { key: "1", metaKey: true });
    expect(onSelectAgent).toHaveBeenCalledWith("numbat-c3");
  });

  it("+ New agent calls onNewAgent", () => {
    const onNewAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={onNewAgent} onReorder={vi.fn()} />,
    );
    fireEvent.click(screen.getByText("+ New agent"));
    expect(onNewAgent).toHaveBeenCalled();
  });

  it("the × on a session closes it without selecting it", () => {
    const onCloseAgent = vi.fn();
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={vi.fn()} onCloseAgent={onCloseAgent} />,
    );
    expect(screen.getAllByRole("button", { name: /^Close / })).toHaveLength(previewAgents.length);
    fireEvent.click(screen.getByRole("button", { name: "Close muya-all" }));
    expect(onCloseAgent).toHaveBeenCalledWith("muya-all");
    expect(onSelectAgent).not.toHaveBeenCalled();
  });

  it("past COMPACT_AFTER sessions every session is a one-line row", () => {
    const many = Array.from({ length: COMPACT_AFTER + 1 }, (_, i) => ({ ...previewAgents[i % previewAgents.length], key: `k${i}`, name: `term ${i}` }));
    const { container, rerender } = render(
      <AgentList agents={many.slice(0, COMPACT_AFTER)} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    expect(container.querySelectorAll(".rd-agent-card").length).toBeGreaterThan(0);
    rerender(<AgentList agents={many} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={vi.fn()} />);
    expect(container.querySelectorAll(".rd-agent-card")).toHaveLength(0);
    expect(container.querySelectorAll(".rd-idle-row")).toHaveLength(many.length);
  });
});
