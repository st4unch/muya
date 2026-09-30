import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { GridPanel } from "./GridPanel";
import { previewAgents } from "./previewFixture";

const waitingAgent = previewAgents[0]; // documents-44
const workingAgent = previewAgents[1]; // muya-all
const idleAgent = previewAgents[3]; // iptv-2a

function renderPanel(agent = waitingAgent, overrides: Partial<React.ComponentProps<typeof GridPanel>> = {}) {
  const onApprove = vi.fn();
  const onDeny = vi.fn();
  render(
    <GridPanel
      agent={agent}
      focused
      onFocus={vi.fn()}
      onMaximize={vi.fn()}
      onApprove={onApprove}
      onDeny={onDeny}
      onAlwaysAllow={vi.fn()}
      composerValue=""
      onComposerChange={vi.fn()}
      onSendMessage={vi.fn()}
      {...overrides}
    />,
  );
  return { onApprove, onDeny };
}

describe("GridPanel", () => {
  it("Y approves a focused waiting panel", () => {
    const { onApprove } = renderPanel(waitingAgent);
    fireEvent.keyDown(screen.getByRole("region", { name: "documents-44" }), { key: "Y" });
    expect(onApprove).toHaveBeenCalled();
  });

  it("N denies a focused waiting panel", () => {
    const { onDeny } = renderPanel(waitingAgent);
    fireEvent.keyDown(screen.getByRole("region", { name: "documents-44" }), { key: "n" });
    expect(onDeny).toHaveBeenCalled();
  });

  it("Y/N do nothing on a working panel", () => {
    const { onApprove, onDeny } = renderPanel(workingAgent);
    fireEvent.keyDown(screen.getByRole("region", { name: "muya-all" }), { key: "Y" });
    fireEvent.keyDown(screen.getByRole("region", { name: "muya-all" }), { key: "N" });
    expect(onApprove).not.toHaveBeenCalled();
    expect(onDeny).not.toHaveBeenCalled();
  });

  // Live bug: an idle Claude session sits at its prompt waiting for input — the grid
  // used to hide it behind "Waiting for a task", so it could be neither seen nor typed to.
  it("idle panel still shows its terminal and a composer", () => {
    renderPanel(idleAgent);
    expect(document.querySelector(`[data-terminal-slot="${idleAgent.key}"]`)).toBeTruthy();
    expect(screen.getByLabelText(`Message ${idleAgent.name}`)).toBeInTheDocument();
    expect(screen.queryByText("Waiting for a task")).not.toBeInTheDocument();
  });

  it("working panel composer sends on Enter", () => {
    const onSendMessage = vi.fn();
    renderPanel(workingAgent, { composerValue: "hi", onSendMessage });
    fireEvent.keyDown(screen.getByLabelText("Message muya-all"), { key: "Enter" });
    expect(onSendMessage).toHaveBeenCalledWith("hi");
  });
});
