import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Inspector } from "./Inspector";
import { previewAgents, previewInspector } from "./previewFixture";

describe("Inspector", () => {
  it("shows one approval card per waiting agent and wires Allow/Deny/Open", () => {
    const onApprove = vi.fn();
    const onDeny = vi.fn();
    const onOpen = vi.fn();
    const waiting = previewAgents.filter((a) => a.status === "waiting");
    render(
      <Inspector
        waitingAgents={waiting}
        onApprove={onApprove}
        onDeny={onDeny}
        onOpen={onOpen}
        activeTab="changes"
        onTabChange={vi.fn()}
        inspector={previewInspector}
        onReviewDiff={vi.fn()}
        onCommit={vi.fn()}
      />,
    );
    expect(screen.getByText("NEEDS APPROVAL")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Allow" }));
    expect(onApprove).toHaveBeenCalledWith("documents-44");
    fireEvent.click(screen.getByRole("button", { name: /Deny/ }));
    expect(onDeny).toHaveBeenCalledWith("documents-44");
    fireEvent.click(screen.getByRole("button", { name: "Open" }));
    expect(onOpen).toHaveBeenCalledWith("documents-44");
  });

  it("hides the approvals section when nothing is waiting", () => {
    render(
      <Inspector
        waitingAgents={[]}
        onApprove={vi.fn()}
        onDeny={vi.fn()}
        onOpen={vi.fn()}
        activeTab="changes"
        onTabChange={vi.fn()}
        inspector={previewInspector}
        onReviewDiff={vi.fn()}
        onCommit={vi.fn()}
      />,
    );
    expect(screen.queryByText("NEEDS APPROVAL")).not.toBeInTheDocument();
  });

  it("shows the first 3 changes and a '+ N more files' row", () => {
    render(
      <Inspector
        waitingAgents={[]}
        onApprove={vi.fn()}
        onDeny={vi.fn()}
        onOpen={vi.fn()}
        activeTab="changes"
        onTabChange={vi.fn()}
        inspector={previewInspector}
        onReviewDiff={vi.fn()}
        onCommit={vi.fn()}
      />,
    );
    expect(screen.getByText("src-tauri/src/pty.rs")).toBeInTheDocument();
    expect(screen.getByText("+ 11 more files")).toBeInTheDocument();
  });

  it("switching tabs calls onTabChange", () => {
    const onTabChange = vi.fn();
    render(
      <Inspector
        waitingAgents={[]}
        onApprove={vi.fn()}
        onDeny={vi.fn()}
        onOpen={vi.fn()}
        activeTab="changes"
        onTabChange={onTabChange}
        inspector={previewInspector}
        onReviewDiff={vi.fn()}
        onCommit={vi.fn()}
        filesSlot={<div>files here</div>}
      />,
    );
    fireEvent.click(screen.getByRole("tab", { name: "Files" }));
    expect(onTabChange).toHaveBeenCalledWith("files");
  });

  it("renders the no-conflicts success card when collisions is empty", () => {
    render(
      <Inspector
        waitingAgents={[]}
        onApprove={vi.fn()}
        onDeny={vi.fn()}
        onOpen={vi.fn()}
        activeTab="changes"
        onTabChange={vi.fn()}
        inspector={previewInspector}
        onReviewDiff={vi.fn()}
        onCommit={vi.fn()}
      />,
    );
    expect(screen.getByText("No file conflicts")).toBeInTheDocument();
  });

  it("renders the conflict card when collisions exist", () => {
    render(
      <Inspector
        waitingAgents={[]}
        onApprove={vi.fn()}
        onDeny={vi.fn()}
        onOpen={vi.fn()}
        activeTab="changes"
        onTabChange={vi.fn()}
        inspector={{ ...previewInspector, collisions: [{ file: "src/a.ts", worktrees: ["wt1", "wt2"] }] }}
        onReviewDiff={vi.fn()}
        onCommit={vi.fn()}
      />,
    );
    expect(screen.getByText("File conflicts")).toBeInTheDocument();
    expect(screen.getByText(/src\/a\.ts/)).toBeInTheDocument();
  });
});
