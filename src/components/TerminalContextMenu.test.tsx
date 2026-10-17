import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import TerminalContextMenu, { type TerminalMenuActions } from "./TerminalContextMenu";

function actions(): TerminalMenuActions {
  return { copy: vi.fn(), paste: vi.fn(), pasteAsPath: vi.fn(), selectAll: vi.fn(), openLink: vi.fn(), find: vi.fn(), clear: vi.fn(), font: vi.fn() };
}

describe("TerminalContextMenu", () => {
  it("disables Copy without a selection and hides Open Link without a URL", () => {
    render(<TerminalContextMenu x={10} y={10} hasSelection={false} actions={actions()} onClose={() => {}} />);
    expect(screen.getByRole("menuitem", { name: /Copy/ })).toBeDisabled();
    expect(screen.queryByRole("menuitem", { name: /Open Link/ })).toBeNull();
  });

  it("each item closes the menu and runs its action", () => {
    const a = actions();
    const onClose = vi.fn();
    render(<TerminalContextMenu x={10} y={10} hasSelection link="https://a.com" actions={a} onClose={onClose} />);
    const click = (name: RegExp) => fireEvent.click(screen.getByRole("menuitem", { name }));
    click(/^Copy/); click(/^Paste⌘V|^Paste$/); click(/Paste as Path/); click(/Select All/);
    click(/Open Link/); click(/Find/); click(/Clear Scrollback/);
    click(/Bigger Text/); click(/Smaller Text/); click(/Default Text Size/);
    expect(a.copy).toHaveBeenCalled();
    expect(a.paste).toHaveBeenCalled();
    expect(a.pasteAsPath).toHaveBeenCalled();
    expect(a.selectAll).toHaveBeenCalled();
    expect(a.openLink).toHaveBeenCalled();
    expect(a.find).toHaveBeenCalled();
    expect(a.clear).toHaveBeenCalled();
    expect(a.font).toHaveBeenNthCalledWith(1, 1);
    expect(a.font).toHaveBeenNthCalledWith(2, -1);
    expect(a.font).toHaveBeenNthCalledWith(3, 0);
    expect(onClose).toHaveBeenCalledTimes(10);
  });
});
