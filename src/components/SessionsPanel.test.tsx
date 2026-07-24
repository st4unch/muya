import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import SessionsPanel from "./SessionsPanel";

const noop = () => {};

function renderPanel(waiting?: Set<string>) {
  return render(
    <SessionsPanel
      terminals={[
        { key: "t-wait", name: "needs-you", cwd: "/tmp/a", isClaude: true },
        { key: "t-ok", name: "busy-one", cwd: "/tmp/b", isClaude: true },
      ]}
      activeKey={null}
      terminalPtyIds={{ "t-wait": "pty-1", "t-ok": "pty-2" }}
      waitingKeys={waiting}
      renamingKey={null}
      renameValue=""
      setRenamingKey={noop}
      setRenameValue={noop}
      onActivate={noop}
      onClose={noop}
      onReorder={noop}
      onRename={noop}
    />,
  );
}

describe("SessionsPanel — needs-decision blink", () => {
  it("blinks only the tab whose session is waiting for the operator", () => {
    renderPanel(new Set(["t-wait"]));

    // The waiting tab shows the attention badge; the other one does not.
    const badges = screen.getAllByText(/NEEDS YOU/i);
    expect(badges).toHaveLength(1);

    // The waiting row carries the blink class; the busy row does not. Walk up
    // from each name to its row container (the element with the border classes).
    const waitRow = screen.getByText("needs-you").closest(".session-needs-decision");
    expect(waitRow).not.toBeNull();
    const okRow = screen.getByText("busy-one").closest(".session-needs-decision");
    expect(okRow).toBeNull();
  });

  it("no blink when nothing is waiting", () => {
    renderPanel(new Set());
    expect(screen.queryByText(/NEEDS YOU/i)).toBeNull();
    expect(document.querySelector(".session-needs-decision")).toBeNull();
  });

  it("tolerates an undefined waitingKeys prop", () => {
    renderPanel(undefined);
    expect(screen.queryByText(/NEEDS YOU/i)).toBeNull();
  });
});
