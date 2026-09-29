import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { AgentList } from "./AgentList";
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

  it("selecting a card calls onSelectAgent with its key", () => {
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    fireEvent.click(screen.getByText("muya-all"));
    expect(onSelectAgent).toHaveBeenCalledWith("muya-all");
  });

  it("drag-and-drop calls onReorder(from, to)", () => {
    const onReorder = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={vi.fn()} onReorder={onReorder} />,
    );
    const from = screen.getByText("muya-all").closest("button")!;
    const to = screen.getByText("opencode-review").closest("button")!;
    fireEvent.dragStart(from);
    fireEvent.dragOver(to);
    fireEvent.drop(to);
    expect(onReorder).toHaveBeenCalledWith("muya-all", "opencode-review");
  });

  it("⌘1 selects the first agent in list order", () => {
    const onSelectAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={onSelectAgent} onNewAgent={vi.fn()} onReorder={vi.fn()} />,
    );
    fireEvent.keyDown(window, { key: "1", metaKey: true });
    expect(onSelectAgent).toHaveBeenCalledWith(previewAgents[0].key);
  });

  it("+ New agent calls onNewAgent", () => {
    const onNewAgent = vi.fn();
    render(
      <AgentList agents={previewAgents} selectedKey={null} filter="all" onFilterChange={vi.fn()} onSelectAgent={vi.fn()} onNewAgent={onNewAgent} onReorder={vi.fn()} />,
    );
    fireEvent.click(screen.getByText("+ New agent"));
    expect(onNewAgent).toHaveBeenCalled();
  });
});
