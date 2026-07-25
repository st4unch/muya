import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import SessionsPanel from "./SessionsPanel";

const noop = () => {};

function renderPanel(waiting?: Set<string>, extra?: Partial<React.ComponentProps<typeof SessionsPanel>>) {
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
      {...extra}
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

describe("SessionsPanel — right-click context menu", () => {
  it("shows Duplicate + Reveal in Finder and fires callbacks for the right terminal", () => {
    const onDuplicate = vi.fn();
    const onRevealInFinder = vi.fn();
    renderPanel(undefined, { onDuplicate, onRevealInFinder });

    // Right-click the second terminal's row.
    const row = screen.getByText("busy-one").closest("div");
    fireEvent.contextMenu(row!);

    // Both menu items appear.
    const dup = screen.getByText("Duplicate");
    const reveal = screen.getByText("Reveal in Finder");
    expect(dup).toBeTruthy();
    expect(reveal).toBeTruthy();

    fireEvent.click(dup);
    expect(onDuplicate).toHaveBeenCalledWith("t-ok");

    // Re-open (menu closes after a click) and try reveal.
    fireEvent.contextMenu(screen.getByText("busy-one").closest("div")!);
    fireEvent.click(screen.getByText("Reveal in Finder"));
    expect(onRevealInFinder).toHaveBeenCalledWith("t-ok");
  });

  it("disables Reveal in Finder when the terminal has no cwd", () => {
    const onRevealInFinder = vi.fn();
    render(
      <SessionsPanel
        terminals={[{ key: "t-nocwd", name: "no-dir" }]}
        activeKey={null}
        terminalPtyIds={{}}
        renamingKey={null}
        renameValue=""
        setRenamingKey={noop}
        setRenameValue={noop}
        onActivate={noop}
        onClose={noop}
        onReorder={noop}
        onRename={noop}
        onRevealInFinder={onRevealInFinder}
      />,
    );
    fireEvent.contextMenu(screen.getByText("no-dir").closest("div")!);
    const reveal = screen.getByText("Reveal in Finder").closest("button")!;
    expect(reveal).toBeDisabled();
    fireEvent.click(reveal);
    expect(onRevealInFinder).not.toHaveBeenCalled();
  });

  it("does not open a menu when neither handler is provided", () => {
    renderPanel(undefined);
    fireEvent.contextMenu(screen.getByText("busy-one").closest("div")!);
    expect(screen.queryByText("Duplicate")).toBeNull();
  });
});
